import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

// 02-2 계산 내역(#28 2단계)의 근거 출력. 기존 B·E·R·O·U와 같은 계산에서 나오고 합계가 일치해야 한다.
const t1019 = '2026-10-19T12:00:00+09:00';
final paidSeptember = salary(25, [
  ('2026-09-25', SalaryConfirmation.confirmed),
]);

/// 2026-10-26: 보호액 [id](계좌 [account], 설정액 [amount])를 만든다.
Reserve reserve(String id, int amount, {String account = 'acc-main'}) =>
    Reserve(
      reserveId: id,
      accountId: account,
      amountKrw: amount,
      cancelledAt: null,
    );

/// 2026-10-26: 보호액 [reserveId]에서 의무 [obligationId]로 [amount]원 중 [released]원 해제된 배정 [id]를 만든다.
ReserveAllocation allocation(
  String id,
  String reserveId,
  String obligationId,
  int amount, {
  int released = 0,
}) => ReserveAllocation(
  allocationId: id,
  reserveId: reserveId,
  obligationId: obligationId,
  amountKrw: amount,
  releasedKrw: released,
);

/// 2026-10-26: 02-2 시안과 같은 장부(부분 출금 수리비·비상금 배정·다음 기간·제외 계좌 의무)를 만든다.
/// [reversed]가 true면 모든 목록 순서를 뒤집는다.
LedgerInput receiptLedger({
  bool reversed = false,
  List<ReserveAllocation>? allocations,
  bool allocationsKnown = true,
}) {
  List<T> order<T>(List<T> items) => reversed ? items.reversed.toList() : items;
  return ledger(
    context(t1019),
    order([
      account('acc-main', 1500000, t1019),
      account('acc-save', 500000, t1019),
      account('acc-out', 300000, t1019, included: false),
    ]),
    obligations: order([
      obligation('o-rent', 300000, '2026-10-22'),
      obligation('o-repair', 100000, '2026-10-18'),
      obligation('o-card', 110000, '2026-10-10'),
      obligation('o-phone', 50000, '2026-10-25'),
      obligation('o-insure', 30000, '2026-10-20', account: 'acc-out'),
    ]),
    reserves: order([
      reserve('r-emergency', 400000),
      reserve('r-out', 100000, account: 'acc-out'),
    ]),
    allocations: allocationsKnown
        ? order(
            allocations ??
                [
                  allocation(
                    'al-repair',
                    'r-emergency',
                    'o-repair',
                    100000,
                    released: 40000,
                  ),
                  allocation('al-phone', 'r-emergency', 'o-phone', 20000),
                ],
          )
        : null,
    settlements: order([
      settlement('s-card', 'o-card', 110000),
      settlement('s-repair', 'o-repair', 40000),
    ]),
  );
}

