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

  group('created_at is only sent for rows the server has never seen', () {
    Txn newRow() => Txn.create(
      type: 'income',
      category: 'Friday Collection (জুমার দান)',
      amount: 100,
      paymentMethod: 'cash',
      enteredBy: '00000000-0000-0000-0000-000000000000',
    );

    test('fresh row carries created_at', () {
      expect(newRow().toSupabaseMap().containsKey('created_at'), true);
    });

    test('synced row omits created_at but keeps updated_at', () {
      final synced = Txn.fromLocalMap({
        ...newRow().toLocalMap(),
        'is_new': 0,
        'synced_at': DateTime.now().toIso8601String(),
      });
      final payload = synced.toSupabaseMap();
      expect(payload.containsKey('created_at'), false);
      expect(payload.containsKey('updated_at'), true);
    });

    test('editing an unsynced row still carries created_at', () {
      final edited = newRow().applyEdit(
        type: 'expense',
        category: 'Maintenance (রক্ষণাবেক্ষণ)',
        amount: 200,
        paymentMethod: 'bkash',
        status: 'confirmed',
        date: DateTime(2026, 6, 1),
        enteredBy: '00000000-0000-0000-0000-000000000000',
      );
      expect(edited.isNew, true);
      expect(edited.toSupabaseMap().containsKey('created_at'), true);
    });
  });

  group('parseAmount', () {
    test('reads what people actually type', () {
      expect(Txn.parseAmount('1500'), 1500);
      expect(Txn.parseAmount(' 1500 '), 1500);
      expect(Txn.parseAmount('1,500'), 1500);
      expect(Txn.parseAmount('1,500.50'), 1500.5);
      expect(Txn.parseAmount('250.5'), 250.5);
      expect(Txn.parseAmount('500.'), 500);
      expect(Txn.parseAmount('.5'), 0.5);
    });

    test('converts Bengali digits and the taka sign', () {
      expect(Txn.parseAmount('১৫০'), 150);
      expect(Txn.parseAmount('৳ ১,২৩৪.৫০'), 1234.5);
      expect(Txn.parseAmount('০'), 0);
    });

    test('rejects junk', () {
      expect(Txn.parseAmount(null), isNull);
      expect(Txn.parseAmount(''), isNull);
      expect(Txn.parseAmount('   '), isNull);
      expect(Txn.parseAmount('abc'), isNull);
      expect(Txn.validateAmount('৳১৫০'), null); // valid
      expect(Txn.validateAmount('৳০'), 'Must be > 0');
    });
  });

  group('cleanText folds ledger placeholders to null', () {
    test('blank-ish values become null', () {
      expect(Txn.cleanText(null), isNull);
      expect(Txn.cleanText(''), isNull);
      expect(Txn.cleanText('   '), isNull);
      expect(Txn.cleanText('N/a'), isNull);
      expect(Txn.cleanText(' n/a '), isNull);
      expect(Txn.cleanText('-'), isNull);
      expect(Txn.cleanText('none'), isNull);
    });

    test('real values are trimmed and kept', () {
      expect(Txn.cleanText('  Donation by Sazzad  '), 'Donation by Sazzad');
      expect(Txn.cleanText('N/A bill'), 'N/A bill');
      expect(Txn.cleanText('১ প্যাকেট কয়েল'), '১ প্যাকেট কয়েল');
    });

    test('create and applyEdit both use it', () {
      final t = Txn.create(
        type: 'income',
        category: 'Anonymous',
        amount: 50,
        paymentMethod: 'cash',
        enteredBy: '00000000-0000-0000-0000-000000000000',
        description: '  ',
      );
      expect(t.description, isNull);
      final edited = t.applyEdit(
        type: 'income',
        category: 'Anonymous',
        amount: 50,
        paymentMethod: 'cash',
        status: 'confirmed',
        description: 'N/a',
        date: t.date,
        enteredBy: t.enteredBy,
      );
      expect(edited.description, isNull);
      expect(edited.receiptNumber, t.receiptNumber); // preserved
    });
  });

  test('dateKey always yields yyyy-MM-dd', () {
    expect(Txn.dateKey(DateTime(2026, 6, 5)), '2026-06-05');
    expect(Txn.dateKey(DateTime(2026, 12, 31)), '2026-12-31');
    expect(Txn.dateKey(DateTime(2026, 6, 5, 23, 59)), '2026-06-05');
  });
}
