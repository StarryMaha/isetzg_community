import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iset_community/theme.dart';

void main() {
  testWidgets('app logo renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: AppLogo()),
    ));

    expect(find.byIcon(Icons.school_rounded), findsOneWidget);
  });
}
