import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/connection/connection_test_utils.dart';

const _kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _kbDeposit = '2c56e23d-2e82-59ed-8fce-21459e226167';
const _hanaDemand = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
const _ibkDemand = '4021635f-1b2c-534d-b5b6-9680b3c8d5f2';
const _kakaoDemand = '1ce9128d-d667-5bfc-bed0-949a571c78f5';

/// 2026-10-29: 데모알파를 모두 연결하고 계좌 선택을 차례로 저장하는 가짜 서버 세션.
class _Session {
  _Session(this.repo);

  final FakeUserFinancialRepository repo;
  var _version = 2;

  /// 2026-10-29: [ids]를 계산 포함 계좌로 저장하고 응답 Snapshot을 반환한다.
  Future<FinancialSnapshot> select(List<String> ids) async {
    final saved = await repo.selectAccounts(
      ids,
      WriteContext(
        expectedDataVersion: '${_version++}',
        ruleVersion: 'PAYSE-CALC-1',
        idempotencyKey: 'select-$_version',
      ),
    );
    return FinancialSnapshot.fromJson(
      (saved as FinancialOk<WriteSuccess>).value.snapshot,
    );
  }
}

/// 2026-10-29: 데모알파(demo-ready) 금융사를 모두 연결한 세션을 반환한다.
Future<_Session> _linked() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource('demo-ready'),
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final repo = FakeUserFinancialRepository(
    server: server,
    accessToken: (session as AuthOk<DemoSession>).value.accessToken,
  );
  await repo.linkInstitutions(
    const [
      'bank.kb',
      'bank.shinhan',
      'bank.hana',
      'bank.ibk',
      'bank.kakao',
      'card.hyundai',
      'card.samsung',
      'card.woori',
      'card.kb',
    ],
    const WriteContext(
      expectedDataVersion: '1',
      ruleVersion: 'PAYSE-CALC-1',
      idempotencyKey: 'link',
    ),
  );
  return _Session(repo);
}

/// 2026-10-29: 월급 근거(월급일·월급 계좌·입금 확인 근거)를 비교할 수 있는 글자로 반환한다.
String _salaryBasis(FinancialSnapshot s) {
  final salary = s.settings!.salary;
  return [
    salary.salaryDay,
    salary.salaryAccountId,
    for (final r in salary.receiptEvidence ?? const [])
      '${r.payMonth}:${r.confirmation}:${r.transactionIds.join('+')}',
  ].join('|');
}

/// 2026-10-29: [s]로 계산한 결과를 반환한다. 계산 불가·오류면 실패한다.
calc.CurrentAmountResult _calculated(FinancialSnapshot s) {
  final c = computeHomeCalculation(s);
  expect(c, isA<HomeCalculationReady>());
  final result = (c as HomeCalculationReady).result;
  expect(result.insufficient, isEmpty);
  expect(result.calculated, isTrue);
  return result;
}

void main() {
  test('excluding the salary account from the calculation keeps the salary '
      'basis and still calculates', () async {
    final session = await _linked();
    final before = await session.select([
      _kbDemand,
      _hanaDemand,
      _ibkDemand,
      _kakaoDemand,
    ]);
    final after = await session.select([_hanaDemand, _ibkDemand, _kakaoDemand]);

    expect(
      after.accounts!.singleWhere((a) => a.accountId == _kbDemand).included,
      isFalse,
    );
    expect(_salaryBasis(after), _salaryBasis(before));
    expect(after.settings!.salary.salaryAccountId, _kbDemand);
    expect(
      after.settings!.salary.receiptEvidence!.single.confirmation,
      'confirmed',
    );

    final was = _calculated(before);
    final now = _calculated(after);
    expect(now.salaryCycle!.state, was.salaryCycle!.state);
    expect(now.salaryCycle!.state, calc.SalaryCycleState.normal);
    expect(was.b, 2000000);
    expect(now.b, 500000, reason: '월급 계좌 잔액 1,500,000원만 B에서 빠짐');
    expect(now.r, 0, reason: '월급 계좌의 모아둘 돈 400,000원은 R에서 빠짐');
    expect(now.u, 500000);
  });

  test('the salary basis survives later account changes', () async {
    final session = await _linked();
    final first = await session.select([
      _kbDemand,
      _hanaDemand,
      _ibkDemand,
      _kakaoDemand,
    ]);
    for (final ids in [
      [_ibkDemand],
      [_kbDeposit, _hanaDemand],
      [_kbDemand, _kbDeposit],
    ]) {
      final s = await session.select(ids);
      expect(_salaryBasis(s), _salaryBasis(first), reason: '$ids');
      expect(
        _calculated(s).salaryCycle!.state,
        calc.SalaryCycleState.normal,
        reason: '$ids',
      );
    }
  });
}
