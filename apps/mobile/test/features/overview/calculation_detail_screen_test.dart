import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;
import 'package:payse/shared/design/amount_format.dart';
import 'package:payse/features/overview/calculation_detail_screen.dart';
import 'package:payse/features/overview/composition_bar.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

// 02-2 계산 내역(#28 2단계). 입력은 공통 더미 사본(메모리)이며 원본 파일은 바꾸지 않는다.
const mainAccount = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const savingsAccount = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const excludedAccount = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';

/// 2026-10-26: [json]으로 한 번 계산한 결과. 02-2는 계산을 마친 결과만 연다.
HomeCalculationReady ready(Map<String, Object?> json) =>
    computeHomeCalculation(FinancialSnapshot.fromJson(json))
        as HomeCalculationReady;

/// 2026-10-26: 02-2 화면만 띄운다. [textScale]은 기기 글자 크기 배율이다.
Widget detail(HomeCalculationReady calculation, {double textScale = 1}) =>
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CalculationDetailScreen(calculation: calculation),
    );

/// 2026-10-26: 포함 계좌 잔액을 주계좌 [main]·적금 [savings]로 바꾼 정상 근거 사본.
Map<String, Object?> withBalances(int main, int savings) {
  final json = alphaWithReceipt();
  for (final a in rows(json, 'accounts')) {
    if (a['accountId'] == mainAccount) a['balanceKRW'] = main;
    if (a['accountId'] == savingsAccount) a['balanceKRW'] = savings;
  }
  return json;
}

/// 2026-10-26: 화면 예시 데이터(#100 미반영): 제외 계좌에서 10/20에 나갈 보험료 30,000원을 더한 사본.
Map<String, Object?> withExcludedInsurance() {
  final json = alphaWithReceipt();
  final first = rows(json, 'obligations').first;
  (json['obligations']! as List).add({
    ...first,
    'obligationId': '00000000-0000-5000-8000-0000000000a1',
    'label': '보험료',
    'withdrawalAccountId': excludedAccount,
    'amountKRW': 30000,
    'dueDate': '2026-10-20',
    'statementId': null,
    'recurringPlanId': null,
    'recurrenceKey': null,
    'planRevisionId': null,
  });
  return json;
}

/// 2026-10-26: 영수증·묶음의 모든 펼침 행과 일부 출금 항목을 펼친다.
Future<void> expandAll(WidgetTester tester) async {
  for (final key in [
    'receipt-accounts',
    'receipt-reserves',
    'receipt-scheduled',
    'group-awaiting',
    'group-settled',
    'group-next',
    'group-excluded',
  ]) {
    final row = find.byKey(ValueKey(key));
    if (row.evaluate().isEmpty) continue;
    final head = find.descendant(of: row, matching: find.byType(InkWell));
    if (head.evaluate().isEmpty) continue;
    await tester.ensureVisible(head.first);
    await tester.tap(head.first);
    await tester.pump();
  }
  final partial = find.text('일부 출금');
  if (partial.evaluate().isNotEmpty) {
    await tester.ensureVisible(partial.first);
    await tester.tap(partial.first);
    await tester.pump();
  }
}

/// 2026-10-26: [row] 행 안에 [text]가 한 번 보이는지 확인한다.
void expectIn(String row, String text) => expect(
  find.descendant(of: find.byKey(ValueKey(row)), matching: find.text(text)),
  findsWidgets,
  reason: '$row 안의 $text',
);

