import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/accounts_screen.dart';
import 'package:payse/features/planning/obligation_edit.dart';
import 'package:payse/features/planning/obligation_edit_controller.dart';

import '../../data/connection/plan_write_test_utils.dart';
import '../connection/connection_test_support.dart';

/// 2026-11-03: 편집 컨트롤러 시험 준비. 앱 반영([applied])과 세션 무효 횟수를 남긴다.
class _Rig {
  _Rig(this.session) : flaky = FlakyRepository(session.repository);

  final PlanSession session;
  final FlakyRepository flaky;
  final List<FinancialSnapshot> applied = [];
  int invalid = 0;

  AccountsWriter get writer => (
    repository: flaky,
    policy: instantPolicy(),
    onSessionInvalid: () => invalid++,
    onSnapshot: applied.add,
  );

  ObligationEditController controller([String? id]) => ObligationEditController(
    snapshot: applied.isEmpty ? session.snapshot : applied.last,
    writer: writer,
    obligationId: id,
  );
}

Future<_Rig> _rig({bool rentHeld = false}) async =>
    _Rig(await connectPlan(planSource(rentHeld: rentHeld)));

/// 2026-11-03: 통신비 55,000원을 계산 포함 계좌로 10/22에 넣는다.
void _fillAdd(ObligationEditController c, {String due = '2026-10-22'}) {
  c
    ..setLabel('통신비')
    ..setAmount('55000')
    ..setDueDate(due)
    ..setAccount(kbDemand);
}

