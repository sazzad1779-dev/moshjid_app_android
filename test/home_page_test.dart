import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/data/repositories/txn_repository.dart';
import 'package:moshjid_app/ui/app_scope.dart';
import 'package:moshjid_app/ui/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enteredBy = '00000000-0000-0000-0000-000000000000';

/// Keeps the plugin off the real platform channel so the page boots
/// offline without hanging.
class _FakeConnectivity extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.none,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

Txn _txn({
  required String id,
  String type = 'income',
  double amount = 100,
  required DateTime date,
  String category = 'Regular Donation (নিয়মিত দান)',
  bool isNew = true,
}) => Txn(
  id: id,
  type: type,
  category: category,
  amount: amount,
  paymentMethod: 'cash',
  status: 'confirmed',
  receiptNumber: 'R-$id',
  date: DateTime(date.year, date.month, date.day),
  enteredBy: _enteredBy,
  clientCreatedAt: date,
  isNew: isNew,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ConnectivityPlatform.instance = _FakeConnectivity();

  Future<TxnRepository> repoWith(List<Txn> rows) async {
    sqfliteFfiInit();
    final d = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        version: LocalDb.dbVersion,
        onCreate: LocalDb.createSchema,
        onUpgrade: LocalDb.migrateSchema,
      ),
    );
    final db = LocalDb(database: d);
    await db.insertTxns(rows);
    return TxnRepository(local: db);
  }

  Future<void> pumpHome(WidgetTester tester, TxnRepository repo) async {
    await tester.pumpWidget(
      AppScope(
        repo: repo,
        child: MaterialApp(home: const HomePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // initial auto-sync
  }

  testWidgets('home page boots and renders totals from the SQL aggregate', (
    tester,
  ) async {
    // 30 income + 10 expense rows: more than one page, so a naive
    // "sum the loaded page" implementation would report the wrong balance.
    final repo = await repoWith([
      for (var i = 0; i < 30; i++)
        _txn(id: 'inc$i', amount: 100, date: DateTime(2026, 6, 1 + (i % 28))),
      for (var i = 0; i < 10; i++)
        _txn(
          id: 'exp$i',
          type: 'expense',
          amount: 250,
          date: DateTime(2026, 7, 1 + (i % 28)),
        ),
    ]);

    await pumpHome(tester, repo);

    expect(find.text('Moshjid Transactions'), findsOneWidget);
    // income 3000, expense 2500, balance 500 — all 40 rows, not 50.
    expect(find.text('3,000'), findsOneWidget);
    expect(find.text('2,500'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('40 total'), findsOneWidget);
  });

  testWidgets('first page shows 50 rows and pages the rest in', (tester) async {
    final repo = await repoWith([
      for (var i = 0; i < 120; i++)
        _txn(id: 'id$i', amount: 10, date: DateTime(2026, 6, 1 + (i % 28))),
    ]);

    await pumpHome(tester, repo);
    expect(find.text('120 total'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(50));

    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ListTile), findsNWidgets(70));
  });

  testWidgets('type tabs filter the list', (tester) async {
    final repo = await repoWith([
      _txn(id: 'a', amount: 100, date: DateTime(2026, 6, 1)),
      _txn(
        id: 'b',
        type: 'expense',
        amount: 40,
        date: DateTime(2026, 6, 2),
        category: 'Maintenance (রক্ষণাবেক্ষণ)',
      ),
    ]);

    await pumpHome(tester, repo);
    expect(find.text('2 total'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Expense'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('1 total'), findsOneWidget);
    expect(find.textContaining('Maintenance'), findsOneWidget);
    expect(find.textContaining('Regular Donation'), findsNothing);
  });

  testWidgets('opening the entry sheet prefills from the category list', (
    tester,
  ) async {
    final repo = await repoWith([]);
    await pumpHome(tester, repo);

    expect(find.text('No transactions yet.\nTap + to add.'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('New transaction'), findsOneWidget);
    // The sheet's category dropdown offers the real bilingual categories.
    expect(find.text('Regular Donation (নিয়মিত দান)'), findsWidgets);
    expect(find.textContaining('Imam Salary'), findsWidgets);
  });
}
