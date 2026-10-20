import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/amount_hero.dart';
import 'package:payse/shared/design/payse_tokens.dart';

import 'design_test_utils.dart';

/// 2026-10-20: 금액 줄(Text.rich)의 전체 문자열과 기본 색을 찾아 반환한다.
({String text, Color? color}) amountLine(WidgetTester tester) {
  final rich = tester.widget<RichText>(
    find.descendant(
      of: find.byType(FittedBox),
      matching: find.byType(RichText),
    ),
  );
  return (text: rich.text.toPlainText(), color: rich.text.style?.color);
}

void main() {
  const label = '다음 월급일까지 쓸 수 있는 돈';

  testWidgets('shows normal amount with unit and as-of label', (tester) async {
    await tester.pumpWidget(
      themed(
        const AmountHero(
          label: label,
          amountKrw: 1100000,
          asOfLabel: '10/19 12:00 기준',
        ),
      ),
    );

    final line = amountLine(tester);
    expect(line.text, '1,100,000원');
    expect(line.color, PayseColors.textPrimary);
    expect(find.text('10/19 12:00 기준'), findsOneWidget);
  });

  testWidgets('negative amount keeps minus sign, error color and message', (
    tester,
  ) async {
    await tester.pumpWidget(
      themed(
        const AmountHero(
          label: label,
          amountKrw: -120000,
          message: '모아둘 돈과 예정 지출을 유지하려면 120,000원이 부족해요.',
        ),
      ),
    );

    final line = amountLine(tester);
    expect(line.text, '−120,000원');
    expect(line.color, PayseColors.error);
    expect(find.textContaining('부족해요'), findsOneWidget);
    expect(find.bySemanticsLabel('마이너스 120,000원'), findsOneWidget);
  });

  testWidgets('null amount shows unavailable text, never 0원', (tester) async {
    await tester.pumpWidget(
      themed(
        const AmountHero(
          label: label,
          amountKrw: null,
          message: '삼성카드 결제일을 입력하면 계산할 수 있어요.',
        ),
      ),
    );

    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expect(find.textContaining('0원'), findsNothing);
    expect(find.byType(FittedBox), findsNothing);
  });

  testWidgets('long amount fits a 320dp screen without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      themed(const AmountHero(label: label, amountKrw: 1234567890)),
    );

    expect(tester.takeException(), isNull);
    expect(amountLine(tester).text, '1,234,567,890원');
  });
}
