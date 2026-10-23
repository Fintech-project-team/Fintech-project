import 'business_date.dart';
import 'money.dart';

/// 2026-10-23: 이 패키지가 구현한 계산 규칙 버전(docs/calculation-rules.md 제목).
const String supportedRuleVersion = 'PAYSE-CALC-1';

/// 2026-10-23: 계산 결과를 묶는 기준. 결과에 그대로 보존하며 다른 기준의 결과와 섞지 않는다.
class CalculationContext {
  /// 2026-10-23: 자료 버전 [dataVersion]·원천 버전 [sourceVersion]·규칙 버전 [ruleVersion]·
  /// 기준 시각 [asOf](오프셋 포함)·입력 버전 [inputRevision](0 이상)으로 만든다.
  /// 지원하지 않는 ruleVersion, 형식이 틀린 asOf, 음수 inputRevision은 입력 오류다.
  CalculationContext({
    required this.dataVersion,
    required this.sourceVersion,
    required this.ruleVersion,
    required this.asOf,
    required this.inputRevision,
  }) : asOfInstant = parseOffsetTimestamp(asOf, 'context.asOf') {
    requireId(dataVersion, 'context.dataVersion');
    requireId(sourceVersion, 'context.sourceVersion');
    if (ruleVersion != supportedRuleVersion) {
      throw CalculationInputException(
        InputErrorCode.unsupportedRuleVersion,
        'context.ruleVersion',
        '$supportedRuleVersion만 지원($ruleVersion)',
      );
    }
    if (inputRevision < 0) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'context.inputRevision',
        '0 이상이어야 함($inputRevision)',
      );
    }
  }

  final String dataVersion;
  final String sourceVersion;
  final String ruleVersion;
  final String asOf;
  final int inputRevision;

  /// 2026-10-23: asOf를 UTC로 읽은 시각.
  final DateTime asOfInstant;

  /// 2026-10-23: 계산 기준 업무 날짜 t0(asOf의 서울 날짜).
  BusinessDate get businessDate => BusinessDate.inSeoul(asOfInstant);
}

/// 2026-10-23: 계좌 한 개. 잔액은 원천 값이며 null은 미확보다(0원과 다름).
class AccountBalance {
  /// 2026-10-23: [accountId], 잔액 [balanceKrw](±상한, null 미확보), 잔액 기준 시각 [asOf](null 미확보),
  /// 홈 합산 선택 [included]로 만든다.
  AccountBalance({
    required this.accountId,
    required int? balanceKrw,
    required this.asOf,
    required this.included,
  }) : balanceKrw = balanceKrw == null
           ? null
           : requireSignedMoney(balanceKrw, 'accounts[$accountId].balanceKrw'),
       asOfInstant = asOf == null
           ? null
           : parseOffsetTimestamp(asOf, 'accounts[$accountId].asOf') {
    requireId(accountId, 'accounts.accountId');
  }

  final String accountId;
  final int? balanceKrw;
  final String? asOf;
  final DateTime? asOfInstant;
  final bool included;
}

/// 2026-10-23: 예정 지출 상태. paid는 사용자 값이 아니며 정산 연결로만 표현한다.
enum ObligationStatus { active, cancelled }

/// 2026-10-23: 예정 지출(의무) 하나. 금액·날짜는 사용자가 확인한 계획이다.
class Obligation {
  /// 2026-10-23: [obligationId], 출금 계좌 [withdrawalAccountId], 금액 [amountKrw](Money),
  /// 예정일 [dueDate](YYYY-MM-DD), 상태 [status]로 만든다.
  Obligation({
    required this.obligationId,
    required this.withdrawalAccountId,
    required int amountKrw,
    required String dueDate,
    required this.status,
  }) : amountKrw = requireMoney(
         amountKrw,
         'obligations[$obligationId].amountKrw',
       ),
       dueDate = BusinessDate.parse(
         dueDate,
         'obligations[$obligationId].dueDate',
       ) {
    requireId(obligationId, 'obligations.obligationId');
    requireId(
      withdrawalAccountId,
      'obligations[$obligationId].withdrawalAccountId',
    );
  }

  final String obligationId;
  final String withdrawalAccountId;
  final int amountKrw;
  final BusinessDate dueDate;
  final ObligationStatus status;
}

/// 2026-10-23: 모아둘 돈(보호 설정) 하나. amountKrw는 해제까지 반영한 현재 설정액 R이다.
class Reserve {
  /// 2026-10-23: [reserveId], 보호 계좌 [accountId], 설정액 [amountKrw](Money), 취소 시각 [cancelledAt](null 미취소)으로 만든다.
  Reserve({
    required this.reserveId,
    required this.accountId,
    required int amountKrw,
    required this.cancelledAt,
  }) : amountKrw = requireMoney(amountKrw, 'reserves[$reserveId].amountKrw') {
    requireId(reserveId, 'reserves.reserveId');
    requireId(accountId, 'reserves[$reserveId].accountId');
    if (cancelledAt != null) {
      parseOffsetTimestamp(cancelledAt!, 'reserves[$reserveId].cancelledAt');
    }
  }

  final String reserveId;
  final String accountId;
  final int amountKrw;
  final String? cancelledAt;

  /// 2026-10-23: 취소 기록이 있으면 true. 기록 시각이 asOf보다 늦어도 저장된 취소다.
  bool get cancelled => cancelledAt != null;
}

