import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/auth/random_id.dart';
import '../../data/connection/financial_api.dart';
import '../../data/connection/user_snapshot_repository.dart';
import '../../data/financial_snapshot.dart';
import '../../data/financial_snapshot_repository.dart';
import 'connection_flow_controller.dart';

/// 2026-10-28: 월급 설정(03-7) 화면의 상태 소유자. 마지막으로 받은 Snapshot의 월급 설정을 저장 값으로 두고,
/// 화면 입력(월급일·예상 금액·계좌)과 비교해 바뀐 필드만 PATCH /settings로 보낸다. 금액을 계산하지 않는다.
class SalarySettingsController extends ChangeNotifier {
  /// 2026-10-28: 세션 저장소 [repository], 시작 Snapshot [snapshot], 세션 무효 [onSessionInvalid], 작업 키 난수 [random]으로 만든다.
  SalarySettingsController({
    required this.repository,
    required this._snapshot,
    required this.onSessionInvalid,
    Random? random,
  }) : _random = random ?? Random.secure() {
    _resetDraft();
  }

  final UserFinancialRepository repository;
  final VoidCallback onSessionInvalid;
  final Random _random;
  FinancialSnapshot _snapshot;
  int? _day;
  String _amountDigits = '';
  String? _accountId;
  bool _amountMissing = false;
  ConnectionSaveState _save = const SaveIdle();
  ReloadStatus _reload = ReloadStatus.idle;
  ({String key, String fingerprint})? _attempt;
  bool _disposed = false;

  /// 2026-10-28: 마지막으로 받은 Snapshot(저장 성공·최신 정보 불러오기 뒤 바뀜).
  FinancialSnapshot get snapshot => _snapshot;

  /// 2026-10-28: 저장된 월급 설정.
  SalarySetting? get saved => _snapshot.settings?.salary;

  /// 2026-10-28: 입력 중인 월급일(1~31). 저장 값도 없으면 null이다.
  int? get day => _day;

  /// 2026-10-28: 입력 중인 예상 금액의 숫자만(쉼표 없음). 비었으면 빈 문자열이다.
  String get amountDigits => _amountDigits;

  /// 2026-10-28: 입력 중인 월급 계좌 ID. 저장 값이 숨겨졌고 바꾸지 않았거나 고르지 않았으면 null이다.
  String? get accountId => _accountId;

  /// 2026-10-28: 저장된 월급 계좌가 연결 제한으로 숨겨졌고 아직 다른 계좌로 바꾸지 않았으면 true를 반환한다.
  bool get accountHidden =>
      (saved?.salaryAccountRestricted ?? false) && _accountId == null;

  /// 2026-10-28: 금액을 비운 채 저장을 눌렀으면 true를 반환한다. 금액을 고치면 다시 false가 된다.
  bool get amountMissing => _amountMissing;

  /// 2026-10-28: 저장 진행 상태.
  ConnectionSaveState get save => _save;

  /// 2026-10-28: 버전 불일치 뒤 최신 정보 불러오기 상태.
  ReloadStatus get reload => _reload;

  /// 2026-10-28: 저장 중이거나 최신 정보를 불러오는 중이면 true를 반환한다(입력·나가기를 막는다).
  bool get busy => _save is SaveInProgress || _reload == ReloadStatus.loading;

  /// 2026-10-28: 월급 계좌로 고를 수 있는 계좌. 계산에 쓰기로 고른 계좌만 응답 순서대로 반환한다.
  List<Account> get selectableAccounts => [
    for (final a in _snapshot.accounts ?? const <Account>[])
      if (a.included) a,
  ];

  /// 2026-10-28: 입력 중인 예상 금액. 비었으면 null이다.
  int? get _amount => _amountDigits.isEmpty ? null : int.parse(_amountDigits);

  /// 2026-10-28: 저장 값과 다른 필드만 담은 변경을 반환한다.
  SalaryPatch get patch {
    final s = saved;
    return SalaryPatch(
      salaryDay: _day != s?.salaryDay ? (value: _day) : null,
      salaryAmountKrw: _amount != s?.salaryAmountKrw ? (value: _amount) : null,
      salaryAccountId: _accountId != null && _accountId != s?.salaryAccountId
          ? (value: _accountId)
          : null,
    );
  }

  /// 2026-10-28: 월급일·예상 금액·계좌 중 하나라도 저장 값과 다르면 true를 반환한다.
  bool get dirty => !patch.isEmpty;

  /// 2026-10-28: 저장 버튼을 누를 수 있으면 true를 반환한다. 바뀐 값이 있고, 진행 중이 아니며, 버전 불일치로
  /// 최신 정보를 다시 불러와야 하는 상태가 아닐 때다.
  bool get canSave => dirty && !busy && !outdated;

  /// 2026-10-28: 자료·규칙 버전 불일치로 저장하지 못해 최신 정보를 다시 불러와야 하면 true를 반환한다.
  bool get outdated => switch (_save) {
    SaveFailed(failure: ConnectionSaveFailure.outdated) => true,
    _ => false,
  };

  /// 2026-10-28: 월급일을 [day]로 바꾼다.
  void setDay(int day) {
    if (busy) return;
    _day = day;
    _changed();
  }

