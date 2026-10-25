import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

// 리뷰 결함 회귀: 구간 정보 부족 사유 보존, 귀속 구간을 정하지 못한 가상 소비의 상태.
const t1014 = '2026-10-14T00:00:00+09:00';

ProjectionResult project(
  List<PlannedPayDate> pays,
  List<VirtualPurchase> items,
) => projectPeriods(
  ProjectionInput(
    ledger: ledger(context(t1014), [account('acc-main', 1000000, t1014)]),
    payDates: pays,
    items: items,
  ),
);

VirtualPurchase unknownCard(String purchaseDate) => VirtualPurchase(
  itemId: 'i-card',
  amountKrw: 50000,
  purchaseDate: purchaseDate,
  paymentMethod: PaymentMethod.cardLumpSum,
);

VirtualPurchase cash(String id, String date) => VirtualPurchase(
  itemId: id,
  amountKrw: 10000,
  purchaseDate: date,
  paymentMethod: PaymentMethod.immediate,
);

void main() {
  group('구간 정보 부족 사유를 덮어쓰지 않는다', () {
    test('C2부터 급여 금액 누락과 카드 결제일 미확정이 함께 생기면 두 사유를 모두 남긴다', () {
      final r = project(
        [pay('2026-10-25', null), pay('2026-11-25', 0), pay('2026-12-25', 0)],
        [unknownCard('2026-10-28')],
      );
      final periods = r.allItems!.periods;
      expect(periods[0].endA, isNotNull);
      for (final p in periods.skip(1)) {
        expect(p.insufficient.toSet(), {
          InsufficientReason.salaryAmountMissing,
          InsufficientReason.cardScheduleUnknown,
        });
      }
      expect(r.baseline!.periods[1].insufficient, [
        InsufficientReason.salaryAmountMissing,
      ]);
    });

    test('카드 사유가 C2에서 먼저 생기고 급여 사유가 C3에 추가되면 C3에 둘 다 남는다', () {
      final r = project(
        [pay('2026-10-25', 0), pay('2026-11-25', null), pay('2026-12-25', 0)],
        [unknownCard('2026-10-28')],
      );
      final periods = r.allItems!.periods;
      expect(periods[1].insufficient, [InsufficientReason.cardScheduleUnknown]);
      expect(periods[2].insufficient.toSet(), {
        InsufficientReason.cardScheduleUnknown,
        InsufficientReason.salaryAmountMissing,
      });
      expect(r.baseline!.periods[1].endA, isNotNull);
      expect(r.baseline!.periods[2].insufficient, [
        InsufficientReason.salaryAmountMissing,
      ]);
    });
  });

  group('귀속 구간을 정하지 못한 소비는 반영됨으로 표시하지 않는다', () {
    test('월급일이 없으면 기준일 즉시출금 소비도 구간 미정이고 결과는 정보 부족', () {
      final r = project(const [], [cash('i-now', '2026-10-14')]);
      final placement = r.itemPlacements.single;
      expect(placement.status, ItemPlacementStatus.periodUndetermined);
      expect(placement.cashDate.toString(), '2026-10-14');
      expect(placement.periodIndex, isNull);
      expect(r.allItems!.periods.first.insufficient, [
        InsufficientReason.payDateMissing,
      ]);
    });

    test('p1만 있으면 p1 전 출금은 C1 반영, p1 이후 출금은 구간 미정', () {
      final r = project(
        [pay('2026-10-25', 0)],
        [cash('i-c1', '2026-10-20'), cash('i-after', '2026-10-28')],
      );
      final byId = {for (final p in r.itemPlacements) p.itemId: p};
      expect(byId['i-c1']!.status, ItemPlacementStatus.reflected);
      expect(byId['i-c1']!.periodIndex, 1);
      expect(byId['i-after']!.status, ItemPlacementStatus.periodUndetermined);
      expect(byId['i-after']!.periodIndex, isNull);
      expect(r.allItems!.periods[0].endH, 990000);
      expect(r.allItems!.periods[1].endH, isNull);
    });
  });
}
