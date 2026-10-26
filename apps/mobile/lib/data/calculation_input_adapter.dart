import 'package:payse_calculation/payse_calculation.dart' as calc;

import 'financial_snapshot.dart';

/// 2026-10-23: 스냅샷이 계산 입력 계약을 어겼다(초과 정산·계좌 불일치·근거 거래 상태·원천 버전 등).
/// 정상적인 자료 누락(접근 제한·미수신·미확보)과 구분하며 계산을 계속하지 않는다.
class CalculationContractException implements Exception {
  /// 2026-10-23: 문제 위치 [path]와 이유 [reason]으로 만든다.
  const CalculationContractException(this.path, this.reason);

  final String path;
  final String reason;

  /// 2026-10-23: 위치와 이유를 합친 설명을 반환한다.
  @override
  String toString() => 'CalculationContractException($path: $reason)';
}

/// 2026-10-23: 한 스냅샷에서 만든 홈 계산 입력. [salary]가 null이면 월급 설정을 받지 못한 상태다.
class CalculationInputs {
  /// 2026-10-23: 장부 입력 [ledger]와 월급 입력 [salary]로 만든다.
  const CalculationInputs({required this.ledger, required this.salary});

  final calc.LedgerInput ledger;
  final calc.SalaryInput? salary;
}

/// 2026-10-23: [snapshot] 하나로 계산 패키지 입력을 만든다. 금액·날짜를 보정하거나 계산하지 않는다.
/// 홈에는 사용자 입력이 없어 inputRevision은 0이다. 계약 위반은 [CalculationContractException],
/// 계산 패키지의 값 검사 위반은 CalculationInputException으로 그대로 던진다.
/// 접근 제한·미수신·미확보 거래처럼 정상적인 누락은 해당 목록을 null로 넘겨 정보 부족으로 계산되게 한다.
/// 근거를 일부 받지 못했어도 받은 근거는 끝까지 검사하므로, 확정 위반이 하나라도 있으면 입력 순서와 무관하게 위반이다.
CalculationInputs calculationInputsFromSnapshot(FinancialSnapshot snapshot) {
  final accounts = snapshot.accounts;
  if (accounts == null) {
    throw const CalculationContractException(r'$.accounts', '연결 후 계좌 목록이 없음');
  }
  final context = calc.CalculationContext(
    dataVersion: snapshot.dataVersion,
    sourceVersion: snapshot.sourceVersion,
    ruleVersion: snapshot.ruleVersion,
    asOf: snapshot.asOf,
    inputRevision: 0,
  );
  final evidence = _Evidence(snapshot, accounts);

  return CalculationInputs(
    ledger: calc.LedgerInput(
      context: context,
      accounts: [
        for (final a in accounts)
          calc.AccountBalance(
            accountId: a.accountId,
            balanceKrw: a.balanceKrw,
            asOf: a.asOf,
            included: a.included,
          ),
      ],
      obligations: _obligationsHidingIncluded(snapshot)
          ? null
          : snapshot.obligations
                ?.map(
                  (o) => calc.Obligation(
                    obligationId: o.obligationId,
                    withdrawalAccountId: o.withdrawalAccountId,
                    amountKrw: o.amountKrw,
                    dueDate: o.dueDate,
                    status: o.status == 'cancelled'
                        ? calc.ObligationStatus.cancelled
                        : calc.ObligationStatus.active,
                  ),
                )
                .toList(),
      reserves: snapshot.reserves
          ?.map(
            (r) => calc.Reserve(
              reserveId: r.reserveId,
              accountId: r.accountId,
              amountKrw: r.amountKrw,
              cancelledAt: r.cancelledAt,
            ),
          )
          .toList(),
      allocations: snapshot.allocations
          ?.map(
            (a) => calc.ReserveAllocation(
              allocationId: a.allocationId,
              reserveId: a.reserveId,
              obligationId: a.obligationId,
              amountKrw: a.amountKrw,
              releasedKrw: a.releasedKrw,
            ),
          )
          .toList(),
      settlements: _settlements(snapshot, evidence),
    ),
    salary: _salary(snapshot, evidence),
  );
}

