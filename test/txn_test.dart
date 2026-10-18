import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/models/txn.dart';

void main() {
  test('receipt auto-generates when empty', () {
    final t = Txn.create(
      type: 'income',
      category: 'General Donation',
      amount: 100,
      paymentMethod: 'cash',
      enteredBy: '00000000-0000-0000-0000-000000000000',
      receiptNumber: null,
    );
    expect(t.receiptNumber, isNotNull);
    expect(t.receiptNumber, startsWith('R-'));
  });

  test('amount validation', () {
    expect(Txn.validateAmount(null), isNotNull);
    expect(Txn.validateAmount(''), isNotNull);
    expect(Txn.validateAmount('abc'), isNotNull);
    expect(Txn.validateAmount('-5'), isNotNull);
    expect(Txn.validateAmount('0'), isNotNull);
    expect(Txn.validateAmount('250.5'), isNull);
  });

  test('supabase payload has required keys', () {
    final t = Txn.create(
      type: 'expense',
      category: 'Utility Bill',
      amount: 500,
      paymentMethod: 'bkash',
      enteredBy: '00000000-0000-0000-0000-000000000000',
      description: 'Electricity',
    );
    final m = t.toSupabaseMap();
    for (final k in [
      'id',
      'type',
      'amount',
      'payment_method',
      'status',
      'date',
      'entered_by',
      'client_created_at',
      'is_deleted',
    ]) {
      expect(m.containsKey(k), true, reason: 'missing $k');
    }
    expect(m['is_deleted'], false);
  });

  test('edit preserves identity, resets sync state', () {
    final orig = Txn.create(
      type: 'income',
      category: 'General Donation',
      amount: 100,
      paymentMethod: 'cash',
      enteredBy: '00000000-0000-0000-0000-000000000000',
    );
    final synced = Txn.fromLocalMap({
      ...orig.toLocalMap(),
      'synced_at': DateTime.now().toIso8601String(),
    });
    expect(synced.isSynced, true);
    final edited = synced.applyEdit(
      type: 'expense',
      category: 'Utility Bill',
      amount: 250,
      paymentMethod: 'bkash',
      status: synced.status,
      description: 'corrected',
      receiptNumber: '',
      date: synced.date,
      enteredBy: synced.enteredBy,
    );
    expect(edited.id, orig.id);
    expect(edited.receiptNumber, orig.receiptNumber);
    expect(edited.amount, 250);
    expect(edited.isSynced, false); // dirty -> upserted on next sync
  });

  test('soft-delete round-trips and syncs as is_deleted', () {
    final t = Txn.create(
      type: 'income',
      category: 'Anonymous',
      amount: 50,
      paymentMethod: 'cash',
      enteredBy: '00000000-0000-0000-0000-000000000000',
    );
    final deleted = Txn.fromLocalMap({...t.toLocalMap(), 'is_deleted': 1});
    expect(deleted.isDeleted, true);
    expect(deleted.toSupabaseMap()['is_deleted'], true);
  });
}
