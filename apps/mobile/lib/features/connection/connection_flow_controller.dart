import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/auth/random_id.dart';
import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import 'connection_presentation_policy.dart';

/// 2026-10-22: 12-3에서 기관 한 곳의 표시 상태. 표시 연출이며 서버 연결 상태가 아니다.
enum InstitutionLoadStatus { waiting, loading, failed, done }

/// 2026-10-22: 저장 실패 종류. 같은 요청을 다시 보낼 수 있는지와 화면 안내가 다르다.
enum ConnectionSaveFailure {
  /// 응답을 받지 못했거나 서비스 불가. 같은 작업 키로 결과를 다시 확인한다.
  retryable,

  /// 409 자료·규칙 버전 불일치. 최신 정보를 다시 읽은 뒤 사용자가 다시 진행한다.
  outdated,

  /// 422·403·작업 키 충돌. 같은 내용으로 다시 보내도 성공하지 않는다.
  rejected,
}

/// 2026-10-22: 저장 진행 상태. 저장 중·실패·대기를 서로 다른 값으로 둔다.
sealed class ConnectionSaveState {
  /// 2026-10-22: 하위 상태만 만든다.
  const ConnectionSaveState();
}

/// 2026-10-22: 저장 요청 전 또는 성공 뒤.
final class SaveIdle extends ConnectionSaveState {
  /// 2026-10-22: 대기 상태를 만든다.
  const SaveIdle();
}

/// 2026-10-22: 저장 요청 중.
final class SaveInProgress extends ConnectionSaveState {
  /// 2026-10-22: 저장 중 상태를 만든다.
  const SaveInProgress();
}

/// 2026-10-22: 저장 실패. [failure]로 안내와 다음 행동을 고른다.
final class SaveFailed extends ConnectionSaveState {
  /// 2026-10-22: 실패 종류 [failure]로 만든다.
  const SaveFailed(this.failure);

  final ConnectionSaveFailure failure;
}

/// 2026-10-23: 버전 불일치 뒤 최신 Snapshot 다시 읽기 상태. 읽는 중·실패를 저장 실패와 구분한다.
enum ReloadStatus { idle, loading, failed }

/// 2026-10-22: 같은 논리 작업의 작업 키와 요청 내용. 응답을 받지 못한 같은 요청의 재시도에만 키를 다시 쓴다.
class _Attempt {
  /// 2026-10-22: 작업 키 [key]와 요청 지문 [fingerprint]로 만든다.
  const _Attempt(this.key, this.fingerprint);

  final String key;
  final String fingerprint;
}

/// 2026-10-22: 금융사 연결 흐름(12-1 → 12-2 → 12-3 → 01-1 → 01-2)의 상태 소유자(app-architecture §3).
/// 동의·표시 연출은 흐름 메모리에만 두고 서버 저장 성공 전에는 연결·선택을 확정으로 보지 않는다.
/// 금액을 계산하지 않으며 서버 응답 Snapshot을 [FinancialSnapshot]으로만 읽는다.
class ConnectionFlowController extends ChangeNotifier {
  /// 2026-10-22: 세션 저장소 [repository], 현재 Snapshot [snapshot], 표시 정책 [policy],
  /// 세션 무효 처리 [onSessionInvalid], 작업 키 난수 [random]으로 만든다.
  ConnectionFlowController({
    required this.repository,
    required FinancialSnapshot snapshot,
    required this.policy,
    required this.onSessionInvalid,
    Random? random,
  }) : _snapshot = snapshot,
       _random = random ?? Random.secure() {
    if (snapshot.institutionLinkCount > 0) _resetAccountSelection();
  }

  final UserFinancialRepository repository;
  final ConnectionPresentationPolicy policy;
  final VoidCallback onSessionInvalid;
  final Random _random;

  FinancialSnapshot _snapshot;
  bool _disposed = false;

  /// 2026-10-22: 가장 최근에 받은 Snapshot. 저장 성공 응답이나 다시 읽기로만 바뀐다.
  FinancialSnapshot get snapshot => _snapshot;

  /// 2026-10-22: 이 사용자가 연결할 수 있는 기관 목록(응답 순서 그대로).
  List<Institution> get institutions => _snapshot.institutions;

  /// 2026-10-22: 상태가 바뀌었음을 알린다. 폐기 뒤 늦게 끝난 작업은 알리지 않는다.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 2026-10-22: 흐름을 떠나면 진행 중 연출·저장 결과를 버린다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // 12-1 금융사 고르기