/// 2026-10-23: 근거 거래를 찾고 같은 스냅샷 원천인지 검사한다.
class _Evidence {
  /// 2026-10-23: [snapshot]과 그 계좌 목록 [accounts]로 거래·계좌·참조 확보 상태 표를 만든다.
  /// 같은 거래 ID가 두 번 오면 계약 위반이다.
  _Evidence(this.snapshot, List<Account> accounts)
    : _accounts = {for (final a in accounts) a.accountId: a},
      _asOf = DateTime.parse(snapshot.asOf) {
    for (final t in [
      ...?snapshot.transactions,
      ...?snapshot.relatedTransactions,
    ]) {
      if (_transactions.containsKey(t.transactionId)) {
        throw CalculationContractException(
          r'$.transactions',
          '같은 거래 ID가 두 번 옴(${t.transactionId})',
        );
      }
      _transactions[t.transactionId] = t;
    }
    for (final r in snapshot.referenceResolutions ?? const []) {
      _resolutions[r.transactionId] = r.status;
    }
  }

  final FinancialSnapshot snapshot;
  final Map<String, Account> _accounts;
  final DateTime _asOf;
  final Map<String, SourceTransaction> _transactions = {};
  final Map<String, String> _resolutions = {};

  /// 2026-10-23: 거래 [id]를 반환한다. 다음 페이지에 남았거나 참조 확보 상태가 unavailable이면
  /// 미수신으로 null을 반환한다. 그 밖에 응답에 없으면(resolved인데 없음 포함) [path]의 계약 위반이다.
  SourceTransaction? find(String id, String path) {
    final tx = _transactions[id];
    if (tx != null) return tx;
    final resolution = _resolutions[id];
    if (resolution == 'unavailable') return null;
    if (resolution == null && snapshot.hasMoreTransactions) return null;
    throw CalculationContractException(path, '근거 거래가 응답에 없음($id)');
  }

  /// 2026-10-23: 근거 거래 [tx]와 그 계좌가 이 스냅샷의 원천 버전·잔액 기준시각과 같은지 검사한다.
  /// 같은 JSON에 들어 있다는 것만으로 같은 원천이라고 보지 않는다.
  void requireSameSource(SourceTransaction tx, String path) {
    if (tx.sourceVersion != snapshot.sourceVersion) {
      throw CalculationContractException(path, '근거 거래의 원천 버전이 스냅샷과 다름');
    }
    final account = _accounts[tx.accountId];
    if (account == null) {
      throw CalculationContractException(path, '근거 거래의 계좌가 응답에 없음');
    }
    final accountAsOf = account.asOf;
    if (account.sourceVersion != snapshot.sourceVersion ||
        accountAsOf == null ||
        !DateTime.parse(accountAsOf).isAtSameMomentAs(_asOf)) {
      throw CalculationContractException(
        path,
        '근거 거래 계좌의 원천 버전·잔액 기준시각이 스냅샷과 다름',
      );
    }
  }

  /// 2026-10-26: 급여 근거 거래 [tx]의 입금일이 스냅샷 기준 날짜(asOf의 서울 날짜)보다 늦으면 계약 위반이다.
  /// 나중 시점의 confirmed·partial 상태를 과거 스냅샷에 섞은 입력을 받지 않는다. 입금일이 없으면 검사하지 않는다.
  void requireNotAfterAsOf(SourceTransaction tx, String path) {
    final booked = tx.bookingDate;
    if (booked == null) return;
    final seoul = _asOf.toUtc().add(const Duration(hours: 9));
    final today =
        '${seoul.year.toString().padLeft(4, '0')}-'
        '${seoul.month.toString().padLeft(2, '0')}-'
        '${seoul.day.toString().padLeft(2, '0')}';
    if (booked.compareTo(today) > 0) {
      throw CalculationContractException(path, '근거 거래 입금일이 스냅샷 기준 날짜보다 늦음');
    }
  }
}

/// 2026-10-23: 계획 버전이 숨겨져 포함 계좌의 의무가 빠졌을 수 있으면 true다.
/// 계좌가 미연결이라 숨긴 의무(targetKind account)는 홈 포함 계좌에 속할 수 없어 영향이 없다.
bool _obligationsHidingIncluded(FinancialSnapshot snapshot) =>
    snapshot.accessRestrictions.any(
      (r) =>
          r.ownerType == 'response' &&
          r.field == 'obligations' &&
          (r.targetKind == 'plan' || r.targetKind == 'planRevision'),
    );

