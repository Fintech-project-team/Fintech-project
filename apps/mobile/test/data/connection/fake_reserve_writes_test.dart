import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';

import 'plan_write_test_utils.dart';

const _hana = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
const _shinhan = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _repairAllocation = 'b13023bf-0ce7-5616-9bbb-efb70f816cc6';

/// 2026-11-03: 성공 결과의 Snapshot을 읽는다.
FinancialSnapshot _ok(FinancialOutcome<WriteSuccess> outcome) =>
    FinancialSnapshot.fromJson(
      (outcome as FinancialOk<WriteSuccess>).value.snapshot,
    );

/// 2026-11-03: [outcome]이 [status]·[code]의 거절이면 통과한다.
void _rejected(
  FinancialOutcome<WriteSuccess> outcome,
  int status,
  String code,
) {
  expect(outcome, isA<FinancialInvalid<WriteSuccess>>());
  final invalid = outcome as FinancialInvalid<WriteSuccess>;
  expect((invalid.status, invalid.code), (status, code));
}

/// 2026-11-03: [snapshot]의 남겨둘 돈 [id].
Reserve? _reserve(FinancialSnapshot snapshot, String id) =>
    snapshot.reserves!.where((r) => r.reserveId == id).firstOrNull;

/// 2026-11-03: 계산에서 뺀 하나은행 계좌(잔액 300,000원)에 남겨둘 돈 '여행 자금' 200,000원을 더한 원본.
Map<String, Object?> _withExcludedReserve() {
  final json = planSource();
  (json['reserves']! as List).add({
    'userId': json['userId'],
    'reserveId': '00000000-0000-4000-8000-0000000000f1',
    'accountId': _hana,
    'label': '여행 자금',
    'amountKRW': 200000,
    'cancelledAt': null,
  });
  return json;
}

