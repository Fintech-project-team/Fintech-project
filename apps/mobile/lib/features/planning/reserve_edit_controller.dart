import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/auth/random_id.dart';
import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../data/http/api_transport.dart' show ApiNonContractResponse;
import '../connection/connection_review.dart' show accountById;
import '../overview/accounts_screen.dart' show AccountsWriter;
import '../overview/home_calculation.dart';
import 'obligation_edit.dart';
import 'obligation_edit_controller.dart';
import 'plan_periods.dart';
import 'reserve_edit.dart';

/// 2026-11-03: 결과를 확인하지 못한 남겨둘 돈 요청. 다시 보낼 때 본문·버전·배열 순서·작업 키를 그대로 쓴다.
typedef _Pending = ({
  EditOp op,
  WriteContext write,
  ReserveInput? input,
  ReservePatch? patch,
  List<DetachAllocation>? detach,
});

/// 2026-11-03: 남겨둘 돈 추가·수정·취소(03-5, 29-5b)의 입력·미리보기·저장. 저장 상태와
/// 재시도 규칙은 예정 지출 편집([ObligationEditController])과 같다: 결과 불명은 같은 요청 재전송, 자료 충돌은 최신 정보를 받은 뒤
/// 새 키로, 최신 정보를 받기 전에는 저장·취소를 막는다.
/// 2026-11-04: 이 돈으로 낼 지출(사용 계획) 고르기·금액 바꾸기·해제를 더했다(29-5c). 새로 고르거나 늘리는 것은 이번 월급 주기
/// 예정 지출만 가능하고, 다음 월급 기간 지출이나 월급 주기를 정할 수 없을 때는 줄이기·해제만 된다.
class ReserveEditController extends ChangeNotifier {
  /// 2026-11-03: 지금 Snapshot [snapshot], 저장 연결 [writer], 고칠 남겨둘 돈 [reserveId](추가면 null)로 만든다. [random]은
  /// 작업 키 생성용이며 테스트에서만 바꾼다.
  ReserveEditController({
    required FinancialSnapshot snapshot,
    required this.writer,
    this.reserveId,
    Random? random,
  }) : _snapshot = snapshot,
       _calculation = computeHomeCalculation(snapshot),
       _random = random ?? Random.secure() {
    final r = facts?.reserve;
    _label = r?.label ?? '';
    _amount = r?.amountKrw;
    _accountId = r?.accountId;
    _plans = planItems(facts);
  }

  final AccountsWriter writer;
  final String? reserveId;
  final Random _random;
  FinancialSnapshot _snapshot;
  HomeCalculation _calculation;
  late String _label;
  int? _amount;
  String? _accountId;
  late List<PlanItem> _plans;
  ({int index, PlanItem item})? _lastUnplanned;
  EditSave _save = const EditIdle();
  _Pending? _pending;
  bool _needsLatest = false;
  bool _disposed = false;

  /// 2026-11-03: 지금 기준 Snapshot.
  FinancialSnapshot get snapshot => _snapshot;

  /// 2026-11-03: 지금 기준 계산.
  HomeCalculation get calculation => _calculation;

  /// 2026-11-03: 고칠 남겨둘 돈의 제약. 추가거나 더 고칠 수 없으면 null이다.
  ReserveFacts? get facts {
    final id = reserveId;
    return id == null ? null : reserveFacts(_snapshot, id);
  }

  /// 2026-11-03: 지금 입력.
  ReserveDraft get draft => (
    label: _label,
    amountKrw: _amount,
    accountId: _accountId,
    plans: List.unmodifiable(_plans),
  );

  /// 2026-11-04: 지금 사용 계획(예정일 순).
  List<PlanItem> get plans => List.unmodifiable(_plans);

  /// 2026-11-04: 이번 월급 주기를 정할 수 있으면 true다. false면 지출을 새로 고르거나 늘릴 수 없다.
  bool get cycleKnown => cycleRange != null;

