/// 2026-10-21: 10-3 인증번호 단계에서 서버로 보내는 합성 자격. 요청이 끝나면 버리고 저장하지 않는다.
class DemoCredentials {
  /// 2026-10-21: 정규화한 이름 [name], 하이픈·공백을 뺀 [phone], 숫자 6자리 [code]로 만든다.
  const DemoCredentials({
    required this.name,
    required this.phone,
    required this.code,
  });

  final String name;
  final String phone;
  final String code;
}

/// 2026-10-21: POST /demo-sessions 201 응답(api-contract §2). 토큰 원문은 이 응답에서만 받는다.
/// [name]은 검증된 계정의 저장 이름으로 인증 이름과 호칭의 공통 값이다(제출 문자열이 아님). 소유권은 userId로 판단한다.
class DemoSession {
  /// 2026-10-21: 응답의 [userId]·[name]·[sessionId]·[accessToken]·[issuedAt]으로 만든다. tokenType은 항상 Bearer다.
  const DemoSession({
    required this.userId,
    required this.name,
    required this.sessionId,
    required this.accessToken,
    required this.issuedAt,
  });

  final String userId;
  final String name;
  final String sessionId;
  final String accessToken;
  final DateTime issuedAt;
}

/// 2026-10-21: POST /demo-sessions/current/reverify 200 응답. 새 토큰을 주지 않는다.
class ReverifiedSession {
  /// 2026-10-21: 재확인한 현재 세션의 [userId]·[sessionId]로 만든다.
  const ReverifiedSession({required this.userId, required this.sessionId});

  final String userId;
  final String sessionId;
}

/// 2026-10-21: 인증 요청 결과. 성공과 실패 종류를 하나의 타입으로 겹치지 않게 구분한다.
sealed class AuthOutcome<T> {
  /// 2026-10-21: 하위 결과 타입만 만든다.
  const AuthOutcome();
}

/// 2026-10-21: 요청 성공. [value]는 응답 값이다.
final class AuthOk<T> extends AuthOutcome<T> {
  /// 2026-10-21: 응답 [value]로 만든다.
  const AuthOk(this.value);

  final T value;
}

/// 2026-10-21: 401 AUTH_REJECTED. 자격 불일치·사용 중 계정·비활성 계정을 구분하지 않는다(09-11).
final class AuthRejected<T> extends AuthOutcome<T> {
  /// 2026-10-21: 이유를 담지 않는 거절 결과를 만든다.
  const AuthRejected();
}

/// 2026-10-21: 401 SESSION_INVALID. 보낸 토큰이 이미 무효(운영 종료·소실)다. 자격 거절과 다르게
/// 기기 세션을 정리하고 10-2 식별 입력부터 신규 로그인으로 보낸다(09-13).
final class AuthSessionInvalid<T> extends AuthOutcome<T> {
  /// 2026-10-21: 무효 세션 결과를 만든다.
  const AuthSessionInvalid();
}

/// 2026-10-21: 429 시도 제한. [retryAfter]는 Retry-After 초를 옮긴 대기 시간이다.
final class AuthRateLimited<T> extends AuthOutcome<T> {
  /// 2026-10-21: 대기 시간 [retryAfter]로 만든다.
  const AuthRateLimited(this.retryAfter);

  final Duration retryAfter;
}

/// 2026-10-21: 422 형식 오류. 서버는 입력값을 응답에 넣지 않으므로 이유를 담지 않는다.
final class AuthInvalidInput<T> extends AuthOutcome<T> {
  /// 2026-10-21: 형식 오류 결과를 만든다.
  const AuthInvalidInput();
}

/// 2026-10-21: 503 등 서비스 불가. 인증 성공으로 바꾸지 않는다.
final class AuthUnavailable<T> extends AuthOutcome<T> {
  /// 2026-10-21: 서비스 불가 결과를 만든다.
  const AuthUnavailable();
}

/// 2026-10-21: 응답을 받지 못한 연결 실패. [error]는 원인이다.
final class AuthNetworkFailure<T> extends AuthOutcome<T> {
  /// 2026-10-21: 원인 [error]로 만든다.
  const AuthNetworkFailure(this.error);

  final Object error;
}

/// 2026-10-21: 데모 세션 인증 계약(api-contract §2). 가짜 구현과 실제 API 구현이 같은 의미를 지킨다.
/// 화면·ViewModel은 이 인터페이스만 쓰고 예외 대신 [AuthOutcome]을 받는다.
abstract interface class AuthRepository {
  /// 2026-10-21: POST /demo-sessions. [credentials](name·phone·code)로 세션 발급을 요청한다.
  Future<AuthOutcome<DemoSession>> createSession(DemoCredentials credentials);

  /// 2026-10-21: POST /demo-sessions/current/reverify. 유효한 [accessToken]의 소유자가 [credentials]와
  /// 맞는지 확인한다. 새 세션·토큰을 발급하지 않는다(PIN 분실·5회 오류 복구, C01).
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  );

  /// 2026-10-21: DELETE /demo-sessions/current. [accessToken] 세션을 끝낸다. 이미 무효인 토큰은 [AuthSessionInvalid]로 돌려준다.
  Future<AuthOutcome<void>> endSession(String accessToken);
}

/// 2026-10-21: 실제 서버가 없는 빌드에서 쓰는 구현. 모든 요청을 서비스 불가로 돌려준다.
class UnavailableAuthRepository implements AuthRepository {
  /// 2026-10-21: 상태 없는 인스턴스를 만든다.
  const UnavailableAuthRepository();

  /// 2026-10-21: 세션을 만들지 않고 서비스 불가를 반환한다.
  @override
  Future<AuthOutcome<DemoSession>> createSession(
    DemoCredentials credentials,
  ) async => const AuthUnavailable();

  /// 2026-10-21: 재확인하지 않고 서비스 불가를 반환한다.
  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  ) async => const AuthUnavailable();

  /// 2026-10-21: 종료하지 않고 서비스 불가를 반환한다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) async =>
      const AuthUnavailable();
}
