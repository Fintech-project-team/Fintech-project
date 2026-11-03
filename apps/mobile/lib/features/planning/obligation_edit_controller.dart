import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/auth/random_id.dart';
import '../../data/connection/financial_api.dart';
import '../../data/connection/user_snapshot_repository.dart';
import '../../data/financial_snapshot.dart';
import '../../data/financial_snapshot_repository.dart';
import '../../data/http/api_transport.dart' show ApiNonContractResponse;
import '../overview/accounts_screen.dart' show AccountsWriter;
import '../overview/home_calculation.dart';
import 'obligation_edit.dart';

/// 2026-11-03: 예정 지출 편집에서 보내는 쓰기 종류.
enum EditOp { add, update, cancel }

/// 2026-11-03: 서버가 저장을 거절한 이유(오류 코드별, 422 전체를 한도 초과로 묶지 않음).
enum EditRejection {
  /// 409 HISTORY_LOCKED: 이미 출금·정산된 이력이 있어 바꿀 수 없음.
  historyLocked,

  /// 409 RELATION_CONFLICT: 취소된 예정 지출이거나 연결 정보가 바뀜.
  relationConflict,

  /// 422 LIMIT_EXCEEDED: 남겨둘 돈 연결 한도를 넘음.
  limit,

  /// 422 VALIDATION_FAILED 등 입력 형식 오류.
  validation,

  /// 403: 볼 수 없게 된 항목.
  forbidden,

  /// 그 밖(작업 키 충돌 등). 같은 키로 다시 보내지 않는다.
  other,
}

/// 2026-11-03: 저장 진행 상태.
sealed class EditSave {
  const EditSave();
}

/// 2026-11-03: 아무 요청도 없다.
final class EditIdle extends EditSave {
  const EditIdle();
}

/// 2026-11-03: 요청 중이다.
final class EditSaving extends EditSave {
  const EditSaving();
}

/// 2026-11-03: 결과를 확인하지 못했다(실패로 단정하지 않음). [connection]이면 연결 끊김이 확인된 경우다.
final class EditUnknown extends EditSave {
  /// 2026-11-03: 원인 [connection]과 쓰기 종류 [op]로 만든다.
  const EditUnknown({required this.connection, required this.op});

  final bool connection;
  final EditOp op;
}

/// 2026-11-03: 그사이 자료나 계산 규칙이 바뀌어 저장하지 않았다. 최신 정보를 받아 다시 확인해야 한다.
final class EditStale extends EditSave {
  const EditStale();
}

/// 2026-11-03: 최신 정보로 다시 계산했다. 사용자가 확인한 뒤 새 작업 키로 저장한다.
final class EditReloaded extends EditSave {
  const EditReloaded();
}

/// 2026-11-03: 서버가 [reason]으로 거절했다.
final class EditRejected extends EditSave {
  /// 2026-11-03: 거절 이유 [reason]과 쓰기 종류 [op]로 만든다.
  const EditRejected(this.reason, this.op);

  final EditRejection reason;
  final EditOp op;
}

/// 2026-11-03: 최신 정보를 불러오지 못했다.
final class EditReloadFailed extends EditSave {
  const EditReloadFailed();
}

/// 2026-11-03: 최신 정보에서 이 예정 지출을 더 고칠 수 없게 됐다(취소·삭제·카드 청구 연결 등).
final class EditGone extends EditSave {
  const EditGone();
}

/// 2026-11-03: 결과를 확인하지 못한 요청. 다시 보낼 때 본문·버전·배열 순서·작업 키를 그대로 쓴다.
typedef _Pending = ({
  EditOp op,
  WriteContext write,
  ObligationInput? input,
  ObligationPatch? patch,
  List<DetachAllocation>? detach,
});

