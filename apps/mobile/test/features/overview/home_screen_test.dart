import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/calculation_input_adapter.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/calculation_detail_screen.dart';
import 'package:payse/features/overview/composition_bar.dart';
import 'package:payse/features/overview/cycle_moon.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/shared/design/amount_hero.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/primary_button.dart';

import '../../data/calculation_input_adapter_test.dart'
    show alphaWithReceipt, salaryOf, septemberSalaryTx;
import '../../data/connection/connection_test_utils.dart';

Widget home(
  HomeCalculation calculation, {
  VoidCallback? onReload,
  HomeSalaryRecord record = HomeSalaryRecord.none,
}) => MaterialApp(
  theme: buildPayseTheme(),
  home: Scaffold(
    body: HomeScreen(
      calculation: calculation,
      onReload: onReload ?? () {},
      record: record,
    ),
  ),
);

/// 2026-10-26: 홈 주기 줄 달의 밝은 면 비율(null이면 위상 없는 자리 표시).
double? moonLit(WidgetTester tester) =>
    tester.widget<CycleMoon>(find.byKey(const ValueKey('home-cycle-moon'))).lit;

/// 2026-10-26: 홈 장부 행 [key] 안에 [text]가 보이는지 확인한다.
void expectRow(String key, String text) => expect(
  find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text)),
  findsOneWidget,
  reason: '$key 행의 $text',
);

/// 2026-10-26: 테두리 버튼 [key]가 보이고 비활성인지 확인한다.
void expectDisabledButton(WidgetTester tester, String key) {
  final button = tester.widget<OutlinedButton>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(OutlinedButton),
    ),
  );
  expect(button.onPressed, isNull, reason: '$key는 4단계에서 연결하기 전까지 비활성');
  expect(
    tester.getSemantics(find.byKey(ValueKey(key))),
    isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    reason: '$key는 누를 수 없음을 접근성 상태로도 알린다',
  );
}

HomeCalculation calculate(Map<String, Object?> json) =>
    computeHomeCalculation(FinancialSnapshot.fromJson(json));

