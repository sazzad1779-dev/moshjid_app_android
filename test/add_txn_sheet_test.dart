import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/config/app_config.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/ui/widgets/txn_form_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Drives the real AddTxnSheet against a throwaway database.
Future<Txn?> openSheet(
  WidgetTester tester,
  LocalDb db, {
  Txn? existing,
}) async {
  Txn? saved;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () async {
              await showModalBottomSheet(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => AddTxnSheet(
                  local: db,
                  existing: existing,
                  onSave: (t) async => saved = t,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return saved;
}

Future<void> pickCategory(WidgetTester tester, String label) async {
  // Focus the category field so the suggestion list is showing.
  final field = find.widgetWithText(TextField, 'Category');
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, label);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Taps one of the three type buttons in the [TypeSelector].
Future<void> tapType(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> pickMember(WidgetTester tester, String name) async {
  await tester.tap(find.text('Choose member'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, name);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('the member field is hidden for a non-member category',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);
      expect(find.text('Member'), findsNothing);
      expect(find.text('Choose member'), findsNothing);
    });
  });

  testWidgets('the member field appears for Imam Hadiya on income',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);
      await pickCategory(tester, 'Imam Hadiya');
      expect(find.text('Choose member'), findsOneWidget);
    });
  });

  testWidgets('the member field is hidden for Imam Hadiya on expense',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);
      await tapType(tester, 'Expense');
      await pickCategory(tester, 'Imam Hadiya');
      expect(
        find.text('Choose member'),
        findsNothing,
        reason: 'the expense side of Imam Hadiya has no member',
      );
    });
  });

  testWidgets('the type that is tapped is the type that gets used',
      (tester) async {
    // The dropdown this replaced kept showing the type the form opened with,
    // so every entry was saved as income regardless of what was chosen.
    await LocalDb.withTempDb((db) async {
      final saved = <Txn>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => AddTxnSheet(
                  local: db,
                  onSave: (t) async => saved.add(t),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapType(tester, 'Expense');
      await tester.enterText(
          find.widgetWithText(TextFormField, '0'), '120');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();

      expect(saved.single.type, 'expense');
    });
  });

  testWidgets('switching type re-lists the categories for that type',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);

      // Default type is income, so Friday Collection is offered.
      await tester.tap(find.widgetWithText(TextField, 'Category'));
      await tester.pumpAndSettle();
      expect(find.text('Friday Collection'), findsOneWidget);

      await tapType(tester, 'Expense');

      await tester.tap(find.widgetWithText(TextField, 'Category'));
      await tester.pumpAndSettle();
      expect(find.text('Electricity Bill'), findsOneWidget,
          reason: 'expense categories replaced the income ones');
      expect(find.text('Friday Collection'), findsNothing);
    });
  });

  testWidgets('the category list filters as you type', (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);
      final field = find.widgetWithText(TextField, 'Category');
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'frid');
      await tester.pumpAndSettle();
      expect(find.text('Friday Collection'), findsOneWidget);
      expect(find.text('Magrib Donation'), findsNothing);
    });
  });

  testWidgets('a member from the roster is saved onto the transaction',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      final member = await db.ensureProfile(fullName: 'Roxi');
      final saved = <Txn>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => AddTxnSheet(
                  local: db,
                  onSave: (t) async => saved.add(t),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await pickCategory(tester, 'Imam Hadiya');
      await pickMember(tester, 'Roxi');
      await tester.enterText(find.widgetWithText(TextFormField, '0'), '300');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save income'));
      await tester.pumpAndSettle();

      expect(saved.single.memberId, member.id);
      expect(saved.single.donorName, 'Roxi');
    });
  });

  testWidgets('a member typed in the roster is stored in the local db',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      await openSheet(tester, db);
      await pickCategory(tester, 'Imam Hadiya');

      // The roster is empty in a fresh database, so the only route is the
      // inline "Add" row.
      await tester.tap(find.text('Choose member'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Shamsul Bapary');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Add "Shamsul Bapary" as a new member'), findsOneWidget);
      await tester.tap(find.text('Add "Shamsul Bapary" as a new member'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Shamsul Bapary');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add member'));
      await tester.pumpAndSettle();

      final stored = await db.allProfiles();
      expect(stored.map((p) => p.fullName), contains('Shamsul Bapary'));
      expect(stored.single.isPending, isTrue,
          reason: 'not on the server yet');
    });
  });

  testWidgets('the donor identity rule drives which categories want a member',
      (tester) async {
    expect(AppConfig.categoryTakesDonor('Imam Hadiya', 'income'), isTrue);
    expect(AppConfig.categoryTakesDonor('Imam Hadiya', 'expense'), isFalse);
    expect(AppConfig.categoryTakesDonor('Friday Collection', 'income'), isFalse);
  });
}