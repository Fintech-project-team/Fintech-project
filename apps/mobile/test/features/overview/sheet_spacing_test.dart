import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;
import 'package:payse/features/overview/transaction_query.dart';
import 'package:payse/features/overview/transaction_sheets.dart';
import 'package:payse/features/planning/plan_period_sheet.dart';
import 'package:payse/features/planning/plan_periods.dart';
import 'package:payse/shared/design/payse_theme.dart';

/// 2026-11-02: 아래 안전 영역 [inset]인 화면에서 시트 [sheet]를 열고, 본문 아래 여백이 고정값이며 본문 끝 바로 아래에 적용 위 선이 오는지 확인한다.
Future<void> _gap(WidgetTester tester, Widget sheet, double inset) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(bottom: inset);
  tester.view.viewPadding = FakeViewPadding(bottom: inset);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showPayseSheet<void>(context, sheet),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  final list = find.descendant(
    of: find.byType(SelectSheet),
    matching: find.byType(ListView),
  );
  final listView = tester.widget<ListView>(list);
  final bottom = tester.getRect(list).bottom;
  final divider = tester.getRect(
    find
        .descendant(
          of: find.byType(SelectSheet),
          matching: find.byType(Divider),
        )
        .last,
  );
  expect((listView.padding! as EdgeInsets).bottom, SelectSheet.bottomGap);
  expect(divider.top, bottom);
}

void main() {
  final today = calc.BusinessDate.parse('2026-10-19', 'test');

  for (final inset in [0.0, 24.0, 48.0]) {
    testWidgets('전체 거래 월 선택 시트: 아래 안전 영역 $inset에서도 격자 아래 여백 같음', (
      tester,
    ) async {
      await _gap(
        tester,
        const PeriodSheet(
          bounds: QueryBounds('2025-10-20', '2026-10-19'),
          current: PeriodSelection(PeriodKind.month, month: '2026-10'),
        ),
        inset,
      );
      final grid = tester.widget<GridView>(find.byType(GridView).first);
      expect(grid.padding, EdgeInsets.zero, reason: '안전 영역을 격자 여백으로 쓰지 않는다');
    });

    testWidgets('계획 기간 시트(달력 월·월급 기간): 안전 영역 $inset에서도 같은 여백', (tester) async {
      final month = monthOf(today);
      await _gap(
        tester,
        PlanPeriodSheet(
          salary: null,
          months: [month],
          current: month,
          today: today,
        ),
        inset,
      );
      final grid = tester.widget<GridView>(find.byType(GridView).first);
      expect((grid.padding! as EdgeInsets).bottom, 0);
    });
  }
}
