import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

/// 2026-10-26: #92 급여 명목 회차(payMonth) 공동 사례. docs/data-model.md '급여 회차와 예정일'.
void main() {
  const confirmed = SalaryConfirmation.confirmed;
  const unknown = SalaryConfirmation.unknown;

  LedgerInput at(String asOf, List<Obligation> obligations) => ledger(
    context(asOf),
    [account('acc-main', 800000, asOf)],
    obligations: obligations,
  );

  group('11/1 월급을 10/30으로 앞당김(payMonth 2026-11, 예정일 10-30)', () {
    final moved = [
      receipt('2026-10', '2026-10-01', confirmed),
      receipt('2026-11', '2026-10-30', confirmed),
    ];

    test('10/30 입금 확인 뒤 직전 회차는 11월분, 다음 회차는 12월분(12/1)이다', () {
      final r = current(
        at('2026-10-30T15:00:00+09:00', [
          obligation('o-1030', 100000, '2026-10-30'),
          obligation('o-1201', 200000, '2026-12-01'),
        ]),
        salaryOf(1, moved),
      );
      final cycle = r.salaryCycle!;
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-11');
      expect(cycle.previousPayDate!.date.toString(), '2026-10-30');
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-12');
      expect(cycle.nextPayDate!.date.toString(), '2026-12-01');
      expect(cycle.periodStart.toString(), '2026-10-30');
      expect(cycle.periodEnd.toString(), '2026-12-01');
      expect(r.insufficient, isEmpty);
      expect(line(r, 'o-1030').placement, ObligationPlacement.inCurrentPeriod);
      expect(line(r, 'o-1201').placement, ObligationPlacement.outsidePeriod);
      expect(r.e, 100000);
    });

    test('10/30 입금 확인 전이면 이동 예정일 10/30을 급여일로 대기하고 당일 출금은 반영 대기다(D5)', () {
      final r = current(
        at('2026-10-30T09:00:00+09:00', [
          obligation('o-1029', 50000, '2026-10-29'),
          obligation('o-1030', 100000, '2026-10-30'),
          obligation('o-1105', 70000, '2026-11-05'),
        ]),
        salaryOf(1, [
          receipt('2026-10', '2026-10-01', confirmed),
          receipt('2026-11', '2026-10-30', unknown),
        ]),
      );
      final cycle = r.salaryCycle!;
      expect(cycle.state, SalaryCycleState.awaitingDeposit);
      expect(cycle.periodStart.toString(), '2026-10-01');
      expect(cycle.periodEnd.toString(), '2026-10-30');
      expect(line(r, 'o-1030').placement, ObligationPlacement.awaitingSalary);
      expect(line(r, 'o-1029').placement, ObligationPlacement.awaitingSalary);
      expect(line(r, 'o-1105').placement, ObligationPlacement.outsidePeriod);
    });

    test('미래 월급일은 t0 이후 가장 먼저 도래하는 뒤 회차 날짜이며 이동한 날짜의 달에 1을 더하지 않는다', () {
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 10, 30),
        salaryDay: 1,
        receiptEvidence: moved,
        amountKrw: 3000000,
      );
      expect(pays.uncertainFrom, isNull);
      expect(
        [for (final p in pays.payDates) p.date.toString()],
        ['2026-12-01', '2027-01-01', '2027-02-01'],
      );
      expect(
        pays.payDates.every((p) => p.basis == PayDateBasis.recurringSetting),
        isTrue,
      );
    });
  });

  group('입금 전에 원천이 준 이동 예정일(unknown 근거)은 경계로만 쓴다(2026-10-26 수정안)', () {
    final provided = [
      receipt('2026-10', '2026-10-01', confirmed),
      receipt('2026-11', '2026-10-30', unknown),
    ];

    test('10/29 조회: 11월분 이동 예정일 10/30을 다음 경계로 쓰고 입금 완료로 보지 않는다', () {
      final r = current(
        at('2026-10-29T12:00:00+09:00', [
          obligation('o-1029', 50000, '2026-10-29'),
          obligation('o-1030', 100000, '2026-10-30'),
        ]),
        salaryOf(1, provided),
      );
      final cycle = r.salaryCycle!;
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-10');
      expect(cycle.nextPayDate!.date.toString(), '2026-10-30');
      expect(cycle.nextPayDate!.fromEvidence, isTrue);
      expect(cycle.nextReceipt, SalaryReceiptStatus.unknown);
      expect(cycle.periodEnd.toString(), '2026-10-30');
      expect(line(r, 'o-1029').placement, ObligationPlacement.inCurrentPeriod);
      expect(line(r, 'o-1030').placement, ObligationPlacement.outsidePeriod);
      expect([r.b, r.e, r.u], [800000, 50000, 750000]);
    });

    test('구간 계산은 10/30을 확인된 경계(confirmed basis)로 쓰고 이후는 반복 월급일로 예상한다', () {
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 10, 29),
        salaryDay: 1,
        receiptEvidence: provided,
        amountKrw: 3000000,
      );
      expect(
        [for (final p in pays.payDates) '${p.date}:${p.basis.name}'],
        [
          '2026-10-30:sourceEvidence',
          '2026-12-01:recurringSetting',
          '2027-01-01:recurringSetting',
        ],
      );
    });

    test('11/1 조회: 10월분 미룬 예정일 11/2를 다음 경계로 쓴다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 1),
        salaryOf(31, [
          receipt('2026-09', '2026-09-30', confirmed),
          receipt('2026-10', '2026-11-02', unknown),
        ]),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-09');
      expect(cycle.periodEnd.toString(), '2026-11-02');
      expect(cycle.nextReceipt, SalaryReceiptStatus.unknown);
    });
  });

  group('10/31 월급을 11/2로 미룸(payMonth 2026-10, 예정일 11-02)', () {
    test('11/2 입금 확인 뒤 직전 회차는 10월분, 다음은 11월분(11/30 말일 보정)이다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 2),
        salaryOf(31, [
          receipt('2026-09', '2026-09-30', confirmed),
          receipt('2026-10', '2026-11-02', confirmed),
        ]),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-10');
      expect(cycle.previousPayDate!.date.toString(), '2026-11-02');
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-11');
      expect(cycle.nextPayDate!.date.toString(), '2026-11-30');
      expect(cycle.nextPayDate!.monthEndAdjusted, isTrue);
      expect(cycle.periodEnd.toString(), '2026-11-30');
    });

    test('11/2 당일 입금 확인 전이면 9월분 구간을 유지한다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 2),
        salaryOf(31, [
          receipt('2026-09', '2026-09-30', confirmed),
          receipt('2026-10', '2026-11-02', unknown),
        ]),
      );
      expect(cycle.state, SalaryCycleState.awaitingDeposit);
      expect(cycle.periodStart.toString(), '2026-09-30');
      expect(cycle.periodEnd.toString(), '2026-11-02');
    });
  });

  test('연속 조기 입금: 10/20에 10월분·11월분이 모두 confirmed면 홈 종료는 12/25, 12/1 지출은 E에 한 번, 급여는 다시 더하지 않는다', () {
    final evidence = [
      receipt('2026-09', '2026-09-25', confirmed),
      receipt('2026-10', '2026-10-25', confirmed),
      receipt('2026-11', '2026-11-25', confirmed),
    ];
    final r = current(
      at('2026-10-20T12:00:00+09:00', [
        obligation('o-1201', 100000, '2026-12-01'),
        obligation('o-1225', 200000, '2026-12-25'),
      ]),
      salaryOf(25, evidence),
    );
    expect(r.salaryCycle!.state, SalaryCycleState.normal);
    expect(r.salaryCycle!.periodEnd.toString(), '2026-12-25');
    expect(line(r, 'o-1201').placement, ObligationPlacement.inCurrentPeriod);
    expect(line(r, 'o-1225').placement, ObligationPlacement.outsidePeriod);
    expect([r.b, r.e, r.u], [800000, 100000, 700000]);
    final pays = scheduledPayDates(
      after: BusinessDate(2026, 10, 20),
      salaryDay: 25,
      receiptEvidence: evidence,
      amountKrw: 3000000,
    );
    expect(pays.payDates.first.date.toString(), '2026-12-25');
    expect(pays.uncertainFrom, isNull);
  });

  group('10/25 예정·10/24 실제 입금(예정일 유지, confirmed)', () {
    final early = [
      receipt('2026-09', '2026-09-25', confirmed),
      receipt('2026-10', '2026-10-25', confirmed),
    ];

    test('홈은 10/24부터 11/25까지 구간으로 전환하고 예정일은 10/25로 남는다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 10, 24),
        salaryOf(25, early),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.nextPayDate!.date.toString(), '2026-10-25');
      expect(cycle.nextReceipt, SalaryReceiptStatus.confirmed);
      expect(cycle.periodEnd.toString(), '2026-11-25');
    });

    test('구간 계산은 이미 잔액에 든 10월분을 다시 입금하지 않고 11월분부터 월급일로 쓴다', () {
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 10, 24),
        salaryDay: 25,
        receiptEvidence: early,
        amountKrw: 3000000,
      );
      expect(pays.uncertainFrom, isNull);
      expect(
        [for (final p in pays.payDates) p.date.toString()],
        ['2026-11-25', '2026-12-25', '2027-01-25'],
      );
    });
  });

  group('다른 회차의 예정일이 같아도 구간을 정할 수 있으면 계산한다(2026-10-26 A 결정)', () {
    test(
      '10월분·11월분이 10/30에 입금되고 12월분 예정일이 12/1이면 정상 구간, 잔액에 급여를 다시 더하지 않는다',
      () {
        final evidence = [
          receipt('2026-10', '2026-10-30', confirmed),
          receipt('2026-11', '2026-10-30', confirmed),
        ];
        final input = salaryOf(1, evidence);
        final r = current(
          at('2026-11-05T12:00:00+09:00', [
            obligation('o-1120', 100000, '2026-11-20'),
            obligation('o-1201', 200000, '2026-12-01'),
          ]),
          input,
        );
        final cycle = r.salaryCycle!;
        expect(cycle.state, SalaryCycleState.normal);
        expect(cycle.previousPayDate!.payMonth.toString(), '2026-11');
        expect(cycle.nextPayDate!.payMonth.toString(), '2026-12');
        expect(cycle.periodStart.toString(), '2026-10-30');
        expect(cycle.periodEnd.toString(), '2026-12-01');
        expect(r.insufficient, isEmpty);
        expect([r.b, r.e, r.u], [800000, 100000, 700000]);
        expect(input.receiptEvidence, hasLength(2));
        expect(
          [
            for (final e in input.receiptEvidence!)
              e.expectedPayDate.toString(),
          ],
          ['2026-10-30', '2026-10-30'],
        );
      },
    );

    test('앞 회차는 확인됐고 같은 날 현재 회차가 입금 전이면 길이 0 구간이라 현재 구간만 제한하고 원천을 보존한다', () {
      final input = salaryOf(1, [
        receipt('2026-10', '2026-10-30', confirmed),
        receipt('2026-11', '2026-10-30', unknown),
      ]);
      final r = current(
        at('2026-10-30T15:00:00+09:00', [
          obligation('o-1105', 100000, '2026-11-05'),
        ]),
        input,
      );
      expect(r.salaryCycle!.state, SalaryCycleState.insufficientData);
      expect(r.insufficient, [InsufficientReason.payDateConflict]);
      expect([r.b, r.e, r.u], [800000, null, null]);
      expect(input.receiptEvidence, hasLength(2));
    });

    test('같은 날 앞 회차가 입금 전이면 오늘 반영된 입금이 어느 회차인지 구분해야 해 제한한다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 5),
        salaryOf(1, [
          receipt('2026-10', '2026-10-30', unknown),
          receipt('2026-11', '2026-10-30', confirmed),
        ]),
      );
      expect(cycle.state, SalaryCycleState.insufficientData);
      expect(cycle.issue, InsufficientReason.payDateConflict);
    });

    test('모호한 구간이 지나 다음 회차가 확인되면 이후 현재 구간은 정상 계산한다', () {
      final r = current(
        at('2026-12-05T12:00:00+09:00', [
          obligation('o-1220', 100000, '2026-12-20'),
        ]),
        salaryOf(1, [
          receipt('2026-10', '2026-10-30', unknown),
          receipt('2026-11', '2026-10-30', confirmed),
          receipt('2026-12', '2026-12-01', confirmed),
        ]),
      );
      expect(r.salaryCycle!.state, SalaryCycleState.normal);
      expect(r.salaryCycle!.previousPayDate!.payMonth.toString(), '2026-12');
      expect(r.salaryCycle!.periodEnd.toString(), '2027-01-01');
      expect([r.b, r.e, r.u], [800000, 100000, 700000]);
    });
  });

  group('날짜 역전: 밀린 과거 회차가 늦게 입금돼도 현재 회차·구간을 되돌리지 않는다(2026-10-26 결정)', () {
    // 월급일 1일. 11월분을 10/30에 받고, 밀린 10월분을 11/2에 받았으며, 12월분 예정일은 12/1이다.
    List<SalaryReceipt> evidence(SalaryConfirmation october) => [
      receipt('2026-09', '2026-09-01', confirmed),
      receipt('2026-10', '2026-11-02', october),
      receipt('2026-11', '2026-10-30', confirmed),
    ];

    test('11/3 조회: 11월분 기준 10/30~12/1 구간을 유지하고 잔액에 급여를 다시 더하지 않는다', () {
      final input = salaryOf(1, evidence(confirmed));
      final r = current(
        at('2026-11-03T12:00:00+09:00', [
          obligation('o-1102', 50000, '2026-11-02'),
          obligation('o-1120', 100000, '2026-11-20'),
          obligation('o-1201', 200000, '2026-12-01'),
        ]),
        input,
      );
      final cycle = r.salaryCycle!;
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-11');
      expect(cycle.nextPayDate!.payMonth.toString(), '2026-12');
      expect(cycle.periodStart.toString(), '2026-10-30');
      expect(cycle.periodEnd.toString(), '2026-12-01');
      expect(r.insufficient, isEmpty);
      expect([r.b, r.e, r.u], [800000, 150000, 650000]);
      expect(input.receiptEvidence, hasLength(3));
    });

    test('10월분 입금 전인 11/1에도 11월분 기준 구간이며 10월분 대기로 되돌아가지 않는다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2026, 11, 1),
        salaryOf(1, evidence(unknown)),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.payMonth.toString(), '2026-11');
      expect(cycle.periodEnd.toString(), '2026-12-01');
    });

    test('구간 계산도 12월분(12/1)부터 경계로 쓰고 밀린 10월분 입금일을 경계로 쓰지 않는다', () {
      final pays = scheduledPayDates(
        after: BusinessDate(2026, 11, 3),
        salaryDay: 1,
        receiptEvidence: evidence(confirmed),
        amountKrw: 3000000,
      );
      expect(pays.uncertainFrom, isNull);
      expect(
        [for (final p in pays.payDates) p.date.toString()],
        ['2026-12-01', '2027-01-01', '2027-02-01'],
      );
    });
  });

  test('확인된 이동 예정일이 없으면 반복 월급일로 다음 경계를 예상하되 근거·입금 확인으로 만들지 않는다', () {
    final evidence = [receipt('2026-10', '2026-10-25', confirmed)];
    final input = salaryOf(25, evidence);
    final r = current(
      at('2026-10-26T12:00:00+09:00', [
        obligation('o-1110', 100000, '2026-11-10'),
      ]),
      input,
    );
    final next = r.salaryCycle!.nextPayDate!;
    expect(next.date.toString(), '2026-11-25');
    expect(next.fromEvidence, isFalse);
    expect(r.salaryCycle!.nextReceipt, SalaryReceiptStatus.absent);
    expect(input.receiptEvidence, hasLength(1));
    expect([r.b, r.e, r.u], [800000, 100000, 700000]);
    final pays = scheduledPayDates(
      after: BusinessDate(2026, 10, 26),
      salaryDay: 25,
      receiptEvidence: evidence,
      amountKrw: 3000000,
    );
    expect(pays.payDates.first.basis, PayDateBasis.recurringSetting);
  });

  test('payMonth와 예정일의 기간 차이만으로 거절하지 않는다(11월분을 다음 해 3월에 지급)', () {
    final input = salaryOf(25, [
      receipt('2026-10', '2026-10-25', confirmed),
      receipt('2026-11', '2027-03-02', unknown),
    ]);
    expect(
      input.receiptEvidence!.last.expectedPayDate.toString(),
      '2027-03-02',
    );
    expect(
      () => resolveSalaryCycle(BusinessDate(2026, 12, 15), input),
      returnsNormally,
    );
    expect(
      () => scheduledPayDates(
        after: BusinessDate(2026, 12, 15),
        salaryDay: 25,
        receiptEvidence: input.receiptEvidence!,
        amountKrw: 3000000,
      ),
      returnsNormally,
    );
  });

  test('먼 회차를 앞당겨 받은 근거도 직전 회차 탐색에 포함한다', () {
    final cycle = resolveSalaryCycle(
      BusinessDate(2026, 10, 20),
      salaryOf(25, [
        receipt('2026-09', '2026-09-25', confirmed),
        receipt('2026-10', '2026-10-15', confirmed),
        receipt('2026-11', '2026-10-16', confirmed),
        receipt('2026-12', '2026-10-17', confirmed),
      ]),
    );
    expect(cycle.state, SalaryCycleState.normal);
    expect(cycle.previousPayDate!.payMonth.toString(), '2026-12');
    expect(cycle.nextPayDate!.payMonth.toString(), '2027-01');
    expect(cycle.periodEnd.toString(), '2027-01-25');
  });

  test('월급일 설정을 25일에서 10일로 바꿔도 과거 근거의 회차·예정일로 직전 회차를 유지한다', () {
    final cycle = resolveSalaryCycle(
      BusinessDate(2026, 10, 26),
      salaryOf(10, [receipt('2026-10', '2026-10-25', confirmed)]),
    );
    expect(cycle.state, SalaryCycleState.normal);
    expect(cycle.previousPayDate!.payMonth.toString(), '2026-10');
    expect(cycle.previousPayDate!.date.toString(), '2026-10-25');
    expect(cycle.nextPayDate!.date.toString(), '2026-11-10');
    expect(cycle.periodEnd.toString(), '2026-11-10');
  });

  test('payMonth는 정확한 YYYY-MM만 받는다', () {
    for (final bad in ['2026-13', '2026-1', '0000-01', '2026-10-01', '']) {
      expect(
        () => receipt(bad, '2026-10-25', confirmed),
        throwsA(
          isA<CalculationInputException>().having(
            (e) => e.code,
            'code',
            InputErrorCode.invalidValue,
          ),
        ),
        reason: bad,
      );
    }
    expect(receipt('9999-12', '2026-10-25', confirmed).payMonth.month, 12);
  });
}
