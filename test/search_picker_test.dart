import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/ui/widgets/search_picker.dart';

/// Pumps a picker plus a readout of the current value, so a test can assert
/// both what was rendered and what the field reported.
Widget harness({required Widget child}) {
  return MaterialApp(
    home: Scaffold(
      // Scrollable so the expanded option list never overflows the 800x600
      // test window -- that is a harness artefact, not a widget fault.
      body: SingleChildScrollView(
        child: Builder(
          builder: (context) => Column(
            children: [
              child,
              const SizedBox(height: 600),
              TextButton(
                onPressed: () => FocusScope.of(context).unfocus(),
                child: const Text('blur'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  const cats = [
    PickerOption(value: 'Friday Collection', label: 'Friday Collection'),
    PickerOption(value: 'Regular Donation', label: 'Regular Donation'),
    PickerOption(value: 'Imam Hadiya', label: 'Imam Hadiya'),
    PickerOption(value: 'Donation (Outside Box)',
        label: 'Donation (Outside Box)'),
  ];

  testWidgets('shows the label of the selected option', (tester) async {
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        value: 'Imam Hadiya',
        onSelected: (_) {},
      ),
    ));
    expect(find.text('Imam Hadiya'), findsOneWidget);
  });

  testWidgets('typing filters the list', (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        onSelected: (_) {},
        onQueryChanged: seen.add,
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('Regular Donation'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'regu');
    await tester.pumpAndSettle();
    expect(find.text('Regular Donation'), findsOneWidget);
    expect(seen.last, 'regu');
  });

  testWidgets('an empty match shows a message rather than nothing',
      (tester) async {
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Donor',
        options: const [],
        onSelected: (_) {},
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing available yet'), findsOneWidget);
  });

  testWidgets('tapping a row reports the option and closes the list',
      (tester) async {
    PickerOption? picked;
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        onSelected: (o) => picked = o,
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Imam Hadiya').last);
    await tester.pumpAndSettle();

    expect(picked?.value, 'Imam Hadiya');
    // The list is gone, but the field keeps the text.
    expect(find.text('Imam Hadiya'), findsOneWidget);
  });

  testWidgets('submitting an exact match picks it', (tester) async {
    PickerOption? picked;
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        onSelected: (o) => picked = o,
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Imam Hadiya');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(picked?.value, 'Imam Hadiya');
  });

  testWidgets('submitting a non-matching query picks nothing', (tester) async {
    PickerOption? picked;
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        onSelected: (o) => picked = o,
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Silently choosing a prefix match would save the wrong category.
    expect(picked, isNull);
  });

  group('add row', () {
    testWidgets('appears when the builder returns a label', (tester) async {
      await tester.pumpWidget(harness(
        child: SearchPickerField(
          label: 'Donor',
          options: const [],
          onSelected: (_) {},
          addLabelBuilder: (q) => q.trim().isEmpty ? null : 'Add "$q"',
        ),
      ));

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Roxi');
      await tester.pumpAndSettle();
      expect(find.text('Add "Roxi"'), findsOneWidget);
    });

    testWidgets('is hidden when the builder returns null', (tester) async {
      await tester.pumpWidget(harness(
        child: SearchPickerField(
          label: 'Category',
          options: cats,
          onSelected: (_) {},
          addLabelBuilder: (_) => null,
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add "'), findsNothing);
    });

    testWidgets('reports isAction so the caller can branch', (tester) async {
      PickerOption? picked;
      await tester.pumpWidget(harness(
        child: SearchPickerField(
          label: 'Donor',
          options: const [],
          onSelected: (o) => picked = o,
          addLabelBuilder: (q) => q.trim().isEmpty ? null : 'Add "$q"',
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Roxi');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add "Roxi"'));
      await tester.pumpAndSettle();

      expect(picked?.isAction, isTrue);
      expect(picked?.value, PickerOption.newValue);
    });
  });

  testWidgets('the clear button empties the field', (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        value: 'Imam Hadiya',
        onSelected: (_) {},
        onQueryChanged: seen.add,
      ),
    ));

    expect(find.text('Imam Hadiya'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(seen.last, '');
  });

  testWidgets('a disabled field shows no suggestions', (tester) async {
    await tester.pumpWidget(harness(
      child: SearchPickerField(
        label: 'Category',
        options: cats,
        onSelected: (_) {},
        enabled: false,
      ),
    ));
    expect(find.text('Regular Donation'), findsNothing);
  });
}