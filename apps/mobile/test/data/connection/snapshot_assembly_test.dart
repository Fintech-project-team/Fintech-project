import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/connection/snapshot_assembly.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';

import 'connection_test_utils.dart';

const _codes = [
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
];

const _w = WriteContext(
  expectedDataVersion: '1',
  ruleVersion: 'PAYSE-CALC-1',
  idempotencyKey: 'link',
);

/// 2026-11-01: 거래를 [pageSize]씩 나누는 가짜 서버에 데모알파를 모두 연결하고 계좌를 고른 세션을 반환한다.
Future<FakeUserFinancialRepository> _session(int? pageSize) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource('demo-ready'),
    transactionPageSize: pageSize,
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final repo = FakeUserFinancialRepository(
    server: server,
    accessToken: (session as AuthOk<DemoSession>).value.accessToken,
  );
  final linked = await repo.linkInstitutions(_codes, _w);
  final accounts =
      ((linked as FinancialOk<WriteSuccess>).value.snapshot['accounts']!
              as List)
          .map((a) => (a as Map)['accountId']! as String)
          .toList();
  await repo.selectAccounts(
    accounts,
    const WriteContext(
      expectedDataVersion: '2',
      ruleVersion: 'PAYSE-CALC-1',
      idempotencyKey: 'select',
    ),
  );
  return repo;
}

/// 2026-11-01: 첫 페이지와 cursor별 응답을 정해 둔 저장소. 조회 횟수를 센다.
class _Pages implements UserFinancialRepository {
  _Pages(this.snapshots, this.pages);

