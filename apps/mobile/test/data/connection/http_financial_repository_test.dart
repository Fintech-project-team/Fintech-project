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

  test(
    'obligation writes: paths, body W, cancel body with exact detach list',
    () async {
      transport.handler = (_) => jsonResponse(200, _saved('8'));
      await repo.createObligation(
        const ObligationInput(
          label: '통신비',
          withdrawalAccountId: 'a1',
          amountKrw: 55000,
          dueDate: '2026-10-22',
        ),
        _w,
      );
      await repo.updateObligation(
        'o 1',
        const ObligationPatch(amountKrw: 62000),
        _w,
      );
      await repo.cancelObligation('o1', const [
        DetachAllocation(allocationId: 'al1', unreleasedKrw: 30000),
      ], _w);
      final [create, update, cancel] = transport.requests;
      const w = {
        'expectedDataVersion': '7',
        'ruleVersion': 'PAYSE-CALC-1',
        'idempotencyKey': 'key-1',
      };
      expect((create.method, create.uri.path), ('POST', '/api/obligations'));
      expect(create.body, {
        'amountKRW': 55000,
        'dueDate': '2026-10-22',
        'label': '통신비',
        'withdrawalAccountId': 'a1',
        ...w,
      });
      expect(
        (update.method, update.uri.path),
        ('PATCH', '/api/obligations/o%201'),
      );
      expect(update.body, {'amountKRW': 62000, ...w}, reason: '바꾼 필드만');
      expect(
        (cancel.method, cancel.uri.path),
        ('POST', '/api/obligations/o1/cancel'),
        reason: 'DELETE 대신 cancel 경로 하나',
      );
      expect(cancel.body, {
        'detachAllocations': [
          {'allocationId': 'al1', 'unreleasedKRW': 30000},
        ],
        ...w,
      });
    },
  );

  test('reserve writes: empty allocationChanges on create, patch without it, cancel path', () async {
    transport.handler = (_) => jsonResponse(200, _saved('8'));
    await repo.createReserve(
      const ReserveInput(label: '비상금', accountId: 'a1', amountKrw: 400000),
      _w,
    );
    await repo.updateReserve('r 1', const ReservePatch(amountKrw: 300000), _w);
    await repo.cancelReserve('r1', const [
      DetachAllocation(allocationId: 'al1', unreleasedKrw: 60000),
    ], _w);
    final [create, update, cancel] = transport.requests;
    const w = {
      'expectedDataVersion': '7',
      'ruleVersion': 'PAYSE-CALC-1',
      'idempotencyKey': 'key-1',
    };
    expect((create.method, create.uri.path), ('POST', '/api/reserves'));
    expect(create.body, {
      'accountId': 'a1',
      'allocationChanges': {'create': [], 'remove': [], 'update': []},
      'amountKRW': 400000,
      'label': '비상금',
      ...w,
    });
    expect((update.method, update.uri.path), ('PATCH', '/api/reserves/r%201'));
    expect(update.body, {'amountKRW': 300000, ...w}, reason: '연결은 보내지 않음');
    expect(
      (cancel.method, cancel.uri.path),
      ('POST', '/api/reserves/r1/cancel'),
    );
    expect(cancel.body, {
      'detachAllocations': [
        {'allocationId': 'al1', 'unreleasedKRW': 60000},
      ],
      ...w,
    });
  });

  test(
    'reserve plan changes: allocationChanges arrays on create and patch',
    () async {
      transport.handler = (_) => jsonResponse(200, _saved('8'));
      await repo.createReserve(
        const ReserveInput(
          label: '여행 자금',
          accountId: 'a1',
          amountKrw: 300000,
          changes: AllocationChanges(
            create: [(obligationId: 'o1', amountKrw: 100000)],
          ),
        ),
        _w,
      );
      await repo.updateReserve(
        'r1',
        const ReservePatch(
          changes: AllocationChanges(
            create: [(obligationId: 'o2', amountKrw: 20000)],
            update: [(allocationId: 'al1', amountKrw: 40000)],
            remove: ['al2'],
          ),
        ),
        _w,
      );
      final [create, update] = transport.requests;
      expect((create.body! as Map)['allocationChanges'], {
        'create': [
          {'amountKRW': 100000, 'obligationId': 'o1'},
        ],
        'remove': [],
        'update': [],
      });
      expect(update.body, {
        'allocationChanges': {
          'create': [
            {'amountKRW': 20000, 'obligationId': 'o2'},
          ],
          'remove': ['al2'],
          'update': [
            {'allocationId': 'al1', 'amountKRW': 40000},
          ],
        },
        'expectedDataVersion': '7',
        'ruleVersion': 'PAYSE-CALC-1',
        'idempotencyKey': 'key-1',
      });
    },
  );

  test('409·422 business codes keep their status and code', () async {
    for (final (status, code) in const [
      (409, 'HISTORY_LOCKED'),
      (409, 'RELATION_CONFLICT'),
      (422, 'LIMIT_EXCEEDED'),
      (422, 'VALIDATION_FAILED'),
    ]) {
      transport.handler = (_) => errorResponse(status, code);
      final result = await repo.updateObligation(
        'o1',
        const ObligationPatch(amountKrw: 1),
        _w,
      );
      expect(result, isA<FinancialInvalid<WriteSuccess>>());
      final invalid = result as FinancialInvalid<WriteSuccess>;
      expect((invalid.status, invalid.code), (status, code));
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
