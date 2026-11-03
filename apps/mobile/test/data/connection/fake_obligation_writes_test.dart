import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';

import 'plan_write_test_utils.dart';

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

/// 2026-11-03: [snapshot]의 예정 지출 [id].
Obligation? _obligation(FinancialSnapshot snapshot, String id) =>
    snapshot.obligations!.where((o) => o.obligationId == id).firstOrNull;

const _input = ObligationInput(
  label: ' 통신비 ',
  withdrawalAccountId: kbDemand,
  amountKrw: 55000,
  dueDate: '2026-10-22',
);

void main() {
  group('POST /obligations', () {
    test('단건을 만들고 자료 버전을 올린다(이름 앞뒤 공백 제거, 청구·반복 연결 없음)', () async {
      final s = await connectPlan(planSource());
      final before = s.snapshot.obligations!.length;
      final result = await s.repository.createObligation(
        _input,
        writeOf(s.snapshot, 'add-1'),
      );
      final next = _ok(result);
      expect(next.obligations, hasLength(before + 1));
      final created = next.obligations!.last;
      expect(
        (created.label, created.amountKrw, created.dueDate, created.status),
        ('통신비', 55000, '2026-10-22', 'active'),
      );
      expect(created.statementId, isNull);
      expect(created.recurringPlanId, isNull);
      expect(
        int.parse(next.dataVersion),
        int.parse(s.snapshot.dataVersion) + 1,
      );
      expect(
        (result as FinancialOk<WriteSuccess>)
            .value
            .receipt
            .changedRefs
            .single
            .resource,
        'obligation',
      );
    });

    test('응답을 잃은 뒤 같은 키·같은 본문으로 다시 보내면 한 건만 생긴다(replay)', () async {
      final s = await connectPlan(planSource());
      final before = s.snapshot.obligations!.length;
      final write = writeOf(s.snapshot, 'add-once');
      final first = _ok(await s.repository.createObligation(_input, write));
      final again = await s.repository.createObligation(_input, write);
      expect((again as FinancialOk<WriteSuccess>).value.replayed, isTrue);
      expect(_ok(again).obligations, hasLength(before + 1));
      expect(_ok(again).dataVersion, first.dataVersion);
    });

    test('같은 키에 다른 본문은 작업 키 충돌, 옛 버전은 STALE_DATA', () async {
      final s = await connectPlan(planSource());
      final write = writeOf(s.snapshot, 'add-key');
      await s.repository.createObligation(_input, write);
      final other = await s.repository.createObligation(
        const ObligationInput(
          label: '다른 이름',
          withdrawalAccountId: kbDemand,
          amountKrw: 1,
          dueDate: '2026-10-22',
        ),
        write,
      );
      expect(other, isA<FinancialIdempotencyConflict<WriteSuccess>>());
      final stale = await s.repository.createObligation(
        _input,
        writeOf(s.snapshot, 'add-stale'),
      );
      expect(stale, isA<FinancialStaleData<WriteSuccess>>());
    });

    test('이름 81자·없는 날짜는 422 VALIDATION_FAILED, 연결 밖 계좌는 403', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await s.repository.createObligation(
          ObligationInput(
            label: '가' * 81,
            withdrawalAccountId: kbDemand,
            amountKrw: 1,
            dueDate: '2026-10-22',
          ),
          writeOf(s.snapshot, 'long'),
        ),
        422,
        'VALIDATION_FAILED',
      );
      _rejected(
        await s.repository.createObligation(
          const ObligationInput(
            label: '통신비',
            withdrawalAccountId: kbDemand,
            amountKrw: 1,
            dueDate: '2026-02-30',
          ),
          writeOf(s.snapshot, 'date'),
        ),
        422,
        'VALIDATION_FAILED',
      );
      expect(
        await s.repository.createObligation(
          const ObligationInput(
            label: '통신비',
            withdrawalAccountId: 'not-an-account',
            amountKrw: 1,
            dueDate: '2026-10-22',
          ),
          writeOf(s.snapshot, 'acct'),
        ),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
    });

    test('만든 예정 지출은 로그아웃 뒤 다시 로그인해도 남아 있다', () async {
      final s = await connectPlan(planSource());
      await s.repository.createObligation(_input, writeOf(s.snapshot, 'keep'));
      await s.auth.endSession(s.repository.accessToken);
      final again = FakeUserFinancialRepository(
        server: s.server,
        accessToken: await signIn(s.auth),
      );
      final loaded = FinancialSnapshot.fromJson(
        (await again.loadSnapshot() as FinancialOk<Map<String, Object?>>).value,
      );
      expect(loaded.obligations!.map((o) => o.label), contains('통신비'));
      expect(loaded.obligations, hasLength(s.snapshot.obligations!.length + 1));
    });
  });

  group('PATCH /obligations/{id}', () {
    test('바꾼 필드만 반영하고 나머지는 그대로', () async {
      final s = await connectPlan(planSource());
      final next = _ok(
        await s.repository.updateObligation(
          rentId,
          const ObligationPatch(amountKrw: 320000),
          writeOf(s.snapshot, 'rent'),
        ),
      );
      final rent = _obligation(next, rentId)!;
      expect(
        (rent.amountKrw, rent.label, rent.dueDate),
        (320000, '월세', '2026-10-22'),
      );
    });

    test('카드 청구의 금액·정산액보다 작은 금액·정산 있는 계좌 변경은 409 HISTORY_LOCKED', () async {
      final s = await connectPlan(planSource());
      _rejected(
        await s.repository.updateObligation(
          cardBillId,
          const ObligationPatch(amountKrw: 1),
          writeOf(s.snapshot, 'bill'),
        ),
        409,
        'HISTORY_LOCKED',
      );
      _rejected(
        await s.repository.updateObligation(
          repairId,
          const ObligationPatch(amountKrw: 39999),
          writeOf(s.snapshot, 'below-paid'),
        ),
        409,
        'HISTORY_LOCKED',
      );
      _rejected(
        await s.repository.updateObligation(
          repairId,
          const ObligationPatch(
            withdrawalAccountId: '67521b1b-de86-54cf-98ba-91bb04d0a256',
          ),
          writeOf(s.snapshot, 'move-paid'),
        ),
        409,
        'HISTORY_LOCKED',
      );
    });

    test(
      '미해제 연결 합계보다 잔여가 작아지면 422 LIMIT_EXCEEDED(정산 40,000 + 연결 60,000)',
      () async {
        final s = await connectPlan(planSource());
        _rejected(
          await s.repository.updateObligation(
            repairId,
            const ObligationPatch(amountKrw: 99999),
            writeOf(s.snapshot, 'limit'),
          ),
          422,
          'LIMIT_EXCEEDED',
        );
        expect(
          await s.repository.updateObligation(
            repairId,
            const ObligationPatch(amountKrw: 100000, label: '보일러 수리'),
            writeOf(s.snapshot, 'floor'),
          ),
          isA<FinancialOk<WriteSuccess>>(),
        );
      },
    );

    test('취소된 예정 지출은 409 RELATION_CONFLICT, 빈 patch는 422', () async {
      final s = await connectPlan(planSource());
      final cancelled = _ok(
        await s.repository.cancelObligation(
          rentId,
          const [],
          writeOf(s.snapshot, 'cancel'),
        ),
      );
      _rejected(
        await s.repository.updateObligation(
          rentId,
          const ObligationPatch(amountKrw: 1),
          writeOf(cancelled, 'after-cancel'),
        ),
        409,
        'RELATION_CONFLICT',
      );
      _rejected(
        await s.repository.updateObligation(
          rentId,
          const ObligationPatch(),
          writeOf(cancelled, 'empty'),
        ),
        422,
        'VALIDATION_FAILED',
      );
    });
  });

  group('POST /obligations/{id}/cancel', () {
    test('미해제 연결을 정확히 담으면 취소와 해제를 함께 하고 보호 설정액은 그대로', () async {
      final s = await connectPlan(planSource(rentHeld: true));
      final reserveBefore = s.snapshot.reserves!.single.amountKrw;
      final next = _ok(
        await s.repository.cancelObligation(rentId, const [
          DetachAllocation(
            allocationId: rentAllocationId,
            unreleasedKrw: 30000,
          ),
        ], writeOf(s.snapshot, 'cancel-held')),
      );
      expect(_obligation(next, rentId)!.status, 'cancelled');
      expect(
        next.allocations!.where((a) => a.allocationId == rentAllocationId),
        isEmpty,
        reason: '해제 이력이 없는 배정은 지운다',
      );
      expect(next.reserves!.single.amountKrw, reserveBefore);
    });

    test('누락·금액 불일치는 409 RELATION_CONFLICT, 중복은 422, 없는 배정은 403', () async {
      final s = await connectPlan(planSource(rentHeld: true));
      _rejected(
        await s.repository.cancelObligation(
          rentId,
          const [],
          writeOf(s.snapshot, 'missing'),
        ),
        409,
        'RELATION_CONFLICT',
      );
      _rejected(
        await s.repository.cancelObligation(rentId, const [
          DetachAllocation(
            allocationId: rentAllocationId,
            unreleasedKrw: 20000,
          ),
        ], writeOf(s.snapshot, 'amount')),
        409,
        'RELATION_CONFLICT',
      );
      _rejected(
        await s.repository.cancelObligation(rentId, const [
          DetachAllocation(
            allocationId: rentAllocationId,
            unreleasedKrw: 30000,
          ),
          DetachAllocation(
            allocationId: rentAllocationId,
            unreleasedKrw: 30000,
          ),
        ], writeOf(s.snapshot, 'dup')),
        422,
        'VALIDATION_FAILED',
      );
      expect(
        await s.repository.cancelObligation(rentId, const [
          DetachAllocation(allocationId: 'nope', unreleasedKrw: 1),
        ], writeOf(s.snapshot, 'unknown')),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
      expect(
        _obligation(
          FinancialSnapshot.fromJson(
            (await s.repository.loadSnapshot()
                    as FinancialOk<Map<String, Object?>>)
                .value,
          ),
          rentId,
        )!.status,
        'active',
        reason: '거절된 요청은 일부도 저장하지 않는다',
      );
    });

    test('정산이 있거나 카드 청구면 409 HISTORY_LOCKED', () async {
      final s = await connectPlan(planSource());
      for (final id in [repairId, cardBillId]) {
        _rejected(
          await s.repository.cancelObligation(
            id,
            const [],
            writeOf(s.snapshot, 'locked-$id'),
          ),
          409,
          'HISTORY_LOCKED',
        );
      }
    });
  });
}
