import 'package:flutter_test/flutter_test.dart';
import 'package:car_key_app/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const CarKeyApp());
    expect(find.text('车钥匙'), findsNothing); // title not shown as text widget
  });
}
