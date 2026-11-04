import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/auth/auth_repository.dart';
import '../../data/auth/credential_stores.dart';
import '../../data/http/api_transport.dart';
import 'auth_services.dart';
import 'auth_validation.dart';

/// 2026-10-21: 10-1 필수 약관 동의 상태. 필수 항목을 모두 골라야 다음으로 갈 수 있다.
class TermsViewModel extends ChangeNotifier {
  /// 2026-10-21: 필수 항목 이름 목록 [requiredItems]로 만든다. 처음에는 모두 해제다.
  TermsViewModel(this.requiredItems)
    : _agreed = List.filled(requiredItems.length, false);

  final List<String> requiredItems;
  final List<bool> _agreed;

  /// 2026-10-21: [index] 항목의 동의 여부를 반환한다.
  bool isAgreed(int index) => _agreed[index];

  /// 2026-10-21: 필수 항목을 모두 골랐으면 true를 반환한다.
  bool get allAgreed => _agreed.every((v) => v);

  /// 2026-10-21: [index] 항목을 [value]로 바꾼다.
  void setAgreed(int index, bool value) {
    _agreed[index] = value;
    notifyListeners();
  }

  /// 2026-10-21: 모든 항목을 [value]로 바꾼다('모두 동의').
  void setAll(bool value) {
    _agreed.fillRange(0, _agreed.length, value);
    notifyListeners();
  }
}

/// 2026-10-21: 10-2 입력 오류 위치. 이름이 틀리면 이름만, 이름이 맞으면 번호만 알린다.
enum IdentityError { name, phone }

/// 2026-10-21: 10-2 합성 이름·전화번호 입력 상태. 서버로 보내지 않고 형식만 검사한다.
class IdentityViewModel extends ChangeNotifier {
  /// 2026-10-21: 이전에 통과한 입력 [initial]이 있으면 채워 둔다(같은 흐름 입력 유지).
  IdentityViewModel({IdentityDraft? initial})
    : name = TextEditingController(text: initial?.name ?? ''),
      phone = TextEditingController(text: initial?.phone ?? '') {
    name.addListener(_onEdit);
    phone.addListener(_onEdit);
  }

  final TextEditingController name;
  final TextEditingController phone;
  bool _submitted = false;
  IdentityError? _error;

  /// 2026-10-21: 현재 표시할 오류 위치를 반환한다. 제출 전에는 null이다.
  IdentityError? get error => _error;

  /// 2026-10-21: 두 칸이 모두 비어 있지 않으면 true를 반환한다.
  bool get canSubmit =>
      name.text.trim().isNotEmpty && phone.text.trim().isNotEmpty;

  /// 2026-10-21: 입력이 바뀌면 제출 이후에 한해 오류를 다시 계산한다.
  void _onEdit() {
    if (_submitted) _error = _validate().$2;
    notifyListeners();
  }

  /// 2026-10-21: 정규화한 입력과 첫 오류 위치를 반환한다.
  (IdentityDraft?, IdentityError?) _validate() {
    final n = normalizeName(name.text);
    if (!isValidName(n)) return (null, IdentityError.name);
    final p = normalizePhone(phone.text);
    if (!isValidPhone(p)) return (null, IdentityError.phone);
    return (IdentityDraft(name: n, phone: p!), null);
  }

  /// 2026-10-21: 형식을 검사해 통과하면 정규화한 입력을, 아니면 null을 반환하고 오류를 표시한다.
  IdentityDraft? submit() {
    _submitted = true;
    final (draft, error) = _validate();
    _error = error;
    notifyListeners();
    return draft;
  }

  /// 2026-10-21: 입력 controller를 폐기한다.
  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }
}

/// 2026-11-02: 인증·로그아웃 실패 안내 문구. 화면마다 같은 상황은 같은 문구를 쓴다.
const String connectionFailedMessage = '연결하지 못했어요. 잠시 후 다시 시도해주세요';
const String secureConnectionMessage =
    '보안 연결을 확인하지 못했어요. 서버 인증서 또는 이 기기의 인증서 등록 상태를 확인해 주세요.';
