import '../http/api_config.dart';
import '../http/api_transport.dart';
import 'financial_api.dart';

/// 2026-11-01: 실제 서버의 금융 조회·쓰기(docs/api-contract.md §3·§5·§6). 한 세션의 Bearer 토큰으로만 요청한다.
/// 받은 응답 JSON을 그대로 돌려주며 페이지 병합은 [AssembledFinancialRepository]가 맡는다. 세션을 닫은 뒤 도착한 응답과
/// 이 세션에서 이미 본 것보다 낮은 자료 버전의 응답은 반영하지 않는다(§5-6).
class HttpUserFinancialRepository implements UserFinancialRepository {
  /// 2026-11-01: 서버 설정 [config], 통신 [transport], 세션 토큰 [accessToken]으로 만든다.
  HttpUserFinancialRepository({
    required this.config,
    required this.transport,
    required this.accessToken,
  });

  final ApiConfig config;
  final ApiTransport transport;
  final String accessToken;
  BigInt _latestVersion = BigInt.zero;
  bool _closed = false;

  /// 2026-11-01: 세션이 끝났다. 이후 요청과 진행 중 요청의 늦은 응답을 세션 무효로 돌려 반영하지 않는다.
  @override
  void close() => _closed = true;

  /// 2026-11-01: GET /snapshot. 이미 본 버전보다 낮은 응답은 서비스 불가로 돌려 다시 읽게 한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    final result = await _send(
      ApiRequest(method: 'GET', uri: config.resolve('/snapshot')),
      (json) => json,
    );
    if (result case FinancialOk(:final value) when !_accept(value)) {
      return const FinancialUnavailable();
    }
    return result;
  }

  /// 2026-11-01: GET /transactions?cursor. cursor는 해석하지 않고 그대로 보낸다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadTransactionPage(
    String cursor,
  ) => _send(
    ApiRequest(
      method: 'GET',
      uri: config.resolve('/transactions', {'cursor': cursor}),
    ),
    (json) => json,
  );

  /// 2026-11-01: POST /institution-links.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) => _write('POST', '/institution-links', {
    'institutionCodes': institutionCodes,
  }, write);

  /// 2026-11-01: PATCH /account-selection.
  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) => _write('PATCH', '/account-selection', {'accountIds': accountIds}, write);

  /// 2026-11-01: PATCH /settings. 월급 설정만 보내고 카드 계획은 보내지 않는다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) => _write('PATCH', '/settings', {'salary': salary.toJson()}, write);

  /// 2026-11-01: PATCH /accounts/{accountId}. null은 이름 해제다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) => _write('PATCH', '/accounts/${Uri.encodeComponent(accountId)}', {
    'nickname': nickname,
  }, write);

  /// 2026-11-03: POST /obligations.
  @override
  Future<FinancialOutcome<WriteSuccess>> createObligation(
    ObligationInput obligation,
    WriteContext write,
  ) => _write('POST', '/obligations', obligation.toJson(), write);

  /// 2026-11-03: PATCH /obligations/{id}.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateObligation(
    String obligationId,
    ObligationPatch patch,
    WriteContext write,
  ) => _write(
    'PATCH',
    '/obligations/${Uri.encodeComponent(obligationId)}',
    patch.toJson(),
    write,
  );

  /// 2026-11-03: POST /obligations/{id}/cancel. 취소는 DELETE 대신 이 경로 하나로 보낸다(W는 본문).
  @override
  Future<FinancialOutcome<WriteSuccess>> cancelObligation(
    String obligationId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) => _write(
    'POST',
    '/obligations/${Uri.encodeComponent(obligationId)}/cancel',
    {
      'detachAllocations': [for (final d in detach) d.toJson()],
    },
    write,
  );

  /// 2026-11-01: 금융 쓰기. W는 본문 최상위에 둔다(§1). 재시도는 호출부가 같은 [write]로 다시 부른다(자동 재시도 없음).
  Future<FinancialOutcome<WriteSuccess>> _write(
    String method,
    String path,
    Map<String, Object?> body,
    WriteContext write,
  ) async {
    final result = await _send(
      ApiRequest(
        method: method,
        uri: config.resolve(path),
        body: {
          ...body,
          'expectedDataVersion': write.expectedDataVersion,
          'ruleVersion': write.ruleVersion,
          'idempotencyKey': write.idempotencyKey,
        },
      ),
      _writeSuccess,
    );
    if (result case FinancialOk(:final value) when !_accept(value.snapshot)) {
      return const FinancialUnavailable();
    }
    return result;
  }

  /// 2026-11-01: 받은 Snapshot의 버전이 이 세션에서 본 것보다 낮지 않으면 기록하고 true를 반환한다.
  bool _accept(Map<String, Object?> snapshot) {
    final version = BigInt.tryParse('${snapshot['dataVersion']}');
    if (version == null || version < _latestVersion) return false;
    _latestVersion = version;
    return true;
  }

  /// 2026-11-01: 요청을 한 번 보내 200이면 [parse]로 읽는다. 형식이 틀린 200은 서비스 불가, 오류 봉투는 §6 종류로,
  /// 업무 JSON이 아닌 응답·통신 실패는 [FinancialNetworkFailure]로 돌려준다.
  /// 2026-11-02: 업무 JSON이 아닌 5xx(프록시 뒤 API 중단 등)는 서비스 불가로 돌려준다.
  Future<FinancialOutcome<T>> _send<T>(
    ApiRequest request,
    T? Function(Map<String, Object?> json) parse,
  ) async {
    if (_closed) return const FinancialSessionInvalid();
    final ApiResponse response;
    try {
      response = await transport.send(
        ApiRequest(
          method: request.method,
          uri: request.uri,
          headers: {'authorization': 'Bearer $accessToken'},
          body: request.body,
        ),
      );
    } on ApiTransportException catch (error) {
      return _closed
          ? const FinancialSessionInvalid()
          : FinancialNetworkFailure(error);
    }
    if (_closed) return const FinancialSessionInvalid();
    if (response.status == 200) {
      final json = response.jsonObject;
      final value = json == null ? null : parse(json);
      return value == null ? const FinancialUnavailable() : FinancialOk(value);
    }
    final code = response.errorCode;
    if (code == null) {
      return response.status >= 500
          ? FinancialUnavailable<T>()
          : FinancialNetworkFailure(ApiNonContractResponse(response.status));
    }
    return switch ((response.status, code)) {
      (401, _) => FinancialSessionInvalid<T>(),
      (403, _) => FinancialForbidden<T>(),
      (409, 'STALE_DATA') => FinancialStaleData<T>(),
      (409, 'RULE_VERSION_MISMATCH') => FinancialRuleVersionMismatch<T>(),
      (409, 'IDEMPOTENCY_CONFLICT') => FinancialIdempotencyConflict<T>(),
      (400 || 409 || 413 || 422, _) => FinancialInvalid<T>(
        status: response.status,
        code: code,
      ),
      _ => FinancialUnavailable<T>(),
    };
  }

  /// 2026-11-01: 쓰기 성공 S(§5)를 읽는다. 필수 키가 없거나 형식이 틀리면 null이다.
  static WriteSuccess? _writeSuccess(Map<String, Object?> json) {
    final receipt = json['receipt'];
    final snapshot = json['snapshot'];
    final replayed = json['replayed'];
    if (receipt is! Map || snapshot is! Map || replayed is! bool) return null;
    final refs = receipt['changedRefs'];
    final createdAt = DateTime.tryParse('${receipt['createdAt']}');
    final receiptId = receipt['receiptId'];
    final operationKey = receipt['operationKey'];
    final resultVersion = receipt['resultVersion'];
    if (refs is! List ||
        createdAt == null ||
        receiptId is! String ||
        operationKey is! String ||
        resultVersion is! String) {
      return null;
    }
    final changed = <ChangedRef>[];
    for (final ref in refs) {
      if (ref is! Map || ref['resource'] is! String || ref['id'] is! String) {
        return null;
      }
      changed.add(
        ChangedRef(
          resource: ref['resource']! as String,
          id: ref['id']! as String,
        ),
      );
    }
    return WriteSuccess(
      receipt: WriteReceipt(
        receiptId: receiptId,
        operationKey: operationKey,
        resultVersion: resultVersion,
        createdAt: createdAt,
        changedRefs: List.unmodifiable(changed),
      ),
      replayed: replayed,
      snapshot: snapshot.cast<String, Object?>(),
    );
  }
}