/// 2026-11-03: 예정 지출 추가·수정·취소(03-2, 29-5a)의 입력·미리보기·저장. 원본 Snapshot과 홈 결과는 바꾸지 않고, 저장에 성공한
/// 응답 Snapshot만 [writer]로 앱 전체에 반영한다.
class ObligationEditController extends ChangeNotifier {
  /// 2026-11-03: 지금 Snapshot [snapshot], 저장 연결 [writer], 고칠 예정 지출 [obligationId](추가면 null)로 만든다. [random]은
  /// 작업 키 생성용이며 테스트에서만 바꾼다.
  ObligationEditController({
    required FinancialSnapshot snapshot,
    required this.writer,
    this.obligationId,
    Random? random,
  }) : _snapshot = snapshot,
       _calculation = computeHomeCalculation(snapshot),
       _random = random ?? Random.secure() {
    final o = facts?.obligation;
    _label = o?.label ?? '';
    _amount = o?.amountKrw;
    _dueDate = o?.dueDate;
    _accountId = o?.withdrawalAccountId;
  }

  final AccountsWriter writer;
  final String? obligationId;
  final Random _random;
  FinancialSnapshot _snapshot;
  HomeCalculation _calculation;
  late String _label;
  int? _amount;
  String? _dueDate;
  String? _accountId;
  EditSave _save = const EditIdle();
  _Pending? _pending;
  bool _needsLatest = false;
  bool _disposed = false;

  /// 2026-11-03: 지금 기준 Snapshot.
  FinancialSnapshot get snapshot => _snapshot;

  /// 2026-11-03: 지금 기준 계산.
  HomeCalculation get calculation => _calculation;

  /// 2026-11-03: 고칠 예정 지출의 제약. 추가거나 더 고칠 수 없으면 null이다.
  ObligationFacts? get facts {
    final id = obligationId;
    return id == null ? null : obligationFacts(_snapshot, id);
  }

  /// 2026-11-03: 지금 입력.
  ObligationDraft get draft => (
    label: _label,
    amountKrw: _amount,
    dueDate: _dueDate,
    accountId: _accountId,
  );

  /// 2026-11-03: 저장 진행 상태.
  EditSave get save => _save;

  /// 2026-11-03: 요청 중이면 true다.
  bool get busy => _save is EditSaving;

  /// 2026-11-03: 결과를 확인하지 못한 요청이 있어 입력을 잠가야 하면 true다.
  bool get locked => _pending != null;

  /// 2026-11-03: 자료·규칙 충돌 뒤 최신 정보를 아직 받지 못했으면 true다. 재조회에 실패해도 유지되며, 그동안 저장·취소를 막는다.
  bool get needsLatest => _needsLatest;

  /// 2026-11-03: 입력의 칸별 문제.
  DraftProblems get problems => draftProblems(draft, facts);

  /// 2026-11-03: 수정에서 바꾼 필드. 추가면 null이다.
  ObligationPatch? get patch {
    final o = facts?.obligation;
    if (o == null) return null;
    final label = _label.trim();
    return ObligationPatch(
      label: label != o.label ? label : null,
      amountKrw: _amount != o.amountKrw ? _amount : null,
      dueDate: _dueDate != o.dueDate ? _dueDate : null,
      withdrawalAccountId: _accountId != o.withdrawalAccountId
          ? _accountId
          : null,
    );
  }

  /// 2026-11-03: 바꾼 내용이 없는 수정이면 true다.
  bool get unchanged => patch?.isEmpty ?? false;

  /// 2026-11-03: 지금 저장할 수 있으면 true다(결과 불명이면 같은 요청을 다시 보내는 것만 가능, 최신 정보가 필요하면 불가).
  bool get canSave {
    if (busy || _needsLatest) return false;
    if (locked) return true;
    if (_save is EditGone) return false;
    if (obligationId != null && facts == null) return false;
    return draftComplete(draft, facts) && !unchanged;
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
    return previewDraft(_snapshot, _calculation, draft, facts);
  }

