import 'package:flutter/foundation.dart';
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

  testWidgets('bootstrap stays readable on the PAYSE light theme', (
    tester,
  ) async {
    await tester.pumpWidget(const PayseApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold));
    final theme = Theme.of(context);
    expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(theme.colorScheme.onSurface, const Color(0xFF242629));
    expect(find.text('개발 환경이 준비되었습니다.'), findsOneWidget);
  });

  testWidgets('Pretendard license appears in the Flutter license list', (
    tester,
  ) async {
    await tester.pumpWidget(const PayseApp());

    final entries = await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    final pretendard = entries!.where(
      (entry) => entry.packages.contains('Pretendard'),
    );
    expect(pretendard, hasLength(1));
    final text = pretendard.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('SIL Open Font License'));
  });
}
