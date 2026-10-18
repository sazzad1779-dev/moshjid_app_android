import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/name_key.dart';
import '../models/profile.dart';
import '../models/txn.dart';

/// Offline store. All inserts go here first; sync flips `synced_at`.
///
/// Use [instance]. The database is a single file, and this class is the only
/// thing that opens it.
class LocalDb {
  static const _dbName = 'moshjid.db';
  static const _txnTable = 'transactions_local';
  static const _catTable = 'categories_cache';
  static const _profileTable = 'profiles_cache';

  static const _version = 4;

  /// The one open handle used by the app.
  static final LocalDb instance = LocalDb._();

  /// Test seam: an alternate file for this instance only.
  final String? pathOverride;

  LocalDb._({this.pathOverride});

  /// Runs [body] against a throwaway database file, then deletes it.
  static Future<T> withTempDb<T>(Future<T> Function(LocalDb db) body) async {
    _ensureFfi();
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'moshjid_test_${const Uuid().v4()}.db');
    final temp = LocalDb._(pathOverride: path);
    try {
      return await body(temp);
    } finally {
      await temp.close();
      await deleteDatabase(path);
    }
  }

  Database? _db;

  /// Closes the handle. Used by tests to force a reopen, and by
  /// [withTempDb] so the file can be deleted.
  Future<void> close() async {
    final existing = _db;
    _db = null;
    await existing?.close();
  }

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    _ensureFfi();
    final dir = await getDatabasesPath();
    final path = pathOverride ?? p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: (d, v) async {
        await _createSchema(d);
      },
      onUpgrade: (d, oldV, newV) async {
        // v1 -> v2: soft delete
        if (oldV < 2) {
          await d.execute(
              'ALTER TABLE $_txnTable ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
        }
        // v2 -> v3: date index, and backfill category_id from the cache
        if (oldV < 3) {
          await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_txn_date ON $_txnTable(date DESC)');
          await d.execute(
              'UPDATE $_txnTable SET category_id = (SELECT c.id FROM $_catTable c '
              'WHERE c.name = $_txnTable.category AND c.type = $_txnTable.type) '
              'WHERE category_id IS NULL');
        }
        // v3 -> v4: donors
        if (oldV < 4) {
          await _createProfiles(d);
          await _addTxnDonorColumns(d);
        }
      },
    );
    return _db!;
  }

  /// sqflite's method channel has no Linux/desktop implementation, so desktop
  /// runs go through ffi. Android and iOS keep the default factory.
  static void _ensureFfi() {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> _createSchema(Database d) async {
    await d.execute('''
      CREATE TABLE $_txnTable(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        category TEXT NOT NULL,
        category_id TEXT,
        amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        status TEXT NOT NULL,
        description TEXT,
        receipt_number TEXT,
        date TEXT NOT NULL,
        entered_by TEXT NOT NULL,
        member_id TEXT,
        donor_name TEXT,
        donor_phone TEXT,
        client_created_at TEXT NOT NULL,
        synced_at TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await d.execute(
        'CREATE INDEX idx_txn_synced ON $_txnTable(synced_at)');
    await d.execute(
        'CREATE INDEX idx_txn_date ON $_txnTable(date DESC)');
    await d.execute(
        'CREATE INDEX idx_txn_member ON $_txnTable(member_id)');
    await d.execute('''
      CREATE TABLE $_catTable(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL
      )
    ''');
    await _createProfiles(d);
  }

  Future<void> _createProfiles(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS $_profileTable(
        id TEXT PRIMARY KEY,
        remote_id TEXT,
        full_name TEXT NOT NULL,
        name_key TEXT NOT NULL,
        phone TEXT,
        phone_key TEXT,
        match_key TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'member',
        status TEXT NOT NULL DEFAULT 'approved',
        is_monthly INTEGER NOT NULL DEFAULT 1,
        source TEXT NOT NULL,
        client_created_at TEXT NOT NULL,
        synced_at TEXT
      )
    ''');
    // The offline "keep the first one" rule, enforced by SQLite. Inserting a
    // second donor with the same match_key is a no-op, so typing the same name
    // twice while offline yields one row rather than two.
    await d.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS ux_profiles_match ON $_profileTable(match_key)');
    // A donor can have at most one server row, and one server row can only be
    // adopted by one local row.
    await d.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS ux_profiles_remote ON $_profileTable(remote_id) '
        'WHERE remote_id IS NOT NULL');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS ix_profiles_name ON $_profileTable(name_key)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS ix_profiles_pending ON $_profileTable(synced_at)');
  }

  /// Additive only, so this runs against existing installs without a table
  /// rebuild. `IF NOT EXISTS` keeps it safe on the v1..v3 code paths that reach
  /// here via a fresh onCreate.
  Future<void> _addTxnDonorColumns(Database d) async {
    for (final col in ['member_id', 'donor_name', 'donor_phone']) {
      await d.execute('ALTER TABLE $_txnTable ADD COLUMN $col TEXT');
    }
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_txn_member ON $_txnTable(member_id)');
  }

  // ---- transactions ----

  Future<void> insertTxn(Txn t) async {
    final d = await db;
    await d.insert(_txnTable, t.toLocalMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Txn>> listTxns({int limit = 200}) async {
    final d = await db;
    final rows = await d.query(_txnTable,
        where: 'is_deleted = 0',
        orderBy: 'date DESC, client_created_at DESC',
        limit: limit);
    return rows.map(Txn.fromLocalMap).toList();
  }

  /// Soft-delete: hidden locally, upserted as is_deleted on next sync.
  Future<void> softDelete(String id) async {
    final d = await db;
    await d.update(_txnTable, {'is_deleted': 1, 'synced_at': null},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Txn>> pendingTxns() async {
    final d = await db;
    final rows = await d
        .query(_txnTable, where: 'synced_at IS NULL', orderBy: 'client_created_at ASC');
    return rows.map(Txn.fromLocalMap).toList();
  }

  Future<int> pendingCount() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) as c FROM $_txnTable WHERE synced_at IS NULL AND is_deleted = 0');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> markSynced(String id, DateTime when) async {
    final d = await db;
    await d.update(_txnTable, {'synced_at': when.toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---- categories cache ----
  Future<void> cacheCategories(List<Map<String, dynamic>> cats) async {
    final d = await db;
    final batch = d.batch();
    batch.delete(_catTable);
    for (final c in cats) {
      batch.insert(_catTable, {
        'id': c['id'],
        'name': c['name'],
        'type': c['type'],
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> cachedCategories(String type) async {
    final d = await db;
    return d.query(_catTable, where: 'type = ?', whereArgs: [type], orderBy: 'name ASC');
  }

  /// Resolves the server uuid for a category. The same name can exist under
  /// more than one type (e.g. "Other" and "Imam Hadiya"), so [type] is part of
  /// the lookup key -- matching on name alone returns an arbitrary row.
  Future<String?> resolveCategoryId(String name, String type) async {
    final d = await db;
    final rows = await d.query(_catTable,
        columns: ['id'],
        where: 'name = ? AND type = ?',
        whereArgs: [name, type],
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['id'] as String?;
  }

  // ---- profiles / donors ----

  /// Finds a donor by identity, i.e. the same rule the server applies.
  Future<Profile?> findProfileByMatchKey(String matchKey) async {
    final d = await db;
    final rows = await d.query(_profileTable,
        where: 'match_key = ?', whereArgs: [matchKey], limit: 1);
    if (rows.isEmpty) return null;
    return Profile.fromLocalMap(rows.first);
  }

  Future<Profile?> findProfileById(String id) async {
    final d = await db;
    final rows =
        await d.query(_profileTable, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Profile.fromLocalMap(rows.first);
  }

  /// Returns the donor for this identity, creating one if this device has never
  /// seen them.
  ///
  /// The insert is `IGNORE`, so when the donor already exists the existing row
  /// is returned untouched and the incoming name and phone are discarded. That
  /// is the offline half of "keep the first one": the earliest row on this
  /// device wins, exactly as `tools/donor_dedupe.sql` does on the server.
  ///
  /// A later phone number will not upgrade an existing row, because the
  /// match_key of a phone-less donor is `n:<name>` and a phone-bearing one is
  /// `p:<digits>`; they are different identities by design. Editing a donor's
  /// details is not part of the collection flow.
  Future<Profile> ensureProfile({
    required String fullName,
    String? phone,
    bool isMonthly = true,
  }) async {
    final d = await db;
    final matchKey = NameKey.match(name: fullName, phone: phone);

    final existing = await findProfileByMatchKey(matchKey);
    if (existing != null) return existing;

    final created = Profile.create(
      id: const Uuid().v4(),
      fullName: fullName,
      phone: phone,
      isMonthly: isMonthly,
    );
    // A concurrent insert of the same donor loses harmlessly: IGNORE, then read
    // back whoever actually got in.
    await d.insert(_profileTable, created.toLocalMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await findProfileByMatchKey(matchKey)) ?? created;
  }

  /// Inserts or refreshes a donor that came down from the server.
  ///
  /// Takes the raw Supabase row so the local id is always minted here and a
  /// caller can never supply the wrong one. [row] is matched by identity, not
  /// by id: the same donor can already exist here under a local id from when
  /// they were typed in offline. When that happens the local row is kept as the
  /// identity -- every transaction points at it and nothing needs repointing --
  /// and it simply adopts the server's uuid and canonical spelling.
  Future<Profile> upsertCloudProfile(Map<String, dynamic> row) async {
    final d = await db;
    final incoming = Profile.fromSupabase(row, localId: const Uuid().v4());
    final matchKey = incoming.matchKey;

    final byMatch = await findProfileByMatchKey(matchKey);
    if (byMatch != null) {
      final merged = byMatch.copyWith(
        remoteId: incoming.remoteId,
        fullName: incoming.fullName,
        phone: incoming.phone,
        clearPhone: incoming.phone == null,
        role: incoming.role,
        status: incoming.status,
        isMonthly: incoming.isMonthly,
        source: ProfileSource.cloud,
        // The rule is "keep the first": whichever record of this donor dates
        // from further back wins, whoever we learned it from.
        clientCreatedAt: incoming.clientCreatedAt.isBefore(byMatch.clientCreatedAt)
            ? incoming.clientCreatedAt
            : byMatch.clientCreatedAt,
        syncedAt: DateTime.now(),
      );
      await d.update(_profileTable, merged.toLocalMap(),
          where: 'id = ?', whereArgs: [byMatch.id]);
      return merged;
    }

    // The server knows this person and we have never seen them. The row keeps
    // the freshly minted local id so transactions never hold a server uuid.
    await d.insert(_profileTable, incoming.toLocalMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await findProfileByMatchKey(matchKey)) ?? incoming;
  }

  /// Drops cached donors the server no longer has.
  ///
  /// Only rows that came *from* the server and carry a remote id are eligible.
  /// A donor still pending on this device has no remote id and is never touched,
  /// so pulling while offline work is queued cannot lose it.
  Future<int> pruneCloudProfiles(Set<String> liveRemoteIds) async {
    final d = await db;
    if (liveRemoteIds.isEmpty) {
      // The server reported no donors at all. Everything with a remote id is
      // gone; pending local donors are untouched. `NOT IN ()` would be a
      // syntax error, hence the separate branch.
      return d.delete(_profileTable, where: 'remote_id IS NOT NULL');
    }
    final placeholders = List.filled(liveRemoteIds.length, '?').join(',');
    return d.delete(
      _profileTable,
      where: 'remote_id IS NOT NULL AND remote_id NOT IN ($placeholders)',
      whereArgs: liveRemoteIds.toList(),
    );
  }

  /// Records that a donor now exists on the server under [remoteId].
  ///
  /// Called after a push, including when the server folded this device's donor
  /// into a row another device created first. The local id does not change, so
  /// transactions keep pointing at the same donor.
  Future<void> markProfileSynced({
    required String id,
    required String remoteId,
    DateTime? when,
  }) async {
    final d = await db;
    await d.update(
      _profileTable,
      {
        'remote_id': remoteId,
        'synced_at': (when ?? DateTime.now()).toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Profile>> pendingProfiles() async {
    final d = await db;
    final rows = await d.query(_profileTable,
        where: 'remote_id IS NULL', orderBy: 'client_created_at ASC');
    return rows.map(Profile.fromLocalMap).toList();
  }

  Future<int> pendingProfileCount() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) as c FROM $_profileTable WHERE remote_id IS NULL');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Donors matching [query], best first.
  ///
  /// Ranking is prefix-before-substring so typing "tai" surfaces "Taijul Islam"
  /// ahead of every name that merely contains it. An empty [query] returns the
  /// most recently created donors rather than the whole roster, because the
  /// picker only needs a starting list and the rest arrives as the user types.
  ///
  /// Operators (collectors, admins) are excluded unless [includeStaff] is set:
  /// they live in the same table but nobody donates as Sazzad.
  ///
  /// Ordering happens in Dart via [NameKey.rank] rather than in SQL, because the
  /// rank depends on Unicode-aware lowercasing that SQLite's LIKE does not do,
  /// and because a donor name can contain characters that would have to be
  /// escaped into an ORDER BY clause.
  Future<List<Profile>> searchProfiles(
    String query, {
    int limit = 25,
    bool includeStaff = false,
  }) async {
    final d = await db;
    final q = NameKey.name(query);

    final where = <String>[];
    final args = <Object?>[];
    if (!includeStaff) {
      where.add('role = ?');
      args.add(ProfileRole.member);
    }
    if (q.isNotEmpty) {
      where.add('(name_key = ? OR name_key LIKE ?)');
      args..add(q)..add('%$q%');
    }

    final rows = await d.query(
      _profileTable,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      // No query yet: show who was added most recently, so a donor entered a
      // moment ago is already at the top of the picker. With a query, rank in
      // Dart over a wider read instead of capping in SQL.
      orderBy: q.isEmpty ? 'client_created_at DESC' : 'name_key ASC',
      limit: q.isEmpty ? limit : limit * 4,
    );
    final found = rows.map(Profile.fromLocalMap).toList();
    if (q.isEmpty) return found;
    return NameKey.filter(found, q, (Profile p) => p.fullName);
  }

  /// Every transaction recorded against one donor, newest first. Backs the
  /// member detail sheet, so the whole payment history is available offline.
  Future<List<Txn>> txnsForMember(String memberId) async {
    final d = await db;
    final rows = await d.query(_txnTable,
        where: 'member_id = ? AND is_deleted = 0',
        whereArgs: [memberId],
        orderBy: 'date DESC, client_created_at DESC');
    return rows.map(Txn.fromLocalMap).toList();
  }

  /// Total collected from one donor across every transaction, income side only.
  ///
  /// Read in SQL rather than by loading the rows because the member list shows
  /// this on every tile, and the roster is long enough that reading whole rows
  /// to add up a number would be wasteful.
  Future<double> memberTotal(String memberId) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COALESCE(SUM(amount), 0) AS s FROM $_txnTable '
        "WHERE member_id = ? AND is_deleted = 0 AND type = 'income'",
        [memberId]);
    return (r.first['s'] as num?)?.toDouble() ?? 0;
  }

  /// Every donor, for the picker's unfiltered fallback.
  Future<List<Profile>> allProfiles({bool includeStaff = false}) async {
    final d = await db;
    final rows = await d.query(
      _profileTable,
      where: includeStaff ? null : 'role = ?',
      whereArgs: includeStaff ? null : [ProfileRole.member],
      orderBy: 'name_key ASC',
    );
    return rows.map(Profile.fromLocalMap).toList();
  }
}