/// 2026-10-23: 지급 연결을 검사해 계산 입력으로 바꾼다. 유효 연결만 거래별 배분 합계에 넣는다.
/// 받은 연결은 모두 검사한 뒤, 포함 계좌 의무의 정산 거래가 숨겨졌거나 미수신·미확보가 있으면
/// 정산 합계가 완전하지 않아 null(정보 부족)을 반환한다.
List<calc.SettlementLink>? _settlements(
  FinancialSnapshot snapshot,
  _Evidence evidence,
) {
  final settlements = snapshot.settlements;
  if (settlements == null) return null;
  final obligations = {
    for (final o in snapshot.obligations ?? const <Obligation>[])
      o.obligationId: o,
  };
  final includedAccountIds = {
    for (final a in snapshot.accounts!)
      if (a.included) a.accountId,
  };

  var incomplete = false;
  final perTransaction = <String, int>{};
  for (final link in settlements) {
    if (link.invalidatedAt != null) continue;
    final path =
        r'$.settlements'
        '[${link.linkId}]';
    if (link.evidenceRefs.isEmpty) {
      throw CalculationContractException(path, '정산 근거가 없음');
    }
    final tx = evidence.find(link.transactionId, path);
    if (tx == null) {
      incomplete = true;
      continue;
    }
    if (tx.recordKind != 'account_entry' ||
        tx.direction != 'out' ||
        tx.status != 'posted') {
      throw CalculationContractException(path, '정산 거래가 확정된 계좌 출금이 아님');
    }
    final obligation = obligations[link.obligationId]!;
    if (tx.accountId != obligation.withdrawalAccountId) {
      throw CalculationContractException(path, '정산 거래 계좌가 의무의 출금 계좌와 다름');
    }
    evidence.requireSameSource(tx, path);
    final total = (perTransaction[tx.transactionId] ?? 0) + link.allocatedKrw;
    if (total > tx.amountKrw) {
      throw CalculationContractException(path, '거래별 정산 배분 합계가 실제 출금액을 넘음');
    }
    perTransaction[tx.transactionId] = total;
  }

  final hidden = snapshot.accessRestrictions.any((r) {
    if (r.ownerType == 'response' && r.field == 'settlements') {
      return r.targetKind == 'transaction';
    }
    if (r.ownerType == 'obligation' && r.field == 'settlements') {
      final o = obligations[r.ownerId];
      return o != null &&
          o.status == 'active' &&
          includedAccountIds.contains(o.withdrawalAccountId);
    }
    return false;
  });
  if (incomplete || hidden) return null;

  return [
    for (final link in settlements)
      calc.SettlementLink(
        linkId: link.linkId,
        obligationId: link.obligationId,
        transactionId: link.transactionId,
        allocatedKrw: link.allocatedKrw,
        invalidatedAt: link.invalidatedAt,
      ),
  ];
}

/// 2026-10-23: 월급 설정과 입금 근거를 계산 입력으로 바꾼다. partial·confirmed 근거의 거래는
/// 같은 스냅샷 원천의 posted 계좌 입금이며 잔액에 반영돼야 하고, 입금일이 기준 날짜보다 늦지 않아야 한다. 받은 근거는 모두 검사한 뒤,
/// 근거 키가 접근 제한으로 생략됐거나 근거 거래가 미수신·미확보면 근거를 null(미수신)로 넘긴다.
calc.SalaryInput? _salary(FinancialSnapshot snapshot, _Evidence evidence) {
  final settings = snapshot.settings;
  if (settings == null) return null;
  final salary = settings.salary;
  final receipts = salary.receiptEvidence;
  if (receipts == null) {
    return calc.SalaryInput(salaryDay: salary.salaryDay, receiptEvidence: null);
  }

  var incomplete = false;
  for (final receipt in receipts) {
    if (receipt.confirmation == 'unknown') continue;
    final path =
        r'$.settings.salary.receiptEvidence'
        '[${receipt.payMonth}]';
    if (receipt.transactionIds.isEmpty) {
      throw CalculationContractException(path, '입금 확인 근거에 거래가 없음');
    }
    for (final id in receipt.transactionIds) {
      final tx = evidence.find(id, path);
      if (tx == null) {
        incomplete = true;
        continue;
      }
      if (tx.recordKind != 'account_entry' ||
          tx.direction != 'in' ||
          tx.status != 'posted' ||
          tx.reflectionReason != 'reflected') {
        throw CalculationContractException(path, '근거 거래가 잔액에 반영된 확정 계좌 입금이 아님');
      }
      evidence.requireSameSource(tx, path);
      evidence.requireNotAfterAsOf(tx, path);
    }
  }

  return calc.SalaryInput(
    salaryDay: salary.salaryDay,
    receiptEvidence: incomplete
        ? null
        : [
            for (final r in receipts)
              calc.SalaryReceipt(
                payMonth: r.payMonth,
                expectedPayDate: r.expectedPayDate,
                transactionIds: r.transactionIds,
                confirmation: switch (r.confirmation) {
                  'partial' => calc.SalaryConfirmation.partial,
                  'confirmed' => calc.SalaryConfirmation.confirmed,
                  _ => calc.SalaryConfirmation.unknown,
                },
              ),
          ],
  );
}
