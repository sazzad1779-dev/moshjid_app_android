import 'package:flutter_test/flutter_test.dart';

import 'package:moshjid_app/main.dart';

void main() {
  testWidgets('App boots to PIN gate', (WidgetTester tester) async {
    await tester.pumpWidget(const MoshjidApp());
    expect(find.text('Moshjid Transactions'), findsOneWidget);
    expect(find.text('Unlock'), findsOneWidget);
  });
}