  final Set<String> _chosen = {};

  /// 2026-10-22: 기관 [code]를 골랐으면 true를 반환한다.
  bool isChosen(String code) => _chosen.contains(code);

  /// 2026-10-22: 기관 [code]의 선택을 바꾼다. 기본은 모두 해제다(screen-rules-update §1).
  void toggleChosen(String code) {
    if (!_chosen.remove(code)) _chosen.add(code);
    _changed();
  }

  /// 2026-10-22: 은행을 1곳 이상 골랐으면 true를 반환한다(12-1 다음 활성 조건).
  /// 2026-10-27: 12-1 묶음 [codes]를 모두 고르거나([selected]) 모두 푼다.
  void setChosen(Iterable<String> codes, {required bool selected}) {
    selected ? _chosen.addAll(codes) : _chosen.removeAll(codes);
    _changed();
  }

  bool get hasChosenBank => _hasBank(_chosen);

  /// 2026-10-22: 카드사만 골랐으면 true를 반환한다. 처음(아무것도 안 고름)에는 false다.
  bool get chosenCardOnly => _chosen.isNotEmpty && !hasChosenBank;

  /// 2026-10-22: 고른 기관을 응답 순서대로 반환한다.
  List<Institution> get chosenInstitutions => [
    for (final i in institutions)
      if (_chosen.contains(i.code)) i,
  ];

  // 12-2 동의

  final Set<String> _consented = {};

  /// 2026-10-22: 12-2에 들어갈 때 고르지 않은 기관의 동의를 지운다. 동의는 서버에 저장하지 않는다.
  void enterConsent() {
    _consented.removeWhere((c) => !_chosen.contains(c));
    _changed();
  }

  /// 2026-10-22: 기관 [code]에 동의했으면 true를 반환한다.
  bool isConsented(String code) => _consented.contains(code);

  /// 2026-10-22: 기관 [code]의 동의를 바꾼다. 기본은 모두 해제다.
  void toggleConsent(String code) {
    if (!_consented.remove(code)) _consented.add(code);
    _changed();
  }

  /// 2026-10-22: 고른 기관 모두에 동의했으면 true를 반환한다.
  bool get allConsented =>
      _chosen.isNotEmpty && _chosen.every(_consented.contains);

  /// 2026-10-22: 고른 기관 전체의 동의를 [value]로 맞춘다.
  void setAllConsent(bool value) {
    value ? _consented.addAll(_chosen) : _consented.clear();
    _changed();
  }

  /// 2026-10-22: 은행 1곳 이상 동의했으면 true를 반환한다(12-2 진행 조건).
  bool get hasConsentedBank => _hasBank(_consented);

  /// 2026-10-22: 카드사에만 동의했으면 true를 반환한다.
  bool get consentedCardOnly => _consented.isNotEmpty && !hasConsentedBank;

  // 12-3 불러오기 연출

  final Map<String, InstitutionLoadStatus> _load = {};
  List<String> _loadOrder = const [];
  Set<String>? _drawn;
  int _loadRun = 0;

  /// 2026-10-22: 불러오기 대상 기관을 순서대로 반환한다.
  List<Institution> get loadingInstitutions => [
    for (final code in _loadOrder)
      institutions.firstWhere((i) => i.code == code),
  ];

  /// 2026-10-22: 기관 [code]의 표시 상태를 반환한다.
  InstitutionLoadStatus loadStatusOf(String code) =>
      _load[code] ?? InstitutionLoadStatus.waiting;

  /// 2026-10-22: 아직 대기·진행 중인 기관이 있으면 true를 반환한다. 이때는 제외 버튼을 보이지 않는다.
  bool get loadInProgress => _loadOrder.any((code) {
    final s = loadStatusOf(code);
    return s == InstitutionLoadStatus.waiting ||
        s == InstitutionLoadStatus.loading;
  });

  /// 2026-10-22: 표시상 실패로 끝난 기관을 순서대로 반환한다.
  List<Institution> get failedInstitutions => [
    for (final i in loadingInstitutions)
      if (loadStatusOf(i.code) == InstitutionLoadStatus.failed) i,
  ];

  /// 2026-10-22: 최종 연결 목록(동의한 기관 − 실패로 제외한 기관)을 순서대로 반환한다.
  List<String> get finalCodes => [
    for (final code in _loadOrder)
      if (loadStatusOf(code) == InstitutionLoadStatus.done) code,
  ];

