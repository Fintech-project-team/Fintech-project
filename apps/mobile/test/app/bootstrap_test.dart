import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/payse_app.dart';

void main() {
  testWidgets('PAYSE bootstrap renders without platform or API dependencies', (
    tester,
  ) async {
    await tester.pumpWidget(const PayseApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('PAYSE'), findsOneWidget);
  });
}
