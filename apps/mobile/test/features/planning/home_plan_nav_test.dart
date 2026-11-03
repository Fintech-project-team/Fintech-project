import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/calculation_detail_screen.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/overview/overview_pages.dart';
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/shared/design/amount_format.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse_calculation/payse_calculation.dart'
    show InsufficientReason;

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';
import '../../data/connection/plan_write_test_utils.dart' show planSource;

/// 2026-11-03: [json]으로 계산한 공통 상태.
ValueNotifier<OverviewState> _state(Map<String, Object?> json) =>
    ValueNotifier((
      calculation: computeHomeCalculation(FinancialSnapshot.fromJson(json)),
      history: null,
    ));

/// 2026-11-03: 계산 결과.
HomeCalculationReady _ready(ValueNotifier<OverviewState> state) =>
    state.value.calculation as HomeCalculationReady;

/// 2026-11-03: [child]를 띄운다.
Future<void> _show(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

/// 2026-11-03: 섹션 머리 오른쪽 글자.
String _head(WidgetTester tester, String title) => tester
    .widget<Text>(find.byKey(ValueKey('plan-section-$title')))
    .textSpan!
    .toPlainText();

void main() {
  testWidgets('홈: 남겨둘 돈·예정 지출 행은 계획 탭으로, 계좌 잔액 행은 계산 내역으로', (tester) async {
    final state = _state(alphaWithReceipt());
    addTearDown(state.dispose);
    final asked = <PlanTab>[];
    await _show(
      tester,
      HomeScreen(
        calculation: state.value.calculation,
        onReload: () {},
        links: OverviewLinks(state: state, onShowPlan: asked.add),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-row-reserve')));
    await tester.tap(find.byKey(const ValueKey('home-row-scheduled')));
    await tester.pumpAndSettle();
    expect(asked, [PlanTab.reserves, PlanTab.scheduled]);
    expect(find.byType(CalculationDetailScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-row-balance')));
    await tester.pumpAndSettle();
    expect(find.byType(CalculationDetailScreen), findsOneWidget);
    expect(asked, hasLength(2));
  });

  testWidgets('계산 내역: 관리 줄은 계산 내역을 닫고 계획 탭의 해당 탭을 연다', (tester) async {
    final state = _state(alphaWithReceipt());
    addTearDown(state.dispose);
    final asked = <PlanTab>[];
    final links = OverviewLinks(state: state, onShowPlan: asked.add);
    await _show(tester, const Text('shell'));
    for (final (section, key, label, tab) in [
      (
        CalcSection.reserve,
        'receipt-manage-reserves',
        '남겨둘 돈 관리',
        PlanTab.reserves,
      ),
      (
        CalcSection.scheduled,
        'receipt-manage-scheduled',
        '예정 지출 관리',
        PlanTab.scheduled,
      ),
    ]) {
      openCalculation(
        tester.element(find.text('shell')),
        links,
        section: section,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('현재 비상금 400,000원 중 60,000원은 수리비에 쓸 금액이에요.'),
        findsOneWidget,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(ValueKey(key))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CalculationDetailScreen), findsNothing);
      expect(asked.last, tab);
    }
    expect(find.text('남겨둘 돈 관리'), findsNothing);
  });

  testWidgets('계산 내역 연결 문장: 여러 건이면 예정일이 가장 이른 이름 외 n건', (tester) async {
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(planSource(rentHeld: true)),
    ) as HomeCalculationReady;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: CalculationDetailScreen(calculation: calculation),
      ),
    );
    await tester.pump();
    expect(
      find.text('현재 비상금 400,000원 중 90,000원은 수리비 외 1건에 쓸 금액이에요.'),
      findsOneWidget,
    );
    expect(find.text('남겨둘 돈 관리'), findsNothing, reason: '연결 없이 열면 관리 줄 없음');
  });

  testWidgets('계획 탭 열기 요청: 다른 기간·탭을 보고 있어도 그 탭의 지금 월급 기간·맨 위로', (tester) async {
    final state = _state(alphaWithReceipt());
    addTearDown(state.dispose);
    final focus = PlanFocus();
    addTearDown(focus.dispose);
    await _show(
      tester,
      PlanScreen(
        links: OverviewLinks(state: state),
        focus: focus,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pump();
    expect(find.text('10/25 ~ 11/24'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
    await tester.pump();
    focus.show(PlanTab.scheduled);
    await tester.pumpAndSettle();
    expect(find.text('다음 월급일까지'), findsOneWidget);
    expect(find.text('월세'), findsOneWidget);
  });

  testWidgets('머리 합계는 홈 금액과 같은 기준, 남겨둘 돈은 하위 행과 남겨둘 금액', (tester) async {
    final state = _state(alphaWithReceipt());
    addTearDown(state.dispose);
    final result = _ready(state).result;
    await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
    expect(_head(tester, '앞으로 나갈 돈'), '2건 · ${formatKrw(result.e!)}');
    expect(result.e, 360000);
    await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
    await tester.pump();
    expect(_head(tester, '남겨둘 돈'), '1건 · ${formatKrw(result.rEff!)}');
    expect(result.rEff, 340000);
    expect(find.text('400,000원'), findsOneWidget);
    expect(find.text('설정액'), findsOneWidget);
    expect(find.text('수리비'), findsOneWidget);
    expect(find.text('10/18 예정 · 현재 비상금에서 60,000원 사용 예정'), findsOneWidget);
    expect(find.text('−60,000원'), findsOneWidget);
    expect(find.text('남겨둘 금액'), findsOneWidget);
    expect(find.text('340,000원'), findsOneWidget);
    expect(find.text('연결한 예정 지출'), findsNothing, reason: '하위 행으로 대신함');
  });

  testWidgets('월급 입금 확인 전: 위 안내 띠와 행 칩', (tester) async {
    final state = _state(readSource('salary-wait'));
    addTearDown(state.dispose);
    await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
    expect(find.byKey(const ValueKey('plan-awaiting')), findsOneWidget);
    expect(find.text('월급 입금 확인 전이에요'), findsOneWidget);
    expect(find.text('입금 확인 후 반영'), findsWidgets);
  });

  testWidgets('겹친 금액을 모르면 연결 금액은 부호 없이, 남겨둘 금액·머리 합계는 계산 불가', (tester) async {
    final state = _state(readSource('alpha-ready'));
    addTearDown(state.dispose);
    expect(_ready(state).result.rEff, isNull);
    await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
    await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
    await tester.pump();
    expect(_head(tester, '남겨둘 돈'), '1건 · 계산 불가');
    expect(find.text('60,000원'), findsOneWidget);
    expect(find.text('−60,000원'), findsNothing);
    expect(find.text('계산 불가'), findsOneWidget);
    expect(
      _ready(state).result.insufficient,
      isNot(contains(InsufficientReason.salarySettingsMissing)),
      reason: 'alpha-ready는 월급 정보는 있고 입금 근거가 없음',
    );
    expect(find.text('이번 계산에서 겹치는 금액을 알 수 없어요.'), findsOneWidget);
    expect(find.textContaining('월급 정보가 없어'), findsNothing);
  });

  testWidgets('월급일이 없어 겹친 금액을 모르면 월급 정보 문구', (tester) async {
    final json = readSource('alpha-ready');
    ((json['settings']! as Map)['salary'] as Map)['salaryDay'] = null;
    final state = _state(json);
    addTearDown(state.dispose);
    expect(
      _ready(state).result.insufficient,
      contains(InsufficientReason.salaryDayMissing),
    );
    await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
    await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
    await tester.pump();
    expect(find.text('월급 정보가 없어 이번 기간에 겹치는지 알 수 없어요.'), findsOneWidget);
  });

  group('리뷰 결함 재현', () {
    const hana = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
    const kbDeposit = '2c56e23d-2e82-59ed-8fce-21459e226167';
    const rent = '41c9a92d-536a-5ae8-a053-7755833ff362';

    /// 2026-11-03: 계산에서 뺀 계좌(하나 입출금·국민 예금)에 남겨둘 돈 두 개를 더한다. 여행 자금은 월세에 100,000원 연결.
    Map<String, Object?> withExcludedReserves() {
      final json = alphaWithReceipt();
      final base = rows(json, 'reserves').single;
      (json['reserves']! as List)
        ..add({
          ...base,
          'reserveId': '00000000-0000-4000-8000-0000000000e1',
          'accountId': hana,
          'label': '여행 자금',
          'amountKRW': 500000,
        })
        ..add({
          ...base,
          'reserveId': '00000000-0000-4000-8000-0000000000e2',
          'accountId': kbDeposit,
          'label': '이사 준비',
          'amountKRW': 300000,
        });
      (json['allocations']! as List).add({
        'userId': json['userId'],
        'allocationId': '00000000-0000-4000-8000-0000000000e3',
        'reserveId': '00000000-0000-4000-8000-0000000000e1',
        'obligationId': rent,
        'amountKRW': 100000,
        'releasedKRW': 0,
        'releaseEvidence': <Object?>[],
      });
      return json;
    }

    testWidgets('계산에서 뺀 계좌의 남겨둘 돈은 아래 접힘 구역, 월급 정보 문구 없음(연결 있음·없음)', (
      tester,
    ) async {
      final state = _state(withExcludedReserves());
      addTearDown(state.dispose);
      expect(_ready(state).result.rEff, 340000, reason: '제외 계좌 보호액은 R에 없음');
      await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
      await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
      await tester.pump();
      expect(_head(tester, '남겨둘 돈'), '1건 · 340,000원');
      expect(find.text('여행 자금'), findsNothing, reason: '포함한 것이 있으면 접힘');
      await tester.tap(
        find.byKey(const ValueKey('plan-fold-reserve-excluded')),
      );
      await tester.pump();
      expect(find.text('계산에서 뺀 계좌에 있어 홈 계산과 위 합계에 넣지 않아요.'), findsOneWidget);
      expect(find.text('여행 자금'), findsOneWidget);
      expect(find.text('이사 준비'), findsOneWidget);
      expect(find.text('10/22 예정 · 여행 자금에서 100,000원 사용 예정'), findsOneWidget);
      expect(find.text('100,000원'), findsOneWidget, reason: '부호 없이');
      expect(find.text('남겨둘 금액'), findsOneWidget, reason: '포함한 현재 비상금에만');
      expect(find.textContaining('월급 정보가 없어'), findsNothing);
      expect(find.text('계산 불가'), findsNothing);
    });

    testWidgets('남겨둘 돈이 모두 계산에서 뺀 계좌면 0건 · 0원, 빈 안내, 제외 구역은 펼침', (
      tester,
    ) async {
      final json = alphaWithReceipt();
      rows(json, 'reserves').single['accountId'] = hana;
      final state = _state(json);
      addTearDown(state.dispose);
      expect(_ready(state).result.rEff, 0);
      await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
      await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
      await tester.pump();
      expect(_head(tester, '남겨둘 돈'), '0건 · 0원', reason: '0원과 계산 불가 구분');
      expect(find.text('계산에 포함한 남겨둘 돈이 없어요.'), findsOneWidget);
      expect(find.text('현재 비상금'), findsOneWidget, reason: '처음부터 펼침');
      expect(find.text('60,000원'), findsOneWidget);
      expect(find.text('남겨둘 금액'), findsNothing);
    });

    testWidgets('이전 기간 미지급: 띠에 건수·금액과 홈 반영 안내, 현재 소계 + 이전 기간 = 홈 예정 지출', (
      tester,
    ) async {
      final json = alphaWithReceipt();
      rows(
        json,
        'obligations',
      ).firstWhere((o) => o['obligationId'] == rent)['dueDate'] = '2026-09-20';
      final state = _state(json);
      addTearDown(state.dispose);
      final e = _ready(state).result.e!;
      await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
      expect(_head(tester, '앞으로 나갈 돈'), '1건 · 60,000원');
      expect(find.text('이전 기간에서 남은 지출 1건 · 300,000원'), findsOneWidget);
      expect(
        find.text('예정일이 지났지만 아직 남은 금액이라 홈 예정 지출에 함께 들어가 있어요.'),
        findsOneWidget,
      );
      expect(60000 + 300000, e);
    });

    testWidgets('월급 입금 확인 전의 이전 기간 미지급은 반영 대기 안내', (tester) async {
      final json = readSource('salary-wait');
      rows(
        json,
        'obligations',
      ).firstWhere((o) => o['label'] == '수리비')['dueDate'] = '2026-09-20';
      final state = _state(json);
      addTearDown(state.dispose);
      await _show(tester, PlanScreen(links: OverviewLinks(state: state)));
      expect(find.textContaining('이전 기간에서 남은 지출 1건 ·'), findsOneWidget);
      expect(find.text('월급 입금이 확인되면 쓸 수 있는 돈에서 빼요.'), findsOneWidget);
      expect(find.textContaining('홈 예정 지출에 함께'), findsNothing);
    });
  });
}
