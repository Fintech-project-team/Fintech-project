import 'inputs.dart';
import 'money.dart';

/// 2026-10-23: 값을 계산할 수 없는 이유. 입력 오류가 아니라 정보 부족·보류 상태이며 0원으로 바꾸지 않는다.
enum InsufficientReason {
  noIncludedAccount,
  balanceMissing,
  balanceAsOfMismatch,
  obligationsMissing,
  reservesMissing,
  allocationsMissing,
  settlementsMissing,
  salarySettingsMissing,
  salaryDayMissing,

  /// 2026-10-23: 접근 제한 등으로 입금 근거 목록을 받지 못했다(확인된 빈 목록과 다름).
  receiptEvidenceUnavailable,

  /// 2026-10-23: 직전 월급일 회차의 입금 근거 항목이 없어 입금 여부를 알 수 없다(unknown과 다름).
  receiptEvidenceAbsent,

  /// 2026-10-26: 서로 다른 회차의 예정일이 같아 회차를 구분해야 하거나 길이 0 구간이 되는 홈 계산. 원천은 보존한다.
  payDateConflict,

  /// 2026-10-26: 남은 미확인 회차·같은 날 여러 회차·partial 잔여분 때문에 예상 급여 입금의 금액·시점을 알 수 없다.
  /// 그 날짜가 든 구간부터 시뮬레이션 값을 두지 않는다.
  salaryInflowUncertain,
  payDateMissing,
  salaryAmountMissing,
  cardScheduleUnknown,
}

/// 2026-10-23: 정산을 반영한 의무 한 건의 상태.
class ObligationState {
  /// 2026-10-23: 원본 [obligation], 유효 정산 합계 [settledKrw], 잔여 [remainingKrw]로 만든다.
  const ObligationState(this.obligation, this.settledKrw, this.remainingKrw);

  final Obligation obligation;
  final int settledKrw;
  final int remainingKrw;

  /// 2026-10-23: 활성이고 잔여가 있으면 true(E·예약 후보).
  bool get open =>
      obligation.status == ObligationStatus.active && remainingKrw > 0;
}

/// 2026-10-23: 검증을 마친 장부. 홈 금액과 구간 계산이 같은 집합 정의를 쓰도록 공유한다.
class Ledger {
  Ledger._({
    required this.input,
    required this.accounts,
    required this.b,
    required this.bIssues,
    required this.obligations,
    required this.obligationIssues,
    required this.r,
    required this.reserveIdsInR,
    required this.reserveIssues,
    required this.overlapByObligation,
    required this.overlapIssues,
  });

  final LedgerInput input;
  final Map<String, AccountBalance> accounts;
  final int? b;
  final List<InsufficientReason> bIssues;

  /// 2026-10-23: obligationId 순으로 정렬한 의무 상태. 의무·정산 목록이 모두 있어야 만든다.
  final List<ObligationState>? obligations;
  final List<InsufficientReason> obligationIssues;
  final int? r;
  final Set<String>? reserveIdsInR;
  final List<InsufficientReason> reserveIssues;

  /// 2026-10-23: 의무별로 R 집합 보호액에서 온 미해제 배정 합계.
  final Map<String, int>? overlapByObligation;
  final List<InsufficientReason> overlapIssues;

  /// 2026-10-23: [accountId] 계좌가 홈 합산에 포함됐으면 true.
  bool isIncluded(String accountId) => accounts[accountId]!.included;