void main() {
  group('POST /reserves', () {
    test('계산 포함 계좌에 만들고 버전을 올린다(이름 앞뒤 공백 제거, 연결 없음)', () async {
      final s = await connectPlan(planSource());
      final result = await s.repository.createReserve(
        const ReserveInput(
          label: ' 여행 자금 ',
          accountId: _shinhan,
          amountKrw: 400000,
        ),
        writeOf(s.snapshot, 'r-add'),
      );
      final next = _ok(result);
      final created = next.reserves!.last;
      expect(
        (
          created.label,
          created.accountId,
          created.amountKrw,
          created.cancelledAt,
        ),
        ('여행 자금', _shinhan, 400000, null),
      );
      expect(
        next.allocations!.where((a) => a.reserveId == created.reserveId),
        isEmpty,
      );
      expect(
        int.parse(next.dataVersion),
        int.parse(s.snapshot.dataVersion) + 1,
      );
    });

    test(
      '계산에서 뺀 계좌는 422 VALIDATION_FAILED, 잔액(M5)을 넘으면 422 LIMIT_EXCEEDED',
      () async {
        final s = await connectPlan(planSource());
        _rejected(
          await s.repository.createReserve(
            const ReserveInput(label: '여행', accountId: _hana, amountKrw: 1),
            writeOf(s.snapshot, 'excluded'),
          ),
          422,
          'VALIDATION_FAILED',
        );
        _rejected(
          await s.repository.createReserve(
            const ReserveInput(
              label: '여행',
              accountId: _shinhan,
              amountKrw: 500001,
            ),
            writeOf(s.snapshot, 'over-account'),
          ),
          422,
          'LIMIT_EXCEEDED',
        );
        _rejected(
          await s.repository.createReserve(
            const ReserveInput(
              label: '여행',
              accountId: kbDemand,
              amountKrw: 1100001,
            ),
            writeOf(s.snapshot, 'over-kb'),
            // 국민 1,500,000원에 이미 400,000원이 있어 1,100,001원은 넘는다.
          ),
          422,
          'LIMIT_EXCEEDED',
        );
      },
    );

    test('응답을 잃은 뒤 같은 키·같은 본문 재전송은 한 건만, 재로그인해도 남는다', () async {
      final s = await connectPlan(planSource());
      const input = ReserveInput(
        label: '여행',
        accountId: _shinhan,
        amountKrw: 1000,
      );
      final write = writeOf(s.snapshot, 'once');
      await s.repository.createReserve(input, write);
      final again = await s.repository.createReserve(input, write);
      expect((again as FinancialOk<WriteSuccess>).value.replayed, isTrue);
      await s.auth.endSession(s.repository.accessToken);
      final relogin = FakeUserFinancialRepository(
        server: s.server,
        accessToken: await signIn(s.auth),
      );
      final loaded = FinancialSnapshot.fromJson(
        (await relogin.loadSnapshot() as FinancialOk<Map<String, Object?>>)
            .value,
      );
      expect(loaded.reserves!.where((r) => r.label == '여행'), hasLength(1));
    });
  });

  group('PATCH /reserves/{id}', () {
    test(
      '이 돈으로 낼 금액(미해제 60,000원)보다 적게 줄이면 422 LIMIT_EXCEEDED, 같으면 저장',
      () async {
        final s = await connectPlan(planSource());
        _rejected(
          await s.repository.updateReserve(
            reserveId,
            const ReservePatch(amountKrw: 59999),
            writeOf(s.snapshot, 'floor'),
          ),
          422,
          'LIMIT_EXCEEDED',
        );
        final next = _ok(
          await s.repository.updateReserve(
            reserveId,
            const ReservePatch(amountKrw: 60000, label: '비상금'),
            writeOf(s.snapshot, 'ok'),
          ),
        );
        final r = _reserve(next, reserveId)!;
        expect((r.amountKrw, r.label), (60000, '비상금'));
      },
    );

    test('계산에서 뺀 계좌의 기존 설정은 줄이기·이름은 되고 늘리기는 422', () async {
      final s = await connectPlan(_withExcludedReserve());
      const id = '00000000-0000-4000-8000-0000000000f1';
      expect(
        await s.repository.updateReserve(
          id,
          const ReservePatch(amountKrw: 100000, label: '여행'),
          writeOf(s.snapshot, 'down'),
        ),
        isA<FinancialOk<WriteSuccess>>(),
      );
      final now = FinancialSnapshot.fromJson(
        (await s.repository.loadSnapshot() as FinancialOk<Map<String, Object?>>)
            .value,
      );
      _rejected(
        await s.repository.updateReserve(
          id,
          const ReservePatch(amountKrw: 150000),
          writeOf(now, 'up'),
        ),
        422,
        'VALIDATION_FAILED',
      );
    });

    test('빈 patch는 422, 취소된 남겨둘 돈은 409 RELATION_CONFLICT', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await s.repository.updateReserve(
          reserveId,
          const ReservePatch(),
          writeOf(s.snapshot, 'empty'),
        ),
        422,
        'VALIDATION_FAILED',
      );
      final cancelled = _ok(
        await s.repository.cancelReserve(reserveId, const [
          DetachAllocation(
            allocationId: _repairAllocation,
            unreleasedKrw: 60000,
          ),
        ], writeOf(s.snapshot, 'cancel')),
      );
      _rejected(
        await s.repository.updateReserve(
          reserveId,
          const ReservePatch(label: '다시'),
          writeOf(cancelled, 'after'),
        ),
        409,
        'RELATION_CONFLICT',
      );
    });
  });

  group('POST /reserves/{id}/cancel', () {
    test('미해제 연결을 정확히 담으면 취소하고 해제 이력 있는 연결은 해제액까지 줄인다, 예정 지출은 그대로', () async {
      final s = await connectPlan(planSource());
      final obligationsBefore = s.snapshot.obligations!.length;
      final next = _ok(
        await s.repository.cancelReserve(reserveId, const [
          DetachAllocation(
            allocationId: _repairAllocation,
            unreleasedKrw: 60000,
          ),
        ], writeOf(s.snapshot, 'cancel')),
      );
      expect(_reserve(next, reserveId)!.cancelledAt, isNotNull);
      final allocation = next.allocations!.singleWhere(
        (a) => a.allocationId == _repairAllocation,
      );
      expect((allocation.amountKrw, allocation.releasedKrw), (40000, 40000));
      expect(next.obligations, hasLength(obligationsBefore));
    });

    test('누락·금액 불일치는 409, 없는 배정은 403, 거절은 일부도 저장하지 않음', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await s.repository.cancelReserve(
          reserveId,
          const [],
          writeOf(s.snapshot, 'missing'),
        ),
        409,
        'RELATION_CONFLICT',
      );
      _rejected(
        await s.repository.cancelReserve(reserveId, const [
          DetachAllocation(allocationId: _repairAllocation, unreleasedKrw: 1),
        ], writeOf(s.snapshot, 'amount')),
        409,
        'RELATION_CONFLICT',
      );
      expect(
        await s.repository.cancelReserve(reserveId, const [
          DetachAllocation(allocationId: 'nope', unreleasedKrw: 1),
        ], writeOf(s.snapshot, 'unknown')),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
      final loaded = FinancialSnapshot.fromJson(
        (await s.repository.loadSnapshot() as FinancialOk<Map<String, Object?>>)
            .value,
      );
      expect(_reserve(loaded, reserveId)!.cancelledAt, isNull);
    });
  });
}