  /// 2026-11-04: 이번 월급 주기의 날짜 범위('9/25 ~ 10/24'). 정할 수 없으면 null이다.
  String? get cycleRange {
    final now = _calculation;
    if (now is! HomeCalculationReady) return null;
    final cycle = now.result.salaryCycle;
    final end = cycle?.periodEnd;
    if (cycle == null || end == null) return null;
    return PlanPeriod(
      kind: PlanPeriodKind.salary,
      start: cycle.periodStart,
      end: end,
      role: SalaryRole.current,
    ).range;
  }

  /// 2026-11-04: 새로 고를 수 있는 이번 월급 주기 예정 지출.
  List<PlanCandidate> get candidates => planCandidates(
    _snapshot,
    _calculation,
    reserveId,
    {for (final p in _plans) p.obligationId},
  );

  /// 2026-11-04: 예정 지출 [obligationId]에 이 돈에서 쓸 수 있는 최대 금액. 예정 지출 몫과 남겨둘 금액에서 다른 사용 계획을 뺀
  /// 금액 중 작은 값이다. 새로 고르거나 늘릴 수 없으면(다음 월급 기간·월급 주기 모름) 지금 금액이다(없으면 0).
  int planMax(String obligationId) {
    final current = _planOf(obligationId)?.amountKrw ?? 0;
    final cap = planCap(_snapshot, _calculation, reserveId, obligationId);
    if (cap == null) return current;
    final others = _plans
        .where((p) => p.obligationId != obligationId)
        .fold(0, (sum, p) => sum + p.amountKrw);
    final amount = _amount;
    return amount == null ? cap : max(0, min(cap, amount - others));
  }

  /// 2026-11-04: 금액을 바꿀 수 있는 사용 계획이면 true다. 이번 월급 주기 지출은 최대 금액까지, 월급 주기를 정할 수 없으면 줄이기만
  /// 된다. 다음 월급 기간 지출은 false다(해제만).
  bool planAdjustable(String obligationId) =>
      !cycleKnown ||
      planCap(_snapshot, _calculation, reserveId, obligationId) != null;

  /// 2026-11-04: 바로 앞에 해제한 사용 계획. 되돌릴 것이 없으면 null이다.
  PlanItem? get lastUnplanned => _lastUnplanned?.item;

  /// 2026-11-03: 저장 진행 상태.
  EditSave get save => _save;

  /// 2026-11-03: 요청 중이면 true다.
  bool get busy => _save is EditSaving;

  /// 2026-11-03: 결과를 확인하지 못한 요청이 있어 입력을 잠가야 하면 true다.
  bool get locked => _pending != null;

  /// 2026-11-03: 결과를 모르는 요청이 취소면 true다(하단 다시 시도하기가 같은 취소를 보낸다).
  bool get cancelPending => _pending?.op == EditOp.cancel;

  /// 2026-11-03: 자료·규칙 충돌 뒤 최신 정보를 아직 받지 못했으면 true다. 그동안 저장·취소를 막는다.
  bool get needsLatest => _needsLatest;

  /// 2026-11-03: 입력의 칸별 문제.
  DraftProblems get problems => reserveDraftProblems(draft);

  /// 2026-11-04: 원래 사용 계획에서 바뀐 배정.
  AllocationChanges get changes =>
      allocationChangesOf(planItems(facts), _plans);

  /// 2026-11-03: 수정에서 바꾼 필드. 추가면 null이다.
  ReservePatch? get patch {
    final r = facts?.reserve;
    if (r == null) return null;
    final label = _label.trim();
    return ReservePatch(
      label: label != r.label ? label : null,
      amountKrw: _amount != r.amountKrw ? _amount : null,
      accountId: _accountId != r.accountId ? _accountId : null,
      changes: changes,
    );
  }

  /// 2026-11-03: 바꾼 내용이 없는 수정이면 true다.
  bool get unchanged => patch?.isEmpty ?? false;

