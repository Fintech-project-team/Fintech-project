import '../http/api_config.dart';
import '../http/api_transport.dart';

/// 2026-11-05: 서버 분석 작업 진행(apps/api/contracts/analysis-http.schema.json jobResponse.state).
enum AnalysisJobState {
  queued,
  awaitingInput,
  running,
  succeeded,
  failed,
  outcomeUnknown,
  cancelled,
  expired,
}

/// 2026-11-05: 서버가 알려 준 다음 동작(jobResponse.action).
enum AnalysisJobAction {
  wait,
  submitInput,
  readResult,
  retry,
  refreshInput,
  none,
}

/// 2026-11-05: 결과의 현재 사용 자격(resultAvailability). 작업 성공과 따로 확인한다.
enum AnalysisAvailability {
  unchecked,
  available,
  partial,
  missing,
  inactive,
  stale,
  expired,
  deleted,
}

/// 2026-11-05: 작업 상태 응답. 계약에 없는 값이나 필수 필드 누락은 [fromJson]이 null을 돌려 형식 오류로 본다.
final class AnalysisJobStatus {
  /// 2026-11-05: 대표 작업 [jobId], 상태 [state], 다음 동작 [action], 결과 자격 [availability], 제출 허가 [permit]
  /// (submitInput일 때만), 결과 불명 재시도에 사용자 동의가 필요한지 [retryNeedsAcknowledgement]로 만든다.
  const AnalysisJobStatus({
    required this.jobId,
    required this.state,
    required this.action,
    required this.availability,
    this.permit,
    this.retryNeedsAcknowledgement = false,
  });

  final String jobId;
  final AnalysisJobState state;
  final AnalysisJobAction action;
  final AnalysisAvailability availability;
  final String? permit;
  final bool retryNeedsAcknowledgement;

  /// 2026-11-05: jobResponse JSON [json]을 읽는다. 계약 버전·열거값이 다르면 null이다.
  static AnalysisJobStatus? fromJson(Map<String, Object?> json) {
    if (json['contractVersion'] != _contract) return null;
    final jobId = json['jobId'];
    final state = _enum(AnalysisJobState.values, json['state']);
    final action = _enum(AnalysisJobAction.values, json['action']);
    final availability = _enum(
      AnalysisAvailability.values,
      json['resultAvailability'],
    );
    final permit = json['permit'];
    final review = json['review'];
    if (jobId is! String ||
        state == null ||
        action == null ||
        availability == null ||
        (permit != null && permit is! String) ||
        (review != null && review is! Map)) {
      return null;
    }
    if (action == AnalysisJobAction.submitInput && permit == null) return null;
    final ack = review is Map ? review['retryRequiresAcknowledgement'] : false;
    if (ack is! bool) return null;
    return AnalysisJobStatus(
      jobId: jobId,
      state: state,
      action: action,
      availability: availability,
      permit: permit as String?,
      retryNeedsAcknowledgement: ack,
    );
  }
}

/// 2026-11-05: 결과 조회 응답(queryResponse)의 현재 사용 자격. 해석 본문은 이 단계에서 화면에 쓰지 않는다.
final class AnalysisQueryResult {
  /// 2026-11-05: 결과 자격 [availability]로 만든다.
  const AnalysisQueryResult(this.availability);

  final AnalysisAvailability availability;

  /// 2026-11-05: queryResponse JSON [json]을 읽는다. 계약 버전·자격 값이 다르면 null이다.
  static AnalysisQueryResult? fromJson(Map<String, Object?> json) {
    if (json['contractVersion'] != _contract || json['context'] is! Map) {
      return null;
    }
    final availability = _enum(
      AnalysisAvailability.values,
      json['resultAvailability'],
    );
    return availability == null ? null : AnalysisQueryResult(availability);
  }
}

/// 2026-11-05: 분석 API 호출 결과. 서버 오류 봉투와 통신 실패를 섞지 않는다.
sealed class AnalysisCall<T> {
  /// 2026-11-05: 하위 결과만 만든다.
  const AnalysisCall();
}

/// 2026-11-05: 200·202 응답을 계약대로 읽었다.
final class AnalysisOk<T> extends AnalysisCall<T> {
  /// 2026-11-05: 읽은 값 [value]로 만든다.
  const AnalysisOk(this.value);

  final T value;
}

/// 2026-11-05: 세션이 끝났다(401 또는 세션을 닫은 뒤 도착한 응답).
final class AnalysisSessionInvalid<T> extends AnalysisCall<T> {
  /// 2026-11-05: 세션 무효를 만든다.
  const AnalysisSessionInvalid();
}

/// 2026-11-05: 서버가 오류 봉투로 거절했다. [status]·[code]를 그대로 담는다(409 STALE_DATA, 429 등).
/// [retryAfter]는 서버가 준 재요청 대기 시간이다(없으면 null).
final class AnalysisRejected<T> extends AnalysisCall<T> {
  /// 2026-11-05: 상태 [status], 오류 코드 [code], 재요청 대기 [retryAfter]로 만든다.
  const AnalysisRejected({
    required this.status,
    required this.code,
    this.retryAfter,
  });

  final int status;
  final String code;
  final Duration? retryAfter;
}

/// 2026-11-05: 응답을 받지 못했거나 계약 형식이 아닌 응답이다. [sent]면 서버가 처리했는지 알 수 없다.
final class AnalysisNetworkFailure<T> extends AnalysisCall<T> {
  /// 2026-11-05: 원인 [error]와 요청이 서버에 닿았을 수 있는지 [sent]로 만든다.
  const AnalysisNetworkFailure(this.error, {required this.sent});

  final Object error;
  final bool sent;
}

