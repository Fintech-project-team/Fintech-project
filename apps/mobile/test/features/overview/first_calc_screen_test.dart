import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/composition_bar.dart';
import 'package:payse/features/overview/finance_line_icon.dart';
import 'package:payse/features/overview/first_calc_screen.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/shared/design/amount_format.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_tokens.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

/// 2026-10-27: [json]으로 계산한 결과(U 있음)를 반환한다.
HomeCalculationReady _ready(Map<String, Object?> json) =>
    computeHomeCalculation(FinancialSnapshot.fromJson(json))
        as HomeCalculationReady;

/// 2026-10-27: 01-3을 띄운다.
Future<void> _show(
  WidgetTester tester,
  HomeCalculationReady calculation, {
  VoidCallback? onExplained,
  VoidCallback? onSkipped,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: FirstCalcFlow(
        calculation: calculation,
        onExplained: onExplained ?? () {},
        onSkipped: onSkipped ?? () {},
      ),
    ),
  );
}

/// 2026-10-27: '다음'을 [times]번 누른다.
Future<void> _next(WidgetTester tester, int times) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('1/4 to 4/4 show the same values as the home result', (
    tester,
  ) async {
    final calculation = _ready(alphaWithReceipt());
    final r = calculation.result;
    var explained = 0;
    await _show(tester, calculation, onExplained: () => explained++);
    expect(find.bySemanticsLabel('4단계 중 1단계'), findsOneWidget);
    expect(find.textContaining(formatKrw(r.b!)), findsWidgets);
    expect(find.textContaining('금융정보 기준'), findsOneWidget);

    await _next(tester, 1);
    expect(find.text('모아둘 돈을 빼요'), findsOneWidget);
    expect(find.text(formatKrw(-r.rEff!)), findsOneWidget);

    await _next(tester, 1);
    expect(find.textContaining('전에 나갈 돈을 빼요'), findsOneWidget);
    expect(find.text(formatKrw(-r.e!)), findsOneWidget);

    await _next(tester, 1);
    expect(find.text('계산을 마쳤어요'), findsOneWidget);
    expect(find.byType(CompositionBar), findsOneWidget);
    final segments = find.descendant(
      of: find.byType(CompositionBar),
      matching: find.byType(FractionallySizedBox),
    );
    expect(segments, findsWidgets);
    for (final box in tester.renderObjectList<RenderBox>(segments)) {
      expect(box.size.width, greaterThan(0), reason: '바 구간이 다 늘어나 보인다');
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('first-calc-result'))).data,
      formatKrw(r.u!),
    );
    expect(find.text('홈으로 가기'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('이제 홈에서 확인하세요'), findsOneWidget);
    expect(
      find.byType(FinanceLineIcon),
      findsNWidgets(4),
      reason: '달 둘레 금융 아이콘',
    );
    expect(explained, 0, reason: '시작 화면의 홈으로 가기를 눌러야 완료');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('계산을 마쳤어요'), findsOneWidget, reason: '시작 화면에서 뒤로 가면 4/4');
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const ValueKey('first-calc-start-button')));
    expect(explained, 1);
  });

  testWidgets('steps keep the receipt; only the current row shows details', (
    tester,
  ) async {
    await _show(tester, _ready(alphaWithReceipt()));
    Finder row(int i) => find.byKey(ValueKey('first-calc-row-$i'));
    expect(row(0), findsOneWidget);
    expect(row(1), findsNothing, reason: '모아둘 돈은 2/4부터');
    expect(find.text('금융사에서 받은 잔액 그대로예요.'), findsOneWidget);
    final accountDetail = find.descendant(
      of: row(0),
      matching: find.textContaining('····'),
    );
    expect(accountDetail, findsWidgets, reason: '1/4는 계좌별 잔액을 펼침');

    await _next(tester, 1);
    expect(row(1), findsOneWidget);
    expect(accountDetail, findsNothing, reason: '다음 단계로 가면 지난 행의 내역을 접음');
    final dimmed = tester.widget<AnimatedOpacity>(
      find.descendant(of: row(0), matching: find.byType(AnimatedOpacity)).first,
    );
    expect(dimmed.opacity, lessThan(1), reason: '지난 행은 흐리게');

    await _next(tester, 2);
    for (var i = 0; i < 3; i++) {
      final o = tester.widget<AnimatedOpacity>(
        find
            .descendant(of: row(i), matching: find.byType(AnimatedOpacity))
            .first,
      );
      expect(o.opacity, 1, reason: '4/4는 모든 행을 진하게');
    }
  });

  testWidgets('a replay from home ends on 4/4 without the start screen', (
    tester,
  ) async {
    var explained = 0;
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: FirstCalcFlow(
          calculation: _ready(alphaWithReceipt()),
          outro: false,
          onExplained: () => explained++,
          onSkipped: () {},
        ),
      ),
    );
    await _next(tester, 3);
    await tester.tap(find.text('홈으로'));
    expect(explained, 1);
  });

  testWidgets('reduced motion shows final states at once', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: FirstCalcFlow(
            calculation: _ready(alphaWithReceipt()),
            onExplained: () {},
            onSkipped: () {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('first-calc-next')));
      await tester.pump();
    }
    expect(find.text('계산을 마쳤어요'), findsOneWidget, reason: '움직임 없이 바로 4/4');
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pump();
    expect(find.text('이제 홈에서 확인하세요'), findsOneWidget);
  });

  testWidgets('home on 1/4 to 3/4 skips', (tester) async {
    var skipped = 0;
    await _show(tester, _ready(alphaWithReceipt()), onSkipped: () => skipped++);
    await _next(tester, 2);
    await tester.tap(find.byKey(const ValueKey('first-calc-skip')));
    expect(skipped, 1);
  });

  testWidgets('a negative result is red with the shortfall sentence', (
    tester,
  ) async {
    final json = alphaWithReceipt();
    for (final a in rows(json, 'accounts')) {
      if (a['included'] == true) a['balanceKRW'] = 100000;
    }
    final calculation = _ready(json);
    final u = calculation.result.u!;
    expect(u, isNegative);
    await _show(tester, calculation);
    await _next(tester, 3);
    final result = tester.widget<Text>(
      find.byKey(const ValueKey('first-calc-result')),
    );
    expect(result.data, formatKrw(u));
    expect(result.style!.color, PayseColors.error);
    expect(
      find.text('모아둘 돈과 예정 지출을 모두 확보하려면\n${formatKrw(-u)}이 더 필요해요.'),
      findsOneWidget,
    );
  });

  testWidgets('awaiting deposit keeps held expenses out of the deduction', (
    tester,
  ) async {
    final calculation = _ready(readSource('salary-wait'));
    final held = calculation
        .result
        .placementTotals![calc.ObligationPlacement.awaitingSalary]!;
    await _show(tester, calculation);
    await _next(tester, 2);
    expect(find.text('월급 입금 확인 후\n계산에 반영할 지출이에요'), findsOneWidget);
    expect(find.text('입금 확인 대기'), findsOneWidget);
    expect(find.byKey(const ValueKey('first-calc-held')), findsOneWidget);
    final total = tester.widget<Text>(
      find.byKey(const ValueKey('first-calc-held-total')),
    );
    expect(total.data, formatKrw(held.totalKrw), reason: '보류 지출에는 −를 붙이지 않는다');
    expect(
      find.text(formatKrw(-held.totalKrw)),
      findsNothing,
      reason: '보류 합계를 차감액처럼 보이지 않는다',
    );
    expect(
      find.text('지금은 이 지출을 계산에서 빼지 않아요. 월급 입금이 확인되면 남은 지출을 반영해 다시 계산해요.'),
      findsOneWidget,
    );
    await _next(tester, 1);
    expect(find.text('월급 입금 전 기준으로\n쓸 수 있는 돈이에요'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('first-calc-awaiting-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('지금 계산에서 빼지 않아요'), findsOneWidget);
  });

  testWidgets('zero reserves and zero scheduled expenses say so', (
    tester,
  ) async {
    final json = alphaWithReceipt()
      ..['reserves'] = <Object?>[]
      ..['allocations'] = <Object?>[]
      ..['obligations'] = <Object?>[]
      ..['settlements'] = <Object?>[]
      ..['occurrenceLinks'] = <Object?>[];
    await _show(tester, _ready(json));
    await _next(tester, 1);
    expect(find.text('이번 계산에서 따로 남겨둘\n금액은 0원이에요'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('first-calc-reserve-used')),
      findsNothing,
      reason: '보호액이 없으면 배정 안내 없음',
    );
    await _next(tester, 1);
    expect(find.text('이번 계산에서 뺄\n예정 지출은 없어요'), findsOneWidget);
  });

  testWidgets('reserves fully used by expenses explain why 0 is deducted', (
    tester,
  ) async {
    final json = alphaWithReceipt();
    final lines = _ready(json).result.reserveLines!;
    final used = {for (final l in lines) l.reserveId: l.usedKrw ?? 0};
    expect(used.values.any((v) => v > 0), isTrue, reason: '배정이 있는 사본');
    json['reserves'] = [
      for (final r in rows(json, 'reserves'))
        if (used[r['reserveId']]! > 0)
          {...r, 'amountKRW': used[r['reserveId']]},
    ];
    final calculation = _ready(json);
    expect(calculation.result.rEff, 0);
    await _show(tester, calculation);
    await _next(tester, 1);
    expect(find.text('이번 계산에서 따로 남겨둘\n금액은 0원이에요'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('first-calc-reserve-used')),
      findsOneWidget,
    );
    expect(find.textContaining('모두 예정 지출에 쓰기로 해서'), findsOneWidget);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('320dp at text x$scale has no overflow on any step', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _show(
        tester,
        _ready(alphaWithReceipt()),
        size: const Size(320, 568),
      );
      for (var step = 1; step <= 4; step++) {
        expect(tester.takeException(), isNull, reason: '$step단계 넘침 없음');
        if (step < 4) await _next(tester, 1);
      }
    });
  }
}