  /// 2026-10-23: [input]을 검증해 장부를 만든다. 중복 ID·없는 참조·초과 정산·초과 배정은
  /// CalculationInputException이며 잘라내거나 순서에 따라 일부만 인정하지 않는다.
  factory Ledger.prepare(LedgerInput input) {
    final accounts = <String, AccountBalance>{};
    for (final a in input.accounts) {
      if (accounts.containsKey(a.accountId)) {
        throw CalculationInputException(
          InputErrorCode.duplicateId,
          'accounts',
          a.accountId,
        );
      }
      accounts[a.accountId] = a;
    }

    final bIssues = <InsufficientReason>[];
    final b = _sumIncludedBalances(input, accounts.values, bIssues);

    final obligationList = input.obligations;
    final obligationsById = <String, Obligation>{};
    if (obligationList != null) {
      for (final o in obligationList) {
        if (obligationsById.containsKey(o.obligationId)) {
          throw CalculationInputException(
            InputErrorCode.duplicateId,
            'obligations',
            o.obligationId,
          );
        }
        _requireAccount(
          accounts,
          o.withdrawalAccountId,
          'obligations[${o.obligationId}].withdrawalAccountId',
        );
        obligationsById[o.obligationId] = o;
      }
    }

    final settledByObligation = _validSettlementTotals(
      input.settlements,
      obligationList == null ? null : obligationsById,
    );

    final obligationIssues = <InsufficientReason>[
      if (obligationList == null) InsufficientReason.obligationsMissing,
      if (input.settlements == null) InsufficientReason.settlementsMissing,
    ];
    List<ObligationState>? states;
    if (obligationIssues.isEmpty) {
      final ids = obligationsById.keys.toList()..sort();
      states = [
        for (final id in ids)
          ObligationState(
            obligationsById[id]!,
            settledByObligation![id] ?? 0,
            obligationsById[id]!.amountKrw - (settledByObligation[id] ?? 0),
          ),
      ];
    }

    final reserveList = input.reserves;
    final reservesById = <String, Reserve>{};
    final reserveIssues = <InsufficientReason>[];
    int? r;
    Set<String>? inR;
    if (reserveList == null) {
      reserveIssues.add(InsufficientReason.reservesMissing);
    } else {
      for (final rv in reserveList) {
        if (reservesById.containsKey(rv.reserveId)) {
          throw CalculationInputException(
            InputErrorCode.duplicateId,
            'reserves',
            rv.reserveId,
          );
        }
        _requireAccount(
          accounts,
          rv.accountId,
          'reserves[${rv.reserveId}].accountId',
        );
        reservesById[rv.reserveId] = rv;
      }
      // 제외 계좌 보호액은 B에서 그 잔액을 뺐으므로 R에 다시 넣지 않는다(TC-C04).
      inR = {
        for (final rv in reservesById.values)
          if (!rv.cancelled && accounts[rv.accountId]!.included) rv.reserveId,
      };
      var sum = 0;
      for (final id in inR.toList()..sort()) {
        sum = addKrw(sum, reservesById[id]!.amountKrw, 'R');
      }
      r = sum;
    }

    final overlapIssues = <InsufficientReason>[
      ...obligationIssues,
      ...reserveIssues,
      if (input.allocations == null) InsufficientReason.allocationsMissing,
    ];
    final overlap = _validateAllocations(
      input.allocations,
      reserveList == null ? null : reservesById,
      obligationList == null ? null : obligationsById,
      states,
      inR,
    );

    return Ledger._(
      input: input,
      accounts: accounts,
      b: b,
      bIssues: List.unmodifiable(bIssues),
      obligations: states == null ? null : List.unmodifiable(states),
      obligationIssues: List.unmodifiable(obligationIssues),
      r: r,
      reserveIdsInR: inR == null ? null : Set.unmodifiable(inR),
      reserveIssues: List.unmodifiable(reserveIssues),
      overlapByObligation: overlapIssues.isEmpty
          ? Map.unmodifiable(overlap!)
          : null,
      overlapIssues: List.unmodifiable(overlapIssues),
    );
  }

  /// 2026-10-23: 포함 계좌의 같은 기준시각 잔액 합계 B. 계산할 수 없으면 [issues]에 이유를 넣고 null을 반환한다.
  static int? _sumIncludedBalances(
    LedgerInput input,
    Iterable<AccountBalance> accounts,
    List<InsufficientReason> issues,
  ) {
    final included = accounts.where((a) => a.included).toList()
      ..sort((x, y) => x.accountId.compareTo(y.accountId));
    if (included.isEmpty) {
      issues.add(InsufficientReason.noIncludedAccount);
      return null;
    }
    var sum = 0;
    for (final a in included) {
      final balance = a.balanceKrw;
      final asOf = a.asOfInstant;
      if (balance == null || asOf == null) {
        if (!issues.contains(InsufficientReason.balanceMissing)) {
          issues.add(InsufficientReason.balanceMissing);
        }
        continue;
      }
      if (asOf != input.context.asOfInstant) {
        if (!issues.contains(InsufficientReason.balanceAsOfMismatch)) {
          issues.add(InsufficientReason.balanceAsOfMismatch);
        }
        continue;
      }
      sum = addKrw(sum, balance, 'B');
    }
    return issues.isEmpty ? sum : null;
  }

  /// 2026-10-23: [accountId]가 연결 계좌 목록에 없으면 [path]의 unknownReference 오류다.
  static void _requireAccount(
    Map<String, AccountBalance> accounts,
    String accountId,
    String path,
  ) {
    if (!accounts.containsKey(accountId)) {
      throw CalculationInputException(
        InputErrorCode.unknownReference,
        path,
        accountId,
      );
    }
  }

