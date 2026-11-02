import 'dart:convert';

/// 2026-11-01: 서버로 보낼 요청 하나. 인증·금융 저장소가 만들고 통신 구현은 내용을 해석하지 않는다.
class ApiRequest {
  /// 2026-11-01: HTTP [method], 전체 주소 [uri], 헤더 [headers], JSON 본문 [body](없으면 null)로 만든다.
  const ApiRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;
}

/// 2026-11-01: 받은 응답. [headers]의 이름은 소문자다. 상태 코드와 무관하게 본문을 그대로 담는다.
class ApiResponse {
  /// 2026-11-01: 상태 [status], 소문자 이름 헤더 [headers], UTF-8 본문 [body]로 만든다.
  const ApiResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, String> headers;
  final String body;

  /// 2026-11-01: 본문이 JSON 객체면 그 Map을, 아니면 null을 반환한다. 프록시의 비JSON 응답을 업무 응답과 가른다.
  Map<String, Object?>? get jsonObject {
    if (!(headers['content-type'] ?? '').contains('json')) return null;
    try {
      final value = jsonDecode(body);
      return value is Map ? value.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  /// 2026-11-01: 오류 봉투 {error:{code}}의 code를 반환한다(docs/api-contract.md §6). 봉투가 아니면 null이다.
  String? get errorCode {
    final error = jsonObject?['error'];
    if (error is! Map) return null;
    final code = error['code'];
    return code is String ? code : null;
  }
}

/// 2026-11-01: 응답을 받지 못한 통신 실패의 종류.
enum ApiFailureKind {
  /// 2026-11-01: 서버에 닿기 전 실패(주소·연결 거절). 서버 상태는 바뀌지 않았다.
  notSent,

  /// 2026-11-01: TLS 협상 실패(서버 인증서 검증 실패·클라이언트 인증서 거절 포함). 업무 요청은 처리되지 않았다.
  tls,

  /// 2026-11-01: 요청을 보낸 뒤 응답을 받지 못했다(제한 시간·연결 끊김). 서버가 처리했는지 알 수 없다.
  unknown,
}

/// 2026-11-01: 응답을 받지 못한 통신 실패. 업무 오류(서버 오류 봉투)와 섞지 않는다.
class ApiTransportException implements Exception {
  /// 2026-11-01: 실패 종류 [kind]와 원인 [cause]로 만든다.
  const ApiTransportException(this.kind, this.cause);

  final ApiFailureKind kind;
  final Object cause;

  /// 2026-11-01: 종류와 원인 형식을 반환한다(토큰·본문은 담지 않음).
  @override
  String toString() =>
      'ApiTransportException(${kind.name}, ${cause.runtimeType})';
}

/// 2026-11-02: 응답을 받지 못했거나 업무 응답이 아닌 실패를 화면 안내용으로 나눈 종류.
enum ConnectionProblem {
  /// 2026-11-02: TLS 협상 실패·프록시 거절·기기 인증서 없음. 인터넷이 아니라 인증서 등록·서버 인증서를 확인해야 한다.
  secureConnection,

  /// 2026-11-02: 요청을 보낸 뒤 응답을 받지 못했다. 서버가 처리했을 수 있다.
  resultUnknown,

  /// 2026-11-02: 서버에 닿기 전 실패(주소·연결 거절).
  network,
}

/// 2026-11-02: 통신 실패 원인 [error]의 종류를 반환한다. 통신 계층이 아닌 원인은 [ConnectionProblem.network]로 본다.
/// 업무 JSON이 아닌 응답은 프록시의 인증서 거절(403)만 보안 연결 문제로 본다.
ConnectionProblem connectionProblemOf(Object error) => switch (error) {
  ApiTransportException(kind: ApiFailureKind.tls) ||
  ApiNonContractResponse(status: 403) => ConnectionProblem.secureConnection,
  ApiTransportException(kind: ApiFailureKind.unknown) =>
    ConnectionProblem.resultUnknown,
  _ => ConnectionProblem.network,
};

/// 2026-11-01: 업무 JSON이 아닌 응답(예: 등록 인증서가 아니어서 프록시가 돌려준 403). 계정·금융 오류로 해석하지 않는다.
class ApiNonContractResponse implements Exception {
  /// 2026-11-01: 받은 상태 [status]로 만든다.
  const ApiNonContractResponse(this.status);

  final int status;

  /// 2026-11-01: 상태를 담은 설명을 반환한다.
  @override
  String toString() => 'ApiNonContractResponse($status)';
}

/// 2026-11-01: 요청을 보내고 응답을 받는 통신 경계. 실제 서버는 기기 인증서(mTLS)를 요구하므로 Android 네이티브 구현
/// [DeviceTlsTransport]를 쓰고, 테스트는 가짜 구현을 쓴다. 응답을 받지 못하면 [ApiTransportException]을 던지고, 받은 응답은 상태와 무관하게 돌려준다.
abstract interface class ApiTransport {
  /// 2026-11-01: [request]를 보내 응답을 반환한다.
  Future<ApiResponse> send(ApiRequest request);
}
