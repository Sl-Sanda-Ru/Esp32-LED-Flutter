import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esp32_control/main.dart';

void main() {
  testWidgets('Scan page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const LedApp());
    expect(find.text('Scan for ESP32-LED'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });
}
