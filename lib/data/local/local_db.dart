import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/txn.dart';

/// Minimal offline store. All inserts go here first; sync flips `synced_at`.
class LocalDb {
  static const _dbName = 'moshjid.db';
  static const _txnTable = 'transactions_local';
  static const _catTable = 'categories_cache';
  Database? _db;

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    // sqflite method-channel has no Linux/desktop implementation;
    // use ffi there (Android/iOS keep the default factory).
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (d, v) async {
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
            is_deleted INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await d.execute(
            'CREATE INDEX idx_txn_synced ON $_txnTable(synced_at)');
        await d.execute('''
          CREATE TABLE $_catTable(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          await d.execute(
              'ALTER TABLE $_txnTable ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
    return _db!;
  }

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

  Future<String?> resolveCategoryId(String name) async {
    final d = await db;
    final rows = await d.query(_catTable,
        columns: ['id'], where: 'name = ?', whereArgs: [name], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['id'] as String?;
  }
}