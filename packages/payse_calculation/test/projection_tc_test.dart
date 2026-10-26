import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

// 원문: docs/references/detailed-plan-v7.source.md §7-1 TC-C06~09, docs/calculation-rules.md 시뮬레이션 구간·미래 산식.
const t1014 = '2026-10-14T00:00:00+09:00';

ProjectionResult project(
  LedgerInput l,
  List<PlannedPayDate> pays, [
  List<VirtualPurchase> items = const [],
]) => projectPeriods(ProjectionInput(ledger: l, payDates: pays, items: items));

List<int?> endH(ScenarioResult s) => [for (final p in s.periods) p.endH];
List<int?> endA(ScenarioResult s) => [for (final p in s.periods) p.endA];

void main() {
  group('TC-C06 세 구간 고정 데이터', () {
    final input = ledger(
      context(t1014),
      [account('acc-main', 2000000, t1014)],
      obligations: [obligation('o-approved', 300000, '2026-10-20')],
      reserves: [
        Reserve(
          reserveId: 'r-1',
          accountId: 'acc-main',
          amountKrw: 400000,
          cancelledAt: null,
        ),
      ],
    );
    final pays = [
      pay('2026-10-25', 1000000),
      pay('2026-11-25', 1000000),
      pay('2026-12-25', 1000000),
    ];
    final items = [
      VirtualPurchase(
        itemId: 'i-cash',
        amountKrw: 100000,
        purchaseDate: '2026-10-20',
        paymentMethod: PaymentMethod.immediate,
      ),
      VirtualPurchase(
        itemId: 'i-card',
        amountKrw: 200000,
        purchaseDate: '2026-10-21',
        paymentMethod: PaymentMethod.cardLumpSum,
        plannedWithdrawalDate: '2026-11-05',
      ),
    ];
    final r = project(input, pays, items);

    test('기존/모두 반영 종료 H·종료 직전 A·A 차이가 원문 표와 일치', () {
      expect(endH(r.baseline!), [1700000, 2700000, 3700000]);
      expect(endH(r.allItems!), [1600000, 2400000, 3400000]);
      expect(endA(r.baseline!), [1300000, 2300000, 3300000]);
      expect(endA(r.allItems!), [1200000, 2000000, 3000000]);
      expect(r.endADifferences, [-100000, -300000, -300000]);
    });

    test('이전 A가 아니라 H를 다음 구간 기초로 이월하고 12-25 급여는 상한 밖', () {
      final periods = r.baseline!.periods;
      expect(periods[1].startH, periods[0].endH);
      expect(periods[2].startH, periods[1].endH);
      expect(r.horizonEnd.toString(), '2026-12-25');
      expect([for (final p in periods) p.complete], [true, true, true]);
      expect(periods[2].end.toString(), '2026-12-25');
    });

    test('카드 승인일 10-21에는 H를 줄이지 않고 11-05 출금으로 C2에 귀속', () {
      final card = r.itemPlacements.firstWhere((p) => p.itemId == 'i-card');
      expect(card.cashDate.toString(), '2026-11-05');
      expect(card.periodIndex, 2);
      expect(r.allItems!.periods[0].minH, 1600000);
      expect(r.timePrecision, 'day_end');
    });
  });

  test('TC-C07 같은 날 입금·출금은 C2 일 마감 H=80,000, 일중 순서 불확정 경고', () {
    final r = project(
      ledger(
        context(t1014),
        [account('acc-main', 50000, t1014)],
        obligations: [obligation('o-1', 70000, '2026-10-25')],
      ),
      [
        pay('2026-10-25', 100000),
        pay('2026-11-25', 100000),
        pay('2026-12-25', 100000),
      ],
    );
    final c2 = r.baseline!.periods[1];
    expect(r.baseline!.periods[0].endH, 50000);
    expect(c2.start.toString(), '2026-10-25');
    expect(c2.minH, 80000);
    final warnings = r.baseline!.dayOrderWarnings;
    expect(warnings.single.date.toString(), '2026-10-25');
    expect(warnings.single.possibleIntradayShortfall, isTrue);
    // 일중 최소 -20,000을 확정하지 않는다. 최초 부족 시점·최대 부족액 지표는 이 작업 범위 밖이라 구현하지 않았다.
  });

  test('TC-C08 상한 1/14로 C3가 잘리고 1/14 이후 결제는 범위 밖', () {
    final r = project(
      ledger(
        context(t1014),
        [account('acc-main', 1000000, t1014)],
        obligations: [
          obligation('o-in', 10000, '2027-01-13'),
          obligation('o-out', 20000, '2027-01-14'),
        ],
      ),
      [pay('2026-11-20', 0), pay('2026-12-20', 0), pay('2027-01-20', 0)],
      [
        VirtualPurchase(
          itemId: 'i-late',
          amountKrw: 5000,
          purchaseDate: '2027-01-02',
          paymentMethod: PaymentMethod.cardLumpSum,
          plannedWithdrawalDate: '2027-01-14',
        ),
      ],
    );
    expect(r.horizonEnd.toString(), '2027-01-14');
    final c3 = r.baseline!.periods[2];
    expect(
      [c3.start.toString(), c3.end.toString(), c3.complete],
      ['2026-12-20', '2027-01-14', false],
    );
    expect(c3.endH, 990000);
    expect(r.outOfRangeObligationIds, ['o-out']);
    expect(r.itemPlacements.single.status, ItemPlacementStatus.outOfRange);
  });

  group('TC-C09 31일 월급의 2월·카드일 불명·연체', () {
    test('31일 월급은 2월 말일로 보정하고 가정·보정 표시를 남긴다', () {
      final dates = assumedPayDates(
        after: BusinessDate(2027, 1, 31),
        salaryDay: 31,
        amountKrw: 3000000,
      );
      expect(
        [for (final d in dates) d.date.toString()],
        ['2027-02-28', '2027-03-31', '2027-04-30'],
      );
      expect([for (final d in dates) d.monthEndAdjusted], [true, false, true]);
      expect(
        dates.every((d) => d.basis == PayDateBasis.recurringSetting),
        isTrue,
      );
    });

    test('카드일 불명 가상 소비는 영향 구간 비교를 null로 두고 기존 결과는 유지', () {
      final r = project(
        ledger(context(t1014), [account('acc-main', 1000000, t1014)]),
        [pay('2026-10-25', 0), pay('2026-11-25', 0), pay('2026-12-25', 0)],
        [
          VirtualPurchase(
            itemId: 'i-card',
            amountKrw: 50000,
            purchaseDate: '2026-10-28',
            paymentMethod: PaymentMethod.cardLumpSum,
          ),
        ],
      );
      expect(endA(r.baseline!), [1000000, 1000000, 1000000]);
      expect(endA(r.allItems!), [1000000, null, null]);
      expect(r.endADifferences, [0, null, null]);
      expect(r.allItems!.periods[1].insufficient, [
        InsufficientReason.cardScheduleUnknown,
      ]);
      expect(
        r.itemPlacements.single.status,
        ItemPlacementStatus.scheduleUnknown,
      );
    });

    test('연체 미지급 잔액은 지급일을 만들지 않고 모든 구간 A에 남는다', () {
      final r = project(
        ledger(
          context(t1014),
          [account('acc-main', 1000000, t1014)],
          obligations: [obligation('o-late', 100000, '2026-10-01')],
        ),
        [pay('2026-10-25', 0), pay('2026-11-25', 0), pay('2026-12-25', 0)],
      );
      expect(endH(r.baseline!), [1000000, 1000000, 1000000]);
      expect(endA(r.baseline!), [900000, 900000, 900000]);
    });
  });
}