  /// 2026-11-03: 취소 확인창의 미리보기. 취소할 수 없으면 null이다.
  PlanPreview? get cancelPreview {
    final f = facts;
    if (f == null || f.withdrawn) return null;
    return previewCancel(_snapshot, _calculation, f);
  }

  /// 2026-11-03: 이름 [value]를 입력한다.
  void setLabel(String value) => _edit(() => _label = value);

  /// 2026-11-03: 금액 [value]를 입력한다(쉼표 없는 숫자, 비면 null).
  void setAmount(String value) => _edit(
    () => _amount = value.isEmpty ? null : int.tryParse(value) ?? _amount,
  );

  /// 2026-11-03: 예정일 [value](YYYY-MM-DD)를 고른다.
  void setDueDate(String value) => _edit(() => _dueDate = value);

  /// 2026-11-03: 출금 계좌 [value]를 고른다. 출금된 기록이 있으면 바꾸지 않는다.
  void setAccount(String value) {
    if (facts?.withdrawn ?? false) return;
    _edit(() => _accountId = value);
  }

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
    final o = facts;
    final write = _write();
    if (o == null) {
      return _send((
        op: EditOp.add,
        write: write,
        input: ObligationInput(
          label: _label.trim(),
          withdrawalAccountId: _accountId!,
          amountKrw: _amount!,
          dueDate: _dueDate!,
        ),
        patch: null,
        detach: null,
      ));
    }
    return _send((
      op: EditOp.update,
      write: write,
      input: null,
      patch: patch,
      detach: null,
    ));
  }

  /// 2026-11-03: 이 예정 지출을 취소한다(미해제 연결을 함께 해제). 결과 불명 뒤 다시 누르면 같은 요청을 보낸다. 성공하면 true다.
  Future<bool> cancel() async {
    if (busy || _needsLatest) return false;
    final pending = _pending;
    if (pending != null) {
      return pending.op == EditOp.cancel ? _send(pending) : false;
    }
    final f = facts;
    if (f == null || f.withdrawn) return false;
    return _send((
      op: EditOp.cancel,
      write: _write(),
      input: null,
      patch: null,
      detach: detachAll(f),
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
    final id = obligationId;
    final outcome = switch (request.op) {
      EditOp.add => await repository.createObligation(
        request.input!,
        request.write,
      ),
      EditOp.update => await repository.updateObligation(
        id!,
        request.patch!,
        request.write,
      ),
      EditOp.cancel => await repository.cancelObligation(
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

  /// 2026-11-03: 최신 Snapshot을 다시 받아 제약·미리보기를 다시 계산한다. 입력은 그대로 두고, 앱 전체에도 반영한다.
  /// 결과 불명 요청은 버리지 않는다(그 사이 저장됐는지 사용자가 확인할 수 있게 목록을 갱신할 뿐이다).
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
      _save = obligationId != null && facts == null
          ? const EditGone()
          : const EditReloaded();
    }
    _changed();
  }

  /// 2026-11-03: 기준 Snapshot을 [next]로 바꾸고 다시 계산한다.
  void _replace(FinancialSnapshot next) {
    _snapshot = next;
    _calculation = computeHomeCalculation(next);
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

/// 2026-11-03: 최신 Snapshot을 받아 [writer]로 앱 전체에 반영하고 반환한다. 실패면 null이며, 세션이 무효면 신규 로그인으로 넘긴다.
/// 결과를 모른 채 편집 화면을 나갈 때도 쓴다.
Future<FinancialSnapshot?> refreshLatest(AccountsWriter writer) async {
  final result = await UserSnapshotRepository(writer.repository).loadSnapshot();
  switch (result) {
    case SnapshotLoaded(:final snapshot):
      writer.onSnapshot(snapshot);
      return snapshot;
    case SnapshotLoadFailed(:final error)
        when error is FinancialLoadError && error.sessionInvalid:
      writer.onSessionInvalid();
      return null;
    case _:
      return null;
  }
}
