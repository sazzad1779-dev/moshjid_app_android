import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/txn.dart';
import '../models/txn_summary.dart';

/// Minimal offline store. All inserts go here first; sync flips `synced_at`.
///
/// The underlying sqflite handle is process-wide: creating several
/// `LocalDb` wrappers is cheap and safe, they all share one connection.
class LocalDb {
  static const _dbName = 'moshjid.db';
  static const _txnTable = 'transactions_local';
  static const _catTable = 'categories_cache';
  static const dbVersion = 3;

  static Database? _shared;
  static Future<Database>? _opening;

  final Database? _injected;

  /// [database] lets tests (and previews) supply their own handle, e.g. an
  /// in-memory database built with [createSchema].
  LocalDb({Database? database}) : _injected = database;

  Future<Database> get db async {
    final provided = _injected;
    if (provided != null) return provided;
    final existing = _shared;
    if (existing != null) return existing;
    final pending = _opening;
    if (pending != null) return pending;
    final opening = _open();
    _opening = opening;
    try {
      return await opening;
    } finally {
      _opening = null;
    }
  }

  static Future<Database> _open() async {
    // sqflite method-channel has no Linux/desktop implementation;
    // use ffi there (Android/iOS keep the default factory).
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    final database = await openDatabase(
      path,
      version: dbVersion,
      onCreate: createSchema,
      onUpgrade: migrateSchema,
    );
    _shared = database;
    return database;
  }

  /// Test hook: forget the process-wide handle.
  static void resetSharedForTesting() => _shared = null;

  static Future<void> createSchema(Database d, int version) async {
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
            client_created_at TEXT NOT NULL,
            synced_at TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            is_new INTEGER NOT NULL DEFAULT 1
          )
        ''');
    await d.execute('CREATE INDEX idx_txn_synced ON $_txnTable(synced_at)');
    await d.execute(
      'CREATE INDEX idx_txn_date ON $_txnTable(date, is_deleted)',
    );
    await d.execute('''
          CREATE TABLE $_catTable(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL
          )
        ''');
  }

  static Future<void> migrateSchema(Database d, int oldV, int newV) async {
    if (oldV < 2) {
      await d.execute(
        'ALTER TABLE $_txnTable '
        'ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 3) {
      await d.execute(
        'ALTER TABLE $_txnTable '
        'ADD COLUMN is_new INTEGER NOT NULL DEFAULT 1',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_txn_date ON $_txnTable(date, is_deleted)',
      );
    }
  }

  // ---- transactions ----

  Future<void> insertTxn(Txn t) async {
    final d = await db;
    await d.insert(
      _txnTable,
      t.toLocalMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> insertTxns(List<Txn> ts) async {
    if (ts.isEmpty) return 0;
    final d = await db;
    final batch = d.batch();
    for (final t in ts) {
      batch.insert(
        _txnTable,
        t.toLocalMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    return ts.length;
  }

  /// One page of transactions, newest first. Use [totalTxns] with the same
  /// filters to drive a pager — the list is deliberately not truncated.
  Future<List<Txn>> listTxns({
    int limit = 50,
    int offset = 0,
    String? type,
    DateTime? from,
    DateTime? to,
    String search = '',
  }) async {
    final d = await db;
    final rows = await d.query(
      _txnTable,
      where: _where(type: type, from: from, to: to, search: search),
      whereArgs: _args(type: type, from: from, to: to, search: search),
      orderBy: 'date DESC, client_created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Txn.fromLocalMap).toList();
  }

  Future<int> totalTxns({
    String? type,
    DateTime? from,
    DateTime? to,
    String search = '',
  }) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT COUNT(*) as c FROM $_txnTable WHERE ${_where(type: type, from: from, to: to, search: search)}',
      _args(type: type, from: from, to: to, search: search),
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// Income / expense / count over a range, aggregated by the database.
  Future<TxnSummary> summarize({DateTime? from, DateTime? to}) async {
    final d = await db;
    final r = await d.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income'  THEN amount END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN amount END), 0) AS expense,
        COUNT(*) AS c
      FROM $_txnTable
      WHERE ${_where(type: null, from: from, to: to, search: '')}
    ''', _args(type: null, from: from, to: to, search: ''));
    final row = r.first;
    return TxnSummary(
      income: (row['income'] as num?)?.toDouble() ?? 0,
      expense: (row['expense'] as num?)?.toDouble() ?? 0,
      count: (row['c'] as int?) ?? 0,
    );
  }

  /// Soft-delete: hidden locally, upserted as is_deleted on next sync.
  Future<void> softDelete(String id) async {
    final d = await db;
    await d.update(
      _txnTable,
      {'is_deleted': 1, 'synced_at': null, 'is_new': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Txn>> pendingTxns() async {
    final d = await db;
    final rows = await d.query(
      _txnTable,
      where: 'synced_at IS NULL',
      orderBy: 'client_created_at ASC',
    );
    return rows.map(Txn.fromLocalMap).toList();
  }

  Future<int> pendingCount() async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT COUNT(*) as c FROM $_txnTable '
      'WHERE synced_at IS NULL AND is_deleted = 0',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> markSynced(String id, DateTime when) async {
    final d = await db;
    await d.update(
      _txnTable,
      {'synced_at': when.toIso8601String(), 'is_new': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markManySynced(List<String> ids, DateTime when) async {
    if (ids.isEmpty) return;
    final d = await db;
    final batch = d.batch();
    for (final id in ids) {
      batch.update(
        _txnTable,
        {'synced_at': when.toIso8601String(), 'is_new': 0},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  // ---- categories cache ----

  Future<void> cacheCategories(List<Map<String, dynamic>> cats) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete(_catTable);
      final batch = txn.batch();
      for (final c in cats) {
        batch.insert(_catTable, {
          'id': c['id'],
          'name': c['name'],
          'type': c['type'],
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, dynamic>>> cachedCategories(String type) async {
    final d = await db;
    return d.query(
      _catTable,
      where: 'type = ?',
      whereArgs: [type],
      orderBy: 'name ASC',
    );
  }

  /// Name -> id map for one type, resolved in a single query so a sync of
  /// hundreds of rows does not issue hundreds of lookups.
  Future<Map<String, String>> categoryIdMap(String type) async {
    final d = await db;
    final rows = await d.query(
      _catTable,
      columns: ['name', 'id'],
      where: 'type = ?',
      whereArgs: [type],
    );
    return {for (final r in rows) r['name'] as String: r['id'] as String};
  }

  Future<String?> resolveCategoryId(String name) async {
    final d = await db;
    final rows = await d.query(
      _catTable,
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String?;
  }

  // ---- filter helpers ----

  static String _where({
    String? type,
    DateTime? from,
    DateTime? to,
    String search = '',
  }) {
    final parts = ['is_deleted = 0'];
    if (type != null && type != 'all') parts.add('type = ?');
    if (from != null) parts.add('date >= ?');
    if (to != null) parts.add('date <= ?');
    final q = search.trim();
    if (q.isNotEmpty) {
      parts.add(
        '(category LIKE ? OR description LIKE ? '
        'OR receipt_number LIKE ?)',
      );
    }
    return parts.join(' AND ');
  }

  static List<Object?> _args({
    String? type,
    DateTime? from,
    DateTime? to,
    String search = '',
  }) {
    final args = <Object?>[];
    if (type != null && type != 'all') args.add(type);
    if (from != null) args.add(Txn.dateKey(from));
    if (to != null) args.add(Txn.dateKey(to));
    final q = search.trim();
    if (q.isNotEmpty) args.addAll(['%$q%', '%$q%', '%$q%']);
    return args;
  }
}
