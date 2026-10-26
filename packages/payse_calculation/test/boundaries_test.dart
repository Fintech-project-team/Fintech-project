import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

const t1019 = '2026-10-19T12:00:00+09:00';
const t1014 = '2026-10-14T00:00:00+09:00';
final paidSeptember = salary(25, [
  ('2026-09-25', SalaryConfirmation.confirmed),
]);

Matcher inputError(InputErrorCode code) => throwsA(
  isA<CalculationInputException>().having((e) => e.code, 'code', code),
);

Reserve reserve(
  String id,
  int amount, {
  String account = 'acc-main',
  String? cancelledAt,
}) => Reserve(
  reserveId: id,
  accountId: account,
  amountKrw: amount,
  cancelledAt: cancelledAt,
);

ReserveAllocation allocation(
  String id,
  String reserveId,
  String obligationId,
  int amount, [
  int released = 0,
]) => ReserveAllocation(
  allocationId: id,
  reserveId: reserveId,
  obligationId: obligationId,
  amountKrw: amount,
  releasedKrw: released,
);

void main() {
  group('배정(O) 한도', () {
    test('한 의무에 여러 보호액을 배정한 합계가 잔여액을 넘으면 오류이고 잘라내지 않는다', () {
      final input = ledger(
        context(t1019),
        [account('acc-main', 1000000, t1019)],
        obligations: [obligation('o-1', 300000, '2026-10-22')],
        reserves: [reserve('r-a', 200000), reserve('r-b', 200000)],
        allocations: [
          allocation('al-a', 'r-a', 'o-1', 200000),
          allocation('al-b', 'r-b', 'o-1', 200000),
        ],
      );
      expect(
        () => current(input, paidSeptember),
        inputError(InputErrorCode.overAllocation),
      );
    });

    test('한 보호액을 여러 의무에 배정한 합계가 설정액을 넘으면 오류', () {
      final input = ledger(
        context(t1019),
        [account('acc-main', 1000000, t1019)],
        obligations: [
          obligation('o-1', 300000, '2026-10-22'),
          obligation('o-2', 300000, '2026-10-23'),
        ],
        reserves: [reserve('r-a', 300000)],
        allocations: [
          allocation('al-1', 'r-a', 'o-1', 200000),
          allocation('al-2', 'r-a', 'o-2', 200000),
        ],
      );
      expect(
        () => current(input, paidSeptember),
        inputError(InputErrorCode.overAllocation),
      );
    });

    test('부분 정산 뒤 미해제 배정은 잔여액 이하일 때만 O로 쓴다(해제분 제외)', () {
      final r = current(
        ledger(
          context(t1019),
          [account('acc-main', 1000000, t1019)],
          obligations: [obligation('o-1', 100000, '2026-10-18')],
          reserves: [reserve('r-a', 400000)],
          allocations: [allocation('al-1', 'r-a', 'o-1', 100000, 40000)],
          settlements: [settlement('s-1', 'o-1', 40000)],
        ),
        paidSeptember,
      );
      expect(
        [r.e, r.r, r.o, r.rEff, r.u],
        [60000, 400000, 60000, 340000, 600000],
      );
    });

    test('구간 밖·취소 보호액·제외 계좌 보호액의 배정은 O에 넣지 않는다', () {
      final r = current(
        ledger(
          context(t1019),
          [
            account('acc-main', 1000000, t1019),
            account('acc-off', 0, t1019, included: false),
          ],
          obligations: [
            obligation('o-next', 100000, '2026-11-01'),
            obligation('o-now', 100000, '2026-10-22'),
          ],
          reserves: [
            reserve('r-main', 100000),
            reserve(
              'r-cancel',
              100000,
              cancelledAt: '2026-10-20T09:00:00+09:00',
            ),
            reserve('r-off', 100000, account: 'acc-off'),
          ],
          allocations: [
            allocation('al-next', 'r-main', 'o-next', 100000),
            allocation('al-cancel', 'r-cancel', 'o-now', 50000),
            allocation('al-off', 'r-off', 'o-now', 50000),
          ],
        ),
        paidSeptember,
      );
      expect([r.e, r.r, r.o, r.u], [100000, 100000, 0, 800000]);
    });

    test('해제 누계가 배정액보다 크면 생성 시 오류', () {
      expect(
        () => allocation('al', 'r', 'o', 100, 101),
        inputError(InputErrorCode.invalidValue),
      );
    });
  });

  group('정산 연결', () {
    LedgerInput withLinks(List<SettlementLink> links) => ledger(
      context(t1019),
      [account('acc-main', 700000, t1019)],
      obligations: [obligation('o-rent', 300000, '2026-10-22')],
      settlements: links,
    );

    test('M6 예: 오연결 해제(무효화)하면 의무 잔여가 복원되어 U=400,000, B는 그대로', () {
      final linked = current(
        withLinks([settlement('s-wrong', 'o-rent', 300000)]),
        paidSeptember,
      );
      expect([linked.e, linked.u], [0, 700000]);
      final invalidated = current(
        withLinks([
          settlement(
            's-wrong',
            'o-rent',
            300000,
            invalidatedAt: '2026-10-23T10:00:00+09:00',
          ),
        ]),
        paidSeptember,
      );
      expect(
        [invalidated.b, invalidated.e, invalidated.u],
        [700000, 300000, 400000],
      );
    });

    test('같은 의무·거래의 유효 연결 중복은 오류, 무효화된 이전 연결과는 공존한다', () {
      expect(
        () => current(
          withLinks([
            settlement('s-1', 'o-rent', 100000, tx: 'tx'),
            settlement('s-2', 'o-rent', 100000, tx: 'tx'),
          ]),
          paidSeptember,
        ),
        inputError(InputErrorCode.duplicateId),
      );
      final r = current(
        withLinks([
          settlement(
            's-1',
            'o-rent',
            100000,
            tx: 'tx',
            invalidatedAt: '2026-10-20T00:00:00+09:00',
          ),
          settlement('s-2', 'o-rent', 120000, tx: 'tx'),
        ]),
        paidSeptember,
      );
      expect(r.e, 180000);
    });

    test('같은 linkId·초과 정산·없는 의무 참조는 오류', () {
      expect(
        () => current(
          withLinks([
            settlement('s-1', 'o-rent', 1),
            settlement('s-1', 'o-rent', 2, tx: 'x'),
          ]),
          paidSeptember,
        ),
        inputError(InputErrorCode.duplicateId),
      );
      expect(
        () => current(
          withLinks([
            settlement('s-1', 'o-rent', 200000),
            settlement('s-2', 'o-rent', 100001),
          ]),
          paidSeptember,
        ),
        inputError(InputErrorCode.overSettlement),
      );
      expect(
        () =>
            current(withLinks([settlement('s-1', 'o-none', 1)]), paidSeptember),
        inputError(InputErrorCode.unknownReference),
      );
    });

    test('한 출금을 여러 의무에 나눠 배분하면 각 의무의 배분액만 차감한다', () {
      final r = current(
        ledger(
          context(t1019),
          [account('acc-main', 1000000, t1019)],
          obligations: [
            obligation('o-a', 100000, '2026-10-22'),
            obligation('o-b', 100000, '2026-10-22'),
          ],
          settlements: [
            settlement('s-a', 'o-a', 60000, tx: 'tx-1'),
            settlement('s-b', 'o-b', 40000, tx: 'tx-1'),
          ],
        ),
        paidSeptember,
      );
      expect(r.e, 100000);
    });
  });

  group('날짜·구간 경계', () {
    test('달력 월 가산은 원래 기준일에서 한 번에 계산해 말일 보정이 누적되지 않는다', () {
      final jan31 = BusinessDate(2027, 1, 31);
      expect(jan31.addMonthsClamped(1).toString(), '2027-02-28');
      expect(jan31.addMonthsClamped(2).toString(), '2027-03-31');
      expect(jan31.addMonthsClamped(3).toString(), '2027-04-30');
      expect(
        BusinessDate(2027, 11, 30).addMonthsClamped(3).toString(),
        '2028-02-29',
      );
      expect(
        BusinessDate(2028, 2, 29).addMonthsClamped(12).toString(),
        '2029-02-28',
      );
    });

    test('윤년 2월에는 29일 이상 월급이 2/29, 평년은 2/28', () {
      expect(monthlyPayDate(2028, 2, 31).date.toString(), '2028-02-29');
      expect(monthlyPayDate(2028, 2, 29).monthEndAdjusted, isFalse);
      expect(monthlyPayDate(2027, 2, 29).date.toString(), '2027-02-28');
      expect(
        () => BusinessDate.parse('2027-02-29', 'x'),
        inputError(InputErrorCode.invalidDate),
      );
    });

    test('asOf는 서울 업무 날짜로 바꾼다(UTC 표기도 같은 날짜)', () {
      expect(
        context('2026-10-24T15:30:00Z').businessDate.toString(),
        '2026-10-25',
      );
      expect(
        context('2026-10-24T14:59:59Z').businessDate.toString(),
        '2026-10-24',
      );
    });

    test('31일 월급의 2월 말일 당일은 그날이 직전 월급일이다', () {
      final cycle = resolveSalaryCycle(
        BusinessDate(2027, 2, 28),
        salary(31, [('2027-02-28', SalaryConfirmation.confirmed)]),
      );
      expect(cycle.state, SalaryCycleState.normal);
      expect(cycle.previousPayDate!.monthEndAdjusted, isTrue);
      expect(cycle.periodEnd.toString(), '2027-03-31');
    });

    test('정상 구간 끝(pNext) 당일 의무는 다음 구간, 전날은 현재 구간', () {
      final r = current(
        ledger(
          context(t1019),
          [account('acc-main', 1000000, t1019)],
          obligations: [
            obligation('o-24', 1000, '2026-10-24'),
            obligation('o-25', 2000, '2026-10-25'),
          ],
        ),
        paidSeptember,
      );
      expect(r.e, 1000);
      expect(line(r, 'o-25').placement, ObligationPlacement.outsidePeriod);
    });

    test('p3가 상한과 정확히 같으면 완전 구간, p3가 늦으면 잘린 구간', () {
      ProjectionResult run(String p3) => projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
          payDates: [pay('2026-11-14', 0), pay('2026-12-14', 0), pay(p3, 0)],
          items: const [],
        ),
      );
      final exact = run('2027-01-14');
      expect(exact.horizonEnd.toString(), '2027-01-14');
      expect(exact.baseline!.periods[2].complete, isTrue);
      final late = run('2027-01-15');
      expect(late.horizonEnd.toString(), '2027-01-14');
      expect(late.baseline!.periods[2].complete, isFalse);
    });

    test('p2가 상한을 넘으면 C2가 잘리고 C3는 없다', () {
      final r = projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
          payDates: [pay('2026-12-20', 0), pay('2027-02-20', 0)],
          items: const [],
        ),
      );
      expect(r.baseline!.periods.length, 2);
      expect(r.baseline!.periods[1].end.toString(), '2027-01-14');
      expect(r.baseline!.periods[1].complete, isFalse);
    });

    test('월급일이 t0 이하이거나 증가하지 않으면 오류, 3개를 넘으면 오류', () {
      ProjectionInput input(List<PlannedPayDate> pays) => ProjectionInput(
        ledger: ledger(context(t1014), [account('acc-main', 1, t1014)]),
        payDates: pays,
        items: const [],
      );
      expect(
        () => projectPeriods(input([pay('2026-10-14', 0)])),
        inputError(InputErrorCode.invalidSchedule),
      );
      expect(
        () =>
            projectPeriods(input([pay('2026-10-25', 0), pay('2026-10-25', 0)])),
        inputError(InputErrorCode.invalidSchedule),
      );
      expect(
        () => projectPeriods(
          input([
            pay('2026-10-25', 0),
            pay('2026-11-25', 0),
            pay('2026-12-25', 0),
            pay('2027-01-25', 0),
          ]),
        ),
        inputError(InputErrorCode.invalidValue),
      );
    });

    test('월급일이 없거나 앞 월급 금액이 없으면 해당 구간부터 null', () {
      final missing = projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
          payDates: [pay('2026-10-25', null)],
          items: const [],
        ),
      );
      final periods = missing.baseline!.periods;
      expect(periods[0].endH, 1000);
      expect(periods[1].endH, isNull);
      expect(periods[1].insufficient, [
        InsufficientReason.payDateMissing,
        InsufficientReason.salaryAmountMissing,
      ]);
      expect(
        periods[2].insufficient,
        contains(InsufficientReason.salaryAmountMissing),
      );

      final amountOnly = projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
          payDates: [
            pay('2026-10-25', 0),
            pay('2026-11-25', null),
            pay('2026-12-25', 0),
          ],
          items: const [],
        ),
      );
      expect(
        [for (final p in amountOnly.baseline!.periods) p.endH],
        [1000, 1000, null],
      );
      expect(amountOnly.baseline!.periods[2].insufficient, [
        InsufficientReason.salaryAmountMissing,
      ]);

      final noPay = projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
          payDates: const [],
          items: const [],
        ),
      );
      expect(noPay.baseline!.periods.first.insufficient, [
        InsufficientReason.payDateMissing,
      ]);
    });
  });

  group('입금 확인 전환 보류(Q1·Q2)와 중복', () {
    LedgerInput simple(String asOf) => ledger(
      context(asOf),
      [account('acc-main', 500000, asOf)],
      obligations: [obligation('o-1', 100000, '2026-10-22')],
    );

    test('Q1 직전 월급일 근거 항목이 없으면 입금 정보 부족: U=null, B는 유지', () {
      final r = current(simple(t1019), salary(25, []));
      expect(r.u, isNull);
      expect(r.b, 500000);
      expect(r.salaryCycle!.state, SalaryCycleState.insufficientData);
      expect(r.salaryCycle!.previousReceipt, SalaryReceiptStatus.absent);
      expect(r.insufficient, [InsufficientReason.receiptEvidenceAbsent]);
      expect(line(r, 'o-1').placement, isNull);
    });

    test('근거 부재·unknown·partial·confirmed를 구분한다', () {
      SalaryCycle cycle(List<(String, SalaryConfirmation)> receipts) =>
          resolveSalaryCycle(BusinessDate(2026, 10, 25), salary(25, receipts));
      final absent = cycle([('2026-09-25', SalaryConfirmation.confirmed)]);
      final unknown = cycle([('2026-10-25', SalaryConfirmation.unknown)]);
      final partial = cycle([('2026-10-25', SalaryConfirmation.partial)]);
      final confirmed = cycle([('2026-10-25', SalaryConfirmation.confirmed)]);
      expect(
        [
          for (final c in [absent, unknown, partial, confirmed])
            c.previousReceipt,
        ],
        [
          SalaryReceiptStatus.absent,
          SalaryReceiptStatus.unknown,
          SalaryReceiptStatus.partial,
          SalaryReceiptStatus.confirmed,
        ],
      );
      expect(
        [
          for (final c in [absent, unknown, partial, confirmed]) c.state,
        ],
        [
          SalaryCycleState.insufficientData,
          SalaryCycleState.awaitingDeposit,
          SalaryCycleState.awaitingDeposit,
          SalaryCycleState.normal,
        ],
      );
    });

    test('근거 목록 미수신(null)은 근거 없음([])과 구분해 정보 부족', () {
      final r = current(
        simple(t1019),
        SalaryInput(salaryDay: 25, receiptEvidence: null),
      );
      expect(r.insufficient, [InsufficientReason.receiptEvidenceUnavailable]);
      expect(r.salaryCycle!.previousReceipt, isNull);
    });

    test('Q2-1 해결: 회차 근거의 이동 예정일은 그 회차 월급일이며 정보 부족이 아니다', () {
      final r = current(
        simple(t1019),
        salaryOf(25, [
          receipt('2026-09', '2026-09-24', SalaryConfirmation.confirmed),
        ]),
      );
      expect(r.insufficient, isEmpty);
      expect(r.salaryCycle!.previousPayDate!.date.toString(), '2026-09-24');
      expect(r.salaryCycle!.previousPayDate!.fromEvidence, isTrue);
      expect(r.salaryCycle!.nextPayDate!.date.toString(), '2026-10-25');
      expect(r.salaryCycle!.nextPayDate!.fromEvidence, isFalse);
    });

    // Q2-2 테스트는 confirmation 값별 동작 검증이다. 계산은 확인 시각을 읽지 않으므로
    // 확인 전후 시점 판정 자체는 검증하지 않는다(그 asOf에 유효한 상태 전달은 어댑터 책임).
    group('Q2-2 10/25분 월급이 10/24에 confirmed(상태별 동작)', () {
      const afterConfirm = '2026-10-24T15:00:00+09:00';
      LedgerInput l(String asOf, int balance) => ledger(
        context(asOf),
        [account('acc-main', balance, asOf)],
        obligations: [
          obligation('o-late', 50000, '2026-10-20'),
          obligation('o-23', 70000, '2026-10-23'),
          obligation('o-25', 300000, '2026-10-25'),
          obligation('o-11', 100000, '2026-11-10'),
          obligation('o-1125', 200000, '2026-11-25'),
        ],
        settlements: [settlement('s-23', 'o-23', 70000)],
      );

      test('다음 회차 confirmed 상태면 11/25까지 구간 전환, 미지급 의무 누락·중복 없음', () {
        final r = current(
          l(afterConfirm, 3500000),
          salary(25, [
            ('2026-09-25', SalaryConfirmation.confirmed),
            ('2026-10-25', SalaryConfirmation.confirmed),
          ]),
        );
        expect(r.salaryCycle!.state, SalaryCycleState.normal);
        expect(r.salaryCycle!.nextReceipt, SalaryReceiptStatus.confirmed);
        expect(r.salaryCycle!.periodStart, isNull);
        expect(r.salaryCycle!.periodEnd.toString(), '2026-11-25');
        expect([r.b, r.e, r.u], [3500000, 450000, 3050000]);
        final inE = [
          for (final line in r.obligationLines!)
            if (line.placement == ObligationPlacement.inCurrentPeriod)
              line.obligationId,
        ];
        expect(inE, ['o-11', 'o-25', 'o-late']);
        expect(line(r, 'o-23').placement, ObligationPlacement.settled);
        expect(line(r, 'o-1125').placement, ObligationPlacement.outsidePeriod);
      });

      test('구간 시작일 null은 표시용이라 E·U에 영향이 없다(정상 구간 결과와 같음)', () {
        final early = current(
          l(afterConfirm, 3500000),
          salary(25, [('2026-10-25', SalaryConfirmation.confirmed)]),
        );
        const onPayDay = '2026-10-25T15:00:00+09:00';
        final normal = current(
          ledger(
            context(onPayDay),
            [account('acc-main', 3500000, onPayDay)],
            obligations: [
              obligation('o-late', 50000, '2026-10-20'),
              obligation('o-23', 70000, '2026-10-23'),
              obligation('o-25', 300000, '2026-10-25'),
              obligation('o-11', 100000, '2026-11-10'),
              obligation('o-1125', 200000, '2026-11-25'),
            ],
            settlements: [settlement('s-23', 'o-23', 70000)],
          ),
          salary(25, [('2026-10-25', SalaryConfirmation.confirmed)]),
        );
        expect(early.salaryCycle!.periodStart, isNull);
        expect(normal.salaryCycle!.periodStart.toString(), '2026-10-25');
        expect([early.e, early.u], [normal.e, normal.u]);
        expect(
          [for (final l in early.obligationLines!) l.placement],
          [for (final l in normal.obligationLines!) l.placement],
        );
      });

      test('입력 전제: 같은 confirmed 상태를 더 이른 asOf와 넘기면 확인 전 상태로 되돌리지 못한다', () {
        // 이 결과는 잘못된 입력의 결과다. 그 asOf에 유효한 근거만 넘기는 것은 어댑터 책임이다.
        final r = current(
          l('2026-10-23T09:00:00+09:00', 3500000),
          salary(25, [
            ('2026-09-25', SalaryConfirmation.confirmed),
            ('2026-10-25', SalaryConfirmation.confirmed),
          ]),
        );
        expect(r.salaryCycle!.periodEnd.toString(), '2026-11-25');
      });

      test('직전 회차 근거가 없어도 다음 회차 confirmed면 전환한다', () {
        final r = current(
          l(afterConfirm, 3500000),
          salary(25, [('2026-10-25', SalaryConfirmation.confirmed)]),
        );
        expect(
          [r.e, r.salaryCycle!.previousReceipt],
          [450000, SalaryReceiptStatus.absent],
        );
      });

      test('다음 회차 unknown·partial 상태면 기존 구간 유지', () {
        const beforeConfirm = '2026-10-24T09:00:00+09:00';
        final before = current(
          l(beforeConfirm, 500000),
          salary(25, [
            ('2026-09-25', SalaryConfirmation.confirmed),
            ('2026-10-25', SalaryConfirmation.unknown),
          ]),
        );
        expect(before.salaryCycle!.periodEnd.toString(), '2026-10-25');
        expect(before.e, 50000);
        final partial = current(
          l(afterConfirm, 1500000),
          salary(25, [
            ('2026-09-25', SalaryConfirmation.confirmed),
            ('2026-10-25', SalaryConfirmation.partial),
          ]),
        );
        expect(partial.salaryCycle!.periodEnd.toString(), '2026-10-25');
        expect([partial.e, partial.u], [50000, 1450000]);
      });
    });

    test('같은 회차 근거가 둘이면 오류, 월급 설정 미수신·월급일 미입력은 정보 부족', () {
      expect(
        () => current(
          simple(t1019),
          salaryOf(25, [
            receipt('2026-09', '2026-09-25', SalaryConfirmation.confirmed),
            receipt('2026-09', '2026-09-26', SalaryConfirmation.unknown),
          ]),
        ),
        inputError(InputErrorCode.duplicateId),
      );
      expect(current(simple(t1019), null).insufficient, [
        InsufficientReason.salarySettingsMissing,
      ]);
      expect(current(simple(t1019), salary(null, [])).insufficient, [
        InsufficientReason.salaryDayMissing,
      ]);
    });

    test('확인 전후 입력만으로 결과가 재현되고 같은 입력은 같은 결과', () {
      const asOf = '2026-10-25T10:00:00+09:00';
      LedgerInput l() => ledger(
        context(asOf),
        [account('acc-main', 3000000, asOf)],
        obligations: [
          obligation('o-late', 100000, '2026-10-20'),
          obligation('o-25', 200000, '2026-10-25'),
        ],
      );
      final waiting = salary(25, [
        ('2026-09-25', SalaryConfirmation.confirmed),
        ('2026-10-25', SalaryConfirmation.unknown),
      ]);
      final done = salary(25, [
        ('2026-09-25', SalaryConfirmation.confirmed),
        ('2026-10-25', SalaryConfirmation.confirmed),
      ]);
      expect(current(l(), waiting).e, 0);
      expect(current(l(), done).e, 300000);
      expect(current(l(), waiting).e, 0);
      expect(current(l(), done).u, current(l(), done).u);
    });
  });

  group('제외 계좌 의무(Q3)', () {
    LedgerInput withOff({
      List<Reserve> reserves = const [],
      List<ReserveAllocation> allocations = const [],
      List<SettlementLink> settlements = const [],
      String asOf = t1019,
    }) => ledger(
      context(asOf),
      [
        account('acc-main', 500000, asOf),
        account('acc-off', 100000, asOf, included: false),
      ],
      obligations: [
        obligation('o-main', 100000, '2026-10-22'),
        obligation('o-off', 50000, '2026-10-22', account: 'acc-off'),
      ],
      reserves: reserves,
      allocations: allocations,
      settlements: settlements,
    );

    test('제외 계좌 의무는 E에서 빼고 따로 안내하며 U를 null로 만들지 않는다', () {
      final r = current(withOff(), paidSeptember);
      expect([r.b, r.e, r.u], [500000, 100000, 400000]);
      expect(r.insufficient, isEmpty);
      expect(line(r, 'o-off').placement, ObligationPlacement.excludedAccount);
      expect(line(r, 'o-off').remainingKrw, 50000);
    });

    test('포함 계좌 보호액을 제외 계좌 의무에 배정해도 O에 넣지 않는다', () {
      final r = current(
        withOff(
          reserves: [reserve('r-main', 200000)],
          allocations: [allocation('al-off', 'r-main', 'o-off', 50000)],
        ),
        paidSeptember,
      );
      expect([r.r, r.o, r.rEff, r.u], [200000, 0, 200000, 200000]);
      expect(line(r, 'o-off').overlapKrw, 50000);
    });

    test('제외 계좌 의무의 정산은 그 의무 잔여만 바꾸고 포함 계좌 E에 섞이지 않는다', () {
      final r = current(
        withOff(settlements: [settlement('s-off', 'o-off', 20000)]),
        paidSeptember,
      );
      expect(r.e, 100000);
      expect(line(r, 'o-off').remainingKrw, 30000);
      final paid = current(
        withOff(settlements: [settlement('s-off', 'o-off', 50000)]),
        paidSeptember,
      );
      expect(line(paid, 'o-off').placement, ObligationPlacement.settled);
    });

    test('입금 대기 중에도 제외 계좌 의무는 대기가 아니라 제외 계좌로 분류한다', () {
      const asOf = '2026-10-25T09:00:00+09:00';
      final r = current(
        withOff(asOf: asOf),
        salary(25, [
          ('2026-09-25', SalaryConfirmation.confirmed),
          ('2026-10-25', SalaryConfirmation.unknown),
        ]),
      );
      expect(line(r, 'o-main').placement, ObligationPlacement.awaitingSalary);
      expect(line(r, 'o-off').placement, ObligationPlacement.excludedAccount);
    });

    test('구간 계산도 제외 계좌 의무를 이벤트·예약에서 빼고 결과를 null로 만들지 않는다', () {
      final r = projectPeriods(
        ProjectionInput(
          ledger: ledger(
            context(t1014),
            [
              account('acc-main', 500000, t1014),
              account('acc-off', 100000, t1014, included: false),
            ],
            obligations: [
              obligation('o-main', 100000, '2026-10-22'),
              obligation('o-off', 50000, '2026-10-22', account: 'acc-off'),
            ],
          ),
          payDates: [
            pay('2026-10-25', 0),
            pay('2026-11-25', 0),
            pay('2026-12-25', 0),
          ],
          items: const [],
        ),
      );
      expect(r.insufficient, isEmpty);
      expect(r.excludedAccountObligationIds, ['o-off']);
      expect(r.baseline!.periods[0].endH, 400000);
    });

    test('출금 계좌가 연결 계좌 목록에 없는 의무는 제외 계좌와 구분해 입력 오류', () {
      expect(
        () => current(
          ledger(
            context(t1019),
            [account('acc-main', 500000, t1019)],
            obligations: [
              obligation('o-x', 1, '2026-10-22', account: 'acc-unknown'),
            ],
          ),
          paidSeptember,
        ),
        inputError(InputErrorCode.unknownReference),
      );
    });
  });

  group('누락과 빈 목록', () {
    test('null 목록은 미확인이라 영향 값이 null, 빈 목록은 확인된 0건', () {
      final missing = current(
        ledger(
          context(t1019),
          [account('acc-main', 500000, t1019)],
          obligations: null,
          reserves: null,
          allocations: null,
          settlements: null,
        ),
        paidSeptember,
      );
      expect(
        [missing.b, missing.e, missing.r, missing.o, missing.u],
        [500000, null, null, null, null],
      );
      expect(missing.insufficient.toSet(), {
        InsufficientReason.obligationsMissing,
        InsufficientReason.settlementsMissing,
        InsufficientReason.reservesMissing,
        InsufficientReason.allocationsMissing,
      });
      final empty = current(
        ledger(context(t1019), [account('acc-main', 500000, t1019)]),
        paidSeptember,
      );
      expect([empty.e, empty.r, empty.o, empty.u], [0, 0, 0, 500000]);
    });

    test('0원 잔액은 정상값, 포함 계좌 잔액 미확보·기준시각 불일치·포함 0개는 B=null', () {
      expect(
        current(
          ledger(context(t1019), [account('acc-main', 0, t1019)]),
          paidSeptember,
        ).u,
        0,
      );
      expect(
        current(
          ledger(context(t1019), [account('acc-main', null, t1019)]),
          paidSeptember,
        ).insufficient,
        [InsufficientReason.balanceMissing],
      );
      expect(
        current(
          ledger(context(t1019), [
            account('acc-main', 10, '2026-10-19T11:00:00+09:00'),
          ]),
          paidSeptember,
        ).insufficient,
        [InsufficientReason.balanceAsOfMismatch],
      );
      expect(
        current(
          ledger(context(t1019), [
            account('acc-main', 10, t1019, included: false),
          ]),
          paidSeptember,
        ).insufficient,
        [InsufficientReason.noIncludedAccount],
      );
    });

    test('같은 시각을 다른 오프셋으로 쓴 잔액 기준시각은 일치로 본다', () {
      final r = current(
        ledger(context(t1019), [
          account('acc-main', 10, '2026-10-19T03:00:00Z'),
        ]),
        paidSeptember,
      );
      expect(r.b, 10);
    });

    test('장부 정보가 부족하면 구간 계산 결과도 null이고 사유를 남긴다', () {
      final r = projectPeriods(
        ProjectionInput(
          ledger: ledger(context(t1014), [account('acc-main', null, t1014)]),
          payDates: [pay('2026-10-25', 0)],
          items: const [],
        ),
      );
      expect(r.baseline, isNull);
      expect(r.insufficient, [InsufficientReason.balanceMissing]);
    });
  });

  group('금액 한도', () {
    test('입력 금액 범위: 잔액 ±9e12, Money 0 이상, PositiveMoney 1 이상', () {
      expect(
        () => account('a', maxAbsKrw + 1, t1019),
        inputError(InputErrorCode.amountOutOfRange),
      );
      expect(account('a', -maxAbsKrw, t1019).balanceKrw, -maxAbsKrw);
      expect(
        () => obligation('o', -1, '2026-10-22'),
        inputError(InputErrorCode.amountOutOfRange),
      );
      expect(
        () => settlement('s', 'o', 0),
        inputError(InputErrorCode.amountOutOfRange),
      );
      expect(
        () => allocation('al', 'r', 'o', 0),
        inputError(InputErrorCode.amountOutOfRange),
      );
    });

    test('B 중간 합계가 상한을 넘으면 오류이며 잘라내지 않는다', () {
      expect(
        () => current(
          ledger(context(t1019), [
            account('a1', maxAbsKrw, t1019),
            account('a2', 1, t1019),
          ]),
          paidSeptember,
        ),
        inputError(InputErrorCode.amountOutOfRange),
      );
    });

    test('U가 -9e12보다 작아지면 오류', () {
      expect(
        () => current(
          ledger(
            context(t1019),
            [account('acc-main', -maxAbsKrw, t1019)],
            obligations: [obligation('o-1', 1, '2026-10-22')],
          ),
          paidSeptember,
        ),
        inputError(InputErrorCode.amountOutOfRange),
      );
    });

    test('구간 H 계산 중 상한을 넘으면 오류', () {
      expect(
        () => projectPeriods(
          ProjectionInput(
            ledger: ledger(context(t1014), [
              account('acc-main', maxAbsKrw, t1014),
            ]),
            payDates: [
              pay('2026-10-25', 1),
              pay('2026-11-25', 1),
              pay('2026-12-25', 1),
            ],
            items: const [],
          ),
        ),
        inputError(InputErrorCode.amountOutOfRange),
      );
    });
  });

  group('기준·불변·순서', () {
    test('지원하지 않는 ruleVersion, 오프셋 없는 asOf, 음수 inputRevision은 오류', () {
      expect(
        () => CalculationContext(
          dataVersion: '1',
          sourceVersion: 's',
          ruleVersion: 'PAYSE-CALC-2',
          asOf: t1019,
          inputRevision: 0,
        ),
        inputError(InputErrorCode.unsupportedRuleVersion),
      );
      expect(
        () => context('2026-10-19T12:00:00'),
        inputError(InputErrorCode.invalidDate),
      );
      expect(
        () => context(t1019, inputRevision: -1),
        inputError(InputErrorCode.invalidValue),
      );
    });

    test(
      '결과는 dataVersion·sourceVersion·ruleVersion·asOf·inputRevision을 보존한다',
      () {
        final ctx = context(t1019, inputRevision: 42);
        final r = current(
          ledger(ctx, [account('acc-main', 1, t1019)]),
          paidSeptember,
        );
        expect(identical(r.context, ctx), isTrue);
        expect(
          [
            r.context.dataVersion,
            r.context.sourceVersion,
            r.context.ruleVersion,
            r.context.asOf,
            r.context.inputRevision,
          ],
          ['7', 'test-source', 'PAYSE-CALC-1', t1019, 42],
        );
      },
    );

    test('입력 목록을 나중에 바꿔도 계산 입력은 그대로이고 결과 목록은 수정할 수 없다', () {
      final obligations = [obligation('o-1', 100, '2026-10-22')];
      final input = ledger(context(t1019), [
        account('acc-main', 1000, t1019),
      ], obligations: obligations);
      obligations.add(obligation('o-2', 900, '2026-10-22'));
      final r = current(input, paidSeptember);
      expect(r.e, 100);
      expect(
        () => input.obligations!.add(obligations.last),
        throwsUnsupportedError,
      );
      expect(() => r.obligationLines!.clear(), throwsUnsupportedError);
      expect(
        () => r.insufficient.add(InsufficientReason.balanceMissing),
        throwsUnsupportedError,
      );
    });

    test('입력 목록 순서를 바꿔도 결과와 오류 종류가 같다', () {
      final obligations = [
        obligation('o-a', 100000, '2026-10-20'),
        obligation('o-b', 200000, '2026-10-22'),
        obligation('o-c', 50000, '2026-11-02'),
      ];
      final reserves = [reserve('r-a', 100000), reserve('r-b', 50000)];
      final allocations = [
        allocation('al-1', 'r-a', 'o-a', 100000),
        allocation('al-2', 'r-b', 'o-b', 50000),
      ];
      final settlements = [
        settlement('s-1', 'o-b', 20000),
        settlement('s-2', 'o-c', 10000),
      ];
      CurrentAmountResult run(bool reversed) {
        List<T> order<T>(List<T> list) =>
            reversed ? list.reversed.toList() : list;
        return current(
          ledger(
            context(t1019),
            order([
              account('acc-main', 900000, t1019),
              account('acc-sub', 100000, t1019),
            ]),
            obligations: order(obligations),
            reserves: order(reserves),
            allocations: order(allocations),
            settlements: order(settlements),
          ),
          paidSeptember,
        );
      }

      final a = run(false);
      final b = run(true);
      expect([a.b, a.e, a.r, a.o, a.u], [b.b, b.e, b.r, b.o, b.u]);
      expect(
        [for (final l in a.obligationLines!) l.obligationId],
        [for (final l in b.obligationLines!) l.obligationId],
      );
    });

    test('Q5 배정 의무 가상 출금 때 예약과 연결 배정액만큼 R을 함께 해제해 A가 이어진다', () {
      final r = projectPeriods(
        ProjectionInput(
          ledger: ledger(
            context(t1014),
            [account('acc-main', 1000000, t1014)],
            obligations: [obligation('o-1', 300000, '2026-10-20')],
            reserves: [reserve('r-1', 300000)],
            allocations: [allocation('al-1', 'r-1', 'o-1', 300000)],
          ),
          payDates: [
            pay('2026-10-25', 0),
            pay('2026-11-25', 0),
            pay('2026-12-25', 0),
          ],
          items: const [],
        ),
      );
      final c1 = r.baseline!.periods[0];
      expect([c1.endH, c1.endA, c1.minA], [700000, 700000, 700000]);
    });

    group('Q5 연결 배정액만 해제', () {
      List<int?> endAOf(LedgerInput l) {
        final r = projectPeriods(
          ProjectionInput(
            ledger: l,
            payDates: [
              pay('2026-10-25', 0),
              pay('2026-11-25', 0),
              pay('2026-12-25', 0),
            ],
            items: const [],
          ),
        );
        return [for (final p in r.baseline!.periods) p.endA];
      }

      test('의무 300,000에 100,000만 배정: 출금 때 100,000만 해제하고 나머지 보호는 유지', () {
        // H 1,000,000 → 700,000, R 300,000 → 200,000, A = 700,000 − 200,000.
        final a = endAOf(
          ledger(
            context(t1014),
            [account('acc-main', 1000000, t1014)],
            obligations: [obligation('o-1', 300000, '2026-10-20')],
            reserves: [reserve('r-1', 300000)],
            allocations: [allocation('al-1', 'r-1', 'o-1', 100000)],
          ),
        );
        expect(a, [500000, 500000, 500000]);
      });

      test('실제 부분 정산 뒤 남은 배정만 가상 출금 때 해제', () {
        // 100,000 의무 중 40,000 실제 정산·해제 → 잔여 60,000·미해제 60,000. R 400,000(해제 반영).
        final a = endAOf(
          ledger(
            context(t1014),
            [account('acc-main', 1000000, t1014)],
            obligations: [obligation('o-1', 100000, '2026-10-18')],
            reserves: [reserve('r-1', 400000)],
            allocations: [allocation('al-1', 'r-1', 'o-1', 100000, 40000)],
            settlements: [settlement('s-1', 'o-1', 40000)],
          ),
        );
        // H 940,000, R 340,000 → A 600,000. 해제 전 A도 1,000,000 − 60,000 − (400,000 − 60,000) = 600,000.
        expect(a, [600000, 600000, 600000]);
      });

      test('한 보호액이 여러 의무에 연결되면 각 의무 출금 때 그 배정만 해제하고 미배정분은 남긴다', () {
        // R 300,000 = o-1 배정 100,000 + o-2 배정 150,000 + 미배정 50,000.
        final input = ledger(
          context(t1014),
          [account('acc-main', 1000000, t1014)],
          obligations: [
            obligation('o-1', 100000, '2026-10-20'),
            obligation('o-2', 200000, '2026-11-05'),
          ],
          reserves: [reserve('r-1', 300000)],
          allocations: [
            allocation('al-1', 'r-1', 'o-1', 100000),
            allocation('al-2', 'r-1', 'o-2', 150000),
          ],
        );
        final r = projectPeriods(
          ProjectionInput(
            ledger: input,
            payDates: [
              pay('2026-10-25', 0),
              pay('2026-11-25', 0),
              pay('2026-12-25', 0),
            ],
            items: const [],
          ),
        );
        final periods = r.baseline!.periods;
        // C1 끝: H 900,000, R 200,000(o-2 배정은 C2 예약이라 아직 겹침 아님) → A 700,000.
        // C2 끝: H 700,000, R 50,000(미배정분만 남음) → A 650,000.
        expect([for (final p in periods) p.endH], [900000, 700000, 700000]);
        expect([for (final p in periods) p.endA], [700000, 650000, 650000]);
        // C2 시작일(10-25) A: 900,000 − 200,000 − (200,000 − 150,000) = 650,000. 출금일 전후 연속.
        expect(periods[1].minA, 650000);
      });
    });

    test('구간 계산의 가상 R 해제는 같은 입력의 현재 U·R에 섞이지 않는다', () {
      final input = ledger(
        context(t1014),
        [account('acc-main', 1000000, t1014)],
        obligations: [obligation('o-1', 300000, '2026-10-20')],
        reserves: [reserve('r-1', 300000)],
        allocations: [allocation('al-1', 'r-1', 'o-1', 300000)],
      );
      final s = salary(25, [('2026-09-25', SalaryConfirmation.confirmed)]);
      final before = current(input, s);
      projectPeriods(
        ProjectionInput(
          ledger: input,
          payDates: [
            pay('2026-10-25', 0),
            pay('2026-11-25', 0),
            pay('2026-12-25', 0),
          ],
          items: const [],
        ),
      );
      final after = current(input, s);
      expect([before.r, before.o, before.u], [300000, 300000, 700000]);
      expect([after.r, after.o, after.u], [before.r, before.o, before.u]);
      expect(input.reserves!.single.amountKrw, 300000);
      expect(input.allocations!.single.releasedKrw, 0);
    });

    test('가상 소비 입력: 0건이면 비교 해제, 6건·중복 ID·구매일 범위 밖·카드 결제일이 구매일보다 이르면 오류', () {
      ProjectionInput input(List<VirtualPurchase> items) => ProjectionInput(
        ledger: ledger(context(t1014), [account('acc-main', 1000, t1014)]),
        payDates: [
          pay('2026-10-25', 0),
          pay('2026-11-25', 0),
          pay('2026-12-25', 0),
        ],
        items: items,
      );
      VirtualPurchase item(String id, [String date = '2026-10-20']) =>
          VirtualPurchase(
            itemId: id,
            amountKrw: 1,
            purchaseDate: date,
            paymentMethod: PaymentMethod.immediate,
          );
      final none = projectPeriods(input(const []));
      expect([none.allItems, none.endADifferences], [null, null]);
      expect(
        () => projectPeriods(input([for (var i = 0; i < 6; i++) item('i$i')])),
        inputError(InputErrorCode.invalidValue),
      );
      expect(
        () => projectPeriods(input([item('i'), item('i')])),
        inputError(InputErrorCode.duplicateId),
      );
      expect(
        () => projectPeriods(input([item('i', '2026-10-13')])),
        inputError(InputErrorCode.invalidSchedule),
      );
      expect(
        () => projectPeriods(input([item('i', '2026-12-25')])),
        inputError(InputErrorCode.invalidSchedule),
      );
      expect(
        () => VirtualPurchase(
          itemId: 'c',
          amountKrw: 1,
          purchaseDate: '2026-10-20',
          paymentMethod: PaymentMethod.cardLumpSum,
          plannedWithdrawalDate: '2026-10-19',
        ),
        inputError(InputErrorCode.invalidSchedule),
      );
    });
  });

  test('lib는 flutter·입출력·현재 시각·난수를 쓰지 않는다', () {
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in sources) {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('package:flutter')), reason: file.path);
      expect(text, isNot(contains('dart:io')), reason: file.path);
      expect(text, isNot(contains('DateTime.now')), reason: file.path);
      expect(text, isNot(contains('Random')), reason: file.path);
    }
  });
}
