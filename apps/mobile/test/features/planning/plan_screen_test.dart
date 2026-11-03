import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/planning/card_bill_screen.dart';
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

/// 2026-11-02: [json]으로 계산한 계획 탭을 띄운다. 테스트마다 새 Snapshot·상태·위젯 트리를 만든다.
Future<void> _pump(
  WidgetTester tester,
  Map<String, Object?> json, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final snapshot = FinancialSnapshot.fromJson(json);
  final state = ValueNotifier<OverviewState>((
    calculation: computeHomeCalculation(snapshot),
    history: null,
  ));
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: PlanScreen(links: OverviewLinks(state: state)),
      ),
    ),
  );
  await tester.pump();
}

/// 2026-11-02: 예정 지출 [label] 줄 안에 [text]가 있는지.
Finder _inRow(String label, String text) => find.descendant(
  of: find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          '${(w.key! as ValueKey).value}'.startsWith('plan-row-'),
    ),
  ),
  matching: find.text(text),
);

/// 2026-11-02: 기간 머리 제목.
String? _title(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('plan-period')),
        matching: find.byType(Text),
      ),
    )
    .data;

void main() {
  testWidgets('현재 월급 기간: 앞으로 나갈 돈에 날짜 라벨, 일부 출금은 남은 금액 강조, 이미 나간 돈은 접힘', (
    tester,
  ) async {
    await _pump(tester, alphaWithReceipt());
    expect(_title(tester), '다음 월급일까지');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('plan-range'))).data,
      '9/25 ~ 10/24 · 10월 19일 12:00 기준',
    );
    expect(_inRow('월세', 'D-3'), findsOneWidget);
    expect(_inRow('수리비', '예정일 지남'), findsOneWidget);
    expect(_inRow('수리비', '60,000원'), findsOneWidget);
    expect(_inRow('수리비', '남은 금액'), findsOneWidget);
    expect(_inRow('수리비', '예정 100,000원 · 10/16 출금 40,000원'), findsOneWidget);
    expect(find.text('일부 출금'), findsNothing);
    expect(find.text('통신비'), findsNothing);
    expect(find.text('카드 청구'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('plan-fold-done')));
    await tester.pump();
    expect(find.text('카드 청구'), findsOneWidget);
    expect(_inRow('카드 청구', '110,000원'), findsOneWidget);
    expect(_inRow('카드 청구', 'D-3'), findsNothing);
  });

  testWidgets('일부 출금이 여러 날짜면 한 날짜에 합계를 붙이지 않고 누적, 무효 정산은 빼고', (tester) async {
    final json = alphaWithReceipt();
    final repair = rows(
      json,
      'obligations',
    ).firstWhere((o) => o['label'] == '수리비')['obligationId'];
    final original = rows(
      json,
      'settlements',
    ).firstWhere((x) => x['obligationId'] == repair);
    final used = {
      for (final x in rows(json, 'settlements')) x['transactionId'],
    };
    final other = rows(json, 'transactions').firstWhere(
      (t) =>
          t['recordKind'] == 'account_entry' &&
          t['direction'] == 'out' &&
          t['accountId'] ==
              rows(json, 'obligations').first['withdrawalAccountId'] &&
          t['withdrawalDate'] != null &&
          t['withdrawalDate'] != '2026-10-16' &&
          (t['amountKRW']! as int) >= 10000 &&
          !used.contains(t['transactionId']),
    );
    json['allocations'] = <Object?>[];
    json['settlements'] = [
      ...rows(json, 'settlements'),
      {
        ...original,
        'linkId': '00000000-0000-4000-8000-0000000000b1',
        'transactionId': other['transactionId'],
        'allocatedKRW': 10000,
      },
      {
        ...original,
        'linkId': '00000000-0000-4000-8000-0000000000b2',
        'transactionId': other['transactionId'],
        'allocatedKRW': 5000,
        'invalidatedAt': '2026-10-18T00:00:00+09:00',
      },
    ];
    await _pump(tester, json);
    expect(_inRow('수리비', '50,000원'), findsOneWidget);
    expect(_inRow('수리비', '예정 100,000원 · 누적 출금 50,000원'), findsOneWidget);
  });

  testWidgets('청구를 대표하는 예정 지출을 누르면 카드 결제 상세, 뒤로 가면 펼침 유지', (tester) async {
    await _pump(tester, alphaWithReceipt());
    await tester.tap(find.byKey(const ValueKey('plan-fold-done')));
    await tester.pump();
    await tester.tap(find.text('카드 청구'));
    await tester.pumpAndSettle();
    expect(find.byType(CardBillScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CardBillScreen), findsNothing);
    expect(find.text('카드 청구'), findsOneWidget);
  });

  testWidgets('다음 월급 기간으로 넘기면 그 기간 지출과 D-n, 끝에서는 화살표가 꺼진다', (tester) async {
    await _pump(tester, alphaWithReceipt());
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('plan-prev')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pump();
    expect(_title(tester), '10/25 ~ 11/24');
    expect(_inRow('통신비', 'D-6'), findsOneWidget);
    expect(find.text('월세'), findsNothing);
  });

  testWidgets('기간 시작 전의 미처리 지출은 안내만 두고, 누르면 전체를 보인다', (tester) async {
    final json = alphaWithReceipt();
    rows(
      json,
      'obligations',
    ).firstWhere((o) => o['label'] == '수리비')['dueDate'] = '2026-09-20';
    await _pump(tester, json);
    expect(find.text('이전 기간에서 남은 지출 1건'), findsOneWidget);
    expect(find.text('받은 정보 기준으로 남은 금액이 있어요.'), findsOneWidget);
    expect(find.text('수리비'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('plan-carry')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('plan-carry-list')),
        matching: find.text('수리비'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('월급 정보가 없으면 이번 달 기본, D-n 없이 예정일 지남만', (tester) async {
    await _pump(tester, readSource('alpha-ready'));
    expect(_title(tester), '2026년 10월');
    expect(find.byKey(const ValueKey('plan-no-salary')), findsOneWidget);
    expect(find.textContaining('D-'), findsNothing);
    expect(_inRow('수리비', '예정일 지남'), findsOneWidget);
  });

  testWidgets('기간 선택 시트: 달력 월로 바꾸고 적용해야 반영, 닫으면 그대로', (tester) async {
    await _pump(tester, alphaWithReceipt());
    await tester.tap(find.byKey(const ValueKey('plan-period')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sheet-note')),
      findsNothing,
      reason: '월급 기간은 목록에 범위가 있어 조회 기간 줄 없음',
    );
    await tester.tap(find.byKey(const ValueKey('plan-kind-month')));
    await tester.pump();
    expect(find.text('이번 달'), findsOneWidget);
    expect(find.text('조회 기간 2026년 10월 1일 ~ 10월 31일'), findsOneWidget);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(_title(tester), '다음 월급일까지');

    await tester.tap(find.byKey(const ValueKey('plan-period')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan-kind-month')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-apply')));
    await tester.pumpAndSettle();
    expect(_title(tester), '2026년 10월');
    expect(_inRow('월세', 'D-3'), findsOneWidget);
  });

  testWidgets('남겨둘 돈: 현재 설정액과 직접 연결한 예정 지출만', (tester) async {
    await _pump(tester, alphaWithReceipt());
    await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
    await tester.pump();
    expect(find.text('현재 비상금'), findsOneWidget);
    expect(find.text('400,000원'), findsOneWidget);
    expect(find.text('설정액'), findsOneWidget);
    expect(find.text('60,000원 배정'), findsOneWidget);
  });

  testWidgets('320dp·글자 1.3배에서도 넘치지 않는다', (tester) async {
    await _pump(tester, alphaWithReceipt(), width: 320, textScale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
