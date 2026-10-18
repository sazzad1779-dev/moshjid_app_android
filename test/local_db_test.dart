import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/data/repositories/txn_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enteredBy = '00000000-0000-0000-0000-000000000000';

Future<LocalDb> _memDb() async {
  sqfliteFfiInit();
  final d = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      // Every test needs its own store: without this the factory hands out
      // the same cached in-memory database to all callers.
      singleInstance: false,
      version: LocalDb.dbVersion,
      onCreate: LocalDb.createSchema,
      onUpgrade: LocalDb.migrateSchema,
    ),
  );
  return LocalDb(database: d);
}

Txn _txn({
  required String id,
  String type = 'income',
  double amount = 100,
  required DateTime date,
  String category = 'Regular Donation (নিয়মিত দান)',
  String? description,
  bool isDeleted = false,
  DateTime? createdAt,
}) => Txn(
  id: id,
  type: type,
  category: category,
  amount: amount,
  paymentMethod: 'cash',
  status: 'confirmed',
  description: description,
  receiptNumber: 'R-$id',
  date: DateTime(date.year, date.month, date.day),
  enteredBy: _enteredBy,
  clientCreatedAt: createdAt ?? date,
  isDeleted: isDeleted,
);
void main() {
  setUpAll(() => sqfliteFfiInit());

  group('summarize', () {
    test('totals cover every row, not just the loaded page', () async {
      final db = await _memDb();
      // 222 rows: more than one page, which is what used to be truncated.
      final rows = <Txn>[
        for (var i = 0; i < 177; i++)
          _txn(id: 'inc$i', amount: 100, date: DateTime(2026, 6, 1 + (i % 28))),
        for (var i = 0; i < 45; i++)
          _txn(
            id: 'exp$i',
            type: 'expense',
            amount: 50,
            date: DateTime(2026, 7, 1 + (i % 28)),
          ),
      ];
      await db.insertTxns(rows);

      final all = await db.summarize();
      expect(all.income, 177 * 100);
      expect(all.expense, 45 * 50);
      expect(all.balance, 177 * 100 - 45 * 50);
      expect(all.count, 222);

      final june = await db.summarize(
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 30),
      );
      expect(june.income, 177 * 100);
      expect(june.expense, 0);
      expect(june.count, 177);
    });

    test('soft-deleted rows are excluded from totals', () async {
      final db = await _memDb();
      await db.insertTxns([
        _txn(id: 'a', amount: 100, date: DateTime(2026, 6, 1)),
        _txn(id: 'b', amount: 900, date: DateTime(2026, 6, 2)),
      ]);
      await db.softDelete('b');
      final s = await db.summarize();
      expect(s.income, 100);
      expect(s.count, 1);
      // pendingCount() hides deleted rows, but pendingTxns() still returns
      // 'b' — it has to reach the server as is_deleted=true.
      expect(await db.pendingCount(), 1);
      expect((await db.pendingTxns()).map((t) => t.id).toSet(), {'a', 'b'});
    });
  });

  group('listTxns paging and filters', () {
    test('pages through all rows newest first', () async {
      final db = await _memDb();
      await db.insertTxns([
        for (var i = 0; i < 120; i++)
          _txn(
            id: 'id$i',
            amount: i + 1,
            date: DateTime(2026, 6, 1 + (i % 28)),
          ),
      ]);
      expect(await db.totalTxns(), 120);

      final seen = <String>[];
      var offset = 0;
      while (true) {
        final page = await db.listTxns(limit: 50, offset: offset);
        if (page.isEmpty) break;
        seen.addAll(page.map((t) => t.id));
        offset += page.length;
      }
      expect(seen.length, 120);
      expect(seen.toSet().length, 120, reason: 'no duplicates across pages');
    });

    test('filters by type, date range and search text', () async {
      final db = await _memDb();
      await db.insertTxns([
        _txn(id: 'a', amount: 10, date: DateTime(2026, 6, 5)),
        _txn(
          id: 'b',
          type: 'expense',
          amount: 20,
          date: DateTime(2026, 7, 5),
          description: 'electricity',
        ),
        _txn(
          id: 'c',
          type: 'expense',
          amount: 30,
          date: DateTime(2026, 7, 9),
          category: 'Maintenance (রক্ষণাবেক্ষণ)',
        ),
      ]);

      expect((await db.listTxns(type: 'expense')).length, 2);
      expect(
        (await db.listTxns(
          from: DateTime(2026, 7, 1),
          to: DateTime(2026, 7, 31),
        )).length,
        2,
      );
      expect((await db.listTxns(search: 'electricity')).single.id, 'b');
      expect((await db.listTxns(search: 'রক্ষণাবেক্ষণ')).single.id, 'c');
      expect((await db.listTxns(search: 'nothing here')), isEmpty);
    });
  });

  group('sync bookkeeping', () {
    test(
      'markSynced clears the is_new flag so created_at is not rewritten',
      () async {
        final db = await _memDb();
        await db.insertTxn(_txn(id: 'a', date: DateTime(2026, 6, 1)));

        var fresh = (await db.pendingTxns()).single;
        expect(fresh.isNew, true);
        expect(fresh.toSupabaseMap().containsKey('created_at'), true);

        await db.markSynced('a', DateTime(2026, 6, 2));

        // A fresh read (as the next sync run does) must not resend created_at.
        expect(await db.pendingTxns(), isEmpty);
        final stored = await db.listTxns(limit: 1);
        expect(stored.single.isNew, false);
        expect(stored.single.toSupabaseMap().containsKey('created_at'), false);
      },
    );

    test(
      'pendingTxns is ordered oldest-first so sync batches are stable',
      () async {
        final db = await _memDb();
        await db.insertTxns([
          _txn(
            id: 'a',
            date: DateTime(2026, 6, 3),
            createdAt: DateTime(2026, 6, 3, 10),
          ),
          _txn(
            id: 'b',
            date: DateTime(2026, 6, 1),
            createdAt: DateTime(2026, 6, 1, 10),
          ),
          _txn(
            id: 'c',
            date: DateTime(2026, 6, 2),
            createdAt: DateTime(2026, 6, 2, 10),
          ),
        ]);
        expect((await db.pendingTxns()).map((t) => t.id).toList(), [
          'b',
          'c',
          'a',
        ]);
      },
    );

    test('markManySynced clears a whole chunk', () async {
      final db = await _memDb();
      await db.insertTxns([
        for (var i = 0; i < 5; i++)
          _txn(id: 'id$i', date: DateTime(2026, 6, i + 1)),
      ]);
      await db.markManySynced(['id0', 'id1', 'id2'], DateTime(2026, 7, 1));
      expect((await db.pendingTxns()).map((t) => t.id).toList(), [
        'id3',
        'id4',
      ]);
    });
  });

  group('category cache', () {
    test('name to id map is resolved in one query', () async {
      final db = await _memDb();
      await db.cacheCategories([
        {
          'id': 'u1',
          'name': 'Regular Donation (নিয়মিত দান)',
          'type': 'income',
        },
        {'id': 'u2', 'name': 'Friday Collection (জুমার দান)', 'type': 'income'},
        {'id': 'e1', 'name': 'Maintenance (রক্ষণাবেক্ষণ)', 'type': 'expense'},
      ]);
      expect(await db.categoryIdMap('income'), {
        'Regular Donation (নিয়মিত দান)': 'u1',
        'Friday Collection (জুমার দান)': 'u2',
      });
      expect(await db.categoryIdMap('expense'), {
        'Maintenance (রক্ষণাবেক্ষণ)': 'e1',
      });
    });

    test('cacheCategories replaces the previous list', () async {
      final db = await _memDb();
      await db.cacheCategories([
        {'id': 'u1', 'name': 'Old (পুরনো)', 'type': 'income'},
      ]);
      await db.cacheCategories([
        {'id': 'u2', 'name': 'New (নতুন)', 'type': 'income'},
      ]);
      final rows = await db.cachedCategories('income');
      expect(rows.length, 1);
      expect(rows.single['name'], 'New (নতুন)');
    });
  });

  group('TxnRepository', () {
    test(
      'falls back to the built-in categories when the cache is empty',
      () async {
        final repo = TxnRepository(local: await _memDb());
        final cats = await repo.categoryNames(AppCategories.income);
        expect(cats, contains('Imam Salary (ইমামের বেতন)'));
        expect(cats, contains('Electricity Bill (বিদ্যুৎ বিল)'));
      },
    );

    test('load returns a page plus the unpaginated total', () async {
      final repo = TxnRepository(local: await _memDb());
      await repo.saveMany([
        for (var i = 0; i < 60; i++)
          _txn(id: 'id$i', date: DateTime(2026, 6, 1 + (i % 28))),
      ]);
      final page = await repo.load(limit: 25);
      expect(page.items.length, 25);
      expect(page.total, 60);
      expect(page.hasMore, true);
    });

    test('summary honours the date range regardless of type filter', () async {
      final repo = TxnRepository(local: await _memDb());
      await repo.saveMany([
        _txn(id: 'a', amount: 100, date: DateTime(2026, 6, 1)),
        _txn(id: 'b', type: 'expense', amount: 40, date: DateTime(2026, 7, 1)),
      ]);
      expect((await repo.summary()).balance, 60);

      final june = await repo.summary(
        filter: TxnFilter(
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 30),
        ),
      );
      expect(june.income, 100);
      expect(june.expense, 0);
      expect(june.count, 1);

      // A type filter narrows the list, not the balance figures.
      final incomeOnly = await repo.summary(
        filter: const TxnFilter(type: 'income'),
      );
      expect(incomeOnly.balance, 60);
    });

    test('filter copyWith can clear the date range', () async {
      final f = TxnFilter(
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 30),
      );
      expect(f.isEmpty, false);
      expect(f.copyWith(clearRange: true).from, isNull);
      expect(f.copyWith(clearRange: true).to, isNull);
      expect(f.copyWith(type: 'expense').from, DateTime(2026, 6, 1));
      expect(const TxnFilter.all().isEmpty, true);
    });
  });
}
