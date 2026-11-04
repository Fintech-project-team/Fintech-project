import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';

import 'plan_write_test_utils.dart';

const _shinhan = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _repairAllocation = 'b13023bf-0ce7-5616-9bbb-efb70f816cc6';

/// 2026-11-04: 성공 결과의 Snapshot을 읽는다.
FinancialSnapshot _ok(FinancialOutcome<WriteSuccess> outcome) =>
    FinancialSnapshot.fromJson(
      (outcome as FinancialOk<WriteSuccess>).value.snapshot,
    );

/// 2026-11-04: [outcome]이 [status]·[code]의 거절이면 통과한다.
void _rejected(
  FinancialOutcome<WriteSuccess> outcome,
  int status,
  String code,
) {
  expect(outcome, isA<FinancialInvalid<WriteSuccess>>());
  final invalid = outcome as FinancialInvalid<WriteSuccess>;
  expect((invalid.status, invalid.code), (status, code));
}

/// 2026-11-04: [snapshot]에서 남겨둘 돈 [reserve]의 예정 지출 [obligation] 배정들(총액, 해제액).
List<(int, int)> _held(
  FinancialSnapshot snapshot,
  String reserve,
  String obligation,
) => [
  for (final a in snapshot.allocations!)
    if (a.reserveId == reserve && a.obligationId == obligation)
      (a.amountKrw, a.releasedKrw),
];

/// 2026-11-04: 남겨둘 돈 [reserveId]에 [changes]만 보내는 PATCH.
Future<FinancialOutcome<WriteSuccess>> _patch(
  PlanSession s,
  AllocationChanges changes, {
  int? amountKrw,
  String key = 'plan',
}) => s.repository.updateReserve(
  reserveId,
  ReservePatch(amountKrw: amountKrw, changes: changes),
  writeOf(s.snapshot, key),
);

