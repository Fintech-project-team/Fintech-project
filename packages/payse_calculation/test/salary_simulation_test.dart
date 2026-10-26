import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

/// 2026-10-26: 급여 회차 역전·같은 날·조기 지급·partial에서 홈 다음 경계와 시뮬레이션 정보 부족 시작 구간.
/// 단일 경계 회차에는 설정 월급 S를 넣고, 금액·시점이 불확실한 날짜가 든 구간부터 값을 두지 않는다.
void main() {
  const confirmed = SalaryConfirmation.confirmed;
  const unknown = SalaryConfirmation.unknown;
  const partial = SalaryConfirmation.partial;
  const s = 3000000;

  ProjectionResult simulate(
    String asOf,
    int day,
    List<SalaryReceipt> ev, {
    List<VirtualPurchase> items = const [],
  }) {
    final ctx = context(asOf);
    final pays = scheduledPayDates(
      after: ctx.businessDate,
      salaryDay: day,
      receiptEvidence: ev,
      amountKrw: s,
    );
    return projectPeriods(
      ProjectionInput(
        ledger: ledger(ctx, [account('acc-main', 800000, asOf)]),
        payDates: pays.payDates,
        items: items,
        salaryUncertainFrom: pays.uncertainFrom,
        salaryUncertainReason:
            pays.uncertainReason ?? InsufficientReason.salaryInflowUncertain,
      ),
    );
  }

  void expectComputed(PeriodResult p) {
    expect(p.insufficient, isEmpty, reason: 'C${p.index}');
    expect([p.startH, p.endH, p.endA, p.minH, p.minA], everyElement(isNotNull));
  }

  void expectWithheld(PeriodResult p, InsufficientReason reason) {
    expect(p.insufficient, contains(reason), reason: 'C${p.index}');
    expect([p.startH, p.endH, p.endA, p.minH, p.minA], everyElement(isNull));
  }

  List<String> dates(ScheduledPayDates pays) => [
    for (final p in pays.payDates) '${p.date}:${p.basis.name}',
  ];

  group('사례 1: 월급일 31일, 10월분 11/2·11월분 10/30', () {
    test('10/29: 다음 경계 10/30(11월분 S), 남은 10월분의 11/2가 든 C2부터 정보 부족', () {
      final ev = [
        receipt('2026-09', '2026-09-30', confirmed),
        receipt('2026-10', '2026-11-02', unknown),
        receipt('2026-11', '2026-10-30', unknown),
      ];
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 10, 29),
        salaryOf(31, ev),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-11');
      expect(cycle.periodEnd.toString(), '2026-10-30');

      final pays = scheduledPayDates(
        after: BusinessDate(2026, 10, 29),
        salaryDay: 31,
        receiptEvidence: ev,
        amountKrw: s,
      );
      expect(dates(pays), [
        '2026-10-30:sourceEvidence',
        '2026-12-31:recurringSetting',
        '2027-01-31:recurringSetting',
      ]);
      expect(pays.payDates.first.amountKrw, s);
      expect(pays.uncertainFrom.toString(), '2026-11-02');

      final periods = simulate(
        '2026-10-29T12:00:00+09:00',
        31,
        ev,
      ).baseline!.periods;
      expectComputed(periods[0]);
      expectWithheld(periods[1], InsufficientReason.salaryInflowUncertain);
      expectWithheld(periods[2], InsufficientReason.salaryInflowUncertain);
    });

    test('10/31(11월분 확인, 10월분 남음): 홈은 계산, 11/2가 든 C1부터 시뮬레이션 정보 부족', () {
      final ev = [
        receipt('2026-09', '2026-09-30', confirmed),
        receipt('2026-10', '2026-11-02', unknown),
        receipt('2026-11', '2026-10-30', confirmed),
      ];
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 10, 31),
        salaryOf(31, ev),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.periodEnd.toString(), '2026-12-31');
      final periods = simulate(
        '2026-10-31T12:00:00+09:00',
        31,
        ev,
      ).baseline!.periods;
      expectWithheld(periods[0], InsufficientReason.salaryInflowUncertain);
    });
  });

  group('사례 2: 월급일 25일, 11월분 다음 해 3/2·12월분 근거 없음', () {
    final ev = [
      receipt('2026-10', '2026-10-25', confirmed),
      receipt('2026-11', '2027-03-02', unknown),
    ];

    test('11/26: 다음 경계 12/25(12월분, 반복 설정), 3/2는 예측 범위 밖이라 C1~C3 계산', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 26),
        salaryOf(25, ev),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-12');
      expect(cycle.nextPayDate!.fromEvidence, isFalse);
      expect(cycle.periodEnd.toString(), '2026-12-25');

      final pays = scheduledPayDates(
        after: BusinessDate(2026, 11, 26),
        salaryDay: 25,
        receiptEvidence: ev,
        amountKrw: s,
      );
      expect(dates(pays), [
        '2026-12-25:recurringSetting',
        '2027-01-25:recurringSetting',
        '2027-02-25:recurringSetting',
      ]);
      expect(pays.uncertainFrom.toString(), '2027-03-02');
      final r = simulate('2026-11-26T12:00:00+09:00', 25, ev);
      expect(r.horizonEnd.toString(), '2027-02-25');
      r.baseline!.periods.forEach(expectComputed);
    });

    test('12/26에 12월분이 확인되면 3/2가 든 C3부터 정보 부족', () {
      final withDecember = [...ev, receipt('2026-12', '2026-12-25', confirmed)];
      final periods = simulate(
        '2026-12-26T12:00:00+09:00',
        25,
        withDecember,
      ).baseline!.periods;
      expectComputed(periods[0]);
      expectComputed(periods[1]);
      expect(periods[2].start.toString(), '2027-02-25');
      expectWithheld(periods[2], InsufficientReason.salaryInflowUncertain);
    });

    test('12/26에 12월분 근거가 없으면 홈은 입금 정보 부족이고 시뮬레이션도 C1부터 정보 부족(선행조건)', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 12, 26),
        salaryOf(25, ev),
      );
      expect(cycle.issue, InsufficientReason.receiptEvidenceAbsent);
      final periods = simulate(
        '2026-12-26T12:00:00+09:00',
        25,
        ev,
      ).baseline!.periods;
      for (final p in periods) {
        expectWithheld(p, InsufficientReason.receiptEvidenceAbsent);
      }
    });
  });

  group('사례 3: 월급일 1일, 10월분·11월분 모두 10/30 예정', () {
    final ev = [
      receipt('2026-09', '2026-09-01', confirmed),
      receipt('2026-10', '2026-10-30', unknown),
      receipt('2026-11', '2026-10-30', unknown),
    ];

    test('10/15: 홈 다음 경계 10/30, 같은 날 두 회차라 10/30부터(C2) 시뮬레이션 정보 부족', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 10, 15),
        salaryOf(1, ev),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.periodEnd.toString(), '2026-10-30');
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 10, 15),
        salaryDay: 1,
        receiptEvidence: ev,
        amountKrw: s,
      );
      expect(dates(pays).first, '2026-10-30:sourceEvidence');
      expect(dates(pays)[1], '2026-12-01:recurringSetting');
      expect(pays.uncertainFrom.toString(), '2026-10-30');
      final periods = simulate(
        '2026-10-15T12:00:00+09:00',
        1,
        ev,
      ).baseline!.periods;
      expectComputed(periods[0]);
      expectWithheld(periods[1], InsufficientReason.salaryInflowUncertain);
    });
  });

  group('사례 4: 월급일 25일, 12월분을 11/20으로 앞당김·11월분 근거 없음', () {
    test('11/10: 다음 경계 11/20(12월분 S), 남은 11월분의 11/25가 든 C2부터 정보 부족', () {
      final ev = [
        receipt('2026-10', '2026-10-25', confirmed),
        receipt('2026-12', '2026-11-20', unknown),
      ];
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 10),
        salaryOf(25, ev),
      );
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-12');
      expect(cycle.periodEnd.toString(), '2026-11-20');
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 11, 10),
        salaryDay: 25,
        receiptEvidence: ev,
        amountKrw: s,
      );
      expect(dates(pays), [
        '2026-11-20:sourceEvidence',
        '2027-01-25:recurringSetting',
        '2027-02-25:recurringSetting',
      ]);
      expect(pays.payDates.first.amountKrw, s);
      expect(pays.uncertainFrom.toString(), '2026-11-25');
      final periods = simulate(
        '2026-11-10T12:00:00+09:00',
        25,
        ev,
      ).baseline!.periods;
      expectComputed(periods[0]);
      expect(periods[1].start.toString(), '2026-11-20');
      expectWithheld(periods[1], InsufficientReason.salaryInflowUncertain);
    });

    test('11/21(12월분 확인): 홈은 12월분 기준으로 계산, 11/25가 든 C1부터 시뮬레이션 정보 부족', () {
      final ev = [
        receipt('2026-10', '2026-10-25', confirmed),
        receipt('2026-12', '2026-11-20', confirmed),
      ];
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 21),
        salaryOf(25, ev),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-12');
      expect(cycle.periodEnd.toString(), '2027-01-25');
      final periods = simulate(
        '2026-11-21T12:00:00+09:00',
        25,
        ev,
      ).baseline!.periods;
      expectWithheld(periods[0], InsufficientReason.salaryInflowUncertain);
    });
  });

  test('불확실 구간에 놓인 즉시출금·카드 구매도 귀속(reflected)은 유지하지만 그 구간 금액·구매 전후 차이는 null이고 앞 구간은 계산한다', () {
    final ev = [
      receipt('2026-09', '2026-09-30', confirmed),
      receipt('2026-10', '2026-11-02', unknown),
      receipt('2026-11', '2026-10-30', unknown),
    ];
    final r = simulate(
      '2026-10-29T12:00:00+09:00',
      31,
      ev,
      items: [
        VirtualPurchase(
          itemId: 'now',
          amountKrw: 100000,
          purchaseDate: '2026-10-29',
          paymentMethod: PaymentMethod.immediate,
        ),
        VirtualPurchase(
          itemId: 'later',
          amountKrw: 300000,
          purchaseDate: '2026-11-05',
          paymentMethod: PaymentMethod.immediate,
        ),
        VirtualPurchase(
          itemId: 'card',
          amountKrw: 200000,
          purchaseDate: '2026-11-03',
          paymentMethod: PaymentMethod.cardLumpSum,
          plannedWithdrawalDate: '2026-11-20',
        ),
      ],
    );
    expect(
      [
        for (final p in r.itemPlacements)
          '${p.itemId}:${p.status.name}:${p.periodIndex}:${p.cashDate}',
      ],
      [
        'now:reflected:1:2026-10-29',
        'later:reflected:2:2026-11-05',
        'card:reflected:2:2026-11-20',
      ],
    );
    final withItems = r.allItems!.periods;
    expectComputed(withItems[0]);
    expect(withItems[0].endH, 700000);
    expect(r.endADifferences![0], -100000);
    expectWithheld(withItems[1], InsufficientReason.salaryInflowUncertain);
    expectWithheld(withItems[2], InsufficientReason.salaryInflowUncertain);
    expect(r.endADifferences!.skip(1), everyElement(isNull));
  });

  group('partial 회차와 현재 회차 선행조건', () {
    test('다음 경계 회차가 partial이면 S 전액을 다시 넣지 않고 그 예정일이 든 구간부터 정보 부족', () {
      final ev = [
        receipt('2026-10', '2026-10-25', confirmed),
        receipt('2026-11', '2026-11-25', partial),
      ];
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 11, 10),
        salaryDay: 25,
        receiptEvidence: ev,
        amountKrw: s,
      );
      expect(pays.uncertainFrom.toString(), '2026-11-25');
      final periods = simulate(
        '2026-11-10T12:00:00+09:00',
        25,
        ev,
      ).baseline!.periods;
      expectComputed(periods[0]);
      expect(periods[0].endH, 800000);
      expectWithheld(periods[1], InsufficientReason.salaryInflowUncertain);
      expectWithheld(periods[2], InsufficientReason.salaryInflowUncertain);
    });

    test('현재 회차가 partial이면 남은 금액을 알 수 없어 C1부터 정보 부족', () {
      final periods = simulate('2026-10-26T12:00:00+09:00', 25, [
        receipt('2026-10', '2026-10-25', partial),
      ]).baseline!.periods;
      for (final p in periods) {
        expectWithheld(p, InsufficientReason.salaryInflowUncertain);
      }
    });

    test('현재 회차가 입금 전(unknown)이면 C1부터 정보 부족', () {
      final periods = simulate('2026-10-25T12:00:00+09:00', 25, [
        receipt('2026-09', '2026-09-25', confirmed),
        receipt('2026-10', '2026-10-25', unknown),
      ]).baseline!.periods;
      expectWithheld(periods[0], InsufficientReason.salaryInflowUncertain);
    });
  });
}