/// 2026-10-26: 화면 폭을 [width]dp로 맞추고 테스트 뒤 되돌린다.
void useWidth(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('① 정상: 기간·시간축·3구간 바·영수증 합계를 계산 결과 그대로 보인다', (tester) async {
    await tester.pumpWidget(detail(ready(withExcludedInsurance())));
    expect(find.text('계산 내역'), findsOneWidget);
    expect(find.text('이번 계산 기간 9/25 – 10/24'), findsOneWidget);
    expect(find.text('기준일 10/19 · 다음 월급일 10/25'), findsOneWidget);
    expect(find.text('10/19 기준'), findsOneWidget);
    expect(find.text('10/25 월급일'), findsOneWidget);
    expect(
      tester.getRect(find.text('10/25 월급일')).right,
      closeTo(
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 24,
        0.5,
      ),
      reason: '월급일 날짜는 오른쪽 여백 끝에 맞춘다',
    );
    expect(find.text('10/19 12:00 금융정보 기준'), findsOneWidget);
    expect(find.byKey(const ValueKey('composition-bar')), findsOneWidget);
    final segments = find.descendant(
      of: find.byKey(const ValueKey('composition-bar')),
      matching: find.byType(DecoratedBox),
    );
    expect(segments, findsNWidgets(3));
    for (final e in segments.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, 6);
      expect(tester.getSize(find.byWidget(e.widget)).width, greaterThan(0));
    }
    expect(find.textContaining('쓸 수 있는 돈'), findsNWidgets(3));

    expect(find.text('2,000,000원'), findsOneWidget);
    expect(find.text('−340,000원'), findsOneWidget);
    expect(find.text('−360,000원'), findsOneWidget);
    expect(find.text('1,300,000원'), findsOneWidget);
    expect(
      find.text('현재 비상금 400,000원 중 60,000원은 예정 지출에 쓸 예정이에요.'),
      findsOneWidget,
    );
    expect(find.textContaining('월세'), findsNothing, reason: '처음에는 모두 접혀 있다');
    expect(find.text('처음 등록한 예정 금액'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('receipt-scheduled')));
    await tester.pump();
    final receiptLines = find.descendant(
      of: find.byType(CalculationDetailScreen),
      matching: find.byWidgetPredicate(
        (w) => w is Divider && w.color == const Color(0xFFECEEF1),
      ),
    );
    final charcoalLines = find
        .byWidgetPredicate(
          (w) => w is Divider && w.color == const Color(0xFF242629),
        )
        .evaluate()
        .toList();
    final doubleLineTop = (charcoalLines[1].renderObject! as RenderBox)
        .localToGlobal(Offset.zero)
        .dy;
    for (final e in receiptLines.evaluate()) {
      final box = e.renderObject! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      expect(
        bottom < doubleLineTop - 9 || bottom > doubleLineTop,
        isTrue,
        reason: '이중선 바로 위에 회색 구분선을 두지 않는다',
      );
    }
    expect(find.textContaining('월세'), findsOneWidget);
    expect(find.text('예정일 10/22'), findsOneWidget);
    expect(find.text('D-3'), findsOneWidget);
    expect(find.text('예정일 10/18 지남 · 현재 비상금에서 사용 예정'), findsOneWidget);

    expect(find.textContaining('출금 완료 내역'), findsOneWidget);
    expect(find.text('150,000원'), findsOneWidget);
    expect(find.text('아래 지출이 빠져나간 뒤의 잔액으로 계산했어요.'), findsOneWidget);
    expect(find.textContaining('다음 기간 지출'), findsOneWidget);
    expect(find.text('다음 계산 기간에 나갈 돈이라, 이번 계산에서는 빼지 않아요.'), findsOneWidget);
    expect(find.textContaining('제외 계좌 지출'), findsOneWidget);
    expect(find.text('30,000원'), findsOneWidget);
    expect(find.textContaining('입금 확인 후 반영할 지출'), findsNothing);
    expect(find.byKey(const ValueKey('detail-awaiting-notice')), findsNothing);
    expect(find.text(CalculationDetailScreen.footnote), findsOneWidget);
  });

  testWidgets('펼침: 계좌·모아둘 돈·일부 출금·묶음 내역을 원천 이름과 계산값으로 보인다', (tester) async {
    await tester.pumpWidget(detail(ready(withExcludedInsurance())));
    await tester.tap(find.textContaining('계좌 잔액'));
    await tester.tap(find.textContaining('모아둘 돈').last);
    await tester.pump();
    expect(find.text('월급 계좌'), findsOneWidget);
    expect(find.text('1,500,000원'), findsOneWidget);
    expect(find.text('500,000원'), findsOneWidget);
    expect(find.textContaining('현재 비상금'), findsWidgets);
    expect(find.text('설정한 금액'), findsOneWidget);
    expect(find.text('예정 지출에 쓸 금액 · 예정일 10/18'), findsOneWidget);
    expect(find.text('−60,000원'), findsOneWidget);
    expect(find.text('쓰지 않고 남겨둘 금액'), findsOneWidget);
    expect(find.textContaining('으로 설정한'), findsNothing);
    expect(find.textContaining('로 쓰기로'), findsNothing);
    expect(find.text('340,000원'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('receipt-scheduled')));
    await tester.tap(find.byKey(const ValueKey('receipt-scheduled')));
    await tester.pump();
    await tester.ensureVisible(find.text('일부 출금'));
    await tester.tap(find.text('일부 출금'));
    await tester.pump();
    expect(find.text('처음 등록한 예정 금액'), findsOneWidget);
    expect(find.text('100,000원'), findsOneWidget);
    expect(find.text('−40,000원'), findsOneWidget);
    expect(find.text('남은 예정 지출'), findsOneWidget);
    expect(find.text('10/16 출금 · 국민은행 ····0001'), findsOneWidget);

    await tester.ensureVisible(find.textContaining('출금 완료 내역'));
    await tester.tap(find.textContaining('출금 완료 내역'));
    await tester.ensureVisible(find.textContaining('제외 계좌 지출'));
    await tester.tap(find.textContaining('제외 계좌 지출'));
    await tester.pump();
    expect(find.text('카드 청구'), findsOneWidget);
    expect(find.text('10/10 출금 · 국민은행 ····0001'), findsOneWidget);
    expect(find.text('110,000원'), findsOneWidget);
    expect(find.textContaining('보험료'), findsOneWidget);
    expect(find.text('계산 제외 계좌'), findsOneWidget);
    expect(find.textContaining('하나은행 ····0003'), findsOneWidget);
  });

  testWidgets('② 0원: 노란 구간 없이 2구간, 결과 0원', (tester) async {
    final calculation = ready(withBalances(200000, 500000));
    expect(compositionBarStateOf(calculation.result), CompositionBarState.zero);
    await tester.pumpWidget(detail(calculation));
    expect(find.byKey(const ValueKey('composition-bar')), findsOneWidget);
    expect(find.text('0원'), findsOneWidget);
    expect(find.textContaining('쓸 수 있는 돈'), findsOneWidget);
  });

  testWidgets('③ 음수·잔액 양수: 빼야 할 돈 기준 바, 잔액 위치, 부족 구간과 필요 금액', (tester) async {
    final calculation = ready(withBalances(0, 500000));
    expect(
      compositionBarStateOf(calculation.result),
      CompositionBarState.shortfall,
    );
    await tester.pumpWidget(detail(calculation));
    expect(find.byKey(const ValueKey('shortfall-bar')), findsOneWidget);
    final shortfallSegments = find.descendant(
      of: find.byKey(const ValueKey('shortfall-bar')),
      matching: find.byType(DecoratedBox),
    );
    expect(shortfallSegments, findsNWidgets(2));
    for (final e in shortfallSegments.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, 6);
    }
    expect(find.text('모아둘 돈 + 예정 지출 700,000원'), findsOneWidget);
    expect(find.text('계좌 잔액 500,000원'), findsOneWidget);
    expect(find.text('200,000원 부족'), findsOneWidget);
    expect(find.text('−200,000원'), findsOneWidget);
    expect(
      find.text('모아둘 돈과 예정 지출을 모두 확보하려면\n200,000원이 더 필요해요.'),
      findsOneWidget,
    );
    final result = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('receipt-result')),
        matching: find.byType(Text),
      ),
    );
    expect(result.style!.color, const Color(0xFFB42318));
  });

  testWidgets('④ 잔액 0원: 바·범례·색 칩 없이 영수증만 보인다', (tester) async {
    final calculation = ready(withBalances(0, 0));
    expect(
      compositionBarStateOf(calculation.result),
      CompositionBarState.noBalance,
    );
    await tester.pumpWidget(detail(calculation));
    expect(find.byKey(const ValueKey('composition-bar')), findsNothing);
    expect(find.byType(ColorChipLabel), findsOneWidget);
    expect(find.text('0원'), findsOneWidget);
    expect(find.text('−700,000원'), findsOneWidget);
    expect(
      find.text('모아둘 돈과 예정 지출을 모두 확보하려면\n700,000원이 더 필요해요.'),
      findsOneWidget,
    );
  });

  testWidgets('⑤ 잔액 음수: 음수 잔액부터 그대로 계산하고 바를 쓰지 않는다', (tester) async {
    final calculation = ready(withBalances(-100000, 0));
    await tester.pumpWidget(detail(calculation));
    expect(find.byKey(const ValueKey('composition-bar')), findsNothing);
    expect(find.text('−100,000원'), findsOneWidget);
    expect(find.text('−800,000원'), findsOneWidget);
  });

  testWidgets('⑥ 정보 부족(공통 더미): 바 대신 사유 안내, 계산 불가와 설정 보호액을 구분한다', (
    tester,
  ) async {
    final calculation = ready(readSource('alpha-ready'));
    await tester.pumpWidget(detail(calculation));
    expect(find.text('계산 기간을 정하지 못했어요'), findsOneWidget);
    expect(find.text('기준일 10/19'), findsOneWidget);
    expect(find.text('10/19 기준'), findsNothing);
    expect(find.byKey(const ValueKey('composition-bar')), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-insufficient-notice')),
      findsOneWidget,
    );
    expect(find.text('지난 월급 입금 정보를 확인할 수 없어 계산하지 않았어요.'), findsOneWidget);
    expect(find.text('2,000,000원'), findsOneWidget);
    expect(find.text('계산 불가'), findsNWidgets(2));
    expect(find.text('현재 비상금'), findsOneWidget);
    expect(find.text('설정한 금액'), findsOneWidget);
    expect(find.text('400,000원'), findsOneWidget);
    expect(find.text('예정 지출에 사용할 금액을 확인할 수 없어요.'), findsOneWidget);
    expect(find.text('계산할 수 없어요'), findsOneWidget);
    expect(find.text('확인 필요'), findsNothing);
    expect(find.text('0원'), findsNothing);
    expect(find.textContaining('출금 완료 내역'), findsOneWidget);
  });

  testWidgets('⑥ 정보 부족(예정 지출 숨김): 기간을 알면 기간·시간축을 유지한다', (tester) async {
    final json = alphaWithReceipt();
    json['accessRestrictions'] = [
      {
        'ownerType': 'response',
        'ownerId': null,
        'field': 'obligations',
        'targetKind': 'planRevision',
        'reason': 'not_connected',
      },
    ];
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(json),
    );
    if (calculation is! HomeCalculationReady) {
      fail('예정 지출 숨김은 정보 부족 결과여야 한다: $calculation');
    }
    expect(calculation.result.u, isNull);
    await tester.pumpWidget(detail(calculation));
    expect(find.text('이번 계산 기간 9/25 – 10/24'), findsOneWidget);
    expect(find.text('10/19 기준'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-insufficient-notice')),
      findsOneWidget,
    );
    expect(find.text('계산할 수 없어요'), findsOneWidget);
  });

  testWidgets('⑦ 입금 확인 전: 바 아래 한 곳에 빠진 지출 합계, 예정 지출은 입금 확인 대기', (tester) async {
    await tester.pumpWidget(detail(ready(readSource('salary-wait'))));
    expect(find.text('이전 계산 기간 9/25 – 10/24'), findsOneWidget);
    expect(find.text('기준일 10/25 · 오늘 월급일 · 월급 입금 확인 전'), findsOneWidget);
    expect(find.byKey(const ValueKey('composition-bar')), findsOneWidget);
    expect(find.text('아직 월급 입금이 확인되지 않았어요'), findsOneWidget);
    expect(
      find.text(
        '아래 지출 410,000원은 현재 금액에 포함하지 않았어요. 입금이 확인되면 다음 월급일까지의 지출과 함께 계산해요.',
      ),
      findsOneWidget,
    );
    expect(find.text('입금 확인 대기'), findsOneWidget);
    expect(find.text('−400,000원'), findsOneWidget);
    expect(find.text('1,600,000원'), findsOneWidget);
    expect(find.textContaining('입금 확인 후 반영할 지출'), findsOneWidget);
    expect(find.text('410,000원'), findsOneWidget);
    expect(find.text('예정일 지남'), findsNothing, reason: '처음에는 접혀 있다');
    await tester.ensureVisible(find.textContaining('입금 확인 후 반영할 지출'));
    await tester.tap(find.textContaining('입금 확인 후 반영할 지출'));
    await tester.pump();
    expect(find.text('예정일 지남'), findsNWidgets(2));
    expect(find.text('오늘'), findsOneWidget);
    expect(find.textContaining('아직 월급 입금이'), findsOneWidget);
  });

  testWidgets('시간축 기준 표시: 10% 이하 왼쪽, 90% 이상 오른쪽, 그 사이 점 기준 가운데', (
    tester,
  ) async {
    useWidth(tester, 300);
    Future<Rect> place(double f) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: AnchoredLabel(
                fraction: f,
                child: const SizedBox(
                  width: 60,
                  height: 10,
                  key: ValueKey('l'),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getRect(find.byKey(const ValueKey('l')));
    }

    expect((await place(0.05)).left, 0);
    expect((await place(0.1)).left, 0);
    expect((await place(0.95)).right, 300);
    expect((await place(0.9)).right, 300);
    expect((await place(0.5)).center.dx, 150);
    expect((await place(0.12)).left, greaterThanOrEqualTo(0));
    expect((await place(0.88)).right, lessThanOrEqualTo(300));
  });

  testWidgets('기간 초반(9/26) 기준 표시는 왼쪽 끝에 맞춰 잘리지 않는다', (tester) async {
    final json = alphaWithReceipt();
    json['asOf'] = '2026-09-26T12:00:00+09:00';
    for (final a in rows(json, 'accounts')) {
      a['asOf'] = '2026-09-26T12:00:00+09:00';
    }
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(json),
    );
    if (calculation is! HomeCalculationReady) {
      fail('9/26 기준 사본은 계산을 마쳐야 한다: $calculation');
    }
    expect(calculation.result.salaryCycle?.periodStart, isNotNull);
    await tester.pumpWidget(detail(calculation));
    final label = tester.getRect(find.text('9/26 기준'));
    expect(label.left, greaterThanOrEqualTo(24));
  });

  for (final (name, json, scale) in [
    ('정상 320', withExcludedInsurance, 1.0),
    ('정상 320 큰 글자', withExcludedInsurance, 1.3),
    ('음수 320 큰 글자', () => withBalances(0, 500000), 1.3),
    ('입금 대기 320 큰 글자', () => readSource('salary-wait'), 1.3),
    ('정상 320 글자 2배', withExcludedInsurance, 2.0),
    ('정보 부족 320 큰 글자', () => readSource('alpha-ready'), 1.3),
  ]) {
    testWidgets('$name: 모두 펼쳐도 넘치지 않고 금액이 한 줄로 남는다', (tester) async {
      useWidth(tester, 320);
      await tester.pumpWidget(detail(ready(json()), textScale: scale));
      await expandAll(tester);
      expect(tester.takeException(), isNull);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        if ((text.data ?? '').endsWith('원')) expect(text.maxLines ?? 1, 1);
      }
    });
  }

  for (final (name, json) in [
    ('정상·부분 출금·비상금 배정', withExcludedInsurance),
    ('음수', () => withBalances(0, 500000)),
    ('입금 확인 전', () => readSource('salary-wait')),
  ]) {
    testWidgets('영수증 정합성($name): 계산 결과 항등식과 화면 값이 일치한다', (tester) async {
      useWidth(tester, 390);
      final c = ready(json());
      final r = c.result;
      final lines = r.obligationLines!;
      int sum(Iterable<int> xs) => xs.fold(0, (a, b) => a + b);

      expect(sum(r.accountLines!.map((l) => l.balanceKrw)), r.b);
      expect(sum(r.reserveLines!.map((l) => l.effectiveKrw!)), r.rEff);
      expect(sum(r.reserveLines!.map((l) => l.usedKrw!)), r.o);
      for (final l in r.reserveLines!) {
        expect(l.amountKrw - l.usedKrw!, l.effectiveKrw);
        expect(sum(l.overlaps!.map((o) => o.unreleasedKrw)), l.usedKrw);
      }
      for (final l in lines) {
        expect(l.amountKrw - l.settledKrw, l.remainingKrw);
      }
      for (final entry in r.placementTotals!.entries) {
        final at = lines.where((l) => l.placement == entry.key);
        expect(entry.value.count, at.length);
        expect(entry.value.totalKrw, sum(at.map((l) => l.remainingKrw)));
      }
      final inPeriod = lines.where(
        (l) => l.placement == calc.ObligationPlacement.inCurrentPeriod,
      );
      expect(sum(inPeriod.map((l) => l.remainingKrw)), r.e);
      expect(r.b! - r.rEff! - r.e!, r.u);
      expect(r.b! - r.deductionKrw!, r.u);
      expect(r.settledTotal!.totalKrw, sum(lines.map((l) => l.settledKrw)));

      await tester.pumpWidget(detail(c));
      await expandAll(tester);
      String minus(int v) => v == 0 ? formatKrw(0) : formatKrw(-v);
      expectIn('receipt-accounts', formatKrw(r.b!));
      for (final l in r.accountLines!) {
        expectIn('receipt-accounts', formatKrw(l.balanceKrw));
      }
      expectIn('receipt-reserves', minus(r.rEff!));
      for (final l in r.reserveLines!) {
        expectIn('receipt-reserves', formatKrw(l.amountKrw));
        expectIn('receipt-reserves', formatKrw(l.effectiveKrw!));
        for (final o in l.overlaps!) {
          expectIn('receipt-reserves', formatKrw(-o.unreleasedKrw));
        }
      }
      expectIn('receipt-scheduled', minus(r.e!));
      for (final l in inPeriod) {
        expectIn('receipt-scheduled', formatKrw(l.remainingKrw));
        if (l.settledKrw > 0) {
          expectIn('receipt-scheduled', formatKrw(l.amountKrw));
          expectIn('receipt-scheduled', formatKrw(-l.settledKrw));
        }
      }
      expectIn('receipt-result', formatKrw(r.u!));
      final groups = {
        calc.ObligationPlacement.awaitingSalary: 'group-awaiting',
        calc.ObligationPlacement.outsidePeriod: 'group-next',
        calc.ObligationPlacement.excludedAccount: 'group-excluded',
      };
      for (final MapEntry(:key, :value) in groups.entries) {
        final total = r.placementTotals![key];
        if (total == null) continue;
        expectIn(value, formatKrw(total.totalKrw));
        for (final l in lines.where((l) => l.placement == key)) {
          expectIn(value, formatKrw(l.remainingKrw));
        }
      }
      if (r.settledTotal!.count > 0) {
        expectIn('group-settled', formatKrw(r.settledTotal!.totalKrw));
        for (final l in lines.where((l) => l.settledKrw > 0)) {
          expectIn('group-settled', formatKrw(l.settledKrw));
        }
      }
    });
  }

  testWidgets('홈 계산 내역 보기: 같은 계산 결과 객체로 02-2를 연다', (tester) async {
    final calculation = ready(alphaWithReceipt());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: Scaffold(
          body: HomeScreen(calculation: calculation, onReload: () {}),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('home-detail-button'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final screen = tester.widget<CalculationDetailScreen>(
      find.byType(CalculationDetailScreen),
    );
    expect(identical(screen.calculation, calculation), isTrue);
    expect(find.text('1,300,000원'), findsOneWidget);

    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.byType(CalculationDetailScreen), findsNothing);
  });

  testWidgets('데이터 오류 홈에는 계산 내역 진입점이 없다', (tester) async {
    final json = alphaWithReceipt();
    rows(json, 'settlements').first['allocatedKRW'] = 999999999;
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(json),
    );
    expect(calculation, isA<HomeCalculationDataError>());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: Scaffold(
          body: HomeScreen(calculation: calculation, onReload: () {}),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('home-detail-button')), findsNothing);
  });
}