/// 2026-11-05: 분석 작업 API(apps/api/docs/analysis-api.md §3). 본문은 2단계 묶음이 만든 JSON을 그대로 보낸다.
abstract interface class AnalysisApi {
  /// 2026-11-05: POST /analysis-jobs. [body]는 접수 본문(멱등 키 포함)이다.
  Future<AnalysisCall<AnalysisJobStatus>> accept(Map<String, Object?> body);

  /// 2026-11-05: GET /analysis-jobs/{jobId}. [wait]면 Prefer: wait=5로 실행 완료를 최대 5초 기다리게 한다.
  Future<AnalysisCall<AnalysisJobStatus>> status(
    String jobId, {
    bool wait = false,
  });

  /// 2026-11-05: POST /analysis-jobs/{jobId}/input. [body]는 context·input·permit·멱등 키다.
  Future<AnalysisCall<AnalysisJobStatus>> submitInput(
    String jobId,
    Map<String, Object?> body,
  );

  /// 2026-11-05: POST /analysis-jobs/{jobId}/retry. 사용자가 다시 시도를 눌렀을 때만 부른다.
  Future<AnalysisCall<AnalysisJobStatus>> retry(
    String jobId,
    Map<String, Object?> body,
  );

  /// 2026-11-05: POST /analysis-results/query. 모델 호출 없이 현재 입력의 저장 결과 자격만 확인한다.
  Future<AnalysisCall<AnalysisQueryResult>> query(Map<String, Object?> body);

  /// 2026-11-05: 세션이 끝났다. 이후 요청과 늦은 응답은 세션 무효로 돌린다.
  void close();
}

/// 2026-11-05: 실제 서버 분석 API. 한 세션의 Bearer 토큰으로만 요청하며 자동 재시도는 하지 않는다.
class HttpAnalysisApi implements AnalysisApi {
  /// 2026-11-05: 서버 설정 [config], 통신 [transport], 세션 토큰 [accessToken]으로 만든다.
  HttpAnalysisApi({
    required this.config,
    required this.transport,
    required this.accessToken,
  });

  final ApiConfig config;
  final ApiTransport transport;
  final String accessToken;
  bool _closed = false;

  /// 2026-11-05: 세션을 닫는다.
  @override
  void close() => _closed = true;

  /// 2026-11-05: 접수.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> accept(Map<String, Object?> body) =>
      _send('POST', '/analysis-jobs', body, AnalysisJobStatus.fromJson);

  /// 2026-11-05: 상태 조회.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> status(
    String jobId, {
    bool wait = false,
  }) => _send(
    'GET',
    '/analysis-jobs/${Uri.encodeComponent(jobId)}',
    null,
    AnalysisJobStatus.fromJson,
    headers: wait ? const {'prefer': 'wait=5'} : const {},
  );

  /// 2026-11-05: 입력 제출.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> submitInput(
    String jobId,
    Map<String, Object?> body,
  ) => _send(
    'POST',
    '/analysis-jobs/${Uri.encodeComponent(jobId)}/input',
    body,
    AnalysisJobStatus.fromJson,
  );

  /// 2026-11-05: 사용자 재시도.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> retry(
    String jobId,
    Map<String, Object?> body,
  ) => _send(
    'POST',
    '/analysis-jobs/${Uri.encodeComponent(jobId)}/retry',
    body,
    AnalysisJobStatus.fromJson,
  );

  /// 2026-11-05: 결과 조회.
  @override
  Future<AnalysisCall<AnalysisQueryResult>> query(Map<String, Object?> body) =>
      _send(
        'POST',
        '/analysis-results/query',
        body,
        AnalysisQueryResult.fromJson,
      );

  /// 2026-11-05: 요청을 한 번 보내 200·202면 [parse]로 읽는다. 형식이 틀린 성공 응답과 업무 JSON이 아닌 응답은
  /// 통신 실패, 오류 봉투는 [AnalysisRejected], 401은 세션 무효로 돌려준다.
  Future<AnalysisCall<T>> _send<T>(
    String method,
    String path,
    Map<String, Object?>? body,
    T? Function(Map<String, Object?> json) parse, {
    Map<String, String> headers = const {},
  }) async {
    if (_closed) return AnalysisSessionInvalid<T>();
    final ApiResponse response;
    try {
      response = await transport.send(
        ApiRequest(
          method: method,
          uri: config.resolve(path),
          headers: {...headers, 'authorization': 'Bearer $accessToken'},
          body: body,
        ),
      );
    } on ApiTransportException catch (error) {
      if (_closed) return AnalysisSessionInvalid<T>();
      return AnalysisNetworkFailure<T>(
        error,
        sent: error.kind == ApiFailureKind.unknown,
      );
    }
    if (_closed) return AnalysisSessionInvalid<T>();
    if (response.status == 200 || response.status == 202) {
      final json = response.jsonObject;
      final value = json == null ? null : parse(json);
      return value == null
          ? AnalysisNetworkFailure<T>(
              ApiNonContractResponse(response.status),
              sent: true,
            )
          : AnalysisOk<T>(value);
    }
    if (response.status == 401) return AnalysisSessionInvalid<T>();
    final code = response.errorCode;
    if (code == null) {
      return AnalysisNetworkFailure<T>(
        ApiNonContractResponse(response.status),
        sent: true,
      );
    }
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return AnalysisRejected<T>(
      status: response.status,
      code: code,
      retryAfter: seconds == null || seconds < 0
          ? null
          : Duration(seconds: seconds),
    );
  }
}

const String _contract = 'PAYSE-ANALYSIS-1';

/// 2026-11-05: 열거값 [values] 중 이름이 [raw]인 것을 반환한다. 없으면 null이다.
T? _enum<T extends Enum>(List<T> values, Object? raw) {
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}
