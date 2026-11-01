import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/overview/overview_pages.dart';
import 'package:payse/features/overview/period_flow_screen.dart';
import 'package:payse/features/overview/transaction_feed.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_symbols.dart';
import 'package:payse/shared/design/payse_tokens.dart';
import 'package:payse/features/overview/transactions_screen.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

const _kb = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _hyundai = 'dd908fb3-e0db-5927-8ce4-edc29d758df7';
const _transferOut = '6f8dad9e-3b56-577b-bf51-c1fbc7d46109';

/// 2026-10-31: [json]으로 계산한 이번 기간 내역을 띄운다. 전체 거래 보기를 누른 횟수를 [onShowAll]로 센다.
Future<ValueNotifier<OverviewState>> _pump(
  WidgetTester tester,
  Map<String, Object?> json, {
  VoidCallback? onShowAll,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final snapshot = FinancialSnapshot.fromJson(json);
  final calculation = computeHomeCalculation(snapshot);
  final state = ValueNotifier<OverviewState>((
    calculation: calculation,
    history: null,
  ));
  final feed = TransactionFeed(snapshot: snapshot);
  addTearDown(feed.dispose);
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
        body: PeriodFlowScreen(
          calculation: calculation,
          feed: feed,
          links: OverviewLinks(state: state),
          onShowAll: onShowAll ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

/// 2026-10-31: [key] 안에 [text]가 있는지.
Finder _in(String key, String text) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.textContaining(text, findRichText: true),
);

void main() {
  testWidgets('정상: 계산 결과의 월급 주기와 계산에 포함한 계좌·카드만, 제외 계좌 거래는 없다', (tester) async {
    await _pump(tester, alphaWithReceipt());
    expect(find.text('9/25 – 10/24'), findsOneWidget);
    expect(find.text('이번 월급 주기'), findsOneWidget);
    expect(find.text('계산에 포함한 계좌·카드'), findsOneWidget);
    expect(_in('flow-pick-instrument', '계좌 2개 · 카드 3개'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('flow-pick-instrument')),
      findsOneWidget,
      reason: '대상 개수와 계좌·카드별 보기는 한 버튼',
    );
    expect(find.text('10월 19일 12:00 기준'), findsOneWidget);
    expect(find.text('모아결식품 해솔길점'), findsNothing, reason: '하나(제외) 계좌 거래');
    expect(find.text('돈 흐름'), findsNothing);
  });

  testWidgets('이체는 경로·금액·아이콘·내 계좌 이체만, 의미 설명은 상세에서', (tester) async {
    await _pump(tester, alphaWithReceipt());
    final row = find.byKey(const ValueKey('flow-transfer-$_transferOut'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: row, matching: find.text('입출금 통장 → 자유 적금')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('내 계좌 이체')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(PayseSymbols.compareArrows),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('합계 잔액은 그대로'), findsNothing);
    expect(
      find.descendant(of: row, matching: find.text('50,000원')),
      findsOneWidget,
      reason: '두 계좌 모두 포함이면 부호 없음',
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('변동 없음'), findsOneWidget);
    expect(find.text('두 계좌가 모두 계산에 포함돼 있어요.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-open-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-amount')), findsOneWidget);
  });

  testWidgets('거래 종류 아이콘: 카드 사용·환불은 카드·되돌림, 문구와 함께', (tester) async {
    await _pump(tester, alphaWithReceipt());
    await tester.tap(find.byKey(const ValueKey('flow-chip-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-kind-card')));
    await tester.pumpAndSettle();
    expect(_in('flow-chip-kind', '카드 사용·환불'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('flow-transfer-$_transferOut')),
      findsNothing,
    );
    expect(find.textContaining('카드 사용 · '), findsWidgets);
    expect(find.textContaining('입금'), findsNothing);
    final refund = find.text('+12,000원');
    expect(
      tester.widget<Text>(refund).style!.color,
      PayseColors.amountIn,
      reason: '+ 금액만 초록',
    );
    final minus = find.textContaining('−').first;
    expect(tester.widget<Text>(minus).style!.color, PayseColors.textPrimary);
    final icon = find.byKey(const ValueKey('tx-kind-icon')).first;
    final row = find.ancestor(of: icon, matching: find.byType(TxRow)).first;
    final name = find.descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (w) => w is Text && w.maxLines == 1 && w.style?.fontSize == 15,
      ),
    );
    expect(
      tester.getTopLeft(icon).dx,
      lessThan(tester.getTopLeft(name.first).dx),
      reason: '아이콘은 거래명 왼쪽 칸',
    );
    for (final e in find.byKey(const ValueKey('tx-kind-icon')).evaluate()) {
      final icon = (e.widget as Icon).icon;
      expect(
        icon == PayseSymbols.creditCard || icon == PayseSymbols.undo,
        isTrue,
        reason: '$icon',
      );
    }
  });

  testWidgets('통합 시트: 계좌·카드 묶음, 출금 계좌 미확인 카드는 따로 세지 않고, 제외 계좌 카드는 없다', (
    tester,
  ) async {
    final json = alphaWithReceipt();
    rows(
      json,
      'cards',
    ).firstWhere((c) => c['cardId'] == _hyundai)['withdrawalAccountId'] = null;
    await _pump(tester, json);
    expect(_in('flow-pick-instrument', '계좌 2개 · 카드 2개'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-pick-instrument')));
    await tester.pumpAndSettle();
    expect(find.text('계좌·카드별 보기'), findsWidgets);
    expect(find.text('계좌 2개'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(InfoSheet),
        matching: find.textContaining('카드 2개', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(find.text('포함 여부를 확인할 수 없는 카드'), findsOneWidget);
    expect(
      find.text('카드 ····0002 · 출금 계좌 국민은행 ····0001'),
      findsOneWidget,
      reason: '카드 번호와 출금 계좌(은행·끝 번호)를 구분해 보인다',
    );
    expect(_in('flow-scope-unknown-$_hyundai', '출금 계좌 미확인'), findsOneWidget);
    expect(find.text('국민 체크카드'), findsNothing, reason: '출금 계좌가 계산 제외 계좌');
    expect(
      find.byKey(const ValueKey('flow-change-selection')),
      findsNothing,
      reason: '저장 연결이 없으면 계산할 계좌 바꾸기 없음',
    );
  });

  testWidgets('월급 입금 확인 전: 지난 계산 기간과 상태를 안내하고 전체 거래 보기를 둔다', (tester) async {
    var all = 0;
    await _pump(tester, readSource('salary-wait'), onShowAll: () => all++);
    expect(find.text('지난 계산 기간'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-awaiting')), findsOneWidget);
    final button = find.byKey(const ValueKey('tx-action-전체 거래 보기'));
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    expect(all, 1);
  });

  testWidgets('월급 주기를 알 수 없으면 기간을 만들지 않고 거래 없음과 구분한다', (tester) async {
    var all = 0;
    await _pump(tester, readSource('alpha-ready'), onShowAll: () => all++);
    expect(find.byKey(const ValueKey('flow-period-unknown')), findsOneWidget);
    expect(find.text('조회 기간을 확인할 수 없어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-empty')), findsNothing);
    expect(find.byKey(const ValueKey('flow-chip-kind')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tx-action-전체 거래 보기')));
    expect(all, 1);
  });

  testWidgets('개별 조회는 이 화면의 월급 주기로 실제 거르고, 바꾸기·기간 변경 뒤에도 이어지며 부모는 그대로', (
    tester,
  ) async {
    final state = await _pump(tester, alphaWithReceipt());
    await tester.tap(find.byKey(const ValueKey('flow-chip-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-kind-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-pick-instrument')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-scope-$_kb')));
    await tester.pumpAndSettle();
    expect(find.byType(InstrumentPage), findsOneWidget);
    expect(_in('account-tx-title', '입출금 통장'), findsOneWidget);
    expect(find.text('계산에 포함'), findsOneWidget);
    expect(_in('period-title', '9/25 – 10/24'), findsOneWidget);
    final list = find.descendant(
      of: find.byKey(const ValueKey('transactions-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('9월 25일 금요일'),
      300,
      scrollable: list.first,
    );
    expect(
      find.text('9월 25일 금요일'),
      findsOneWidget,
      reason: '9월 거래도 실제 목록에 들어간다(달을 걸친 주기)',
    );
    expect(find.text('9월 24일 목요일'), findsNothing, reason: '시작일 전은 빠진다');

    await tester.tap(find.byKey(const ValueKey('instrument-switch')));
    await tester.pumpAndSettle();
    expect(_in('instrument-choice-$_kb', '보는 중'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'instrument-choice-48feba1a-c98e-5d0e-91e1-23d8e1ef00fc',
        ),
      ),
      findsNothing,
      reason: '이번 기간 대상 안에서만 바꾼다',
    );
    await tester.tap(find.byKey(const ValueKey('instrument-choice-$_hyundai')));
    await tester.pumpAndSettle();
    expect(_in('account-tx-title', '현대 신용카드'), findsOneWidget);
    expect(find.text('카드 사용·환불'), findsOneWidget);
    expect(
      _in('period-title', '9/25 – 10/24'),
      findsOneWidget,
      reason: '바꾸기 뒤 기간 유지',
    );

    await tester.tap(find.byKey(const ValueKey('period-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('period-cycle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('period-thisMonth')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('instrument-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('instrument-choice-$_kb')));
    await tester.pumpAndSettle();
    expect(
      _in('period-title', '2026년 10월'),
      findsOneWidget,
      reason: '개별 화면에서 바꾼 기간을 유지',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(InstrumentPage), findsNothing);
    expect(_in('flow-chip-kind', '계좌 입출금'), findsOneWidget, reason: '부모 조건 유지');
    expect(find.text('9/25 – 10/24'), findsOneWidget, reason: '부모 기간 유지');
    final accounts = state.value.calculation.snapshot.accounts!;
    expect(
      [
        for (final a in accounts)
          if (a.included) a.accountId,
      ],
      hasLength(2),
      reason: '조회 대상 바꾸기는 계산 포함 계좌를 바꾸지 않는다',
    );
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('320dp·글자 $scale배에서 넘치지 않는다', (tester) async {
      await _pump(tester, alphaWithReceipt(), width: 320, textScale: scale);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('flow-pick-instrument')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('flow-scope-$_kb')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