const String storageReadFailedMessage = '기기 정보를 읽지 못했어요. 잠시 후 다시 시도해주세요';
const String storageWriteFailedMessage = '기기에 저장하지 못했어요. 잠시 후 다시 시도해주세요';

/// 2026-10-21: 10-3 요청 상태. 입력 중·요청 중과 실패 종류를 하나의 값으로 구분한다.
/// [sessionInvalid]는 복구 중 저장된 토큰이 이미 무효라 신규 로그인으로 가야 하는 상태다(09-13).
enum CodeStatus {
  editing,
  submitting,
  rejected,
  invalidInput,
  rateLimited,
  unavailable,
  sessionInvalid,

  /// 2026-11-02: 로그인 요청을 보낸 뒤 응답을 받지 못했다. 서버에서 로그인이 처리됐을 수 있다(자동 재시도 없음).
  resultUnknown,

  /// 2026-11-02: 보안 연결(서버 인증서·기기 인증서 등록)을 확인하지 못했다.
  secureConnection,
}

/// 2026-10-21: 10-3 인증번호 입력과 표시용 3분 타이머. 실패하면 입력을 유지한다.
/// 표시 타이머와 별개로 429의 재시도 허용 시각을 두어 그 전에는 입력을 고쳐도 다시 보내지 않는다.
class CodeViewModel extends ChangeNotifier {
  /// 2026-10-21: 의존성 [services], 10-2 입력 [draft], 목적 [purpose]로 만든다. 타이머는 바로 시작한다.
  CodeViewModel({
    required this.services,
    required this.draft,
    required this.purpose,
  }) : _startedAt = services.now() {
    _shownSeconds = remaining.inSeconds;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  static const Duration displayTimer = Duration(minutes: 3);

  final AuthServices services;
  final IdentityDraft draft;
  final IdentityPurpose purpose;
  final TextEditingController code = TextEditingController();
  late final Timer _ticker;
  DateTime _startedAt;
  CodeStatus _status = CodeStatus.editing;
  DateTime? _retryAllowedAt;
  bool _disposed = false;
  int _shownSeconds = 0;
  int _shownRetrySeconds = 0;

  /// 2026-10-21: 표시 초(타이머·재시도 대기)가 바뀌거나 재시도 대기가 끝났을 때만 화면을 갱신한다.
  void _tick() {
    var changed = false;
    final seconds = remaining.inSeconds;
    if (seconds != _shownSeconds) {
      _shownSeconds = seconds;
      changed = true;
    }
    if (_status == CodeStatus.rateLimited) {
      final retrySeconds = retryRemaining.inSeconds;
      if (retryRemaining == Duration.zero) {
        _status = CodeStatus.editing;
        _retryAllowedAt = null;
        changed = true;
      } else if (retrySeconds != _shownRetrySeconds) {
        _shownRetrySeconds = retrySeconds;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 2026-10-21: 현재 요청 상태를 반환한다.
  CodeStatus get status => _status;

  /// 2026-10-21: 429 재시도 허용까지 남은 시간을 반환한다. 제한이 없으면 0이다.
  Duration get retryRemaining {
    final until = _retryAllowedAt;
    if (until == null) return Duration.zero;
    final left = until.difference(services.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 2026-10-21: 표시용 남은 시간을 반환한다. 0 아래로 내려가지 않는다.
  Duration get remaining {
    final left = displayTimer - services.now().difference(_startedAt);
    return left.isNegative ? Duration.zero : left;
  }

  /// 2026-10-21: 숫자 6자리이고, 요청 중이 아니며, 429 재시도 대기 중이 아니면 true를 반환한다.
  bool get canSubmit =>
      _status != CodeStatus.submitting &&
      _status != CodeStatus.sessionInvalid &&
      retryRemaining == Duration.zero &&
      isValidCode(code.text);

  /// 2026-10-21: 입력이 바뀌면 실패 표시를 지운다. 429 대기 중이면 제한 안내를 유지한다.
  void onEdited() {
    final waiting =
        _status == CodeStatus.rateLimited && retryRemaining > Duration.zero;
    if (_status != CodeStatus.submitting &&
        _status != CodeStatus.sessionInvalid &&
        !waiting) {
      _status = CodeStatus.editing;
    }
    notifyListeners();
  }

  /// 2026-10-21: 표시가 0:00(1초 미만)이 된 뒤에만 타이머를 3:00부터 다시 시작한다. 코드 재발급·만료는 없다.
  /// 표시(m:ss, 초 버림)와 다시 받기 활성(CodeTimerField)이 같은 경계를 쓴다.
  void resend() {
    if (remaining.inSeconds > 0) return;
    _startedAt = services.now();
    _shownSeconds = remaining.inSeconds;
    notifyListeners();
  }

  /// 2026-10-21: 세션 발급(가입) 또는 재확인(복구)을 요청한다. 성공하면 true를 반환하고 입력을 지운다.
  /// 가입 성공 시 받은 세션을 [SessionStore]에 저장한다. 다만 응답 전에 화면을 떠났으면 저장하지 않고
  /// 받은 세션을 [PendingSessionCleanup]으로 끝낸다. 종료가 확인되지 않으면 정리 담당이 토큰을 보관하고,
  /// 다음 발급 요청 전에 다시 시도한다. 복구는 저장된 토큰으로 재확인만 하며,
  /// 토큰이 이미 무효면 기기 세션·PIN을 정리하고 [CodeStatus.sessionInvalid]로 둔다(화면 생존과 무관).
  /// 2026-11-02: 복구 중 기기 세션을 읽지 못하면 서비스 불가로 알린다(재확인을 건너뛰거나 세션 없음으로 바꾸지 않음).
  /// 2026-11-01: 받은 세션을 기기에 저장하지 못하면 토큰을 잃지 않도록 정리 담당으로 서버 세션을 끝내고 연결 실패로 알린다.
  Future<bool> submit() async {
    if (!canSubmit) return false;
    _status = CodeStatus.submitting;
    notifyListeners();
    final credentials = DemoCredentials(
      name: draft.name,
      phone: draft.phone,
      code: code.text,
    );
    final AuthOutcome<Object?> outcome;
    if (purpose == IdentityPurpose.signup) {
      await services.cleanup.retryPending();
      final result = await services.repository.createSession(credentials);
      var saved = true;
      if (result case AuthOk(:final value)) {
        if (_disposed) {
          await services.cleanup.end(value.accessToken);
          return false;
        }
        try {
          await services.sessionStore.save(
            StoredSession(
              userId: value.userId,
              name: value.name,
              sessionId: value.sessionId,
              accessToken: value.accessToken,
            ),
          );
        } on Exception {
          saved = false;
          await services.cleanup.end(value.accessToken);
        }
      }
      outcome = saved ? result : const AuthUnavailable();
    } else {
      StoredSession? stored;
      var readable = true;
      try {
        stored = await services.sessionStore.read();
      } on Exception {
        readable = false;
      }
      outcome = !readable
          ? const AuthUnavailable()
          : stored == null
          ? const AuthSessionInvalid()
          : await services.repository.reverify(stored.accessToken, credentials);
      if (outcome is AuthSessionInvalid) {
        try {
          await services.sessionStore.clear();
          await services.pinStore.clear();
        } on Exception {
          // 서버가 이미 무효로 확인한 토큰이다. 남아도 다음 조회에서 다시 무효로 처리된다.
        }
      }
    }
    if (_disposed) return outcome is AuthOk;
    switch (outcome) {
      case AuthOk():
        code.clear();
        _status = CodeStatus.editing;
        notifyListeners();
        return true;
      case AuthRejected():
        _status = CodeStatus.rejected;
      case AuthInvalidInput():
        _status = CodeStatus.invalidInput;
      case AuthRateLimited(:final retryAfter):
        _retryAllowedAt = services.now().add(retryAfter);
        _shownRetrySeconds = retryAfter.inSeconds;
        _status = CodeStatus.rateLimited;
      case AuthSessionInvalid():
        _status = CodeStatus.sessionInvalid;
      case AuthUnavailable():
        _status = CodeStatus.unavailable;
      case AuthNetworkFailure(:final error):
        _status = switch (connectionProblemOf(error)) {
          ConnectionProblem.secureConnection => CodeStatus.secureConnection,
          ConnectionProblem.resultUnknown
              when purpose == IdentityPurpose.signup =>
            CodeStatus.resultUnknown,
          _ => CodeStatus.unavailable,
        };
    }
    notifyListeners();
    return false;
  }

  /// 2026-10-21: 타이머를 취소하고 입력을 폐기한다.
  @override
  void dispose() {
    _disposed = true;
    _ticker.cancel();
    code.dispose();
    super.dispose();
  }
}

/// 2026-10-21: 10-4·10-5 단계.
enum PinSetupPhase { create, confirm }

/// 2026-10-21: 10-4 PIN 만들기·10-5 확인 상태. 성공하면 [LocalPinStore]에만 저장하고 서버로 보내지 않는다.
class PinSetupViewModel extends ChangeNotifier {
  /// 2026-10-21: PIN 저장소 [pinStore]로 만든다.
  PinSetupViewModel(this.pinStore);

  static const int length = 6;

  final LocalPinStore pinStore;
  PinSetupPhase _phase = PinSetupPhase.create;
  String _entry = '';
  String? _first;
  String? _error;
  bool _completed = false;

  /// 2026-10-21: 현재 단계를 반환한다.
  PinSetupPhase get phase => _phase;

  /// 2026-10-21: 입력한 자리 수를 반환한다.
  int get filled => _entry.length;

  /// 2026-10-21: 점 아래 오류 문구를 반환한다. 없으면 null이다.
  String? get error => _error;

  /// 2026-10-21: PIN 저장까지 끝났으면 true를 반환한다.
  bool get completed => _completed;

  /// 2026-10-21: 숫자 [digit]을 더하고 6자리가 되면 단계 규칙을 적용한다.
  /// 2026-11-02: 확인 단계에서 기기에 저장하지 못하면 확인 단계에 머물며 다시 입력하게 한다(완료로 바꾸지 않음).
  Future<void> addDigit(int digit) async {
    if (_completed || _entry.length >= length) return;
    _entry += '$digit';
    if (_entry.length < length) {
      notifyListeners();
      return;
    }
    final pin = _entry;
    _entry = '';
    if (_phase == PinSetupPhase.create) {
      if (isWeakPin(pin)) {
        _error = '같은 숫자나 연속된 숫자는 쓸 수 없어요';
      } else {
        _first = pin;
        _error = null;
        _phase = PinSetupPhase.confirm;
      }
    } else if (pin == _first) {
      try {
        await pinStore.setPin(pin);
        _first = null;
        _error = null;
        _completed = true;
      } on Exception {
        _error = storageWriteFailedMessage;
      }
    } else {
      _error = '비밀번호가 일치하지 않아요. 다시 입력해주세요';
    }
    notifyListeners();
  }

  /// 2026-10-21: 마지막 자리를 지운다.
  void removeDigit() {
    if (_entry.isEmpty) return;
    _entry = _entry.substring(0, _entry.length - 1);
    notifyListeners();
  }

  /// 2026-10-21: 확인 단계에서 만들기 단계로 돌아간다. 처음 PIN을 버린다.
  void backToCreate() {
    _phase = PinSetupPhase.create;
    _first = null;
    _entry = '';
    _error = null;
    notifyListeners();
  }
}

/// 2026-10-21: 11-1 PIN 확인 상태. 실패 횟수는 [LocalPinStore]가 보관하고 이 ViewModel은 결과만 표시한다.
/// 5번 틀리면 키패드를 닫고 본인 확인 복구(09-12)를 요구하며, 앱을 다시 시작해도 그 상태가 이어진다.
class PinLoginViewModel extends ChangeNotifier {
  /// 2026-10-21: PIN 저장소 [pinStore]로 만들고 저장된 실패 횟수를 읽는다.
  PinLoginViewModel(this.pinStore) {
    _loadFailures();
  }

  static const int length = 6;
  static const int maxFailures = maxPinFailures;

  final LocalPinStore pinStore;
  String _entry = '';
  int _failures = 0;
  bool _verifying = false;
  bool _disposed = false;
  bool _storageError = false;

  /// 2026-10-21: 입력한 자리 수를 반환한다.
  int get filled => _entry.length;

  /// 2026-10-21: 저장소에 남은 누적 실패 횟수를 반환한다.
  int get failures => _failures;

  /// 2026-10-21: 5번 틀려 복구가 필요하면 true를 반환한다.
  bool get recoveryRequired => _failures >= maxFailures;

  /// 2026-11-02: 마지막 기기 저장소 읽기·확인이 실패했으면 true를 반환한다. 이때는 잠금을 풀지 않는다.
  bool get storageError => _storageError;

  /// 2026-10-21: 저장된 실패 횟수를 읽어 표시에 반영한다.
  /// 2026-11-02: 읽지 못하면 실패 횟수를 0으로 보지 않고 저장소 오류로 표시한다(다음 확인에서 저장소가 횟수를 다시 검사).
  Future<void> _loadFailures() async {
    try {
      final count = await pinStore.failureCount();
      if (_disposed) return;
      _failures = count;
    } on Exception {
      if (_disposed) return;
      _storageError = true;
    }
    notifyListeners();
  }

  /// 2026-10-21: 숫자 [digit]을 더하고 6자리가 되면 저장소로 확인한다. 맞으면 true를 반환한다.
  /// 2026-11-02: 저장소가 확인하지 못하면 맞지 않은 것으로 보고 잠금을 풀지 않는다.
  Future<bool> addDigit(int digit) async {
    if (recoveryRequired || _verifying || _entry.length >= length) return false;
    _entry += '$digit';
    if (_entry.length < length) {
      notifyListeners();
      return false;
    }
    _verifying = true;
    final PinCheckResult result;
    try {
      result = await pinStore.verify(_entry);
    } on Exception {
      _verifying = false;
      _entry = '';
      if (_disposed) return false;
      _storageError = true;
      notifyListeners();
      return false;
    }
    _verifying = false;
    _entry = '';
    if (_disposed) return result.matched;
    _storageError = false;
    _failures = result.failures;
    notifyListeners();
    return result.matched;
  }

  /// 2026-10-21: 마지막 자리를 지운다.
  void removeDigit() {
    if (_entry.isEmpty) return;
    _entry = _entry.substring(0, _entry.length - 1);
    notifyListeners();
  }

  /// 2026-10-21: 폐기 표시 후 정리한다. 늦게 끝난 저장소 응답을 반영하지 않는다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 2026-11-04: 앱 비밀번호 바꾸기 단계(#213). 지금 비밀번호 확인 → 새 비밀번호 → 한 번 더.
enum PinChangePhase { current, create, confirm }

/// 2026-11-04: 내 정보의 앱 비밀번호 바꾸기 상태(#213). 지금 비밀번호 틀림은 잠금 해제와 같은 실패 횟수([LocalPinStore])를
/// 쓰고, 5번이면 본인 확인 복구를 요구한다. 새 비밀번호는 처음 만들 때와 같은 규칙에 더해 지금 비밀번호와 같으면 거절한다.
/// 기기에만 저장하고 서버로 보내지 않는다.
class PinChangeViewModel extends ChangeNotifier {
  /// 2026-11-04: PIN 저장소 [pinStore]로 만들고 저장된 실패 횟수를 읽는다.
  PinChangeViewModel(this.pinStore) {
    _loadFailures();
  }

  static const int length = 6;

  final LocalPinStore pinStore;
  PinChangePhase _phase = PinChangePhase.current;
  String _entry = '';
  String? _current;
  String? _first;
  String? _error;
  int _failures = 0;
  bool _busy = false;
  bool _completed = false;
  bool _disposed = false;

  /// 2026-11-04: 현재 단계를 반환한다.
  PinChangePhase get phase => _phase;

  /// 2026-11-04: 입력한 자리 수를 반환한다.
  int get filled => _entry.length;

  /// 2026-11-04: 점 아래 오류 문구를 반환한다. 없으면 null이다.
  String? get error => _error;

  /// 2026-11-04: 지금 비밀번호 누적 실패 횟수를 반환한다.
  int get failures => _failures;

  /// 2026-11-04: 5번 틀려 본인 확인 복구가 필요하면 true를 반환한다.
  bool get recoveryRequired => _failures >= maxPinFailures;

  /// 2026-11-04: 새 비밀번호 저장까지 끝났으면 true를 반환한다.
  bool get completed => _completed;

  /// 2026-11-04: 저장된 실패 횟수를 읽는다. 읽지 못하면 저장소 오류 문구를 보인다.
  Future<void> _loadFailures() async {
    try {
      final count = await pinStore.failureCount();
      if (_disposed) return;
      _failures = count;
      if (recoveryRequired) _error = '비밀번호를 $maxPinFailures번 틀렸어요';
    } on Exception {
      if (_disposed) return;
      _error = storageReadFailedMessage;
    }
    notifyListeners();
  }

  /// 2026-11-04: 숫자 [digit]을 더하고 6자리가 되면 단계 규칙을 적용한다.
  Future<void> addDigit(int digit) async {
    if (_completed || _busy || recoveryRequired || _entry.length >= length) {
      return;
    }
    _entry += '$digit';
    if (_entry.length < length) {
      notifyListeners();
      return;
    }
    final pin = _entry;
    _entry = '';
    switch (_phase) {
      case PinChangePhase.current:
        await _checkCurrent(pin);
      case PinChangePhase.create:
        if (isWeakPin(pin)) {
          _error = '같은 숫자나 연속된 숫자는 쓸 수 없어요';
        } else if (pin == _current) {
          _error = '지금 쓰는 비밀번호와 다르게 만들어주세요';
        } else {
          _first = pin;
          _error = null;
          _phase = PinChangePhase.confirm;
        }
      case PinChangePhase.confirm:
        await _save(pin);
    }
    if (!_disposed) notifyListeners();
  }

  /// 2026-11-04: 지금 비밀번호 [pin]을 저장소로 확인한다. 맞으면 새 비밀번호 단계로 간다.
  Future<void> _checkCurrent(String pin) async {
    _busy = true;
    try {
      final result = await pinStore.verify(pin);
      if (_disposed) return;
      _failures = result.failures;
      if (result.matched) {
        _current = pin;
        _error = null;
        _phase = PinChangePhase.create;
      } else if (result.recoveryRequired) {
        _error = '비밀번호를 $maxPinFailures번 틀렸어요';
      } else {
        _error = '비밀번호가 맞지 않아요 ($_failures/$maxPinFailures)';
      }
    } on Exception {
      if (_disposed) return;
      _error = storageReadFailedMessage;
    } finally {
      _busy = false;
    }
  }

  /// 2026-11-04: 확인 입력 [pin]이 새 비밀번호와 같으면 저장한다. 다르면 새 비밀번호부터 다시 입력한다.
  Future<void> _save(String pin) async {
    if (pin != _first) {
      _first = null;
      _phase = PinChangePhase.create;
      _error = '비밀번호가 일치하지 않아요. 다시 입력해주세요';
      return;
    }
    _busy = true;
    try {
      await pinStore.setPin(pin);
      if (_disposed) return;
      _current = null;
      _first = null;
      _error = null;
      _completed = true;
    } on Exception {
      if (_disposed) return;
      _error = storageWriteFailedMessage;
    } finally {
      _busy = false;
    }
  }

  /// 2026-11-04: 마지막 자리를 지운다.
  void removeDigit() {
    if (_entry.isEmpty) return;
    _entry = _entry.substring(0, _entry.length - 1);
    notifyListeners();
  }

  /// 2026-11-04: 한 단계 뒤로 간다. 한 번 더 → 새 비밀번호, 새 비밀번호 → 지금 비밀번호(다시 확인). 지금 비밀번호 단계면
  /// false를 반환해 화면을 닫게 한다.
  bool back() {
    if (_busy) return true;
    switch (_phase) {
      case PinChangePhase.current:
        return false;
      case PinChangePhase.create:
        _current = null;
        _phase = PinChangePhase.current;
      case PinChangePhase.confirm:
        _first = null;
        _phase = PinChangePhase.create;
    }
    _entry = '';
    _error = null;
    notifyListeners();
    return true;
  }

  /// 2026-11-04: 폐기 표시 후 정리한다. 늦게 끝난 저장소 응답을 반영하지 않는다.
  @override
  void dispose() {
    _disposed = true;
    _current = null;
    _first = null;
    super.dispose();
  }
}
