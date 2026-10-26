import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/calculation_input_adapter.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/shared/design/amount_hero.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/calculation_input_adapter_test.dart'
    show alphaWithReceipt, salaryOf, septemberSalaryTx;
import '../../data/connection/connection_test_utils.dart';

Widget home(HomeCalculation calculation, {VoidCallback? onReload}) =>
    MaterialApp(
      theme: buildPayseTheme(),
      home: Scaffold(
        body: HomeScreen(calculation: calculation, onReload: onReload ?? () {}),
      ),
    );

HomeCalculation calculate(Map<String, Object?> json) =>
    computeHomeCalculation(FinancialSnapshot.fromJson(json));

void main() {
  testWidgets('정상: 쓸 수 있는 돈·기준 시각·장부(B, R−O, E)를 같은 결과로 보인다', (tester) async {
    await tester.pumpWidget(home(calculate(alphaWithReceipt())));
    expect(find.text('다음 월급일까지 쓸 수 있는 돈'), findsOneWidget);
    expect(find.text('월급까지 6일'), findsOneWidget);
    expect(find.text('9/25 – 10/24'), findsOneWidget);
    expect(find.text('월급일 전 2건'), findsOneWidget);
    expect(find.text('10월 19일 12:00 기준'), findsOneWidget);
    expect(
      find.textContaining('1,300,000', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('계좌 잔액'), findsOneWidget);
    expect(find.text('모아둘 돈'), findsOneWidget);
    expect(find.text('예정 지출'), findsOneWidget);
    expect(
      find.text('설정 400,000원 중 예정 지출에 들어 있는 60,000원은 모아둘 돈에서 다시 빼지 않아요'),
      findsOneWidget,
    );
    expect(find.text('2,000,000원'), findsOneWidget);
    expect(find.text('340,000원'), findsOneWidget);
    expect(find.text('360,000원'), findsOneWidget);
  });

  testWidgets('음수: −와 부족 문장을 보이고 0원으로 바꾸지 않는다', (tester) async {
    final json = alphaWithReceipt();
    for (final a in rows(json, 'accounts')) {
      if (a['included'] == true) a['balanceKRW'] = 100000;
    }
    await tester.pumpWidget(home(calculate(json)));
    expect(find.text('모아둘 돈과 예정 지출을 빼면 500,000원이 부족해요.'), findsOneWidget);
    expect(find.textContaining('−500,000', findRichText: true), findsOneWidget);
    expect(find.text('0원'), findsNothing);
  });

  testWidgets('정보 부족: 공통 더미(근거 부재)는 계산할 수 없어요와 사유를 보이고 0원이 없다', (tester) async {
    await tester.pumpWidget(home(calculate(readSource('alpha-ready'))));
    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expect(find.text('지난 월급 입금 정보를 확인할 수 없어 계산하지 않았어요.'), findsOneWidget);
    expect(find.text('월급 정보 확인 필요'), findsOneWidget);
    expect(find.text('계좌 잔액'), findsOneWidget);
    expect(find.text('예정 지출'), findsNothing);
  });

  testWidgets('정보 부족: 같은 예정일 회차를 구분해야 하면 계산하지 못한 이유를 보이고 0원이 없다', (
    tester,
  ) async {
    final json = alphaWithReceipt();
    (salaryOf(json)['receiptEvidence']! as List).add({
      'payMonth': '2026-10',
      'expectedPayDate': '2026-09-25',
      'transactionIds': <String>[],
      'confirmation': 'unknown',
    });
    await tester.pumpWidget(home(calculate(json)));
    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expect(
      find.text('월급 예정일이 겹쳐 다음 월급일까지 쓸 수 있는 돈을 계산하지 못했어요.'),
      findsOneWidget,
    );
    expect(find.text('0원'), findsNothing);
  });

  // 2026-10-26: 8월분은 9월분과 다른 별도 입금 거래를 참조한다(테스트 입력 사본, 원천 자산은 그대로).
  Map<String, Object?> withAugustOnSameDate(String confirmation) {
    const augustTx = 'test-august-salary-on-0925';
    final json = alphaWithReceipt();
    final september = rows(
      json,
      'transactions',
    ).firstWhere((t) => t['transactionId'] == septemberSalaryTx);
    (json['transactions']! as List).add({
      ...september,
      'transactionId': augustTx,
    });
    (salaryOf(json)['receiptEvidence']! as List).add({
      'payMonth': '2026-08',
      'expectedPayDate': '2026-09-25',
      'transactionIds': confirmation == 'unknown' ? <String>[] : [augustTx],
      'confirmation': confirmation,
    });
    return json;
  }

  testWidgets('같은 예정일이어도 회차가 각자 입금 거래로 모두 확인되면 겹침 안내가 없다', (tester) async {
    await tester.pumpWidget(home(calculate(withAugustOnSameDate('confirmed'))));
    expect(find.text(AmountHero.unavailableText), findsNothing);
    expect(find.textContaining('월급 예정일이 겹쳐'), findsNothing);
  });

  testWidgets('같은 예정일의 앞 회차만 미확인이면 계산을 제한하고 겹침 안내를 보인다', (tester) async {
    await tester.pumpWidget(home(calculate(withAugustOnSameDate('unknown'))));
    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expect(
      find.text('월급 예정일이 겹쳐 다음 월급일까지 쓸 수 있는 돈을 계산하지 못했어요.'),
      findsOneWidget,
    );
  });

  testWidgets('입금 대기 09-14: 월급일 당일 입금 전, 반영 대기 의무를 경고로 알린다', (tester) async {
    await tester.pumpWidget(home(calculate(readSource('salary-wait'))));
    expect(find.text('오늘은 월급일 · 입금 확인 전'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-awaiting-notice')), findsOneWidget);
    expect(find.textContaining('취소되거나 낸 것으로 바뀐 것은 아니에요'), findsOneWidget);
  });

  testWidgets('입금 대기 09-15: 월급일이 지나도 확인 전이면 미입금 상태', (tester) async {
    final json = readSource('salary-wait');
    json['asOf'] = '2026-10-26T09:00:00+09:00';
    for (final a in rows(json, 'accounts')) {
      a['asOf'] = '2026-10-26T09:00:00+09:00';
    }
    await tester.pumpWidget(home(calculate(json)));
    expect(find.text('월급 입금 확인 전'), findsOneWidget);
  });

  testWidgets('데이터 오류: 금액을 보이지 않고 다시 불러오기만 준다', (tester) async {
    var reloads = 0;
    final json = alphaWithReceipt();
    salaryOf(json)['receiptEvidence'] = [
      {
        'payMonth': '2026-09',
        'expectedPayDate': '2026-09-25',
        'transactionIds': ['missing-tx'],
        'confirmation': 'confirmed',
      },
    ];
    final calculation = calculate(json);
    expect(calculation, isA<HomeCalculationDataError>());
    await tester.pumpWidget(home(calculation, onReload: () => reloads++));
    expect(find.byKey(const ValueKey('home-data-error')), findsOneWidget);
    expect(find.textContaining('원', findRichText: true), findsNothing);
    expect(find.textContaining('해결'), findsNothing);
    await tester.tap(find.text('다시 불러오기'));
    expect(reloads, 1);
  });

  testWidgets('계산 패키지 입력 검사 위반(초과 배정)도 데이터 오류', (tester) async {
    final json = alphaWithReceipt();
    rows(json, 'allocations').first['amountKRW'] = 500000;
    expect(calculate(json), isA<HomeCalculationDataError>());
  });

  testWidgets('예상하지 못한 오류는 데이터 오류·정보 부족과 구분해 보고한다', (tester) async {
    final reported = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    final snapshot = FinancialSnapshot.fromJson(alphaWithReceipt());
    final HomeCalculation calculation;
    // 실패해도 원래 처리기를 되돌려야 테스트가 시간 초과로 멈추지 않는다.
    FlutterError.onError = reported.add;
    try {
      calculation = computeHomeCalculation(
        snapshot,
        toInputs: (_) => throw StateError('bug'),
      );
    } finally {
      FlutterError.onError = original;
    }
    expect(calculation, isA<HomeCalculationUnexpectedError>());
    expect(reported.single.exception, isA<StateError>());
    await tester.pumpWidget(home(calculation));
    expect(find.byKey(const ValueKey('home-unexpected-error')), findsOneWidget);
  });

  testWidgets('계약 예외 종류만 데이터 오류로 바꾼다', (tester) async {
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(alphaWithReceipt()),
      toInputs: (_) => throw const CalculationContractException(r'$', 'test'),
    );
    expect(calculation, isA<HomeCalculationDataError>());
  });

  testWidgets('320dp·글자 2배에서도 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final json = alphaWithReceipt();
    for (final a in rows(json, 'accounts')) {
      if (a['included'] == true) a['balanceKRW'] = 4000000000000;
    }
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 568),
          textScaler: TextScaler.linear(2),
        ),
        child: home(calculate(json)),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('근거 거래 ID 상수는 공통 더미의 9/25 급여 입금이다', () {
    final tx = rows(
      readSource('alpha-ready'),
      'transactions',
    ).firstWhere((t) => t['transactionId'] == septemberSalaryTx);
    expect([tx['bookingDate'], tx['direction']], ['2026-09-25', 'in']);
  });
}
