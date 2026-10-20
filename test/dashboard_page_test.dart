import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';
import 'package:moshjid_app/ui/dashboard_page.dart';

/// Returns canned rows instead of reaching Supabase.
class _FakeSync extends SyncService {
  final List<Map<String, dynamic>> rows;

  _FakeSync(this.rows) : super(LocalDb.instance);

  @override
  Future<List<Map<String, dynamic>>?> pullTransactions({
    DateTime? startDate,
    DateTime? endDate,
  }) async => rows;
}

Map<String, dynamic> _txn({
  required String id,
  required String category,
  required String type,
  required double amount,
  String date = '2026-10-19',
}) {
  // The category id is shared by every transaction in the same category, just
  // like transactions.category_id points at one transaction_categories row.
  final categoryId =
      'cat-$type-${category.toLowerCase().replaceAll(' ', '-')}';
  return {
    'id': id,
    'category_id': categoryId,
    'amount': amount,
    'date': date,
    'receipt_number': null,
    'transaction_categories': {
      'id': categoryId,
      'name': category,
      'type': type,
    },
  };
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  List<Map<String, dynamic>> rows,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DashboardPage(
        revision: 0,
        syncing: false,
        pendingTxns: 0,
        pendingMembers: 0,
        onSync: () async {},
        onDataChanged: () async {},
        sync: _FakeSync(rows),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final rows = [
    _txn(id: 'i1', category: 'Imam Hadiya', type: 'income', amount: 500),
    _txn(id: 'e1', category: 'Imam Hadiya', type: 'expense', amount: 3000),
    _txn(id: 'i2', category: 'Friday Collection', type: 'income', amount: 100),
  ];

  testWidgets('shows the type for categories whose name exists under both', (
    tester,
  ) async {
    await _pumpDashboard(tester, rows);

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();

    // Name alone would render two identical "Imam Hadiya" entries.
    expect(find.text('Imam Hadiya (Income)'), findsOneWidget);
    expect(find.text('Imam Hadiya (Expense)'), findsOneWidget);

    await tester.tap(find.text('Imam Hadiya (Expense)').last);
    await tester.pumpAndSettle();

    expect(find.text('Transactions (1)'), findsOneWidget);
    expect(find.text('Income by Category'), findsNothing);
    expect(find.text('Expense by Category'), findsOneWidget);
  });

  testWidgets('the type chip narrows the category options', (tester) async {
    await _pumpDashboard(tester, rows);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Income'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();

    expect(find.text('Imam Hadiya (Income)'), findsOneWidget);
    expect(find.text('Imam Hadiya (Expense)'), findsNothing);
    expect(find.text('Electricity Bill'), findsNothing);
  });
}