/// 2026-10-23: 보호액을 의무에 명시 배정한 기록(O의 근거).
class ReserveAllocation {
  /// 2026-10-23: [allocationId], [reserveId], [obligationId], 배정 총액 [amountKrw](PositiveMoney),
  /// 해제 누계 [releasedKrw](0~amountKrw)로 만든다.
  ReserveAllocation({
    required this.allocationId,
    required this.reserveId,
    required this.obligationId,
    required int amountKrw,
    required int releasedKrw,
  }) : amountKrw = requirePositiveMoney(
         amountKrw,
         'allocations[$allocationId].amountKrw',
       ),
       releasedKrw = requireMoney(
         releasedKrw,
         'allocations[$allocationId].releasedKrw',
       ) {
    requireId(allocationId, 'allocations.allocationId');
    requireId(reserveId, 'allocations[$allocationId].reserveId');
    requireId(obligationId, 'allocations[$allocationId].obligationId');
    if (this.releasedKrw > this.amountKrw) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'allocations[$allocationId].releasedKrw',
        '해제 누계가 배정액보다 큼',
      );
    }
  }

  final String allocationId;
  final String reserveId;
  final String obligationId;
  final int amountKrw;
  final int releasedKrw;

  /// 2026-10-23: 미해제 배정액(amountKrw − releasedKrw).
  int get unreleasedKrw => amountKrw - releasedKrw;
}

/// 2026-10-23: 확인된 실제 출금과 의무의 지급 연결.
class SettlementLink {
  /// 2026-10-23: [linkId], [obligationId], 출금 거래 [transactionId], 배분액 [allocatedKrw](PositiveMoney),
  /// 무효 시각 [invalidatedAt](null 유효)으로 만든다.
  SettlementLink({
    required this.linkId,
    required this.obligationId,
    required this.transactionId,
    required int allocatedKrw,
    required this.invalidatedAt,
  }) : allocatedKrw = requirePositiveMoney(
         allocatedKrw,
         'settlements[$linkId].allocatedKrw',
       ) {
    requireId(linkId, 'settlements.linkId');
    requireId(obligationId, 'settlements[$linkId].obligationId');
    requireId(transactionId, 'settlements[$linkId].transactionId');
    if (invalidatedAt != null) {
      parseOffsetTimestamp(
        invalidatedAt!,
        'settlements[$linkId].invalidatedAt',
      );
    }
  }

  final String linkId;
  final String obligationId;
  final String transactionId;
  final int allocatedKrw;
  final String? invalidatedAt;

  /// 2026-10-23: 무효 기록이 없으면 true. 기록 시각이 asOf보다 늦어도 저장된 정정이므로 무효다.
  bool get valid => invalidatedAt == null;
}

/// 2026-10-23: 급여 입금 확인 상태. confirmed만 입금 완료이며 partial 합계로 전환하지 않는다.
enum SalaryConfirmation { unknown, partial, confirmed }

/// 2026-10-23: 월별 급여 입금 근거 하나.
class SalaryReceipt {
  /// 2026-10-23: 예정일 [expectedPayDate](YYYY-MM-DD), 근거 거래 [transactionIds], 확인 상태 [confirmation]으로 만든다.
  SalaryReceipt({
    required String expectedPayDate,
    required List<String> transactionIds,
    required this.confirmation,
  }) : expectedPayDate = BusinessDate.parse(
         expectedPayDate,
         'receiptEvidence.expectedPayDate',
       ),
       transactionIds = List.unmodifiable(transactionIds);

  final BusinessDate expectedPayDate;
  final List<String> transactionIds;
  final SalaryConfirmation confirmation;
}

/// 2026-10-23: 월급 설정. salaryDay null은 미입력이며 0이나 임의 날짜로 바꾸지 않는다.
/// 근거 목록은 이 asOf에 유효한 상태로 전달돼야 한다. 계산은 확인 시각을 읽지 않으므로
/// 더 나중 상태를 과거 asOf와 함께 넘기면 확인 전 상태를 복원하지 못한다.
class SalaryInput {
  /// 2026-10-23: 월급일 [salaryDay](1~31, null 미입력), 입금 근거 [receiptEvidence]로 만든다.
  /// []는 확인된 근거 없음, null은 접근 제한 등으로 근거를 받지 못한 상태다.
  SalaryInput({
    required this.salaryDay,
    required List<SalaryReceipt>? receiptEvidence,
  }) : receiptEvidence = receiptEvidence == null
           ? null
           : List.unmodifiable(receiptEvidence) {
    final day = salaryDay;
    if (day != null && (day < 1 || day > 31)) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'salary.salaryDay',
        '1~31이어야 함($day)',
      );
    }
  }

  final int? salaryDay;
  final List<SalaryReceipt>? receiptEvidence;
}

/// 2026-10-23: 장부 입력 묶음. 목록의 null은 미확인(미수신), 빈 목록은 확인된 0건이다.
class LedgerInput {
  /// 2026-10-23: 기준 [context], 연결 계좌 전체 [accounts](포함·제외 모두), 의무·보호액·배정·정산 목록으로 만든다.
  /// 목록은 복사해 수정 불가로 보관한다.
  LedgerInput({
    required this.context,
    required List<AccountBalance> accounts,
    required List<Obligation>? obligations,
    required List<Reserve>? reserves,
    required List<ReserveAllocation>? allocations,
    required List<SettlementLink>? settlements,
  }) : accounts = List.unmodifiable(accounts),
       obligations = obligations == null
           ? null
           : List.unmodifiable(obligations),
       reserves = reserves == null ? null : List.unmodifiable(reserves),
       allocations = allocations == null
           ? null
           : List.unmodifiable(allocations),
       settlements = settlements == null
           ? null
           : List.unmodifiable(settlements);

  final CalculationContext context;
  final List<AccountBalance> accounts;
  final List<Obligation>? obligations;
  final List<Reserve>? reserves;
  final List<ReserveAllocation>? allocations;
  final List<SettlementLink>? settlements;
}