  /// 2026-10-22: 최종 목록에 계산할 은행이 있으면 true를 반환한다. 없으면 진행을 막는다.
  bool get finalHasBank => _hasBank(finalCodes.toSet());

  /// 2026-10-22: 동의한 기관으로 불러오기 연출을 시작한다. 같은 동의로 돌아오면 이전 결과를 유지하고,
  /// 실패 추첨은 흐름에서 처음 한 번만 한다.
  Future<void> startLoading() async {
    final order = [
      for (final i in institutions)
        if (_consented.contains(i.code)) i.code,
    ];
    if (listEquals(order, _loadOrder) && _load.isNotEmpty) return;
    _loadOrder = order;
    _load
      ..clear()
      ..addEntries(
        order.map((c) => MapEntry(c, InstitutionLoadStatus.waiting)),
      );
    _drawn ??= {...policy.drawFailures(order)};
    final run = ++_loadRun;
    _changed();
    for (final code in order) {
      if (_disposed || run != _loadRun) return;
      _load[code] = InstitutionLoadStatus.loading;
      _changed();
      await policy.stepDelay();
      if (_disposed || run != _loadRun) return;
      _load[code] = _drawn!.contains(code)
          ? InstitutionLoadStatus.failed
          : InstitutionLoadStatus.done;
      _changed();
    }
  }

  /// 2026-10-22: 실패 행을 다시 시도한다. 2~3초 뒤 표시상 완료하며, 이 흐름에서 불러오기를 다시 시작해도
  /// 그 기관은 다시 실패하지 않는다.
  /// 2026-10-23: 연결 저장 중에는 저장 목록과 표시가 어긋나지 않도록 다시 시도하지 않는다.
  Future<void> retry(String code) async {
    if (_linkSave is SaveInProgress ||
        loadStatusOf(code) != InstitutionLoadStatus.failed) {
      return;
    }
    final run = _loadRun;
    _load[code] = InstitutionLoadStatus.loading;
    _changed();
    await policy.retryDelay();
    if (_disposed || run != _loadRun) return;
    _drawn?.remove(code);
    _load[code] = InstitutionLoadStatus.done;
    _changed();
  }

  // 저장

  ConnectionSaveState _linkSave = const SaveIdle();
  ConnectionSaveState _selectionSave = const SaveIdle();
  _Attempt? _linkAttempt;
  _Attempt? _selectionAttempt;

  /// 2026-10-22: 연결 저장(POST /institution-links) 상태.
  ConnectionSaveState get linkSave => _linkSave;

  /// 2026-10-22: 계좌 선택 저장(PATCH /account-selection) 상태.
  ConnectionSaveState get selectionSave => _selectionSave;

  /// 2026-10-22: 최종 목록으로 연결을 저장한다. 성공 응답의 Snapshot을 받은 뒤에만 true를 반환한다.
  /// 저장 중 중복 요청은 보내지 않는다.
  /// 2026-10-23: 최신 Snapshot을 다시 읽는 중에는 보내지 않는다.
  Future<bool> saveLinks() async {
    if (_linkSave is SaveInProgress ||
        _reload == ReloadStatus.loading ||
        !finalHasBank ||
        loadInProgress) {
      return false;
    }
    final codes = finalCodes;
    final (attempt, write) = _write(_linkAttempt, 'link', codes);
    _linkAttempt = attempt;
    _linkSave = const SaveInProgress();
    _changed();
    final outcome = await repository.linkInstitutions(codes, write);
    if (_disposed) return false;
    final ok = _accept(outcome, (failure) => _linkSave = SaveFailed(failure));
    if (ok) {
      _linkAttempt = null;
      _linkSave = const SaveIdle();
      _resetAccountSelection();
    } else if (_linkSave is! SaveFailed ||
        (_linkSave as SaveFailed).failure != ConnectionSaveFailure.retryable) {
      _linkAttempt = null;
    }
    _changed();
    return ok;
  }

  // 01-1 계좌 고르기

  final Set<String> _selectedAccounts = {};
  String? _reserveNoticeAccount;
  bool _accountSelectionStarted = false;

  /// 2026-10-22: 연결된 계좌를 응답 순서대로 반환한다.
  List<Account> get accounts => _snapshot.accounts ?? const [];

  /// 2026-10-22: 계좌 [accountId]를 계산에 포함하도록 골랐으면 true를 반환한다.
  bool isAccountSelected(String accountId) =>
      _selectedAccounts.contains(accountId);

