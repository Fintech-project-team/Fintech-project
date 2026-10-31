import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/connection/transaction_history.dart';
import 'package:payse/data/financial_snapshot.dart';

import '../../features/connection/connection_test_support.dart';
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

/// 2026-10-30: 거래를 [pageSize]씩 나누는 가짜 서버에 데모알파를 모두 연결한 세션을 반환한다.
Future<(FakeFinancialServer, FakeUserFinancialRepository, String)> _session({
  int? pageSize = 100,
  String stem = 'demo-ready',
}) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource(stem),
    transactionPageSize: pageSize,
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final token = (session as AuthOk<DemoSession>).value.accessToken;
  final repo = FakeUserFinancialRepository(server: server, accessToken: token);
  await repo.linkInstitutions(
    _codes,
    const WriteContext(
      expectedDataVersion: '1',
      ruleVersion: 'PAYSE-CALC-1',
      idempotencyKey: 'link',
    ),
  );
  return (server, repo, token);
}

Future<FinancialSnapshot> _snapshot(UserFinancialRepository repo) async =>
    FinancialSnapshot.fromJson(
      ((await repo.loadSnapshot()) as FinancialOk<Map<String, Object?>>).value,
    );

void main() {
  test('기본(페이지 크기 없음)은 Snapshot에 거래를 모두 담고 다음 페이지가 없다', () async {
    final (_, repo, _) = await _session(pageSize: null);
    final s = await _snapshot(repo);
    final total = (readSource('demo-ready')['transactions']! as List).length;
    expect(s.transactions, hasLength(total));
    expect(s.nextTransactionCursor, isNull);
  });

  test('100건씩 나누면 첫 페이지 100건과 cursor, 수집하면 모두 같은 거래 하나씩', () async {
    final (_, repo, _) = await _session();
    final s = await _snapshot(repo);
    expect(s.transactions, hasLength(100));
    expect(s.nextTransactionCursor, isNotNull);
    final ids = [for (final t in s.transactions!) t.transactionId];
    expect(ids, [...ids]..sort(), reason: 'transactionId 오름차순');
    final result = await TransactionHistoryCollector(
      repo,
    ).collect(s) as TransactionHistoryReady;
    final total = (readSource('demo-ready')['transactions']! as List).length;
    expect(result.transactions, hasLength(total));
    expect(
      result.transactions.map((t) => t.transactionId).toSet(),
      hasLength(total),
    );
  });

  test('딱 100건 경계: 다음 페이지가 정확히 남은 만큼이고 마지막 페이지 cursor는 null', () async {
    final (server, repo, token) = await _session(pageSize: 101);
    final s = await _snapshot(repo);
    final first = await server.getTransactionPage(
      token,
      s.nextTransactionCursor!,
    );
    final page = TransactionPage.fromJson(
      (first as FinancialOk<Map<String, Object?>>).value,
    );
    final total = (readSource('demo-ready')['transactions']! as List).length;
    expect(page.transactions, hasLength(total - 101));
    expect(page.nextCursor, isNull);
  });

  test('변조 cursor는 400, 다른 사용자 cursor는 403', () async {
    final (server, repo, token) = await _session();
    final s = await _snapshot(repo);
    expect(
      await server.getTransactionPage(token, 'abc'),
      isA<FinancialInvalid<Map<String, Object?>>>(),
    );
    final other = s.nextTransactionCursor!.replaceFirst(
      s.userId,
      '00000000-0000-0000-0000-000000000000',
    );
    expect(
      await server.getTransactionPage(token, other),
      isA<FinancialForbidden<Map<String, Object?>>>(),
    );
  });

  test('수집 중 자료 버전이 바뀌면(409) 새 Snapshot부터 다시 받는다', () async {
    final (_, repo, _) = await _session();
    final old = await _snapshot(repo);
    await repo.selectAccounts(
      const ['6069b37a-abf5-56fc-8bf0-153f5301fd1c'],
      WriteContext(
        expectedDataVersion: old.dataVersion,
        ruleVersion: old.ruleVersion,
        idempotencyKey: 'select',
      ),
    );
    final result = await TransactionHistoryCollector(
      repo,
    ).collect(old) as TransactionHistoryReady;
    expect(result.snapshot.dataVersion, isNot(old.dataVersion));
  });

  test('중간 페이지 실패·같은 ID 다른 값은 실패, 세션 무효는 세션 무효', () async {
    final (_, real, _) = await _session();
    final s = await _snapshot(real);
    final page = (await real.loadTransactionPage(
      s.nextTransactionCursor!,
    ) as FinancialOk<Map<String, Object?>>).value;

    final failing = ScriptedRepository()
      ..pageResults.add(const FinancialUnavailable());
    expect(
      await TransactionHistoryCollector(failing).collect(s),
      isA<TransactionHistoryFailed>(),
    );

    final rows = [
      for (final t in page['transactions']! as List) Map.of(t as Map),
    ];
    final twice = {
      ...page,
      'transactions': [
        rows.first,
        {...rows.first, 'merchantName': '다른 이름'},
      ],
      'page': {...(page['page']! as Map), 'nextCursor': null},
    };
    final dup = ScriptedRepository()..pageResults.add(FinancialOk(twice));
    expect(
      await TransactionHistoryCollector(dup).collect(s),
      isA<TransactionHistoryFailed>(),
    );

    final expired = ScriptedRepository()
      ..pageResults.add(const FinancialSessionInvalid());
    expect(
      await TransactionHistoryCollector(expired).collect(s),
      isA<TransactionHistorySessionInvalid>(),
    );
  });

  test('계약 밖 열거값은 형식 오류, 계좌 내역의 approved·cancelled는 허용', () {
    final json = readSource('demo-ready');
    final rows = json['transactions']! as List;
    final account = (rows.cast<Map>()).firstWhere(
      (t) => t['recordKind'] == 'account_entry',
    );
    account['status'] = 'approved';
    expect(() => FinancialSnapshot.fromJson(json), returnsNormally);
    account['status'] = 'cancelled';
    expect(() => FinancialSnapshot.fromJson(json), returnsNormally);
    account['status'] = 'pending';
    expect(
      () => FinancialSnapshot.fromJson(json),
      throwsA(isA<SnapshotFormatException>()),
    );
    account['status'] = 'posted';
    account['direction'] = 'sideways';
    expect(
      () => FinancialSnapshot.fromJson(json),
      throwsA(isA<SnapshotFormatException>()),
    );
  });
}
