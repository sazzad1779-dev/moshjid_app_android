import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/ui/widgets/txn_form_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('tap option without typing', (tester) async {
    await LocalDb.withTempDb((db) async {
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
      final catField = find.widgetWithText(TextField, 'Category');
      await tester.tap(catField);
      await tester.pumpAndSettle();
      debugPrint('options shown: ${find.byType(ListTile).evaluate().length}');
      await tester.tap(find.text('Magrib Donation').last);
      await tester.pumpAndSettle();
      final c = tester.widget<TextField>(catField);
      debugPrint('field text after tap: "${c.controller?.text}"');
      await tester.enterText(find.byType(TextFormField).first, '100');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save income'));
      await tester.pumpAndSettle();
      debugPrint('saved category: ${saved?.category}');
    });
  });
}