  /// 2026-10-22: 1개 이상 골랐으면 true를 반환한다(0개 선택 불가).
  bool get canSaveSelection => _selectedAccounts.isNotEmpty;

  /// 2026-10-29: 고른 계좌가 현재 Snapshot의 계산 포함 계좌와 다르면 true를 반환한다(계좌 탭에서 다시 고를 때 쓴다).
  bool get selectionChanged {
    final included = {
      for (final a in accounts)
        if (a.included) a.accountId,
    };
    return included.length != _selectedAccounts.length ||
        !included.containsAll(_selectedAccounts);
  }

  /// 2026-10-22: 계좌 [accountId]에 연결된 유효한 모아둘 돈을 반환한다(취소된 것은 제외).
  List<Reserve> reservesOf(String accountId) => [
    for (final r in _snapshot.reserves ?? const <Reserve>[])
      if (r.accountId == accountId && r.cancelledAt == null) r,
  ];

  /// 2026-10-22: 09-10 안내를 보일 계좌. 모아둘 돈이 있는 계좌를 해제할 때마다 바뀐다.
  String? get reserveNoticeAccount => _reserveNoticeAccount;

  /// 2026-10-22: 계좌 [accountId]의 선택을 바꾼다. 모아둘 돈이 있는 계좌를 해제하면 09-10 안내를 보인다.
  void toggleAccount(String accountId) {
    if (_selectedAccounts.remove(accountId)) {
      _reserveNoticeAccount = reservesOf(accountId).isEmpty ? null : accountId;
    } else {
      _selectedAccounts.add(accountId);
      if (_reserveNoticeAccount == accountId) _reserveNoticeAccount = null;
    }
    _changed();
  }

  /// 2026-10-27: 01-1 묶음 [accountIds]를 모두 고르거나([selected]) 모두 푼다. 묶음 해제는 화면이 한 번 확인한 뒤
  /// 부르므로 계좌별 09-10 안내를 띄우지 않는다.
  void setAccounts(Iterable<String> accountIds, {required bool selected}) {
    selected
        ? _selectedAccounts.addAll(accountIds)
        : _selectedAccounts.removeAll(accountIds);
    _reserveNoticeAccount = null;
    _changed();
  }

  /// 2026-10-22: 고른 계좌로 계산에 쓸 계좌 집합을 교체 저장한다. 성공 응답을 받은 뒤에만 true를 반환한다.
  /// 2026-10-23: 최신 Snapshot을 다시 읽는 중에는 보내지 않는다.
  Future<bool> saveSelection() async {
    if (_selectionSave is SaveInProgress ||
        _reload == ReloadStatus.loading ||
        !canSaveSelection) {
      return false;
    }
    final ids = [
      for (final a in accounts)
        if (_selectedAccounts.contains(a.accountId)) a.accountId,
    ];
    final (attempt, write) = _write(_selectionAttempt, 'select', ids);
    _selectionAttempt = attempt;
    _selectionSave = const SaveInProgress();
    _changed();
    final outcome = await repository.selectAccounts(ids, write);
    if (_disposed) return false;
    final ok = _accept(
      outcome,
      (failure) => _selectionSave = SaveFailed(failure),
    );
    if (ok) {
      _selectionAttempt = null;
      _selectionSave = const SaveIdle();
    } else if ((_selectionSave as SaveFailed).failure !=
        ConnectionSaveFailure.retryable) {
      _selectionAttempt = null;
    }
    _changed();
    return ok;
  }

  ReloadStatus _reload = ReloadStatus.idle;

  /// 2026-10-23: 최신 Snapshot 다시 읽기 상태.
  ReloadStatus get reloadStatus => _reload;

  /// 2026-10-22: 버전 불일치 뒤 최신 Snapshot을 다시 읽는다. 사용자의 고른 상태는 유지하고 저장은 다시 누를 때 보낸다.
  /// 2026-10-23: 읽는 중 중복 요청을 보내지 않고, 조회 실패·형식 오류는 실패 상태로 남겨 화면이 알린다.
  Future<void> reload() async {
    if (_reload == ReloadStatus.loading) return;
    _reload = ReloadStatus.loading;
    _changed();
    final outcome = await repository.loadSnapshot();
    if (_disposed) return;
    final parsed = switch (outcome) {
      FinancialOk(:final value) => _parse(value),
      _ => null,
    };
    if (parsed != null) {
      _snapshot = parsed;
      _reload = ReloadStatus.idle;
      _linkSave = const SaveIdle();
      _selectionSave = const SaveIdle();
      _selectedAccounts.removeWhere(
        (id) => !accounts.any((a) => a.accountId == id),
      );
    } else if (outcome is FinancialSessionInvalid) {
      _reload = ReloadStatus.idle;
      onSessionInvalid();
    } else {
      _reload = ReloadStatus.failed;
    }
    _changed();
  }

