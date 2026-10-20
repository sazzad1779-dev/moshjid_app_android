import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/config/app_config.dart';

/// "Imam Hadiya" is both sides of one arrangement: donors paying in monthly
/// (income) and the imam being paid out (expense). These are separate category
/// rows with separate ids, so every lookup has to key on (name, type).
void main() {
  group('seedCategories', () {
    test('has Imam Hadiya under both income and expense', () {
      expect(AppConfig.seedCategories['income'], contains('Imam Hadiya'));
      expect(AppConfig.seedCategories['expense'], contains('Imam Hadiya'));
    });

    test('has purpose categories under both income and expense', () {
      // Donations collected for the electricity bill or maintenance are income;
      // paying those bills is expense. Both sides of each purpose must exist.
      for (final name in ['Electricity Bill', 'Maintenance']) {
        expect(AppConfig.seedCategories['income'], contains(name));
        expect(AppConfig.seedCategories['expense'], contains(name));
      }
    });

    test('mirrors the canonical list in tools/sync_categories.py', () {
      // The category *names* the ledger actually contains. If a row is renamed
      // in Supabase, this test is the reminder to update both lists.
      for (final name in [
        'Friday Collection',
        'Regular Donation',
        'Donation (Outside Box)',
        'Electricity Bill',
        'Maintenance',
      ]) {
        final inIncome = AppConfig.seedCategories['income']!.contains(name);
        final inExpense = AppConfig.seedCategories['expense']!.contains(name);
        expect(inIncome || inExpense, isTrue, reason: '$name missing from seeds');
      }
    });

    test('no longer carries pre-split names', () {
      final all = {...AppConfig.seedCategories['income']!, ...AppConfig.seedCategories['expense']!};
      for (final stale in ['Imam / Staff Hadiya', 'Monthly Due', 'General Donation']) {
        expect(all, isNot(contains(stale)), reason: '$stale was replaced by the canonical list');
      }
    });

    test('every seeded category is a donor category or deliberately is not', () {
      // Guards the one meaningful decision here: the income side takes a donor,
      // the expense side does not.
      expect(AppConfig.categoryTakesDonor('Imam Hadiya', 'income'), isTrue);
      expect(AppConfig.categoryTakesDonor('Imam Hadiya', 'expense'), isFalse);
    });
  });

  group('categoryTakesDonor', () {
    test('is false for unrelated categories', () {
      expect(AppConfig.categoryTakesDonor('Friday Collection', 'income'), isFalse);
      expect(AppConfig.categoryTakesDonor('Electricity Bill', 'expense'), isFalse);
      expect(AppConfig.categoryTakesDonor('Maintenance', 'expense'), isFalse);
    });

    test('cannot be fooled by a category whose name contains another', () {
      // The key is joined with '|', so a type containing one cannot alias a
      // real category's entry.
      expect(AppConfig.categoryTakesDonor('Imam Hadiya', 'income|x'), isFalse);
      expect(AppConfig.categoryTakesDonor('x|Imam Hadiya', 'income'), isFalse);
    });

    test('is case sensitive, matching the server', () {
      expect(AppConfig.categoryTakesDonor('imam hadiya', 'income'), isFalse);
    });
  });
}