import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

// 원문: docs/references/detailed-plan-v7.source.md §7-1 TC-C01~05·09~12, docs/calculation-rules.md 현재 금액·월급 구간.
const t1019 = '2026-10-19T12:00:00+09:00';
final paidSeptember = salary(25, [
  ('2026-09-25', SalaryConfirmation.confirmed),
]);

void main() {
  test('TC-C01 U=B−E−(R−O)이며 이미 입금된 급여를 다시 더하지 않는다', () {
    final r = current(
      ledger(
        context(t1019),
        [account('acc-main', 2000000, t1019)],
        obligations: [obligation('o-rent', 500000, '2026-10-22')],
        reserves: [
          Reserve(
            reserveId: 'r-1',
            accountId: 'acc-main',
            amountKrw: 400000,
            cancelledAt: null,
          ),
        ],
      ),
      paidSeptember,
    );
    expect(
      [r.b, r.e, r.r, r.o, r.rEff, r.u],
      [2000000, 500000, 400000, 0, 400000, 1100000],
    );
    expect(r.insufficient, isEmpty);
    expect(r.salaryCycle!.state, SalaryCycleState.normal);
  });

  test(
    'TC-C02 카드 청구 300,000 출금·정산 후 B=1,700,000·E=200,000·U=1,100,000, 한 번만 반영',
    () {
      final r = current(
        ledger(
          context(t1019),
          [account('acc-main', 1700000, t1019)],
          obligations: [
            obligation('o-card', 300000, '2026-10-20'),
            obligation('o-other', 200000, '2026-10-22'),
          ],
          reserves: [
            Reserve(
              reserveId: 'r-1',
              accountId: 'acc-main',
              amountKrw: 400000,
              cancelledAt: null,
            ),
          ],
          settlements: [settlement('s-card', 'o-card', 300000)],
        ),
        paidSeptember,
      );
      expect([r.b, r.e, r.u], [1700000, 200000, 1100000]);
      final card = line(r, 'o-card');
      expect([card.settledKrw, card.remainingKrw], [300000, 0]);
      expect(card.placement, ObligationPlacement.settled);
    },
  );

  test('TC-C03 보호액과 같은 의무: 전 U=700,000, 전액 출금 후 E=R=O=0·U=700,000', () {
    final reserve = Reserve(
      reserveId: 'r-1',
      accountId: 'acc-main',
      amountKrw: 300000,
      cancelledAt: null,
    );
    final before = current(
      ledger(
        context(t1019),
        [account('acc-main', 1000000, t1019)],
        obligations: [obligation('o-1', 300000, '2026-10-22')],
        reserves: [reserve],
        allocations: [
          ReserveAllocation(
            allocationId: 'al-1',
            reserveId: 'r-1',
            obligationId: 'o-1',
            amountKrw: 300000,
            releasedKrw: 0,
          ),
        ],
      ),
      paidSeptember,
    );
    expect(
      [before.e, before.r, before.o, before.u],
      [300000, 300000, 300000, 700000],
    );

    final after = current(
      ledger(
        context(t1019),
        [account('acc-main', 700000, t1019)],
        obligations: [obligation('o-1', 300000, '2026-10-22')],
        reserves: [
          Reserve(
            reserveId: 'r-1',
            accountId: 'acc-main',
            amountKrw: 0,
            cancelledAt: null,
          ),
        ],
        allocations: [
          ReserveAllocation(
            allocationId: 'al-1',
            reserveId: 'r-1',
            obligationId: 'o-1',
            amountKrw: 300000,
            releasedKrw: 300000,
          ),
        ],
        settlements: [settlement('s-1', 'o-1', 300000)],
      ),
      paidSeptember,
    );
    expect(
      [after.b, after.e, after.r, after.o, after.u],
      [700000, 0, 0, 0, 700000],
    );
  });

  test('TC-C04 제외 계좌 잔액·보호액은 B·R에 넣지 않는다: B=700,000·R=0·U=600,000', () {
    final r = current(
      ledger(
        context(t1019),
        [
          account('acc-main', 700000, t1019),
          account('acc-off', 300000, t1019, included: false),
        ],
        obligations: [obligation('o-1', 100000, '2026-10-22')],
        reserves: [
          Reserve(
            reserveId: 'r-off',
            accountId: 'acc-off',
            amountKrw: 300000,
            cancelledAt: null,
          ),
        ],
      ),
      paidSeptember,
    );
    expect([r.b, r.r, r.e, r.u], [700000, 0, 100000, 600000]);
  });

  test('TC-C05(부분) 포함 계좌 사이 이체 후에도 B=1,000,000 유지', () {
    // 수입·소비로 집계하지 않는지는 연간 소비 집계 작업에서 검증한다. 이 패키지는 거래를 다시 재생하지 않는다.
    LedgerInput balances(int a, int b) => ledger(context(t1019), [
      account('acc-main', a, t1019),
      account('acc-sub', b, t1019),
    ]);
    expect(current(balances(600000, 400000), paidSeptember).b, 1000000);
    expect(current(balances(500000, 500000), paidSeptember).b, 1000000);
  });

  test('TC-C09(홈) 연체 미지급 의무는 기간 종료로 지우지 않고 E에 남는다', () {
    final r = current(
      ledger(
        context(t1019),
        [account('acc-main', 1000000, t1019)],
        obligations: [obligation('o-late', 120000, '2026-09-30')],
      ),
      paidSeptember,
    );
    expect(r.e, 120000);
    expect(line(r, 'o-late').placement, ObligationPlacement.inCurrentPeriod);
  });

  test('TC-C10 300,000 의무 중 100,000 정산 뒤 E=200,000, 취소하면 E 해제·B 불변', () {
    LedgerInput input(ObligationStatus status) => ledger(
      context(t1019),
      [account('acc-main', 900000, t1019)],
      obligations: [obligation('o-1', 300000, '2026-10-22', status: status)],
      settlements: [settlement('s-1', 'o-1', 100000)],
    );
    final partial = current(input(ObligationStatus.active), paidSeptember);
    expect([partial.e, partial.b], [200000, 900000]);
    final cancelled = current(input(ObligationStatus.cancelled), paidSeptember);
    expect([cancelled.e, cancelled.b, cancelled.u], [0, 900000, 900000]);
    expect(line(cancelled, 'o-1').settledKrw, 100000);
    expect(line(cancelled, 'o-1').placement, ObligationPlacement.cancelled);
  });

  group('TC-C11 월급일 입금 확인 시 구간 전환', () {
    List<Obligation> obligations() => [
      obligation('o-rent', 500000, '2026-10-25'),
      obligation('o-phone', 300000, '2026-11-01'),
      obligation('o-loan', 500000, '2026-11-10'),
    ];
    final reserve = [
      Reserve(
        reserveId: 'r-1',
        accountId: 'acc-main',
        amountKrw: 500000,
        cancelledAt: null,
      ),
    ];
    CurrentAmountResult at(
      String asOf,
      int balance,
      SalaryConfirmation october,
    ) => current(
      ledger(
        context(asOf),
        [account('acc-main', balance, asOf)],
        obligations: obligations(),
        reserves: reserve,
      ),
      salary(25, [
        ('2026-09-25', SalaryConfirmation.confirmed),
        ('2026-10-25', october),
      ]),
    );

    test('10/24는 이전 구간이며 U=-300,000', () {
      final r = at(
        '2026-10-24T12:00:00+09:00',
        200000,
        SalaryConfirmation.unknown,
      );
      expect([r.e, r.u], [0, -300000]);
      expect(r.salaryCycle!.state, SalaryCycleState.normal);
      expect(line(r, 'o-rent').placement, ObligationPlacement.outsidePeriod);
    });

    test('10/25 00:00 입금 전은 대기: U=-300,000 유지, 당일 월세는 반영 대기, 예상 월급 미반영', () {
      final r = at(
        '2026-10-25T00:00:00+09:00',
        200000,
        SalaryConfirmation.unknown,
      );
      expect([r.b, r.e, r.u], [200000, 0, -300000]);
      expect(r.salaryCycle!.state, SalaryCycleState.awaitingDeposit);
      expect(r.salaryCycle!.periodEnd.toString(), '2026-10-25');
      expect(line(r, 'o-rent').placement, ObligationPlacement.awaitingSalary);
      expect(line(r, 'o-rent').remainingKrw, 500000);
      expect(r.insufficient, isEmpty);
    });

    test('부분 입금은 원천 잔액에 반영되지만 confirmed 전까지 대기', () {
      final r = at(
        '2026-10-25T09:00:00+09:00',
        1200000,
        SalaryConfirmation.partial,
      );
      expect([r.b, r.e, r.u], [1200000, 0, 700000]);
      expect(r.salaryCycle!.state, SalaryCycleState.awaitingDeposit);
    });

    test(
      '입금 3,000,000 확인 뒤 B=3,200,000·E=1,300,000·U=1,400,000, 대기 의무를 한 번만 포함',
      () {
        final r = at(
          '2026-10-25T10:00:00+09:00',
          3200000,
          SalaryConfirmation.confirmed,
        );
        expect([r.b, r.e, r.u], [3200000, 1300000, 1400000]);
        expect(r.salaryCycle!.periodEnd.toString(), '2026-11-25');
        final inE = r.obligationLines!
            .where((l) => l.placement == ObligationPlacement.inCurrentPeriod)
            .map((l) => l.obligationId)
            .toList();
        expect(inE, ['o-loan', 'o-phone', 'o-rent']);
      },
    );

    test('10/26까지 미입금이면 이전 구간 유지·미입금 상태', () {
      final r = at(
        '2026-10-26T09:00:00+09:00',
        200000,
        SalaryConfirmation.unknown,
      );
      expect([r.e, r.u], [0, -300000]);
      expect(r.salaryCycle!.state, SalaryCycleState.awaitingDeposit);
      expect(r.salaryCycle!.periodStart.toString(), '2026-09-25');
      expect(line(r, 'o-rent').placement, ObligationPlacement.awaitingSalary);
    });

    test('대기 대상은 급여일 당일·연체 의무만이고 월급일 뒤 오늘 기한 의무는 이전 구간 밖', () {
      const asOf = '2026-10-27T09:00:00+09:00';
      final r = current(
        ledger(
          context(asOf),
          [account('acc-main', 200000, asOf)],
          obligations: [
            obligation('o-old', 10000, '2026-10-01'),
            obligation('o-25', 20000, '2026-10-25'),
            obligation('o-26', 30000, '2026-10-26'),
            obligation('o-27', 40000, '2026-10-27'),
          ],
        ),
        salary(25, [
          ('2026-09-25', SalaryConfirmation.confirmed),
          ('2026-10-25', SalaryConfirmation.unknown),
        ]),
      );
      expect(r.e, 0);
      expect(
        [
          for (final id in ['o-old', 'o-25', 'o-26', 'o-27'])
            line(r, id).placement,
        ],
        [
          ObligationPlacement.awaitingSalary,
          ObligationPlacement.awaitingSalary,
          ObligationPlacement.awaitingSalary,
          ObligationPlacement.outsidePeriod,
        ],
      );
    });
  });

  group('TC-C12 청구 갱신·정산·부분 출금·근거 없는 출금', () {
    final reserves = [
      Reserve(
        reserveId: 'r-1',
        accountId: 'acc-main',
        amountKrw: 400000,
        cancelledAt: null,
      ),
    ];
    CurrentAmountResult run(
      int balance,
      int cardAmount,
      List<SettlementLink> links,
    ) => current(
      ledger(
        context(t1019),
        [account('acc-main', balance, t1019)],
        obligations: [
          obligation('o-card', cardAmount, '2026-10-23'),
          obligation('o-other', 200000, '2026-10-22'),
        ],
        reserves: reserves,
        settlements: links,
      ),
      paidSeptember,
    );

    test('갱신 전 E=500,000, 갱신 후 E=545,000', () {
      expect(run(2000000, 300000, []).e, 500000);
      expect(run(2000000, 345000, []).e, 545000);
    });

    test('345,000 출금 정산 뒤 이미 나간 돈 345,000·E=200,000, 이중 차감 없음', () {
      final r = run(1655000, 345000, [settlement('s-card', 'o-card', 345000)]);
      expect(line(r, 'o-card').settledKrw, 345000);
      expect([r.e, r.u], [200000, 1055000]);
    });

    test('300,000 의무에 100,000만 출금하면 남은 200,000만 E', () {
      final r = current(
        ledger(
          context(t1019),
          [account('acc-main', 1900000, t1019)],
          obligations: [obligation('o-bill', 300000, '2026-10-23')],
          settlements: [settlement('s-part', 'o-bill', 100000)],
        ),
        paidSeptember,
      );
      expect(r.e, 200000);
      expect(line(r, 'o-bill').remainingKrw, 200000);
    });

    test('금액만 같은 다른 출금은 정산 연결이 없으므로 E를 유지한다', () {
      // 계산 입력은 명시 정산 연결만 받으며 거래 금액·날짜로 자동 연결하지 않는다.
      final r = run(1700000, 300000, []);
      expect(r.e, 500000);
      expect(line(r, 'o-card').settledKrw, 0);
    });
  });
}