  /// 2026-11-03: 지금 저장할 수 있으면 true다(결과 불명이면 같은 요청을 다시 보내는 것만 가능, 최신 정보가 필요하면 불가).
  bool get canSave {
    if (busy || _needsLatest) return false;
    if (locked) return true;
    if (_save is EditGone) return false;
    if (reserveId != null && facts == null) return false;
    return reserveDraftComplete(draft) && !unchanged;
  }

  /// 2026-11-03: 저장 버튼 위 미리보기. 자료 충돌·거절 뒤 최신 정보를 받기 전이면 null이다(이전 숫자를 보이지 않음).
  PlanPreview? get preview {
    if (_save is EditStale ||
        _save is EditRejected ||
        _save is EditReloadFailed ||
        _save is EditGone) {
      return null;
    }
    if (unchanged) {
      final now = _calculation;
      return now is HomeCalculationReady && now.result.u != null
          ? PreviewReady(now.result.u!, now.result.u!)
          : const PreviewUnavailable();
    }
    return previewReserveDraft(_snapshot, _calculation, draft, facts);
  }

  /// 2026-11-03: 취소 확인창의 미리보기. 취소할 대상이 없으면 null이다.
  PlanPreview? get cancelPreview {
    final f = facts;
    if (f == null) return null;
    return previewReserveCancel(_snapshot, _calculation, f, _snapshot.asOf);
  }

  /// 2026-11-03: 이름 [value]를 입력한다.
  void setLabel(String value) => _edit(() => _label = value);

  /// 2026-11-03: 금액 [value]를 입력한다(쉼표 없는 숫자, 비면 null).
  void setAmount(String value) => _edit(
    () => _amount = value.isEmpty ? null : int.tryParse(value) ?? _amount,
  );

  /// 2026-11-03: 남겨둘 계좌 [value]를 고른다. 계산에 포함한 계좌만 고를 수 있다(지금 계좌는 그대로 둘 수 있다).
  void setAccount(String value) {
    final included = accountById(_snapshot, value)?.included ?? false;
    if (!included && value != facts?.reserve.accountId) return;
    _edit(() => _accountId = value);
  }

  /// 2026-11-04: 예정 지출 [obligationId]를 이 돈에서 [amountKrw]원 쓰도록 고른다. 후보에 있고 1원 이상 최대 금액 이하일 때만 된다.
  /// 이 화면에서 해제한 저장된 배정을 다시 고르면 새로 만들지 않고 그 배정을 쓴다.
  void addPlan(String obligationId, int amountKrw) {
    final c = candidates.where((c) => c.obligationId == obligationId);
    if (c.isEmpty || amountKrw <= 0 || amountKrw > planMax(obligationId)) {
      return;
    }
    final saved = planItems(facts)
        .where((p) => p.obligationId == obligationId)
        .firstOrNull;
    _edit(() {
      _lastUnplanned = null;
      _plans = [
        ..._plans,
        (
          allocationId: saved?.allocationId,
          obligationId: obligationId,
          label: c.first.label,
          dueDate: c.first.dueDate,
          amountKrw: amountKrw,
          releasedKrw: saved?.releasedKrw ?? 0,
          inPeriod: true,
        ),
      ]..sort((x, y) => (x.dueDate ?? '').compareTo(y.dueDate ?? ''));
    });
  }

  /// 2026-11-04: 사용 계획 [obligationId]의 쓸 금액을 [amountKrw]로 바꾼다. 1원 이상 최대 금액 이하일 때만 된다(늘릴 수 없는
  /// 계획은 줄이기만).
  void setPlanAmount(String obligationId, int amountKrw) {
    final p = _planOf(obligationId);
    if (p == null || amountKrw <= 0 || amountKrw > planMax(obligationId)) {
      return;
    }
    if (!planAdjustable(obligationId)) return;
    _edit(() {
      _lastUnplanned = null;
      _plans = [
        for (final q in _plans)
          q.obligationId == obligationId
              ? (
                  allocationId: q.allocationId,
                  obligationId: q.obligationId,
                  label: q.label,
                  dueDate: q.dueDate,
                  amountKrw: amountKrw,
                  releasedKrw: q.releasedKrw,
                  inPeriod: q.inPeriod,
                )
              : q,
      ];
    });
  }

