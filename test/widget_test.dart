import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ghartek_flutter_app/main.dart';

void main() {
  testWidgets('App boots and renders MaterialApp shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
