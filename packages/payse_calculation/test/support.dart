import 'package:payse_calculation/payse_calculation.dart';

/// 2026-10-23: 테스트 기준 [asOf](오프셋 포함)로 계산 기준을 만든다.
CalculationContext context(String asOf, {int inputRevision = 1}) =>
    CalculationContext(
      dataVersion: '7',
      sourceVersion: 'test-source',
      ruleVersion: 'PAYSE-CALC-1',
      asOf: asOf,
      inputRevision: inputRevision,
    );

/// 2026-10-23: [asOf] 기준 잔액 [balance]인 계좌 [id]를 만든다. [included]가 false면 제외 계좌다.
AccountBalance account(
  String id,
  int? balance,
  String asOf, {
  bool included = true,
}) => AccountBalance(
  accountId: id,
  balanceKrw: balance,
  asOf: balance == null ? null : asOf,
  included: included,
);

/// 2026-10-23: [account] 계좌에서 [due]에 [amount]원 나갈 의무 [id]를 만든다.
Obligation obligation(
  String id,
  int amount,
  String due, {
  String account = 'acc-main',
  ObligationStatus status = ObligationStatus.active,
}) => Obligation(
  obligationId: id,
  withdrawalAccountId: account,
  amountKrw: amount,
  dueDate: due,
  status: status,
);

/// 2026-10-23: 의무 [obligationId]에 거래 [tx]로 [amount]원을 배분한 정산 연결 [id]를 만든다.
SettlementLink settlement(
  String id,
  String obligationId,
  int amount, {
  String? tx,
  String? invalidatedAt,
}) => SettlementLink(
  linkId: id,
  obligationId: obligationId,
  transactionId: tx ?? 'tx-$id',
  allocatedKrw: amount,
  invalidatedAt: invalidatedAt,
);

/// 2026-10-23: 장부 입력을 만든다. 목록 기본값은 확인된 빈 목록이다.
LedgerInput ledger(
  CalculationContext ctx,
  List<AccountBalance> accounts, {
  List<Obligation>? obligations = const [],
  List<Reserve>? reserves = const [],
  List<ReserveAllocation>? allocations = const [],
  List<SettlementLink>? settlements = const [],
}) => LedgerInput(
  context: ctx,
  accounts: accounts,
  obligations: obligations,
  reserves: reserves,
  allocations: allocations,
  settlements: settlements,
);

/// 2026-10-26: [payMonth] 회차, 예정일 [date], 상태 [state]의 근거를 만든다.
SalaryReceipt receipt(String payMonth, String date, SalaryConfirmation state) =>
    SalaryReceipt(
      payMonth: payMonth,
      expectedPayDate: date,
      transactionIds: state == SalaryConfirmation.unknown
          ? []
          : ['salary-$payMonth'],
      confirmation: state,
    );

/// 2026-10-23: [day]일 월급과 [receipts]((예정일, 상태)) 근거로 월급 설정을 만든다.
/// 2026-10-26: 이동하지 않은 예정일 사례용이라 회차는 예정일의 연월로 둔다. 이동 사례는 [salaryOf]를 쓴다.
SalaryInput salary(int? day, List<(String, SalaryConfirmation)> receipts) =>
    salaryOf(day, [
      for (final (date, state) in receipts)
        receipt(date.substring(0, 7), date, state),
    ]);

/// 2026-10-26: [day]일 월급과 회차 근거 [receipts]로 월급 설정을 만든다.
SalaryInput salaryOf(int? day, List<SalaryReceipt> receipts) =>
    SalaryInput(salaryDay: day, receiptEvidence: receipts);

/// 2026-10-23: 장부 [l]과 월급 [s]로 홈 금액을 계산한다.
CurrentAmountResult current(LedgerInput l, SalaryInput? s) =>
    calculateCurrentAmount(CurrentAmountInput(ledger: l, salary: s));

/// 2026-10-23: 의무 [id]의 계산 근거 줄을 찾는다.
ObligationLine line(CurrentAmountResult r, String id) =>
    r.obligationLines!.firstWhere((l) => l.obligationId == id);

/// 2026-10-23: 사용자가 가정한 월급일 [date]와 금액 [amount]를 만든다.
PlannedPayDate pay(String date, int? amount) => PlannedPayDate(
  date: date,
  amountKrw: amount,
  basis: PayDateBasis.recurringSetting,
);