  /// 2026-11-04: 사용 계획 [obligationId]를 해제한다(예정 지출은 그대로). 저장 전에는 [undoUnplan]으로 되돌릴 수 있다.
  void unplan(String obligationId) {
    final index = _plans.indexWhere((p) => p.obligationId == obligationId);
    if (index < 0) return;
    _edit(() {
      _lastUnplanned = (index: index, item: _plans[index]);
      _plans = [..._plans]..removeAt(index);
    });
  }

  /// 2026-11-04: 바로 앞에 해제한 사용 계획을 되돌린다.
  void undoUnplan() {
    final last = _lastUnplanned;
    if (last == null) return;
    _edit(() {
      _lastUnplanned = null;
      _plans = [..._plans]..insert(min(last.index, _plans.length), last.item);
    });
  }

  /// 2026-11-04: 사용 계획 중 예정 지출 [obligationId]의 것. 없으면 null이다.
  PlanItem? _planOf(String obligationId) =>
      _plans.where((p) => p.obligationId == obligationId).firstOrNull;

  /// 2026-11-03: 결과를 모르는 요청이 없을 때만 입력을 바꾼다. 거절 안내는 입력을 바꾸면 내린다.
  void _edit(VoidCallback change) {
    if (locked || busy) return;
    change();
    if (_save is EditRejected) _save = const EditIdle();
    _changed();
  }

  /// 2026-11-03: 추가 또는 수정을 저장한다. 결과 불명 뒤에는 같은 요청을 그대로 다시 보낸다. 성공하면 true다.
  Future<bool> submit() async {
    if (!canSave) return false;
    final pending = _pending;
    if (pending != null) return _send(pending);
    if (facts == null) {
      return _send((
        op: EditOp.add,
        write: _write(),
        input: ReserveInput(
          label: _label.trim(),
          accountId: _accountId!,
          amountKrw: _amount!,
          changes: changes,
        ),
        patch: null,
        detach: null,
      ));
    }
    return _send((
      op: EditOp.update,
      write: _write(),
      input: null,
      patch: patch,
      detach: null,
    ));
  }

  /// 2026-11-03: 이 남겨둘 돈을 취소한다(미해제 배정을 함께 해제, 예정 지출은 그대로). 결과 불명 뒤 다시 누르면 같은 요청을
  /// 보낸다. 성공하면 true다.
  Future<bool> cancel() async {
    if (busy || _needsLatest) return false;
    final pending = _pending;
    if (pending != null) {
      return pending.op == EditOp.cancel ? _send(pending) : false;
    }
    final f = facts;
    if (f == null) return false;
    return _send((
      op: EditOp.cancel,
      write: _write(),
      input: null,
      patch: null,
      detach: detachReserve(f),
    ));
  }

  /// 2026-11-03: 지금 Snapshot 기준의 새 W를 만든다.
  WriteContext _write() => WriteContext(
    expectedDataVersion: _snapshot.dataVersion,
    ruleVersion: _snapshot.ruleVersion,
    idempotencyKey: randomUuidV4(_random),
  );

