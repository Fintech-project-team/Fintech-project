import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/http_auth_repository.dart';
import 'package:payse/data/http/api_transport.dart';

import '../http/fake_api_transport.dart';

const _credentials = DemoCredentials(
  name: '테스트',
  phone: '01000000000',
  code: '000000',
);

Map<String, Object?> _created() => {
  'userId': 'u1',
  'name': '테스트',
  'sessionId': 's1',
  'accessToken': 'token-1',
  'tokenType': 'Bearer',
  'issuedAt': '2026-11-01T00:00:00Z',
};

void main() {
  late FakeApiTransport transport;
  late HttpAuthRepository repo;

  setUp(() {
    transport = FakeApiTransport((_) => jsonResponse(201, _created()));
    repo = HttpAuthRepository(config: testApiConfig, transport: transport);
  });

  test('login posts the credentials once and returns the session', () async {
    final result = await repo.createSession(_credentials);
    final session = (result as AuthOk<DemoSession>).value;
    expect((session.userId, session.accessToken), ('u1', 'token-1'));
    final sent = transport.requests.single;
    expect(sent.method, 'POST');
    expect(sent.uri.toString(), 'https://payse.test/api/demo-sessions');
    expect(jsonDecode(jsonEncode(sent.body)), {
      'name': '테스트',
      'phone': '01000000000',
      'code': '000000',
    });
  });

  test('a lost login response is not retried and is not a rejection', () async {
    transport.handler = (_) =>
        throw ApiTransportException(ApiFailureKind.unknown, 'timeout');
    final result = await repo.createSession(_credentials);
    expect(transport.requests, hasLength(1), reason: '로그인 POST는 자동 재시도하지 않는다');
    final failure = result as AuthNetworkFailure<DemoSession>;
    expect(
      (failure.error as ApiTransportException).kind,
      ApiFailureKind.unknown,
    );
  });

  test('error envelopes map to the auth outcomes', () async {
    final cases = <(ApiResponse, Type)>[
      (errorResponse(401, 'AUTH_REJECTED'), AuthRejected<DemoSession>),
      (errorResponse(401, 'SESSION_INVALID'), AuthSessionInvalid<DemoSession>),
      (errorResponse(422, 'VALIDATION_FAILED'), AuthInvalidInput<DemoSession>),
      (
        errorResponse(503, 'TEMPORARILY_UNAVAILABLE'),
        AuthUnavailable<DemoSession>,
      ),
      (errorResponse(429, 'RATE_LIMITED'), AuthUnavailable<DemoSession>),
      (plainResponse(403), AuthNetworkFailure<DemoSession>),
      (plainResponse(502), AuthUnavailable<DemoSession>),
    ];
    for (final (response, type) in cases) {
      transport.handler = (_) => response;
      expect((await repo.createSession(_credentials)).runtimeType, type);
    }
    transport.handler = (_) =>
        errorResponse(429, 'RATE_LIMITED', headers: {'retry-after': '120'});
    final limited = await repo.createSession(_credentials);
    expect(
      (limited as AuthRateLimited).retryAfter,
      const Duration(seconds: 120),
    );
  });

  test('a malformed 201 is not a session', () async {
    transport.handler = (_) =>
        jsonResponse(201, {..._created(), 'tokenType': 'Basic'});
    expect(
      await repo.createSession(_credentials),
      isA<AuthUnavailable<DemoSession>>(),
    );
  });

  test(
    'logout succeeds only on 204; a send failure keeps it unconfirmed',
    () async {
      transport.handler = (_) =>
          const ApiResponse(status: 204, headers: {}, body: '');
      expect(await repo.endSession('token-1'), isA<AuthOk<void>>());
      expect(
        transport.requests.last.headers['authorization'],
        'Bearer token-1',
      );
      expect(transport.requests.last.method, 'DELETE');

      transport.handler = (_) =>
          throw ApiTransportException(ApiFailureKind.notSent, 'down');
      expect(await repo.endSession('token-1'), isA<AuthNetworkFailure<void>>());
      transport.handler = (_) => errorResponse(401, 'SESSION_INVALID');
      expect(await repo.endSession('token-1'), isA<AuthSessionInvalid<void>>());
    },
  );

  test('reverify sends the bearer token and gets no new token', () async {
    transport.handler = (_) => jsonResponse(200, {
      'userId': 'u1',
      'sessionId': 's1',
      'verified': true,
    });
    final result = await repo.reverify('token-1', _credentials);
    expect((result as AuthOk<ReverifiedSession>).value.sessionId, 's1');
    expect(
      transport.requests.single.uri.path,
      '/api/demo-sessions/current/reverify',
    );
    expect(
      transport.requests.single.headers['authorization'],
      'Bearer token-1',
    );
  });
}