void main() {
  test('내역 합계가 B·E·O·R−O·U와 같고 다음 기간 배정은 O에 넣지 않는다', () {
    final r = current(receiptLedger(), paidSeptember);
    expect(
      [r.b, r.e, r.r, r.o, r.rEff, r.u],
      [2000000, 360000, 400000, 60000, 340000, 1300000],
    );
    expect(r.deductionKrw, 700000);
    expect(r.b! - r.deductionKrw!, r.u);

    expect(
      [for (final a in r.accountLines!) (a.accountId, a.balanceKrw)],
      [('acc-main', 1500000), ('acc-save', 500000)],
    );

    final reserves = r.reserveLines!;
    expect(reserves.map((l) => l.reserveId), ['r-emergency']);
    final emergency = reserves.single;
    expect(emergency.amountKrw, 400000);
    expect(
      [for (final o in emergency.overlaps!) (o.obligationId, o.unreleasedKrw)],
      [('o-repair', 60000)],
    );
    expect(emergency.effectiveKrw, r.rEff);
    expect(emergency.usedKrw, r.o);

    final totals = r.placementTotals!;
    expect(totals[ObligationPlacement.inCurrentPeriod]!.count, 2);
    expect(totals[ObligationPlacement.inCurrentPeriod]!.totalKrw, r.e);
    expect(totals[ObligationPlacement.outsidePeriod]!.totalKrw, 50000);
    expect(totals[ObligationPlacement.excludedAccount]!.count, 1);
    expect(totals[ObligationPlacement.excludedAccount]!.totalKrw, 30000);
    expect(totals[ObligationPlacement.settled]!.count, 1);
    expect(totals.containsKey(ObligationPlacement.awaitingSalary), isFalse);

    expect(r.settledTotal!.count, 2);
    expect(r.settledTotal!.totalKrw, 150000);
  });

  test('목록 순서를 바꿔도 내역이 같다', () {
    final a = current(receiptLedger(), paidSeptember);
    final b = current(receiptLedger(reversed: true), paidSeptember);
    expect(
      b.accountLines!.map((l) => l.accountId),
      a.accountLines!.map((l) => l.accountId),
    );
    expect(
      b.reserveLines!.single.overlaps!.map((o) => o.obligationId),
      a.reserveLines!.single.overlaps!.map((o) => o.obligationId),
    );
    expect(
      b.reserveLines!.single.effectiveKrw,
      a.reserveLines!.single.effectiveKrw,
    );
    expect(b.settledTotal!.totalKrw, a.settledTotal!.totalKrw);
    expect(b.deductionKrw, a.deductionKrw);
  });

  test('배정 목록을 모르면 보호액 설정액만 두고 배정·남겨둘 금액·U 근거는 null이다', () {
    final r = current(receiptLedger(allocationsKnown: false), paidSeptember);
    expect(r.u, isNull);
    expect(r.deductionKrw, isNull);
    final line = r.reserveLines!.single;
    expect(line.amountKrw, 400000);
    expect(line.overlaps, isNull);
    expect(line.usedKrw, isNull);
    expect(line.effectiveKrw, isNull);
    expect(r.accountLines, isNotNull);
  });

  test('입금 대기: 반영 대기 합계를 따로 내고 E는 0, 대기 의무 배정은 O에 넣지 않는다', () {
    const t1025 = '2026-10-25T08:00:00+09:00';
    final r = current(
      ledger(
        context(t1025),
        [account('acc-main', 2000000, t1025)],
        obligations: [
          obligation('o-rent', 300000, '2026-10-22'),
          obligation('o-phone', 50000, '2026-10-25'),
        ],
        reserves: [reserve('r-emergency', 400000)],
        allocations: [allocation('al-rent', 'r-emergency', 'o-rent', 100000)],
      ),
      salary(25, [
        ('2026-09-25', SalaryConfirmation.confirmed),
        ('2026-10-25', SalaryConfirmation.unknown),
      ]),
    );
    expect(r.salaryCycle!.state, SalaryCycleState.awaitingDeposit);
    expect([r.e, r.o, r.rEff, r.u], [0, 0, 400000, 1600000]);
    final waiting = r.placementTotals![ObligationPlacement.awaitingSalary]!;
    expect([waiting.count, waiting.totalKrw], [2, 350000]);
    expect(r.reserveLines!.single.overlaps, isEmpty);
    expect(r.reserveLines!.single.effectiveKrw, 400000);
  });

  test('월급 정보 부족: 위치 미정 의무는 위치별 합계에 넣지 않고 B·R 내역은 유지한다', () {
    final r = current(receiptLedger(), salary(25, []));
    expect(r.u, isNull);
    expect(
      r.placementTotals!.containsKey(ObligationPlacement.inCurrentPeriod),
      isFalse,
    );
    expect(r.placementTotals![ObligationPlacement.settled]!.count, 1);
    expect(r.settledTotal!.totalKrw, 150000);
    expect(r.accountLines!.length, 2);
    expect(r.reserveLines!.single.effectiveKrw, isNull);
  });

  test('B를 모르면 계좌 내역도 없다', () {
    final r = current(
      ledger(context(t1019), [account('acc-main', null, t1019)]),
      paidSeptember,
    );
    expect(r.b, isNull);
    expect(r.accountLines, isNull);
  });
}