  /// 2026-11-03: [request]를 보내고 결과에 맞게 상태를 바꾼다.
  Future<bool> _send(_Pending request) async {
    _save = const EditSaving();
    _changed();
    final repository = writer.repository;
    final id = reserveId;
    final outcome = switch (request.op) {
      EditOp.add => await repository.createReserve(
        request.input!,
        request.write,
      ),
      EditOp.update => await repository.updateReserve(
        id!,
        request.patch!,
        request.write,
      ),
      EditOp.cancel => await repository.cancelReserve(
        id!,
        request.detach!,
        request.write,
      ),
    };
    if (_disposed) return false;
    switch (outcome) {
      case FinancialOk(:final value):
        final next = _parse(value.snapshot);
        if (next == null) {
          _pending = request;
          _save = EditUnknown(connection: false, op: request.op);
        } else {
          _pending = null;
          _replace(next);
          _plans = planItems(facts);
          _save = const EditIdle();
          writer.onSnapshot(next);
          _changed();
          return true;
        }
      case FinancialNetworkFailure(:final error):
        _pending = request;
        _save = EditUnknown(
          connection: error is! ApiNonContractResponse,
          op: request.op,
        );
      case FinancialUnavailable():
        _pending = request;
        _save = EditUnknown(connection: false, op: request.op);
      case FinancialStaleData() || FinancialRuleVersionMismatch():
        _pending = null;
        _needsLatest = true;
        _save = const EditStale();
      case FinancialInvalid(:final code):
        _pending = null;
        _save = EditRejected(switch (code) {
          'HISTORY_LOCKED' => EditRejection.historyLocked,
          'RELATION_CONFLICT' => EditRejection.relationConflict,
          'LIMIT_EXCEEDED' => EditRejection.limit,
          _ => EditRejection.validation,
        }, request.op);
      case FinancialForbidden():
        _pending = null;
        _save = EditRejected(EditRejection.forbidden, request.op);
      case FinancialIdempotencyConflict():
        _pending = null;
        _save = EditRejected(EditRejection.other, request.op);
      case FinancialSessionInvalid():
        _pending = null;
        _save = const EditIdle();
        writer.onSessionInvalid();
    }
    _changed();
    return false;
  }

  /// 2026-11-03: 최신 Snapshot을 다시 받아 제약·미리보기를 다시 계산한다. 입력은 그대로 두고 앱 전체에도 반영한다.
  Future<void> reload() async {
    if (busy) return;
    _save = const EditSaving();
    _changed();
    final next = await refreshLatest(writer);
    if (_disposed) return;
    if (next == null) {
      _save = const EditReloadFailed();
    } else {
      _replace(next);
      _pending = null;
      _needsLatest = false;
      _save = reserveId != null && facts == null
          ? const EditGone()
          : const EditReloaded();
    }
    _changed();
  }

  /// 2026-11-03: 기준 Snapshot을 [next]로 바꾸고 다시 계산한다.
  /// 2026-11-04: 입력 중인 사용 계획은 그대로 두되, 저장된 배정은 새 Snapshot의 해제액·기간으로 맞추고 사라진 것은 뺀다.
  void _replace(FinancialSnapshot next) {
    _snapshot = next;
    _calculation = computeHomeCalculation(next);
    final saved = {for (final p in planItems(facts)) p.allocationId: p};
    _plans = [
      for (final p in _plans)
        if (p.allocationId == null)
          p
        else if (saved[p.allocationId] case final s?)
          (
            allocationId: s.allocationId,
            obligationId: s.obligationId,
            label: s.label,
            dueDate: s.dueDate,
            amountKrw: p.amountKrw,
            releasedKrw: s.releasedKrw,
            inPeriod: s.inPeriod,
          ),
    ];
    _lastUnplanned = null;
  }

  /// 2026-11-03: 응답 JSON [json]을 Snapshot으로 읽는다. 형식이 맞지 않으면 null이다.
  static FinancialSnapshot? _parse(Map<String, Object?> json) {
    try {
      return FinancialSnapshot.fromJson(json);
    } on SnapshotFormatException {
      return null;
    }
  }

  /// 2026-11-03: 상태 변화를 알린다.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 2026-11-03: 늦게 도착한 응답이 상태를 바꾸지 않게 표시한다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
