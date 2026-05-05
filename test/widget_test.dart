import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pleasure_principle/main.dart';

void main() {
  testWidgets('shows configuration prompt when no server is saved', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('No server configured'), findsOneWidget);
    expect(find.text('Configure'), findsOneWidget);
  });
}