  /// 2026-10-22: 이전 시도 [previous]가 같은 요청이면 그 작업 키를, 아니면 새 키를 쓴 쓰기 공통 필드를 반환한다.
  (_Attempt, WriteContext) _write(
    _Attempt? previous,
    String kind,
    List<String> body,
  ) {
    final fingerprint = jsonEncode([
      kind,
      _snapshot.dataVersion,
      _snapshot.ruleVersion,
      body,
    ]);
    final attempt = previous != null && previous.fingerprint == fingerprint
        ? previous
        : _Attempt(randomUuidV4(_random), fingerprint);
    return (
      attempt,
      WriteContext(
        expectedDataVersion: _snapshot.dataVersion,
        ruleVersion: _snapshot.ruleVersion,
        idempotencyKey: attempt.key,
      ),
    );
  }

  /// 2026-10-22: 쓰기 결과 [outcome]을 반영한다. 성공이면 응답 Snapshot을 받고 true를 반환한다.
  /// 실패면 [fail]로 실패 종류를 기록하고, 401이면 세션 무효 처리를 부른다.
  bool _accept(
    FinancialOutcome<WriteSuccess> outcome,
    void Function(ConnectionSaveFailure) fail,
  ) {
    switch (outcome) {
      case FinancialOk(:final value):
        final parsed = _parse(value.snapshot);
        if (parsed == null) {
          fail(ConnectionSaveFailure.retryable);
          return false;
        }
        _snapshot = parsed;
        return true;
      case FinancialSessionInvalid():
        fail(ConnectionSaveFailure.retryable);
        onSessionInvalid();
      case FinancialStaleData() || FinancialRuleVersionMismatch():
        fail(ConnectionSaveFailure.outdated);
      case FinancialUnavailable() || FinancialNetworkFailure():
        fail(ConnectionSaveFailure.retryable);
      case FinancialInvalid() ||
          FinancialForbidden() ||
          FinancialIdempotencyConflict():
        fail(ConnectionSaveFailure.rejected);
    }
    return false;
  }

  /// 2026-10-22: 응답 JSON [json]을 Snapshot으로 읽는다. 형식이 맞지 않으면 null이다.
  FinancialSnapshot? _parse(Map<String, Object?> json) {
    try {
      return FinancialSnapshot.fromJson(json);
    } on SnapshotFormatException {
      return null;
    }
  }

  /// 2026-10-22: 계좌 선택 기본값을 맞춘다. 입출금은 선택, 예금·적금·기타는 해제(D9).
  /// 2026-10-27: 처음 들어올 때만 맞추며 기본은 모두 미선택이다(저장된 포함 계좌가 있으면 복원). 같은 흐름에서
  /// 12-3으로 돌아갔다 다시 와도 진행 중 선택을 유지하고 응답에 없는 계좌만 뺀다.
  void _resetAccountSelection() {
    if (_accountSelectionStarted) {
      _selectedAccounts.removeWhere(
        (id) => !accounts.any((a) => a.accountId == id),
      );
      return;
    }
    _accountSelectionStarted = true;
    _selectedAccounts
      ..clear()
      ..addAll([
        for (final a in accounts)
          if (a.included) a.accountId,
      ]);
    _reserveNoticeAccount = null;
  }

  /// 2026-10-28: 흐름 밖 쓰기(01-2 월급 설정 저장·최신 정보 불러오기)로 받은 [snapshot]을 현재 Snapshot으로 삼는다.
  /// 01-1로 돌아가 다시 저장해도 옛 자료 버전으로 보내지 않게 한다. 진행 중 선택은 응답에 있는 계좌만 남긴다.
  void adoptSnapshot(FinancialSnapshot snapshot) {
    if (_disposed) return;
    _snapshot = snapshot;
    _selectedAccounts.removeWhere(
      (id) => !accounts.any((a) => a.accountId == id),
    );
    _changed();
  }

  /// 2026-10-22: [codes]에 은행 기관이 있으면 true를 반환한다.
  bool _hasBank(Set<String> codes) =>
      institutions.any((i) => i.kind == 'bank' && codes.contains(i.code));
}
