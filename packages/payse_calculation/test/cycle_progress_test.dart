import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

// 홈 달 표시용 주기 진행률(#28, 2026-10-26 확정). 주기 판단은 resolveSalaryCycle 그대로다.
const ok = SalaryConfirmation.confirmed;
const unknown = SalaryConfirmation.unknown;

/// 2026-10-26: [today]의 주기와 진행률을 반환한다. 월급일은 25일이다.
(SalaryCycle, double?) at(
  BusinessDate today,
  List<(String, SalaryConfirmation)> receipts,
) {
  final cycle = resolveSalaryCycle(today, salary(25, receipts));
  return (cycle, cycleProgress(cycle, today));
}

void main() {
  const september = ('2026-09-25', ok);

  test('정상 주기: 시작일 0, 중간, 예정일 전날 1', () {
    expect(at(BusinessDate(2026, 9, 25), [september]).$2, 0);
    expect(
      at(BusinessDate(2026, 10, 10), [september]).$2,
      closeTo(15 / 29, 1e-9),
    );
    expect(at(BusinessDate(2026, 10, 24), [september]).$2, 1);
  });

  test('예정일에 도달했지만 입금 확인 전이면 진행률이 없다(입금 대기)', () {
    final (cycle, progress) = at(BusinessDate(2026, 10, 25), [
      september,
      ('2026-10-25', unknown),
    ]);
    expect(cycle.state, SalaryCycleState.awaitingDeposit);
    expect(progress, isNull);
  });

  test('예정일이 지나도 입금 대기면 진행률이 없다', () {
    final (cycle, progress) = at(BusinessDate(2026, 10, 28), [
      september,
      ('2026-10-25', unknown),
    ]);
    expect(cycle.state, SalaryCycleState.awaitingDeposit);
    expect(progress, isNull);
  });

  test('예정일에 입금이 확인되면 새 주기 시작이라 0이다', () {
    final (cycle, progress) = at(BusinessDate(2026, 10, 25), [
      september,
      ('2026-10-25', ok),
    ]);
    expect(cycle.state, SalaryCycleState.normal);
    expect(cycle.periodStart, BusinessDate(2026, 10, 25));
    expect(progress, 0);
    expect(
      at(BusinessDate(2026, 11, 24), [september, ('2026-10-25', ok)]).$2,
      1,
    );
  });

  test('조기 입금 확인: 시작일을 모르면 그 회차 예정일까지 0이고 주기 시작일은 비워 둔다', () {
    final (cycle, progress) = at(BusinessDate(2026, 10, 23), [
      september,
      ('2026-10-25', ok),
    ]);
    expect(cycle.state, SalaryCycleState.normal);
    expect(cycle.periodStart, isNull, reason: '표시 기준일을 실제 시작일로 쓰지 않는다');
    expect(cycle.periodEnd, BusinessDate(2026, 11, 25));
    expect(progress, 0);
  });

  test('근거가 없으면 정보 부족이라 진행률이 없다', () {
    final (cycle, progress) = at(BusinessDate(2026, 10, 28), [september]);
    expect(cycle.state, SalaryCycleState.insufficientData);
    expect(progress, isNull);
  });

  test('홈 계산 결과는 같은 주기의 진행률을 담는다', () {
    const asOf = '2026-10-19T12:00:00+09:00';
    final r = current(
      ledger(context(asOf), [account('acc-main', 1000000, asOf)]),
      salary(25, [september]),
    );
    expect(r.cycleProgress, closeTo(24 / 29, 1e-9));
  });
}
