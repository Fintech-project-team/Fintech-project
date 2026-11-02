import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/connection/http_financial_repository.dart';
import 'package:payse/data/http/api_transport.dart';

import '../http/fake_api_transport.dart';

const _w = WriteContext(
  expectedDataVersion: '7',
  ruleVersion: 'PAYSE-CALC-1',
  idempotencyKey: 'key-1',
);

Map<String, Object?> _snapshot(String version) => {
  'userId': 'u1',
  'dataVersion': version,
};

Map<String, Object?> _saved(String version) => {
  'receipt': {
    'receiptId': 'r1',
    'operationKey': 'key-1',
    'resultVersion': version,
    'createdAt': '2026-11-01T00:00:00Z',
    'changedRefs': [
      {'resource': 'account', 'id': 'a1'},
    ],
  },
  'replayed': false,
  'snapshot': _snapshot(version),
};

void main() {
  late FakeApiTransport transport;
  late HttpUserFinancialRepository repo;

  setUp(() {
    transport = FakeApiTransport((_) => jsonResponse(200, _snapshot('7')));
    repo = HttpUserFinancialRepository(
      config: testApiConfig,
      transport: transport,
      accessToken: 'token-1',
    );
  });

  test(
    'reads send only the bearer token; the cursor is passed as is',
    () async {
      expect(
        await repo.loadSnapshot(),
        isA<FinancialOk<Map<String, Object?>>>(),
      );
      await repo.loadTransactionPage('opaque+/=');
      final [snapshot, page] = transport.requests;
      expect(snapshot.uri.path, '/api/snapshot');
      expect(snapshot.headers, {'authorization': 'Bearer token-1'});
      expect(page.uri.queryParameters, {'cursor': 'opaque+/='});
    },
  );

  test(
    'writes put W at the top level and read the receipt and snapshot',
    () async {
      transport.handler = (_) => jsonResponse(200, _saved('8'));
      final result = await repo.updateAccountNickname('a 1', null, _w);
      final saved = (result as FinancialOk<WriteSuccess>).value;
      expect(saved.receipt.changedRefs.single.resource, 'account');
      final sent = transport.requests.single;
      expect((sent.method, sent.uri.path), ('PATCH', '/api/accounts/a%201'));
      expect(sent.body, {
        'nickname': null,
        'expectedDataVersion': '7',
        'ruleVersion': 'PAYSE-CALC-1',
        'idempotencyKey': 'key-1',
      });
    },
  );

  test(
    'a retry after an unknown result reuses the same body and key',
    () async {
      transport.handler = (_) =>
          throw const ApiTransportException(ApiFailureKind.unknown, 'timeout');
      expect(
        await repo.selectAccounts(const ['a1'], _w),
        isA<FinancialNetworkFailure<WriteSuccess>>(),
      );
      transport.handler = (_) => jsonResponse(200, _saved('8'));
      expect(
        await repo.selectAccounts(const ['a1'], _w),
        isA<FinancialOk<WriteSuccess>>(),
      );
      expect(transport.requests, hasLength(2), reason: '자동 재시도 없음');
      expect(transport.requests[0].body, transport.requests[1].body);
    },
  );

  test('error envelopes map to the existing outcomes', () async {
    final cases = <(ApiResponse, Type)>[
      (
        errorResponse(401, 'SESSION_INVALID'),
        FinancialSessionInvalid<WriteSuccess>,
      ),
      (
        errorResponse(403, 'RESOURCE_FORBIDDEN'),
        FinancialForbidden<WriteSuccess>,
      ),
      (errorResponse(409, 'STALE_DATA'), FinancialStaleData<WriteSuccess>),
      (
        errorResponse(409, 'RULE_VERSION_MISMATCH'),
        FinancialRuleVersionMismatch<WriteSuccess>,
      ),
      (
        errorResponse(409, 'IDEMPOTENCY_CONFLICT'),
        FinancialIdempotencyConflict<WriteSuccess>,
      ),
      (errorResponse(422, 'VALIDATION_FAILED'), FinancialInvalid<WriteSuccess>),
      (
        errorResponse(503, 'TEMPORARILY_UNAVAILABLE'),
        FinancialUnavailable<WriteSuccess>,
      ),
      (plainResponse(403), FinancialNetworkFailure<WriteSuccess>),
      (plainResponse(502), FinancialUnavailable<WriteSuccess>),
    ];
    for (final (response, type) in cases) {
      transport.handler = (_) => response;
      expect(
        (await repo.linkInstitutions(const ['bank.kb'], _w)).runtimeType,
        type,
        reason: '${response.status} ${response.errorCode}',
      );
    }
  });

  test('a TLS failure is a connection failure, not a business error', () async {
    transport.handler = (_) =>
        throw const ApiTransportException(ApiFailureKind.tls, 'handshake');
    final result = await repo.loadSnapshot();
    final failure = result as FinancialNetworkFailure<Map<String, Object?>>;
    expect((failure.error as ApiTransportException).kind, ApiFailureKind.tls);
  });

  test('older versions and responses after close are not applied', () async {
    transport.handler = (_) => jsonResponse(200, _snapshot('9'));
    await repo.loadSnapshot();
    transport.handler = (_) => jsonResponse(200, _snapshot('8'));
    expect(
      await repo.loadSnapshot(),
      isA<FinancialUnavailable<Map<String, Object?>>>(),
    );
    repo.close();
    expect(
      await repo.loadSnapshot(),
      isA<FinancialSessionInvalid<Map<String, Object?>>>(),
    );
  });
}
