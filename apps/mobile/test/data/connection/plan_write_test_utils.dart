import 'dart:collection';

import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';

import '../calculation_input_adapter_test.dart' show alphaWithReceipt;
import 'connection_test_utils.dart';

/// 2026-11-03: alpha-ready 예정 지출 ID(월세·수리비·카드 청구·통신비 반복 회차).
const rentId = '41c9a92d-536a-5ae8-a053-7755833ff362';
const repairId = 'c2db3f00-b3f5-57bb-be75-cbba8e6384d0';
const cardBillId = 'cdd6c3e1-b8c2-5989-a263-6dd6392a51ef';
const phoneId = '2c213194-b90a-52d2-afe2-888645a93b8c';
const kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const reserveId = 'a40eef85-dd1b-5093-bb15-a522636d0b9b';

/// 2026-11-03: 시험에서 월세에 더한 미해제 배정(30,000원, 해제 이력 없음).
const rentAllocationId = '7f0c1b6e-2d9a-4c3e-9a51-3b8f2e6d4a10';

/// 2026-11-03: 입금 근거가 있는 alpha-ready 원본. [rentHeld]면 월세에 30,000원 배정을 더한다.
Map<String, Object?> planSource({bool rentHeld = false}) {
  final json = alphaWithReceipt();
  if (rentHeld) {
    (json['allocations']! as List).add({
      'userId': json['userId'],
      'allocationId': rentAllocationId,
      'reserveId': reserveId,
      'obligationId': rentId,
      'amountKRW': 30000,
      'releasedKRW': 0,
      'releaseEvidence': <Object?>[],
    });
  }
  return json;
}

/// 2026-11-03: 가짜 서버에 데모알파를 모두 연결하고 원본의 계산 포함 계좌를 고른 세션. [server]는 재접속 확인에 쓴다.
typedef PlanSession = ({
  FakeFinancialServer server,
  FakeAuthRepository auth,
  FakeUserFinancialRepository repository,
  FinancialSnapshot snapshot,
});

/// 2026-11-03: [source]를 원본으로 하는 연결된 세션을 만든다.
Future<PlanSession> connectPlan(Map<String, Object?> source) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => source,
  );
  final repository = FakeUserFinancialRepository(
    server: server,
    accessToken: await signIn(auth),
  );
  WriteContext w(String v, String k) => WriteContext(
    expectedDataVersion: v,
    ruleVersion: source['ruleVersion']! as String,
    idempotencyKey: k,
  );
  final linked = await repository.linkInstitutions([
    for (final i in source['institutions']! as List)
      (i as Map)['code'] as String,
  ], w(source['dataVersion']! as String, 'link'));
  final version =
      (linked as FinancialOk<WriteSuccess>).value.snapshot['dataVersion']
          as String;
  final saved = await repository.selectAccounts([
    for (final a in rows(source, 'accounts'))
      if (a['included'] == true) a['accountId'] as String,
  ], w(version, 'select'));
  return (
    server: server,
    auth: auth,
    repository: repository,
    snapshot: FinancialSnapshot.fromJson(
      (saved as FinancialOk<WriteSuccess>).value.snapshot,
    ),
  );
}

/// 2026-11-03: 데모알파로 새 세션을 열고 토큰을 반환한다.
Future<String> signIn(FakeAuthRepository auth) async {
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  return (session as AuthOk<DemoSession>).value.accessToken;
}

/// 2026-11-03: [snapshot]의 W(새 작업 키 [key]).
WriteContext writeOf(FinancialSnapshot snapshot, String key) => WriteContext(
  expectedDataVersion: snapshot.dataVersion,
  ruleVersion: snapshot.ruleVersion,
  idempotencyKey: key,
);

/// 2026-11-03: 쓰기 결과를 바꿔 끼우는 저장소. [lose]가 남아 있으면 안쪽에서 저장은 한 뒤 응답을 잃은 것처럼 연결 실패를 돌려주고,
/// [scripted]가 남아 있으면 안쪽을 부르지 않고 그 결과를 돌려준다. 받은 요청은 [calls]에 남긴다.
/// [failLoads]가 남아 있으면 Snapshot 조회를 연결 실패로 돌려준다.
class FlakyRepository implements UserFinancialRepository {
  /// 2026-11-03: 안쪽 저장소 [inner]로 만든다.
  FlakyRepository(this.inner);

  final UserFinancialRepository inner;
  int lose = 0;
  int failLoads = 0;
  final Queue<FinancialOutcome<WriteSuccess>> scripted = Queue();
  final List<(String, WriteContext, Object?)> calls = [];

  /// 2026-11-03: 쓰기 [run]에 끼워 넣기 규칙을 적용한다.
  Future<FinancialOutcome<WriteSuccess>> _apply(
    String op,
    WriteContext write,
    Object? body,
    Future<FinancialOutcome<WriteSuccess>> Function() run,
  ) async {
    calls.add((op, write, body));
    if (scripted.isNotEmpty) return scripted.removeFirst();
    final result = await run();
    if (lose > 0) {
      lose--;
      return FinancialNetworkFailure(StateError('응답 유실'));
    }
    return result;
  }

  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    if (failLoads > 0) {
      failLoads--;
      return FinancialNetworkFailure(StateError('조회 실패'));
    }
    return inner.loadSnapshot();
  }

  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadTransactionPage(
    String cursor,
  ) => inner.loadTransactionPage(cursor);

  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) => inner.linkInstitutions(institutionCodes, write);

  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) => inner.selectAccounts(accountIds, write);

  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) => inner.updateSalarySettings(salary, write);

  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) => inner.updateAccountNickname(accountId, nickname, write);

  @override
  Future<FinancialOutcome<WriteSuccess>> createObligation(
    ObligationInput obligation,
    WriteContext write,
  ) => _apply(
    'create',
    write,
    obligation.toJson(),
    () => inner.createObligation(obligation, write),
  );

  @override
  Future<FinancialOutcome<WriteSuccess>> updateObligation(
    String obligationId,
    ObligationPatch patch,
    WriteContext write,
  ) => _apply(
    'update',
    write,
    patch.toJson(),
    () => inner.updateObligation(obligationId, patch, write),
  );

  @override
  Future<FinancialOutcome<WriteSuccess>> cancelObligation(
    String obligationId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) => _apply('cancel', write, [
    for (final d in detach) d.toJson(),
  ], () => inner.cancelObligation(obligationId, detach, write));

  @override
  void close() => inner.close();
}