void main() {
  group('미리보기', () {
    test('추가: 변화량은 미리보기 결과 − 지금 결과, 원본 Snapshot은 그대로', () async {
      final r = await _rig();
      final c = r.controller();
      expect(c.preview, isA<PreviewUnavailable>(), reason: '입력 전');
      expect((c.preview! as PreviewUnavailable).reason, isNull);
      _fillAdd(c);
      final p = c.preview! as PreviewReady;
      expect(p.deltaKrw, -55000);
      expect(
        c.snapshot.obligations,
        hasLength(r.session.snapshot.obligations!.length),
      );
      expect(r.applied, isEmpty, reason: '저장 전에는 앱에 반영하지 않음');
    });

    test('다음 월급일 뒤 예정은 지금 금액이 그대로', () async {
      final c = (await _rig()).controller();
      _fillAdd(c, due: '2026-11-30');
      expect((c.preview! as PreviewReady).deltaKrw, 0);
    });

    test('연결 있는 취소: 지출이 빠지고 연결 금액만큼 남겨둘 돈 겹침이 풀린다', () async {
      final c = (await _rig(rentHeld: true)).controller(rentId);
      final p = c.cancelPreview! as PreviewReady;
      expect(p.deltaKrw, 300000 - 30000);
    });
  });

  group('제약', () {
    test('수리비: 하한 = 정산 40,000 + 연결 60,000, 이유를 한 번에 말하고 저장을 막음', () async {
      final c = (await _rig()).controller(repairId);
      final facts = c.facts!;
      expect(
        (facts.settledKrw, facts.heldKrw, facts.floorKrw),
        (40000, 60000, 100000),
      );
      expect(facts.withdrawn, isTrue);
      c.setAmount('90000');
      expect(
        c.problems.amount,
        "40,000원이 이미 출금됐고 남겨둘 돈 '현재 비상금'에 60,000원이 연결돼 있어 "
        '100,000원보다 적게 줄일 수 없어요.',
      );
      expect(c.canSave, isFalse);
      expect((c.preview! as PreviewUnavailable).reason, isNull);
      c.setAccount('67521b1b-de86-54cf-98ba-91bb04d0a256');
      expect(c.draft.accountId, kbDemand, reason: '출금 기록이 있으면 계좌를 바꾸지 않음');
      expect(c.cancelPreview, isNull);
      expect(await c.cancel(), isFalse);
    });

    test('카드 청구 예정 지출은 편집 대상이 아니고, 반복 회차는 표시', () async {
      final r = await _rig();
      expect(r.controller(cardBillId).facts, isNull);
      expect(r.controller(phoneId).facts!.recurring, isTrue);
    });

    test('바꾼 내용이 없으면 수정할 수 없음', () async {
      final c = (await _rig()).controller(rentId);
      expect(c.unchanged, isTrue);
      expect(c.canSave, isFalse);
      c.setAmount('310000');
      expect(c.patch!.toJson(), {'amountKRW': 310000});
      expect(c.canSave, isTrue);
    });
  });

  test('잔액 초과: 아직 나가지 않은 금액 기준, 같거나 적거나 모르면 없음', () {
    expect(
      balanceShortfall(amountKrw: 698708, settledKrw: 0, balanceKrw: 300000),
      398708,
    );
    expect(
      balanceShortfall(amountKrw: 100000, settledKrw: 40000, balanceKrw: 60000),
      isNull,
      reason: '이미 출금된 40,000원은 빼고 비교',
    );
    expect(
      balanceShortfall(amountKrw: 1, settledKrw: 0, balanceKrw: null),
      isNull,
    );
    expect(
      balanceShortfall(amountKrw: null, settledKrw: 0, balanceKrw: 0),
      isNull,
    );
  });

  group('저장', () {
    test('추가 성공: 응답 Snapshot을 앱에 반영', () async {
      final r = await _rig();
      final c = r.controller();
      _fillAdd(c);
      expect(await c.submit(), isTrue);
      expect(
        r.applied.single.obligations!.map((o) => o.label),
        contains('통신비'),
      );
      expect(c.save, isA<EditIdle>());
    });

    test('응답 유실: 결과 불명·입력 잠금, 다시 시도는 같은 키·본문이라 한 건만 생김', () async {
      final r = await _rig();
      r.flaky.lose = 1;
      final c = r.controller();
      _fillAdd(c);
      expect(await c.submit(), isFalse);
      expect(c.save, isA<EditUnknown>());
      expect((c.save as EditUnknown).connection, isTrue);
      expect(c.locked, isTrue);
      c.setLabel('바꾼 이름');
      expect(c.draft.label, '통신비', reason: '결과 확인 전에는 입력을 바꾸지 않음');
      expect(c.canSave, isTrue);
      expect(await c.submit(), isTrue);
      final [first, second] = r.flaky.calls;
      expect(second.$2.idempotencyKey, first.$2.idempotencyKey);
      expect(second.$2.expectedDataVersion, first.$2.expectedDataVersion);
      expect(second.$3, first.$3);
      expect(
        r.applied.last.obligations,
        hasLength(r.session.snapshot.obligations!.length + 1),
        reason: '두 번 보내도 한 건',
      );
    });

    test('자료 충돌: 저장 안 됨 → 미리보기 대체 → 다시 받아 확인 뒤 새 키로 저장', () async {
      final r = await _rig();
      final c = r.controller();
      _fillAdd(c);
      await r.session.repository.updateAccountNickname(
        kbDemand,
        '생활비',
        writeOf(r.session.snapshot, 'other-device'),
      );
      expect(await c.submit(), isFalse);
      expect(c.save, isA<EditStale>());
      expect(c.preview, isNull, reason: '이전 숫자를 최신 예측처럼 보이지 않음');
      expect(c.canSave, isFalse, reason: '자동 재저장 없음');
      await c.reload();
      expect(c.save, isA<EditReloaded>());
      expect(c.preview, isA<PreviewReady>());
      expect(c.draft.label, '통신비', reason: '입력 유지');
      expect(await c.submit(), isTrue);
      final keys = {for (final call in r.flaky.calls) call.$2.idempotencyKey};
      expect(keys, hasLength(2), reason: '바뀐 버전의 요청은 새 키');
    });

    test('자료 충돌 뒤 재조회가 실패하면 저장·취소를 계속 막고, 재조회 성공 뒤 새 키로 저장', () async {
      final r = await _rig();
      final c = r.controller(rentId)..setAmount('310000');
      await r.session.repository.updateAccountNickname(
        kbDemand,
        '생활비',
        writeOf(r.session.snapshot, 'other-device'),
      );
      expect(await c.submit(), isFalse);
      expect(c.save, isA<EditStale>());
      r.flaky.failLoads = 1;
      await c.reload();
      expect(c.save, isA<EditReloadFailed>());
      expect(c.needsLatest, isTrue);
      expect(c.canSave, isFalse, reason: '최신 정보 없이 이전 버전으로 다시 보내지 않음');
      expect(await c.submit(), isFalse);
      expect(await c.cancel(), isFalse);
      expect(r.flaky.calls, hasLength(1), reason: '막힌 동안 요청 없음');
      await c.reload();
      expect(c.save, isA<EditReloaded>());
      expect(c.canSave, isTrue);
      expect(await c.submit(), isTrue);
      final [first, second] = r.flaky.calls;
      expect(second.$2.idempotencyKey, isNot(first.$2.idempotencyKey));
      expect(
        second.$2.expectedDataVersion,
        isNot(first.$2.expectedDataVersion),
      );
    });

    test('코드별 거절: HISTORY_LOCKED·LIMIT_EXCEEDED를 구분하고 입력은 유지', () async {
      final r = await _rig();
      final c = r.controller(rentId)..setAmount('310000');
      r.flaky.scripted
        ..add(const FinancialInvalid(status: 409, code: 'HISTORY_LOCKED'))
        ..add(const FinancialInvalid(status: 422, code: 'LIMIT_EXCEEDED'))
        ..add(const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED'))
        ..add(const FinancialForbidden());
      for (final reason in [
        EditRejection.historyLocked,
        EditRejection.limit,
        EditRejection.validation,
        EditRejection.forbidden,
      ]) {
        expect(await c.submit(), isFalse);
        expect((c.save as EditRejected).reason, reason);
        expect(c.draft.amountKrw, 310000);
        expect(c.locked, isFalse);
      }
    });

    test('연결 있는 취소: 정확한 해제 목록을 보내고 보호 설정액은 그대로', () async {
      final r = await _rig(rentHeld: true);
      final c = r.controller(rentId);
      expect(await c.cancel(), isTrue);
      expect(r.flaky.calls.single.$3, [
        {'allocationId': rentAllocationId, 'unreleasedKRW': 30000},
      ]);
      final next = r.applied.single;
      expect(
        next.obligations!.firstWhere((o) => o.obligationId == rentId).status,
        'cancelled',
      );
      expect(
        next.reserves!.single.amountKrw,
        r.session.snapshot.reserves!.single.amountKrw,
      );
    });

    test('세션 무효는 신규 로그인으로 넘김', () async {
      final r = await _rig();
      r.flaky.scripted.add(const FinancialSessionInvalid());
      final c = r.controller();
      _fillAdd(c);
      expect(await c.submit(), isFalse);
      expect(r.invalid, 1);
    });
  });
}
