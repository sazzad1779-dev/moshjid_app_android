import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/ui/members_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The members tab: the roster the app could not show before, read straight out
/// of the local database.
Future<void> openMembers(
  WidgetTester tester,
  LocalDb db, {
  void Function()? onDataChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: MembersPage(
      revision: 0,
      local: db,
      onDataChanged: () async => onDataChanged?.call(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('lists every member held in the local database', (tester) async {
    await LocalDb.withTempDb((db) async {
      await db.ensureProfile(fullName: 'Roxi Ahmed');
      await db.ensureProfile(fullName: 'Shamsul Bapary', phone: '01712345678');
      await db.ensureProfile(fullName: 'Taijul Islam');

      await openMembers(tester, db);

      expect(find.text('Roxi Ahmed'), findsOneWidget);
      expect(find.text('Shamsul Bapary'), findsOneWidget);
      expect(find.text('01712345678'), findsOneWidget);
      expect(find.text('Taijul Islam'), findsOneWidget);
    });
  });

  testWidgets('search narrows the roster', (tester) async {
    await LocalDb.withTempDb((db) async {
      await db.ensureProfile(fullName: 'Roxi Ahmed');
      await db.ensureProfile(fullName: 'Shamsul Bapary');

      await openMembers(tester, db);
      await tester.enterText(find.byType(TextField), 'rox');
      await tester.pumpAndSettle();

      expect(find.text('Roxi Ahmed'), findsOneWidget);
      expect(find.text('Shamsul Bapary'), findsNothing);
    });
  });

  testWidgets('a member added here is a local row straight away', (tester) async {
    await LocalDb.withTempDb((db) async {
      var pushed = false;
      await openMembers(tester, db, onDataChanged: () => pushed = true);

      await tester.tap(find.text('Add member'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Nasir Uddin');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add member').last);
      await tester.pumpAndSettle();

      final stored = await db.allProfiles();
      expect(stored.map((p) => p.fullName), contains('Nasir Uddin'));
      expect(pushed, isTrue, reason: 'sync is kicked off right after');
      expect(find.text('Nasir Uddin'), findsOneWidget);
    });
  });

  testWidgets('the detail sheet shows the collected total and the history',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      final member = await db.ensureProfile(fullName: 'Roxi Ahmed');
      await db.insertTxn(Txn.create(
        type: 'income',
        category: 'Imam Hadiya',
        amount: 500,
        paymentMethod: 'cash',
        enteredBy: 'tester',
        memberId: member.id,
        donorName: member.fullName,
      ));

      await openMembers(tester, db);
      await tester.tap(find.text('Roxi Ahmed'));
      await tester.pumpAndSettle();

      expect(find.text('Collected'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
      expect(find.text('Imam Hadiya'), findsOneWidget);
    });
  });

  testWidgets('recording a payment opens the form with the member already set',
      (tester) async {
    await LocalDb.withTempDb((db) async {
      final member = await db.ensureProfile(fullName: 'Roxi Ahmed');
      Txn? saved;

      await tester.pumpWidget(MaterialApp(
        home: MembersPage(
          revision: 0,
          local: db,
          onDataChanged: () async {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Roxi Ahmed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record a payment'));
      await tester.pumpAndSettle();

      // The member is shown on the form already, and no picker is needed.
      expect(find.text('Roxi Ahmed'), findsWidgets);

      await tester.enterText(find.widgetWithText(TextFormField, '0'), '250');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save income'));
      await tester.pumpAndSettle();

      saved = (await db.listTxns()).single;
      expect(saved.memberId, member.id);
      expect(saved.category, 'Imam Hadiya');
    });
  });
}