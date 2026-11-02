import 'dart:async';
import 'dart:convert';

import 'package:payse/data/http/api_config.dart';
import 'package:payse/data/http/api_transport.dart';

/// 2026-11-01: 테스트용 서버 설정(형식 설명용 주소이며 실제 서버가 아님).
final ApiConfig testApiConfig = ApiConfig.parse(
  baseUrl: 'https://payse.test/api',
  timeoutSeconds: '10',
)!;

/// 2026-11-01: 받은 요청을 남기고 [handler]로 응답을 정하는 가짜 통신. [handler]가 던지면 그대로 던진다.
class FakeApiTransport implements ApiTransport {
  /// 2026-11-01: 응답 함수 [handler]로 만든다.
  FakeApiTransport(this.handler);

  FutureOr<ApiResponse> Function(ApiRequest request) handler;
  final List<ApiRequest> requests = [];

  /// 2026-11-01: 요청을 남기고 [handler]의 응답을 돌려준다.
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

/// 2026-11-01: JSON 응답을 만든다.
ApiResponse jsonResponse(
  int status,
  Object? body, {
  Map<String, String>? headers,
}) => ApiResponse(
  status: status,
  headers: {'content-type': 'application/json', ...?headers},
  body: jsonEncode(body),
);

/// 2026-11-01: 오류 봉투 응답을 만든다(docs/api-contract.md §6).
ApiResponse errorResponse(
  int status,
  String code, {
  Map<String, String>? headers,
}) => jsonResponse(status, {
  'error': {'code': code, 'message': 'x', 'requestId': 'r', 'details': []},
}, headers: headers);

/// 2026-11-01: 업무 JSON이 아닌 응답(프록시 거절 등)을 만든다.
ApiResponse plainResponse(int status) => ApiResponse(
  status: status,
  headers: const {'content-type': 'text/plain'},
  body: 'Forbidden',
);
