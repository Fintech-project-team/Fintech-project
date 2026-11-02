/// 2026-11-01: 실제 PAYSE 서버 연결 설정. 빌드할 때 --dart-define으로만 받으며 앱 안에서 바꾸지 않는다.
/// 주소를 주지 않으면 실제 서버 모드가 아니다. 값이 있는데 형식이 틀리면 조용히 가짜 서버로 바꾸지 않고 [ApiConfigException]으로 실패한다.
class ApiConfig {
  /// 2026-11-01: 검증을 마친 주소 [baseUri]와 요청 제한 시간 [timeout]으로 만든다.
  const ApiConfig._(this.baseUri, this.timeout);

  /// 2026-11-01: 서버 주소. https 스킴·호스트만 허용하고 배포 prefix 경로는 그대로 둔다(끝 '/'는 뺀다).
  final Uri baseUri;

  /// 2026-11-01: 요청 하나의 연결부터 응답 본문까지 기다리는 최대 시간. 서버 계약에 정해진 값이 없어 빌드할 때 받는다.
  final Duration timeout;

  static const String baseUrlKey = 'PAYSE_API_BASE_URL';
  static const String timeoutKey = 'PAYSE_API_TIMEOUT_SECONDS';

  /// 2026-11-01: 빌드 설정에서 읽는다. 주소가 비었으면 null(실제 서버 모드 아님)이다.
  static ApiConfig? fromEnvironment() => parse(
    baseUrl: const String.fromEnvironment(baseUrlKey),
    timeoutSeconds: const String.fromEnvironment(timeoutKey),
  );

  /// 2026-11-01: 주소 [baseUrl]과 제한 시간 초 [timeoutSeconds](1~600 정수)를 검사한다. 주소가 비었으면 null을 반환한다.
  /// 주소가 있는데 https 아님·호스트 없음·사용자 정보·쿼리·조각이 있거나 제한 시간이 없거나 범위 밖이면 [ApiConfigException]이다.
  static ApiConfig? parse({
    required String baseUrl,
    required String timeoutSeconds,
  }) {
    if (baseUrl.isEmpty) return null;
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ApiConfigException('$baseUrlKey는 쿼리·조각 없는 https 주소여야 함');
    }
    final seconds = int.tryParse(timeoutSeconds);
    if (seconds == null || seconds < 1 || seconds > 600) {
      throw const ApiConfigException('$timeoutKey는 1~600 사이 정수 초여야 함');
    }
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return ApiConfig._(uri.replace(path: path), Duration(seconds: seconds));
  }

  /// 2026-11-01: 계약 경로 [path]('/'로 시작)를 배포 prefix 뒤에 붙인 요청 주소를 반환한다. [query]는 그대로 인코딩한다.
  Uri resolve(String path, [Map<String, String>? query]) =>
      baseUri.replace(path: '${baseUri.path}$path', queryParameters: query);
}

/// 2026-11-01: 실제 서버 설정이 잘못됐다. 앱 시작 시 드러내며 가짜 서버로 대체하지 않는다.
class ApiConfigException implements Exception {
  /// 2026-11-01: 원인 [message]로 만든다. 설정 값 자체는 담지 않는다.
  const ApiConfigException(this.message);

  final String message;

  /// 2026-11-01: 원인 문장을 반환한다.
  @override
  String toString() => 'ApiConfigException: $message';
}