void main() {
  testWidgets('정상: 쓸 수 있는 돈·기준 시각·장부(B, R−O, E)를 같은 결과로 보인다', (tester) async {
    final calculation = calculate(alphaWithReceipt()) as HomeCalculationReady;
    final r = calculation.result;
    expect(r.b! - r.rEff! - r.e!, r.u, reason: '장부 금액의 합이 U와 같다');
    await tester.pumpWidget(home(calculation));
    expect(find.text(HomeScreen.amountLabel), findsOneWidget);
    expect(find.text('월급까지 6일'), findsOneWidget);
    expect(find.text('9/25 – 10/24'), findsOneWidget);
    expect(find.text('10월 19일 12:00 기준'), findsOneWidget);
    expect(
      find.textContaining('1,300,000', findRichText: true),
      findsOneWidget,
    );
    expectRow('home-row-balance', '2,000,000원');
    expectRow('home-row-reserve', '−340,000원');
    expectRow('home-row-reserve', '1건');
    expectRow('home-row-scheduled', '−360,000원');
    expectRow('home-row-scheduled', '월급일 전 2건');
    expect(find.byKey(const ValueKey('composition-bar')), findsOneWidget);
    expect(find.byType(ColorChipLabel), findsNothing, reason: '홈 구성 바는 범례가 없다');
    expect(find.textContaining('다시 빼지 않아요'), findsNothing);
    expect(
      find.byKey(const ValueKey('home-salary-check-button')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('home-first-calc-button')), findsNothing);
    expect(find.byKey(const ValueKey('home-negative-notice')), findsNothing);
  });

  testWidgets('정상: 장부의 모아둘 돈·예정 지출 행은 02-2 계산 내역을 연다', (tester) async {
    final calculation = calculate(alphaWithReceipt()) as HomeCalculationReady;
    await tester.pumpWidget(home(calculation));
    await tester.tap(find.byKey(const ValueKey('home-row-scheduled')));
    await tester.pumpAndSettle();
    final screen = tester.widget<CalculationDetailScreen>(
      find.byType(CalculationDetailScreen),
    );
    expect(identical(screen.calculation, calculation), isTrue);
  });

  testWidgets('머리의 다시 불러오기 아이콘은 진입 조회를 다시 실행한다', (tester) async {
    var reloads = 0;
    await tester.pumpWidget(
      home(calculate(alphaWithReceipt()), onReload: () => reloads++),
    );
    await tester.tap(find.byTooltip('다시 불러오기'));
    expect(reloads, 1);
  });

  testWidgets('음수: −와 부족 문장을 보이고 0원으로 바꾸지 않는다', (tester) async {
    final json = alphaWithReceipt();
    for (final a in rows(json, 'accounts')) {
      if (a['included'] == true) a['balanceKRW'] = 100000;
    }
    await tester.pumpWidget(home(calculate(json)));
    expect(find.byKey(const ValueKey('home-negative-notice')), findsOneWidget);
    expect(find.text('계획한 금액보다 잔액이 부족해요'), findsOneWidget);
    expect(
      find.text('모아둘 돈과 예정 지출을 모두 확보하려면 500,000원이 더 필요해요.'),
      findsOneWidget,
    );
    expect(find.textContaining('−500,000', findRichText: true), findsOneWidget);
    expect(find.text('0원'), findsNothing);
    expect(find.byKey(const ValueKey('composition-bar')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-row-reserve')),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFF555A61),
        ),
      ),
      findsNothing,
      reason: '바가 없는 음수 홈은 색 칩이 없다',
    );
  });

  testWidgets('정보 부족: 공통 더미(근거 부재)는 통일 문구와 사유를 보이고 0원이 없다', (tester) async {
    await tester.pumpWidget(home(calculate(readSource('alpha-ready'))));
    expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
    expect(find.text('9/25에 예정된 월급의 입금 여부를 확인할 정보가 없어요.'), findsOneWidget);
    expect(find.text('월급 입금 확인 필요'), findsOneWidget);
    expect(moonLit(tester), isNull, reason: '주기를 정할 수 없으면 위상 없는 자리 표시');
    expectRow('home-row-balance', '2,000,000원');
    expectRow('home-row-reserve', '계산 불가');
    expectRow('home-row-scheduled', '계산 불가');
    for (final row in [
      'home-row-balance',
      'home-row-reserve',
      'home-row-scheduled',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey(row)),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
        reason: '값을 모르는 행은 화살표가 없다',
      );
    }
    expect(find.byKey(const ValueKey('composition-bar')), findsNothing);
    expectDisabledButton(tester, 'home-salary-check-button');
    expect(find.byKey(const ValueKey('home-reported-label')), findsNothing);
    expect(find.byKey(const ValueKey('home-detail-button')), findsOneWidget);
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
    expect(
      find.byKey(const ValueKey('home-salary-check-button')),
      findsNothing,
      reason: '월급 입금 확인하기는 지난 회차 근거 부재에만 둔다',
    );
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
    expect(find.text('월급 입금 확인 전이에요'), findsOneWidget);
    expect(
      find.text(
        '예정 지출 410,000원은 현재 금액에 포함하지 않았어요. 입금이 확인되면 다음 기간의 지출과 함께 다시 계산해요.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('composition-bar')), findsOneWidget);
    expectRow('home-row-scheduled', '입금 확인 대기');
    expectRow('home-row-scheduled', '0원');
    expectRow('home-row-reserve', '−400,000원');
    final notice = tester.getRect(
      find.byKey(const ValueKey('home-awaiting-notice')),
    );
    final bar = tester.getRect(find.byKey(const ValueKey('composition-bar')));
    final ledger = tester.getRect(
      find.byKey(const ValueKey('home-row-balance')),
    );
    expect(notice.top - bar.bottom, closeTo(20, 0.5), reason: '바 → 20 → 경고');
    expect(
      ledger.top - notice.bottom,
      closeTo(21, 0.5),
      reason: '경고 → 20 → 구분선(1) → 장부',
    );
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

  testWidgets('정보 부족·미입금 내가 확인한 상태(입력 예시): 상태 라벨과 안내, 비활성 확인 버튼', (
    tester,
  ) async {
    await tester.pumpWidget(
      home(
        calculate(readSource('alpha-ready')),
        record: HomeSalaryRecord.reportedNotDeposited,
      ),
    );
    expect(find.text('9/25 예정 월급 미입금 · 내가 확인한 상태'), findsOneWidget);
    expect(
      find.text('월급 정보 확인 필요'),
      findsOneWidget,
      reason: '별도 상태라 통일 문구를 쓰지 않는다',
    );
    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expect(moonLit(tester), isNull);
    expect(
      find.text('현재는 쓸 수 있는 돈을 계산하기 어려워요. 입금되면 아래에서 거래를 선택해 주세요.'),
      findsOneWidget,
    );
    expect(find.text('9/25에 예정된 월급의 입금 여부를 확인할 정보가 없어요.'), findsNothing);
    expect(find.text(AmountHero.unavailableText), findsOneWidget);
    expectRow('home-row-balance', '2,000,000원');
    expectDisabledButton(tester, 'home-salary-check-button');
  });

  testWidgets('미입금 기록이 있어도 계산이 가능해지면 표시하지 않는다', (tester) async {
    await tester.pumpWidget(
      home(
        calculate(alphaWithReceipt()),
        record: HomeSalaryRecord.reportedNotDeposited,
      ),
    );
    expect(find.byKey(const ValueKey('home-reported-label')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-salary-check-button')),
      findsNothing,
    );
  });

  testWidgets('나중에 해결한 뒤(입력 예시): 정상 홈 장부 아래 비활성 첫 계산 과정 버튼', (tester) async {
    await tester.pumpWidget(
      home(
        calculate(alphaWithReceipt()),
        record: HomeSalaryRecord.resolvedAfterFirstCalc,
      ),
    );
    expect(find.text('처음 계산 과정을 단계별로 보기'), findsOneWidget);
    expectDisabledButton(tester, 'home-first-calc-button');
    final ledger = tester.getRect(
      find.byKey(const ValueKey('home-row-scheduled')),
    );
    final button = tester.getRect(
      find.byKey(const ValueKey('home-first-calc-button')),
    );
    expect(button.top - ledger.bottom, closeTo(24, 0.5));
    await tester.tap(find.byKey(const ValueKey('home-first-calc-button')));
    await tester.pumpAndSettle();
    expect(find.byType(CalculationDetailScreen), findsNothing);
  });

  testWidgets('해결 뒤 기록이어도 아직 정보 부족이면 첫 계산 과정 버튼이 없다', (tester) async {
    await tester.pumpWidget(
      home(
        calculate(readSource('alpha-ready')),
        record: HomeSalaryRecord.resolvedAfterFirstCalc,
      ),
    );
    expect(find.byKey(const ValueKey('home-first-calc-button')), findsNothing);
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

  for (final (name, json, record) in [
    (
      '음수',
      () {
        final j = alphaWithReceipt();
        for (final a in rows(j, 'accounts')) {
          if (a['included'] == true) a['balanceKRW'] = 100000;
        }
        return j;
      },
      HomeSalaryRecord.none,
    ),
    ('입금 대기', () => readSource('salary-wait'), HomeSalaryRecord.none),
    (
      '미입금 확인',
      () => readSource('alpha-ready'),
      HomeSalaryRecord.reportedNotDeposited,
    ),
    ('해결 뒤', alphaWithReceipt, HomeSalaryRecord.resolvedAfterFirstCalc),
  ]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('$name 320dp·글자 $scale배에서도 넘치지 않는다', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildPayseTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: HomeScreen(
                calculation: calculate(json()),
                onReload: () {},
                record: record,
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

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

  group('큰 달 주기 연동', () {
    testWidgets('정상 10/19: 계산 패키지 진행률로 밝은 면 10% + 82% × 진행률', (tester) async {
      final calculation = calculate(alphaWithReceipt()) as HomeCalculationReady;
      expect(calculation.result.cycleProgress, closeTo(24 / 29, 1e-9));
      await tester.pumpWidget(home(calculation));
      expect(moonLit(tester), closeTo(0.10 + 0.82 * 24 / 29, 1e-9));
    });

    testWidgets('예정일 도달·입금 확인 전(입금 대기)은 보름달', (tester) async {
      await tester.pumpWidget(home(calculate(readSource('salary-wait'))));
      expect(moonLit(tester), 1);
    });

    test('표시 비율 규칙: 시작 10%, 마지막 날 92%, 입금 대기 100%, 주기 없음 null', () {
      expect(
        moonLitFraction(progress: 0, awaiting: false),
        closeTo(0.10, 1e-9),
      );
      expect(
        moonLitFraction(progress: 1, awaiting: false),
        closeTo(0.92, 1e-9),
      );
      expect(moonLitFraction(progress: null, awaiting: true), 1);
      expect(moonLitFraction(progress: null, awaiting: false), isNull);
    });
  });

  group('새로고침 상태', () {
    testWidgets('새로고침 중: 이전 숫자 대신 로딩 틀, 헤더 [달] 불러오는 중, 계산 내역 보기 비활성', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: Scaffold(
            body: HomeScreen(
              calculation: calculate(alphaWithReceipt()),
              onReload: () {},
              refresh: HomeRefresh.loading,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);
      expect(find.text('불러오는 중'), findsOneWidget);
      expect(find.text('금융 정보를 불러오고 있어요'), findsOneWidget);
      expect(
        find.textContaining('1,300,000', findRichText: true),
        findsNothing,
      );
      expect(find.text('2,000,000원'), findsNothing);
      expect(find.byKey(const ValueKey('home-reload')), findsNothing);
      expect(find.byType(MoonSkeleton), findsOneWidget);
      expect(find.byType(LoadingMoon), findsOneWidget);
      final button = tester.widget<PrimaryButton>(
        find.byKey(const ValueKey('home-detail-button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('동작 줄이기 설정이면 로딩 달이 반달로 멈춘다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: HomeScreen(
              calculation: calculate(alphaWithReceipt()),
              onReload: () {},
              refresh: HomeRefresh.loading,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final moon = tester.widget<CycleMoon>(
        find.descendant(
          of: find.byType(LoadingMoon),
          matching: find.byType(CycleMoon),
        ),
      );
      expect(moon.lit, 0.5);
      expect(find.text('불러오는 중'), findsOneWidget);
    });

    testWidgets('이전 결과가 있는 실패: 금액·장부·기준 시각을 유지하고 안내와 다시 시도', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: Scaffold(
            body: HomeScreen(
              calculation: calculate(alphaWithReceipt()),
              onReload: () => retries++,
              refresh: HomeRefresh.failed,
            ),
          ),
        ),
      );
      expect(find.text('새 정보를 불러오지 못했어요'), findsOneWidget);
      expect(find.text('이전에 불러온 정보를 보여드려요'), findsOneWidget);
      expect(
        find.textContaining('1,300,000', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('10월 19일 12:00 기준'), findsOneWidget);
      expectRow('home-row-balance', '2,000,000원');
      expect(find.textContaining('인터넷'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-refresh-retry')));
      expect(retries, 1);
    });

    testWidgets('정보 부족 + 새로고침 실패: 정보 부족 안내를 유지하고 다시 시도는 하나만', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: Scaffold(
            body: HomeScreen(
              calculation: calculate(readSource('alpha-ready')),
              onReload: () {},
              refresh: HomeRefresh.failed,
            ),
          ),
        ),
      );
      expect(find.text('새 정보를 불러오지 못했어요'), findsOneWidget);
      expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
      expect(find.text('9/25에 예정된 월급의 입금 여부를 확인할 정보가 없어요.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-salary-check-button')),
        findsOneWidget,
      );
      expect(moonLit(tester), isNull);
    });

    testWidgets('표시할 이전 결과가 없는 실패(데이터 오류 뒤): 홈 틀 + 아직 계산할 수 없어요, 기준 시각 없음', (
      tester,
    ) async {
      final json = alphaWithReceipt();
      rows(json, 'allocations').first['amountKRW'] = 500000;
      final calculation = calculate(json);
      expect(calculation, isA<HomeCalculationDataError>());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: Scaffold(
            body: HomeScreen(
              calculation: calculation,
              onReload: () {},
              refresh: HomeRefresh.failed,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('home-load-failed')), findsOneWidget);
      expect(find.text('금융 정보를 불러오지 못했어요'), findsOneWidget);
      expect(find.text('정보를 불러온 뒤 쓸 수 있는 돈을 계산할 수 있어요'), findsOneWidget);
      expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
      expect(find.text('월급 주기를 확인할 수 없어요'), findsOneWidget);
      expect(find.text('불러오지 못함'), findsNWidgets(3));
      expect(find.textContaining('기준'), findsNothing);
      expect(find.text('다시 시도'), findsOneWidget);
      expect(find.textContaining('원', findRichText: true), findsNothing);
      expect(moonLit(tester), isNull);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey('home-detail-button')),
            )
            .onPressed,
        isNull,
      );
    });

    for (final (name, refresh, json) in [
      ('새로고침 중', HomeRefresh.loading, alphaWithReceipt),
      ('이전 결과 있는 실패', HomeRefresh.failed, alphaWithReceipt),
      ('정보 부족 + 실패', HomeRefresh.failed, () => readSource('alpha-ready')),
    ]) {
      for (final scale in [1.3, 2.0]) {
        testWidgets('$name 320dp·글자 $scale배에서도 넘치지 않는다', (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildPayseTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: HomeScreen(
                  calculation: calculate(json()),
                  onReload: () {},
                  refresh: refresh,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  test('근거 거래 ID 상수는 공통 더미의 9/25 급여 입금이다', () {
    final tx = rows(
      readSource('alpha-ready'),
      'transactions',
    ).firstWhere((t) => t['transactionId'] == septemberSalaryTx);
    expect([tx['bookingDate'], tx['direction']], ['2026-09-25', 'in']);
  });
}
