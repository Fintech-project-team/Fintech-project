import '../http/api_config.dart';
import '../http/api_transport.dart';
import 'auth_repository.dart';

/// 2026-11-01: 실제 서버의 데모 세션 인증(docs/api-contract.md §2). 요청은 한 번만 보내며 자동 재시도하지 않는다.
/// 서버는 기존 세션 유지·새 로그인 거절·자동 만료 없음이므로, 로그인 응답을 받지 못하면 토큰을 잃었을 수 있다
/// ([AuthNetworkFailure]의 error가 [ApiFailureKind.unknown]). 이를 성공이나 자격 거절로 바꾸지 않는다.
class HttpAuthRepository implements AuthRepository {
  /// 2026-11-01: 서버 설정 [config]와 통신 [transport]로 만든다.
  const HttpAuthRepository({required this.config, required this.transport});

  final ApiConfig config;
  final ApiTransport transport;

  /// 2026-11-01: POST /demo-sessions. 201이면 세션을, 아니면 실패 종류를 반환한다.
  @override
  Future<AuthOutcome<DemoSession>> createSession(DemoCredentials credentials) =>
      _send(
        ApiRequest(
          method: 'POST',
          uri: config.resolve('/demo-sessions'),
          body: _credentials(credentials),
        ),
        201,
        (json) {
          if (json['tokenType'] != 'Bearer') return null;
          final userId = json['userId'];
          final name = json['name'];
          final sessionId = json['sessionId'];
          final token = json['accessToken'];
          final issuedAt = DateTime.tryParse('${json['issuedAt']}');
          if (userId is! String ||
              name is! String ||
              name.isEmpty ||
              sessionId is! String ||
              token is! String ||
              token.isEmpty ||
              issuedAt == null) {
            return null;
          }
          return DemoSession(
            userId: userId,
            name: name,
            sessionId: sessionId,
            accessToken: token,
            issuedAt: issuedAt,
          );
        },
      );

  /// 2026-11-01: POST /demo-sessions/current/reverify. 새 토큰을 받지 않는다.
  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  ) => _send(
    ApiRequest(
      method: 'POST',
      uri: config.resolve('/demo-sessions/current/reverify'),
      headers: _bearer(accessToken),
      body: _credentials(credentials),
    ),
    200,
    (json) {
      final userId = json['userId'];
      final sessionId = json['sessionId'];
      if (json['verified'] != true ||
          userId is! String ||
          sessionId is! String) {
        return null;
      }
      return ReverifiedSession(userId: userId, sessionId: sessionId);
    },
  );

  /// 2026-11-01: DELETE /demo-sessions/current. 204만 종료 성공이다. 이미 무효인 토큰은 [AuthSessionInvalid]다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) => _send(
    ApiRequest(
      method: 'DELETE',
      uri: config.resolve('/demo-sessions/current'),
      headers: _bearer(accessToken),
    ),
    204,
    null,
  );

  /// 2026-11-01: [request]를 한 번 보내 [expected] 상태면 [parse]로 값을 읽는다([parse]가 null이면 본문 없는 성공).
  /// 형식이 틀린 성공 응답은 서비스 불가로, 업무 JSON이 아닌 응답과 통신 실패는 [AuthNetworkFailure]로 돌려준다.
  /// 2026-11-02: 업무 JSON이 아닌 5xx(프록시 뒤 API 중단 등)는 인증서 문제가 아니므로 서비스 불가로 돌려준다.
  Future<AuthOutcome<T>> _send<T>(
    ApiRequest request,
    int expected,
    T? Function(Map<String, Object?> json)? parse,
  ) async {
    final ApiResponse response;
    try {
      response = await transport.send(request);
    } on ApiTransportException catch (error) {
      return AuthNetworkFailure(error);
    }
    if (response.status == expected) {
      if (parse == null) return AuthOk<T>(null as T);
      final json = response.jsonObject;
      final value = json == null ? null : parse(json);
      return value == null ? const AuthUnavailable() : AuthOk(value);
    }
    final code = response.errorCode;
    if (code == null) {
      return response.status >= 500
          ? AuthUnavailable<T>()
          : AuthNetworkFailure(ApiNonContractResponse(response.status));
    }
    return switch ((response.status, code)) {
      (401, 'AUTH_REJECTED') => AuthRejected<T>(),
      (401, 'SESSION_INVALID') => AuthSessionInvalid<T>(),
      (422, _) => AuthInvalidInput<T>(),
      (429, _) => switch (int.tryParse(response.headers['retry-after'] ?? '')) {
        final seconds? when seconds >= 0 => AuthRateLimited<T>(
          Duration(seconds: seconds),
        ),
        _ => AuthUnavailable<T>(),
      },
      _ => AuthUnavailable<T>(),
    };
  }

  /// 2026-11-01: 인증 본문(name·phone·code)을 반환한다. 서버로 보낸 뒤 앱이 보관하지 않는다.
  static Map<String, Object?> _credentials(DemoCredentials c) => {
    'name': c.name,
    'phone': c.phone,
    'code': c.code,
  };

  /// 2026-11-01: Bearer 인증 헤더를 반환한다.
  static Map<String, String> _bearer(String accessToken) => {
    'authorization': 'Bearer $accessToken',
  };
}