  final List<Map<String, Object?>> snapshots;
  final Map<String, FinancialOutcome<Map<String, Object?>>> pages;
  int loads = 0;

  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async =>
      FinancialOk(
        snapshots[loads++ < snapshots.length
            ? loads - 1
            : snapshots.length - 1],
      );

  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadTransactionPage(
    String cursor,
  ) async => pages[cursor] ?? const FinancialInvalid();

  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> codes,
    WriteContext write,
  ) async => FinancialOk(
    WriteSuccess(
      receipt: WriteReceipt(
        receiptId: 'r',
        operationKey: write.idempotencyKey,
        resultVersion: '5',
        createdAt: DateTime.utc(2026, 11),
        changedRefs: const [],
      ),
      replayed: false,
      snapshot: snapshots.first,
    ),
  );

  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> ids,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String id,
    String? nickname,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  Future<FinancialOutcome<WriteSuccess>> createObligation(
    ObligationInput obligation,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  Future<FinancialOutcome<WriteSuccess>> updateObligation(
    String id,
    ObligationPatch patch,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  Future<FinancialOutcome<WriteSuccess>> cancelObligation(
    String id,
    List<DetachAllocation> detach,
    WriteContext write,
  ) => throw UnimplementedError();

  @override
  void close() {}
}

/// 2026-11-01: 공통 필드 H와 page를 갖춘 시험용 응답. [version]은 자료 버전, [next]는 다음 cursor다.
Map<String, Object?> _response({
  String version = '5',
  String userId = 'u1',
  String? next,
  List<Map<String, Object?>> transactions = const [],
  List<Map<String, Object?>> related = const [],
  List<Map<String, Object?>> relations = const [],
  List<Map<String, Object?>> links = const [],
  List<Map<String, Object?>> restrictions = const [],
}) => {
  'userId': userId,
  'schemaVersion': 'PAYSE-API-0.6-4',
  'currency': 'KRW',
  'dataVersion': version,
  'sourceVersion': 'src-1',
  'ruleVersion': 'PAYSE-CALC-1',
  'asOf': '2026-11-01T00:00:00+09:00',
  'transactions': transactions,
  'relatedTransactions': related,
  'referenceResolutions': const <Object?>[],
  'transactionRelations': relations,
  'occurrenceLinks': links,
  'coverage': const <Object?>[],
  'page': {
    'nextCursor': next,
    'dataVersion': version,
    'sourceVersion': 'src-1',
  },
  'accessRestrictions': restrictions,
};

Map<String, Object?> _tx(String id, [int amount = 1000]) => {
  'transactionId': id,
  'amountKRW': amount,
};

void main() {
  test(
    'all pages are merged so the home sees the same data as one big snapshot',
    () async {
      final whole = await _session(null);
      final paged = await _session(100);
      final first =
          (await paged.loadSnapshot() as FinancialOk<Map<String, Object?>>)
              .value;
      expect(
        (first['page']! as Map)['nextCursor'],
        isNotNull,
        reason: '실제로 여러 페이지',
      );

      final assembled = await AssembledFinancialRepository(paged)
          .loadSnapshot();
      final merged = FinancialSnapshot.fromJson(
        (assembled as FinancialOk<Map<String, Object?>>).value,
      );
      final full = FinancialSnapshot.fromJson(
        (await whole.loadSnapshot() as FinancialOk<Map<String, Object?>>).value,
      );
      expect(merged.hasMoreTransactions, isFalse);
      expect(
        merged.transactions!.map((t) => t.transactionId).toSet(),
        full.transactions!.map((t) => t.transactionId).toSet(),
      );
      final a = computeHomeCalculation(merged) as HomeCalculationReady;
      final b = computeHomeCalculation(full) as HomeCalculationReady;
      expect(a.result.u, b.result.u);
    },
  );

  test(
    'auxiliary arrays are kept and duplicates merge by their contract keys',
    () async {
      final relation = {
        'kind': 'internal_transfer',
        'fromId': 't1',
        'toId': 't3',
        'evidenceRef': 'e1',
      };
      final link = {
        'recurrenceKey': 'p1:2026-10',
        'purchaseTransactionId': 't3',
        'statementId': null,
        'obligationId': 'o1',
        'evidenceRef': 'e2',
      };
      final restriction = {
        'ownerType': 'transaction',
        'ownerId': 't9',
        'field': 'accountId',
      };
      final repo = AssembledFinancialRepository(
        _Pages(
          [
            _response(
              next: 'c1',
              transactions: [_tx('t1')],
              relations: [relation],
              restrictions: [restriction],
            ),
          ],
          {
            'c1': FinancialOk(
              _response(
                transactions: [_tx('t1'), _tx('t3')],
                related: [_tx('old-1')],
                relations: [relation],
                links: [
                  link,
                  {...link},
                ],
                restrictions: [restriction],
              ),
            ),
          },
        ),
      );
      final json =
          (await repo.loadSnapshot() as FinancialOk<Map<String, Object?>>)
              .value;
      expect((json['transactions']! as List).length, 2);
      expect((json['relatedTransactions']! as List).length, 1);
      expect((json['transactionRelations']! as List).length, 1);
      expect((json['occurrenceLinks']! as List).length, 1);
      expect((json['accessRestrictions']! as List).length, 1);
      expect((json['page']! as Map)['nextCursor'], isNull);
    },
  );

  test(
    'the same id with a different value is a contract error, not overwritten',
    () async {
      final repo = AssembledFinancialRepository(
        _Pages(
          [
            _response(next: 'c1', transactions: [_tx('t1', 1000)]),
          ],
          {
            'c1': FinancialOk(_response(transactions: [_tx('t1', 2000)])),
          },
        ),
      );
      expect(
        await repo.loadSnapshot(),
        isA<FinancialUnavailable<Map<String, Object?>>>(),
      );
    },
  );

  test('a page for another user or source is a contract error', () async {
    for (final page in [
      _response(userId: 'u2'),
      {..._response(), 'sourceVersion': 'src-2'},
    ]) {
      final repo = AssembledFinancialRepository(
        _Pages([_response(next: 'c1')], {'c1': FinancialOk(page)}),
      );
      expect(
        await repo.loadSnapshot(),
        isA<FinancialUnavailable<Map<String, Object?>>>(),
      );
    }
  });

  test('a version change mid-way restarts from a new snapshot; a failure returns no partial data', () async {
    final pages = _Pages(
      [
        _response(next: 'c1', transactions: [_tx('t1')]),
        _response(version: '6', next: 'c2', transactions: [_tx('t1')]),
      ],
      {
        'c1': const FinancialStaleData(),
        'c2': FinancialOk(_response(version: '6', transactions: [_tx('t2')])),
      },
    );
    final json =
        (await AssembledFinancialRepository(pages).loadSnapshot()
                as FinancialOk<Map<String, Object?>>)
            .value;
    expect(pages.loads, 2);
    expect(json['dataVersion'], '6');
    expect((json['transactions']! as List).length, 2);

    final mismatch = _Pages(
      [_response(next: 'c1'), _response(version: '6')],
      {'c1': FinancialOk(_response(version: '6'))},
    );
    expect(
      await AssembledFinancialRepository(mismatch).loadSnapshot(),
      isA<FinancialOk<Map<String, Object?>>>(),
    );
    expect(mismatch.loads, 2, reason: '다른 dataVersion 페이지도 처음부터 다시 받는다');

    final failing = _Pages(
      [_response(next: 'c1')],
      {'c1': const FinancialNetworkFailure<Map<String, Object?>>('down')},
    );
    expect(
      await AssembledFinancialRepository(failing).loadSnapshot(),
      isA<FinancialNetworkFailure<Map<String, Object?>>>(),
    );
  });

  test('a saved write stays a success; its new snapshot is merged when the pages arrive', () async {
    final ok = _Pages(
      [
        _response(next: 'c1', transactions: [_tx('t1')]),
      ],
      {
        'c1': FinancialOk(_response(transactions: [_tx('t2')])),
      },
    );
    final saved = await AssembledFinancialRepository(ok)
        .linkInstitutions(const ['bank.kb'], _w);
    final snapshot = (saved as FinancialOk<WriteSuccess>).value.snapshot;
    expect((snapshot['transactions']! as List).length, 2);

    final broken = _Pages(
      [_response(next: 'c1')],
      {'c1': const FinancialUnavailable<Map<String, Object?>>()},
    );
    final kept = await AssembledFinancialRepository(broken)
        .linkInstitutions(const ['bank.kb'], _w);
    expect(
      ((kept as FinancialOk<WriteSuccess>).value.snapshot['page']!
          as Map)['nextCursor'],
      'c1',
      reason: '저장 성공은 유지하고, 남은 페이지 표시로 계산은 정보 부족이 된다',
    );
  });
}