  /// 2026-10-28: 예상 금액 입력을 숫자 [digits]로 바꾼다.
  void setAmount(String digits) {
    if (busy) return;
    _amountDigits = digits;
    if (digits.isNotEmpty) _amountMissing = false;
    _changed();
  }

  /// 2026-10-28: 월급 계좌를 [accountId]로 바꾼다.
  void setAccount(String accountId) {
    if (busy) return;
    _accountId = accountId;
    _changed();
  }

  /// 2026-10-28: 바뀐 필드를 저장한다. 성공 응답의 Snapshot을 저장 값으로 삼고 그 Snapshot을 반환한다.
  /// 금액이 비었으면 보내지 않고 오류를 표시한다. 실패면 입력을 그대로 두고 null을 반환한다.
  /// 응답을 받지 못한 같은 내용의 재시도에는 같은 작업 키를 쓴다.
  Future<FinancialSnapshot?> submit() async {
    if (!canSave) return null;
    if (_amountDigits.isEmpty) {
      _amountMissing = true;
      _changed();
      return null;
    }
    final body = patch;
    final fingerprint = jsonEncode([
      _snapshot.dataVersion,
      _snapshot.ruleVersion,
      body.toJson(),
    ]);
    final attempt = _attempt?.fingerprint == fingerprint
        ? _attempt!
        : (key: randomUuidV4(_random), fingerprint: fingerprint);
    _attempt = attempt;
    _save = const SaveInProgress();
    _changed();
    final outcome = await repository.updateSalarySettings(
      body,
      WriteContext(
        expectedDataVersion: _snapshot.dataVersion,
        ruleVersion: _snapshot.ruleVersion,
        idempotencyKey: attempt.key,
      ),
    );
    if (_disposed) return null;
    FinancialSnapshot? next;
    switch (outcome) {
      case FinancialOk(:final value):
        next = _parse(value.snapshot);
        _save = next == null
            ? const SaveFailed(ConnectionSaveFailure.retryable)
            : const SaveIdle();
      case FinancialSessionInvalid():
        _save = const SaveFailed(ConnectionSaveFailure.retryable);
        onSessionInvalid();
      case FinancialStaleData() || FinancialRuleVersionMismatch():
        _save = const SaveFailed(ConnectionSaveFailure.outdated);
      case FinancialUnavailable() || FinancialNetworkFailure():
        _save = const SaveFailed(ConnectionSaveFailure.retryable);
      case FinancialInvalid() ||
          FinancialForbidden() ||
          FinancialIdempotencyConflict():
        _save = const SaveFailed(ConnectionSaveFailure.rejected);
    }
    if (_save case SaveFailed(:final failure)
        when failure != ConnectionSaveFailure.retryable) {
      _attempt = null;
    }
    if (next != null) {
      _attempt = null;
      _snapshot = next;
      _resetDraft();
    }
    _changed();
    return next;
  }

  /// 2026-10-28: 최신 Snapshot을 다시 읽는다. 성공하면 저장 값 기준을 바꾸고, 사용자가 바꾼 칸은 입력을 유지하며
  /// 바꾸지 않은 칸은 새 저장 값으로 맞춘 뒤 그 Snapshot을 반환한다.
  /// 실패면 null이고, 세션 무효면 신규 로그인으로 넘긴다.
  Future<FinancialSnapshot?> reloadLatest() async {
    if (busy) return null;
    _reload = ReloadStatus.loading;
    _changed();
    final result = await UserSnapshotRepository(repository).loadSnapshot();
    if (_disposed) return null;
    FinancialSnapshot? next;
    switch (result) {
      case SnapshotLoaded(:final snapshot) when snapshot.accounts != null:
        next = snapshot;
      case SnapshotLoadFailed(:final error)
          when error is FinancialLoadError && error.sessionInvalid:
        onSessionInvalid();
      case _:
        break;
    }
    if (next == null) {
      _reload = ReloadStatus.failed;
    } else {
      final before = saved;
      final after = next.settings?.salary;
      if (_day == before?.salaryDay) _day = after?.salaryDay;
      if (_amount == before?.salaryAmountKrw) {
        _amountDigits = after?.salaryAmountKrw?.toString() ?? '';
      }
      if (_accountId == before?.salaryAccountId) {
        _accountId = after?.salaryAccountId;
      }
      _snapshot = next;
      _reload = ReloadStatus.idle;
      _save = const SaveIdle();
      _attempt = null;
    }
    _changed();
    return next;
  }

  /// 2026-10-28: 입력을 저장 값으로 되돌린다. 숨겨진 계좌는 바꾸지 않은 상태(null)로 둔다.
  void _resetDraft() {
    final s = saved;
    _day = s?.salaryDay;
    _amountDigits = s?.salaryAmountKrw?.toString() ?? '';
    _accountId = s?.salaryAccountId;
    _amountMissing = false;
  }

  /// 2026-10-28: 응답 JSON [json]을 Snapshot으로 읽는다. 형식이 맞지 않거나 계좌 묶음이 없으면 null이다.
  FinancialSnapshot? _parse(Map<String, Object?> json) {
    try {
      final parsed = FinancialSnapshot.fromJson(json);
      return parsed.accounts == null ? null : parsed;
    } on SnapshotFormatException {
      return null;
    }
  }

  /// 2026-10-28: 폐기 전이면 듣는 화면에 알린다.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 2026-10-28: 폐기한다. 늦게 도착한 응답은 반영하지 않는다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