  /// 2026-10-23: 유효 정산 연결의 의무별 배분 합계를 반환한다. [settlements]가 null이면 null이다.
  /// [obligations]가 있을 때만 참조와 의무 금액 한도를 검사한다.
  static Map<String, int>? _validSettlementTotals(
    List<SettlementLink>? settlements,
    Map<String, Obligation>? obligations,
  ) {
    if (settlements == null) return null;
    final linkIds = <String>{};
    final pairs = <(String, String)>{};
    final totals = <String, int>{};
    final sorted = [...settlements]
      ..sort((x, y) => x.linkId.compareTo(y.linkId));
    for (final s in sorted) {
      if (!linkIds.add(s.linkId)) {
        throw CalculationInputException(
          InputErrorCode.duplicateId,
          'settlements',
          s.linkId,
        );
      }
      if (obligations != null && !obligations.containsKey(s.obligationId)) {
        throw CalculationInputException(
          InputErrorCode.unknownReference,
          'settlements[${s.linkId}].obligationId',
          s.obligationId,
        );
      }
      if (!s.valid) continue;
      if (!pairs.add((s.obligationId, s.transactionId))) {
        throw CalculationInputException(
          InputErrorCode.duplicateId,
          'settlements[${s.linkId}]',
          '같은 의무·거래의 유효 연결 중복',
        );
      }
      totals[s.obligationId] = addKrw(
        totals[s.obligationId] ?? 0,
        s.allocatedKrw,
        'settlements[${s.obligationId}].total',
      );
    }
    if (obligations != null) {
      for (final entry in totals.entries) {
        if (entry.value > obligations[entry.key]!.amountKrw) {
          throw CalculationInputException(
            InputErrorCode.overSettlement,
            'settlements[${entry.key}]',
            '유효 정산 합계가 의무 금액보다 큼',
          );
        }
      }
    }
    return totals;
  }

  /// 2026-10-23: 배정 참조와 한도를 검사하고 의무별 R 집합 미해제 배정 합계를 반환한다.
  /// 미취소 보호액별 합계 ≤ 설정액, 활성 의무별 합계 ≤ 잔여액을 넘으면 overAllocation 오류다.
  static Map<String, int>? _validateAllocations(
    List<ReserveAllocation>? allocations,
    Map<String, Reserve>? reserves,
    Map<String, Obligation>? obligations,
    List<ObligationState>? states,
    Set<String>? inR,
  ) {
    if (allocations == null) return null;
    final ids = <String>{};
    final byReserve = <String, int>{};
    final byObligation = <String, int>{};
    final overlap = <String, int>{};
    final sorted = [...allocations]
      ..sort((x, y) => x.allocationId.compareTo(y.allocationId));
    for (final a in sorted) {
      if (!ids.add(a.allocationId)) {
        throw CalculationInputException(
          InputErrorCode.duplicateId,
          'allocations',
          a.allocationId,
        );
      }
      if (reserves != null && !reserves.containsKey(a.reserveId)) {
        throw CalculationInputException(
          InputErrorCode.unknownReference,
          'allocations[${a.allocationId}].reserveId',
          a.reserveId,
        );
      }
      if (obligations != null && !obligations.containsKey(a.obligationId)) {
        throw CalculationInputException(
          InputErrorCode.unknownReference,
          'allocations[${a.allocationId}].obligationId',
          a.obligationId,
        );
      }
      final path = 'allocations[${a.allocationId}]';
      byReserve[a.reserveId] = addKrw(
        byReserve[a.reserveId] ?? 0,
        a.unreleasedKrw,
        path,
      );
      byObligation[a.obligationId] = addKrw(
        byObligation[a.obligationId] ?? 0,
        a.unreleasedKrw,
        path,
      );
      if (inR != null && inR.contains(a.reserveId)) {
        overlap[a.obligationId] = addKrw(
          overlap[a.obligationId] ?? 0,
          a.unreleasedKrw,
          path,
        );
      }
    }
    if (reserves != null) {
      for (final entry in byReserve.entries) {
        final reserve = reserves[entry.key]!;
        if (!reserve.cancelled && entry.value > reserve.amountKrw) {
          throw CalculationInputException(
            InputErrorCode.overAllocation,
            'reserves[${entry.key}]',
            '미해제 배정 합계가 보호 설정액보다 큼',
          );
        }
      }
    }
    if (states != null) {
      for (final s in states) {
        final total = byObligation[s.obligation.obligationId] ?? 0;
        if (s.obligation.status == ObligationStatus.active &&
            total > s.remainingKrw) {
          throw CalculationInputException(
            InputErrorCode.overAllocation,
            'obligations[${s.obligation.obligationId}]',
            '미해제 배정 합계가 의무 잔여액보다 큼',
          );
        }
      }
    }
    return overlap;
  }
}