void main() {
  group('PATCH /reserves 사용 계획', () {
    test('create: 이번 월급 주기 지출에 새 배정을 만든다', () async {
      final s = await connectPlan(planSource());
      final next = _ok(
        await _patch(
          s,
          const AllocationChanges(
            create: [(obligationId: rentId, amountKrw: 100000)],
          ),
        ),
      );
      expect(_held(next, reserveId, rentId), [(100000, 0)]);
      expect(
        int.parse(next.dataVersion),
        int.parse(s.snapshot.dataVersion) + 1,
      );
    });

    test('update: 총 배정액(쓸 금액 + 이미 나간 금액)으로 바꾼다', () async {
      final s = await connectPlan(planSource());
      final next = _ok(
        await _patch(
          s,
          const AllocationChanges(
            update: [(allocationId: _repairAllocation, amountKrw: 90000)],
          ),
        ),
      );
      expect(_held(next, reserveId, repairId), [(90000, 40000)]);
    });

    test('해제 이력이 있는 배정의 해제는 이미 나간 금액까지 update한다', () async {
      final s = await connectPlan(planSource());
      final next = _ok(
        await _patch(
          s,
          const AllocationChanges(
            update: [(allocationId: _repairAllocation, amountKrw: 40000)],
          ),
        ),
      );
      expect(_held(next, reserveId, repairId), [(40000, 40000)]);
    });

    test(
      '해제 이력이 있으면 remove·이미 나간 금액보다 작은 update는 409 HISTORY_LOCKED',
      () async {
        final s = await connectPlan(planSource());
        _rejected(
          await _patch(s, const AllocationChanges(remove: [_repairAllocation])),
          409,
          'HISTORY_LOCKED',
        );
        _rejected(
          await _patch(
            s,
            const AllocationChanges(
              update: [(allocationId: _repairAllocation, amountKrw: 30000)],
            ),
            key: 'plan-2',
          ),
          409,
          'HISTORY_LOCKED',
        );
      },
    );

    test('해제 이력이 없는 배정은 remove로 지운다', () async {
      final s = await connectPlan(planSource(rentHeld: true));
      final next = _ok(
        await _patch(s, const AllocationChanges(remove: [rentAllocationId])),
      );
      expect(_held(next, reserveId, rentId), isEmpty);
    });

    test('예정 지출 남은 금액이나 남겨둘 금액을 넘으면 422 LIMIT_EXCEEDED', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await _patch(
          s,
          const AllocationChanges(
            create: [(obligationId: rentId, amountKrw: 300001)],
          ),
          amountKrw: 1000000,
        ),
        422,
        'LIMIT_EXCEEDED',
      );
      _rejected(
        await _patch(
          s,
          const AllocationChanges(
            create: [(obligationId: rentId, amountKrw: 350000)],
          ),
          key: 'plan-2',
        ),
        422,
        'LIMIT_EXCEEDED',
      );
    });

    test('형식 오류(같은 지출 두 번, 0원)는 422 VALIDATION_FAILED', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await _patch(
          s,
          const AllocationChanges(
            create: [
              (obligationId: rentId, amountKrw: 1000),
              (obligationId: rentId, amountKrw: 1000),
            ],
          ),
        ),
        422,
        'VALIDATION_FAILED',
      );
      _rejected(
        await _patch(
          s,
          const AllocationChanges(
            update: [(allocationId: _repairAllocation, amountKrw: 0)],
          ),
          key: 'plan-2',
        ),
        422,
        'VALIDATION_FAILED',
      );
    });

    test('없는 예정 지출 create·없는 배정 update는 403', () async {
      final s = await connectPlan(planSource());
      expect(
        await _patch(
          s,
          const AllocationChanges(
            create: [
              (
                obligationId: '00000000-0000-4000-8000-0000000000aa',
                amountKrw: 1000,
              ),
            ],
          ),
        ),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
      expect(
        await _patch(
          s,
          const AllocationChanges(
            update: [
              (
                allocationId: '00000000-0000-4000-8000-0000000000bb',
                amountKrw: 1000,
              ),
            ],
          ),
          key: 'plan-2',
        ),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
    });

    test('다른 남겨둘 돈의 배정 update는 409 RELATION_CONFLICT', () async {
      final s = await connectPlan(planSource());
      final added = _ok(
        await s.repository.createReserve(
          const ReserveInput(
            label: '여행 자금',
            accountId: _shinhan,
            amountKrw: 100000,
            changes: AllocationChanges(
              create: [(obligationId: rentId, amountKrw: 50000)],
            ),
          ),
          writeOf(s.snapshot, 'add'),
        ),
      );
      final other = added.allocations!.firstWhere(
        (a) => a.obligationId == rentId,
      );
      final outcome = await s.repository.updateReserve(
        reserveId,
        ReservePatch(
          changes: AllocationChanges(
            update: [(allocationId: other.allocationId, amountKrw: 1000)],
          ),
        ),
        writeOf(added, 'plan'),
      );
      _rejected(outcome, 409, 'RELATION_CONFLICT');
    });
  });

  test('POST /reserves: 새 남겨둘 돈과 함께 사용 계획을 만든다', () async {
    final s = await connectPlan(planSource());
    final next = _ok(
      await s.repository.createReserve(
        const ReserveInput(
          label: '여행 자금',
          accountId: _shinhan,
          amountKrw: 300000,
          changes: AllocationChanges(
            create: [(obligationId: rentId, amountKrw: 100000)],
          ),
        ),
        writeOf(s.snapshot, 'add'),
      ),
    );
    final created = next.reserves!.last;
    expect(_held(next, created.reserveId, rentId), [(100000, 0)]);
  });

  test('가짜 서버 원본은 쓰기 전과 같다(실패한 요청은 저장하지 않음)', () async {
    final s = await connectPlan(planSource());
    await _patch(s, const AllocationChanges(remove: [_repairAllocation]));
    final again = await s.repository.loadSnapshot();
    final snapshot = FinancialSnapshot.fromJson(
      (again as FinancialOk<Map<String, Object?>>).value,
    );
    expect(snapshot.dataVersion, s.snapshot.dataVersion);
    expect(_held(snapshot, reserveId, repairId), [(100000, 40000)]);
  });
}
