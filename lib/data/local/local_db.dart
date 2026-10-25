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

  static const _version = 5;

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
        // v4 -> v5: donor soft delete. Guarded on oldV >= 4 because a v3 or
        // older install has no profiles_cache yet -- the step above creates it
        // already carrying this column, and adding it twice is a hard error.
        if (oldV >= 4 && oldV < 5) {
          await d.execute(
              'ALTER TABLE $_profileTable ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
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
        status TEXT NOT NULL DEFAULT 'active',
        is_monthly INTEGER NOT NULL DEFAULT 1,
        source TEXT NOT NULL,
        client_created_at TEXT NOT NULL,
        synced_at TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0
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

  Future<Profile?> findProfileByRemoteId(String remoteId) async {
    final d = await db;
    final rows = await d.query(_profileTable,
        where: 'remote_id = ?', whereArgs: [remoteId], limit: 1);
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
    if (existing != null) {
      // Re-adding someone who was removed in error brings them back. Resurrect
      // the same row rather than making a twin: ux_profiles_match_key still
      // reserves their identity on both sides, so a second row could not exist.
      if (existing.isDeleted) {
        await updateProfile(
          id: existing.id,
          fullName: existing.fullName,
          phone: existing.phone,
        );
        return (await findProfileById(existing.id)) ?? existing;
      }
      return existing;
    }

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
  /// caller can never supply the wrong one. The server uuid is preferred when
  /// matching because it is the only handle that survives a rename: identity
  /// ([Profile.matchKey]) changes when the name or phone does, so matching on
  /// it first would miss the local row and the insert would be refused by
  /// `ux_profiles_remote`, leaving the stale details on this device forever.
  ///
  /// Falling back to identity still covers the donor who was typed in offline
  /// and has no uuid yet. When that happens the local row is kept as the
  /// handle -- every transaction points at it and nothing needs repointing --
  /// and it simply adopts the server's uuid and canonical spelling.
  Future<Profile> upsertCloudProfile(Map<String, dynamic> row) async {
    final d = await db;
    final incoming = Profile.fromSupabase(row, localId: const Uuid().v4());
    final remoteId = incoming.remoteId;

    final byRemote =
        remoteId == null ? null : await findProfileByRemoteId(remoteId);
    final existing = byRemote ?? await findProfileByMatchKey(incoming.matchKey);

    if (existing != null) {
      // An edit or delete made here but not yet uploaded outranks whatever the
      // server still says. pullProfiles runs before pushProfiles, so taking
      // `incoming` here would discard the queued change; stamping `syncedAt`
      // would drop it for good. A never-pushed donor has no uuid, so it is not
      // protected -- there the server's canonical version wins.
      if (existing.remoteId != null && existing.isPending) return existing;

      final merged = existing.copyWith(
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
        clientCreatedAt:
            incoming.clientCreatedAt.isBefore(existing.clientCreatedAt)
                ? incoming.clientCreatedAt
                : existing.clientCreatedAt,
        isDeleted: incoming.isDeleted,
        syncedAt: DateTime.now(),
      );
      await d.update(_profileTable, merged.toLocalMap(),
          where: 'id = ?', whereArgs: [existing.id]);
      return merged;
    }

    // The server knows this person and we have never seen them. The row keeps
    // the freshly minted local id so transactions never hold a server uuid.
    await d.insert(_profileTable, incoming.toLocalMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await findProfileByMatchKey(incoming.matchKey)) ?? incoming;
  }

  /// Hides cached donors the server no longer considers live.
  ///
  /// Only rows that came *from* the server and carry a remote id are eligible.
  /// A donor still pending on this device has no remote id and is never touched,
  /// so pulling while offline work is queued cannot lose it.
  ///
  /// This is a soft delete, not a row removal: `transactions_local.member_id`
  /// still points at the row, so the payment history keeps resolving to the same
  /// member even after the server drops them. Already-deleted rows are skipped,
  /// which is what preserves a delete this device made and has not uploaded yet.
  Future<int> pruneCloudProfiles(Set<String> liveRemoteIds) async {
    final d = await db;
    final where = StringBuffer('remote_id IS NOT NULL AND is_deleted = 0');
    final args = <Object?>[];
    if (liveRemoteIds.isNotEmpty) {
      // `NOT IN ()` would be a syntax error; an empty live set simply means
      // every cloud donor is gone, which the base predicate already covers.
      final placeholders = List.filled(liveRemoteIds.length, '?').join(',');
      where.write(' AND remote_id NOT IN ($placeholders)');
      args.addAll(liveRemoteIds);
    }
    return d.update(
      _profileTable,
      {'is_deleted': 1, 'synced_at': DateTime.now().toIso8601String()},
      where: where.toString(),
      whereArgs: args.isEmpty ? null : args,
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

  /// Donors whose local copy differs from the server, oldest change first.
  ///
  /// Queued on `synced_at IS NULL`, which is what both a brand new donor and an
  /// edited one look like. Filtering on `remote_id IS NULL` instead would only
  /// ever catch new donors, and every edit would be silently dropped.
  /// Rewrites a donor's details and re-queues it for upload.
  ///
  /// Identity follows the new details: changing the name or phone changes
  /// [Profile.matchKey], and the server's `ux_profiles_match_key` is UNIQUE, so
  /// a collision is refused here rather than being discovered as a 23505 on a
  /// later sync with no way to tell which donor it was.
  ///
  /// The local [Profile.id] and [remoteId] never move, so every transaction that
  /// already points at this donor keeps resolving to them.
  ///
  /// Returns null on success, or a message explaining why it was refused.
  Future<String?> updateProfile({
    required String id,
    required String fullName,
    String? phone,
    bool clearPhone = false,
    bool? isMonthly,
  }) async {
    final d = await db;
    final current = await findProfileById(id);
    if (current == null) return 'This member is no longer on the device.';

    final edited =
        current.applyEdit(fullName: fullName, phone: phone, clearPhone: clearPhone, isMonthly: isMonthly);

    // The unique index on match_key is what stops one person existing twice
    // locally; check it before writing rather than letting the insert fail.
    final clash = await findProfileByMatchKey(edited.matchKey);
    if (clash != null && clash.id != id) {
      return 'Another member already uses this name and phone: ${clash.fullName}.';
    }

    await d.update(_profileTable, edited.toLocalMap(),
        where: 'id = ?', whereArgs: [id]);
    return null;
  }

  /// Flags a donor as deleted locally and re-queues it for upload.
  ///
  /// Not a row removal. `transactions.member_id` is
  /// `ON DELETE SET NULL`, so deleting the profile would strip the member link
  /// from this person's whole payment history. The row stays, hidden from the
  /// roster, and the server is told on the next sync.
  Future<void> softDeleteProfile(String id) async {
    final d = await db;
    final current = await findProfileById(id);
    if (current == null) return;
    // asDeleted drops syncedAt, which is what puts it back in the push queue.
    await d.update(_profileTable, current.asDeleted.toLocalMap(),
        where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Profile>> pendingProfiles() async {
    final d = await db;
    final rows = await d.query(_profileTable,
        where: 'synced_at IS NULL', orderBy: 'client_created_at ASC');
    return rows.map(Profile.fromLocalMap).toList();
  }

  Future<int> pendingProfileCount() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) as c FROM $_profileTable WHERE synced_at IS NULL');
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

    final where = <String>['is_deleted = 0'];
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

  /// Every donor, for the picker's unfiltered fallback. Deleted donors are
  /// excluded; use [findProfileById] to reach one whose history still matters.
  Future<List<Profile>> allProfiles({bool includeStaff = false}) async {
    final d = await db;
    final rows = await d.query(
      _profileTable,
      where: includeStaff ? 'is_deleted = 0' : 'role = ? AND is_deleted = 0',
      whereArgs: includeStaff ? null : [ProfileRole.member],
      orderBy: 'name_key ASC',
    );
    return rows.map(Profile.fromLocalMap).toList();
  }
}