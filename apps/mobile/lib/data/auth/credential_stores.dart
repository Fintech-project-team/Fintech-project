/// 2026-10-21: 기기에 둘 세션 정보. 토큰 원문은 보안 저장소 구현에만 넘긴다.
/// [name]은 로그인 201이 돌려준 호칭용 이름이며 소유권 판단에 쓰지 않는다.
class StoredSession {
  /// 2026-10-21: [userId]·호칭용 [name]·[sessionId]·불투명 [accessToken]으로 만든다.
  const StoredSession({
    required this.userId,
    required this.name,
    required this.sessionId,
    required this.accessToken,
  });

  final String userId;
  final String name;
  final String sessionId;
  final String accessToken;
}

/// 2026-10-21: 세션 토큰 저장 계약. 실제 보안 저장소 방식은 서버 연동·기기 시연 작업에서 정한다.
abstract interface class SessionStore {
  /// 2026-10-21: 저장된 세션을 반환한다. 없으면 null이다.
  Future<StoredSession?> read();

  /// 2026-10-21: [session]으로 덮어써 저장한다.
  Future<void> save(StoredSession session);

  /// 2026-10-21: 저장된 세션을 지운다.
  Future<void> clear();
}

/// 2026-10-21: 11-1 PIN 확인 결과. 실패 횟수는 PIN과 같은 저장소에 함께 남는다.
class PinCheckResult {
  /// 2026-10-21: 일치 여부 [matched], 누적 실패 횟수 [failures]로 만든다.
  const PinCheckResult({required this.matched, required this.failures});

  final bool matched;
  final int failures;

  /// 2026-10-21: 실패가 [maxPinFailures]회에 이르러 본인 확인 복구(09-12)가 필요하면 true를 반환한다.
  bool get recoveryRequired => failures >= maxPinFailures;
}

/// 2026-10-21: PIN 연속 실패 허용 횟수. 이 횟수에 이르면 본인 확인 복구로만 풀린다(시간으로 풀리지 않음).
/// 서버 인증 시도 제한(이름+전화번호 기준 5회/5분)과는 별개인 기기 안 규칙이다.
const int maxPinFailures = 5;

/// 2026-10-21: 기기 PIN 저장 계약. PIN 원문을 돌려주거나 읽어 오는 메서드를 두지 않는다.
/// 실패 횟수를 PIN과 함께 보관해 앱을 다시 시작해도 5회 제한이 풀리지 않게 한다.
/// 실제 구현의 보관 방식(해시·기기 보안 저장소)은 서버 연동·기기 시연 작업에서 정한다. PIN은 서버로 보내지 않는다.
abstract interface class LocalPinStore {
  /// 2026-10-21: PIN이 설정돼 있으면 true를 반환한다.
  Future<bool> hasPin();

  /// 2026-10-21: [pin]을 새 PIN으로 설정하고 실패 횟수를 0으로 되돌린다(기존 PIN 대체·복구 후 재설정).
  Future<void> setPin(String pin);

  /// 2026-10-21: [pin]을 확인해 결과를 반환한다. 맞으면 실패 횟수를 0으로, 틀리면 1 늘린다.
  /// 이미 복구가 필요한 상태면 비교하지 않고 실패로 돌려준다. PIN이 없으면 실패다.
  Future<PinCheckResult> verify(String pin);

  /// 2026-10-21: 누적 실패 횟수를 반환한다(재시작 후 11-1·09-12 표시용).
  Future<int> failureCount();

  /// 2026-10-21: 설정된 PIN과 실패 횟수를 지운다.
  Future<void> clear();
}

/// 2026-10-21: 10-1 필수 약관 동의를 기기에 기록하는 계약.
abstract interface class ConsentStore {
  /// 2026-10-21: 필수 약관에 동의한 기록이 있으면 true를 반환한다.
  Future<bool> hasAgreed();

  /// 2026-10-21: 필수 약관 동의를 기록한다.
  Future<void> saveAgreed();

  /// 2026-10-21: 동의 기록을 지운다.
  Future<void> clear();
}

/// 2026-10-21: 메모리 세션 저장소. 앱을 다시 시작하면 사라진다(재시작 후 유지는 완료 범위 밖).
class MemorySessionStore implements SessionStore {
  StoredSession? _session;

  /// 2026-10-21: 메모리의 세션을 반환한다.
  @override
  Future<StoredSession?> read() async => _session;

  /// 2026-10-21: 메모리에 [session]을 둔다.
  @override
  Future<void> save(StoredSession session) async => _session = session;

  /// 2026-10-21: 메모리의 세션을 지운다.
  @override
  Future<void> clear() async => _session = null;
}

/// 2026-10-21: 메모리 PIN 저장소. 비교만 하며 밖으로 값을 내보내지 않는다. 앱을 다시 시작하면 사라진다.
class MemoryLocalPinStore implements LocalPinStore {
  String? _pin;
  int _failures = 0;

  /// 2026-10-21: PIN 설정 여부를 반환한다.
  @override
  Future<bool> hasPin() async => _pin != null;

  /// 2026-10-21: [pin]을 메모리에 두고 실패 횟수를 지운다.
  @override
  Future<void> setPin(String pin) async {
    _pin = pin;
    _failures = 0;
  }

  /// 2026-10-21: 일치 여부와 누적 실패 횟수를 반환한다. 복구가 필요한 상태면 비교하지 않는다.
  @override
  Future<PinCheckResult> verify(String pin) async {
    if (_failures >= maxPinFailures) {
      return PinCheckResult(matched: false, failures: _failures);
    }
    if (_pin != null && _pin == pin) {
      _failures = 0;
      return const PinCheckResult(matched: true, failures: 0);
    }
    _failures++;
    return PinCheckResult(matched: false, failures: _failures);
  }

  /// 2026-10-21: 누적 실패 횟수를 반환한다.
  @override
  Future<int> failureCount() async => _failures;

  /// 2026-10-21: 메모리의 PIN과 실패 횟수를 지운다.
  @override
  Future<void> clear() async {
    _pin = null;
    _failures = 0;
  }
}

/// 2026-10-21: 메모리 약관 동의 저장소. 앱을 다시 시작하면 사라진다.
class MemoryConsentStore implements ConsentStore {
  bool _agreed = false;

  /// 2026-10-21: 동의 여부를 반환한다.
  @override
  Future<bool> hasAgreed() async => _agreed;

  /// 2026-10-21: 동의를 기록한다.
  @override
  Future<void> saveAgreed() async => _agreed = true;

  /// 2026-10-21: 동의 기록을 지운다.
  @override
  Future<void> clear() async => _agreed = false;
}
