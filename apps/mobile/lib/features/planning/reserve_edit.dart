import 'dart:math';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../connection/connection_review.dart' show accountById;
import '../overview/home_calculation.dart';
import 'obligation_edit.dart';

/// 2026-11-03: 남겨둘 돈 이름의 최대 글자 수(api-contract Label, 앞뒤 공백 제외).
const int reserveLabelMax = 80;

/// 2026-11-03: 이 남겨둘 돈으로 낼 지출 하나(미해제 배정). [unreleasedKrw]는 남은 사용 예정액(배정 총액 − 해제 누계)이고,
/// [label]·[dueDate]는 예정 지출이 보이지 않으면 null이다. [inPeriod]는 이번 계산에서 쓸 수 있는 돈에서 함께 빠지는지다.
typedef ReserveUse = ({
  Allocation allocation,
  String? label,
  String? dueDate,
  int unreleasedKrw,
  bool inPeriod,
});

/// 2026-11-03: 지금 Snapshot에서 본 남겨둘 돈 하나의 수정 제약(29-5b). 29-5b는 연결을 바꾸지 않고 보여 주기만 한다.
class ReserveFacts {
  /// 2026-11-03: 대상 [reserve]와 이 돈으로 낼 지출 [uses], 보호 계좌가 계산에 포함됐는지 [included]로 만든다.
  const ReserveFacts({
    required this.reserve,
    required this.uses,
    required this.included,
  });

  final Reserve reserve;
  final List<ReserveUse> uses;
  final bool included;

  /// 2026-11-03: 줄일 수 있는 최소 금액(남은 사용 예정액 합계). 연결을 자동으로 줄이지 않는다.
  int get floorKrw => uses.fold(0, (sum, u) => sum + u.unreleasedKrw);
}

/// 2026-11-03: [snapshot]에서 남겨둘 돈 [reserveId]의 수정 제약을 반환한다. 없거나 취소됐으면 null이다.
ReserveFacts? reserveFacts(FinancialSnapshot snapshot, String reserveId) {
  final reserve = (snapshot.reserves ?? const <Reserve>[])
      .where((r) => r.reserveId == reserveId && r.cancelledAt == null)
      .firstOrNull;
  if (reserve == null) return null;
  final obligations = {
    for (final o in snapshot.obligations ?? const <Obligation>[])
      o.obligationId: o,
  };
  final calculation = computeHomeCalculation(snapshot);
  final overlapping = calculation is HomeCalculationReady
      ? {
          for (final l in calculation.result.reserveLines ?? const [])
            if (l.reserveId == reserveId)
              for (final o in l.overlaps ?? const []) o.obligationId,
        }
      : const <String>{};
  return ReserveFacts(
    reserve: reserve,
    included: accountById(snapshot, reserve.accountId)?.included ?? false,
    uses: [
      for (final a in snapshot.allocations ?? const <Allocation>[])
        if (a.reserveId == reserveId && a.amountKrw > a.releasedKrw)
          (
            allocation: a,
            label: obligations[a.obligationId]?.label,
            dueDate: obligations[a.obligationId]?.dueDate,
            unreleasedKrw: a.amountKrw - a.releasedKrw,
            inPeriod: overlapping.contains(a.obligationId),
          ),
    ]..sort((x, y) => (x.dueDate ?? '').compareTo(y.dueDate ?? '')),
  );
}

/// 2026-11-03: 취소 요청에 넣을 미해제 배정 전부(정확한 ID·금액).
List<DetachAllocation> detachReserve(ReserveFacts facts) => [
  for (final u in facts.uses)
    DetachAllocation(
      allocationId: u.allocation.allocationId,
      unreleasedKrw: u.unreleasedKrw,
    ),
];

/// 2026-11-03: 이 돈으로 낼 지출 이름들(2건까지 '·'로, 더 많으면 '첫 이름 외 n건'). 이름을 모르면 '예정 지출'이다.
String useNames(ReserveFacts facts) {
  final names = [for (final u in facts.uses) u.label ?? '예정 지출'];
  return names.length <= 2
      ? names.join('·')
      : '${names.first} 외 ${names.length - 1}건';
}

/// 2026-11-03: 입력 중인 남겨둘 돈. [amountKrw]는 입력이 없으면 null이다.
/// 2026-11-04: 이 돈으로 낼 지출 [plans]를 더했다(29-5c).
typedef ReserveDraft = ({
  String label,
  int? amountKrw,
  String? accountId,
  List<PlanItem> plans,
});

/// 2026-11-04: 이 돈으로 낼 지출 하나(사용 계획). [allocationId]는 저장된 배정(새로 고른 것은 null), [amountKrw]는 이 돈에서 쓸 금액
/// (미해제분), [releasedKrw]는 이미 나간 금액(해제 누계), [inPeriod]는 이번 계산에서 함께 빠지는지다.
typedef PlanItem = ({
  String? allocationId,
  String obligationId,
  String? label,
  String? dueDate,
  int amountKrw,
  int releasedKrw,
  bool inPeriod,
});

/// 2026-11-04: [facts]의 기존 사용 계획(없으면 빈 목록).
List<PlanItem> planItems(ReserveFacts? facts) => [
  for (final u in facts?.uses ?? const <ReserveUse>[])
    (
      allocationId: u.allocation.allocationId,
      obligationId: u.allocation.obligationId,
      label: u.label,
      dueDate: u.dueDate,
      amountKrw: u.unreleasedKrw,
      releasedKrw: u.allocation.releasedKrw,
      inPeriod: u.inPeriod,
    ),
];

/// 2026-11-04: 사용 계획 이름들(2건까지 '·'로, 더 많으면 '첫 이름 외 n건').
String planNames(List<PlanItem> plans) {
  final names = [for (final p in plans) p.label ?? '예정 지출'];
  return names.length <= 2
      ? names.join('·')
      : '${names.first} 외 ${names.length - 1}건';
}

/// 2026-11-04: 선택창 후보 하나. [maxKrw]는 이 예정 지출에서 아직 다른 남겨둘 돈이 쓰기로 하지 않은 금액(0이면 고를 수 없음),
/// [heldBy]는 그때 이미 낼 계획인 다른 남겨둘 돈 이름이다.
typedef PlanCandidate = ({
  String obligationId,
  String label,
  String dueDate,
  int maxKrw,
  String? heldBy,
});

/// 2026-11-04: 예정 지출별로 남겨둘 돈 [reserveId](추가면 null) 말고 다른 남겨둘 돈이 쓰기로 한 금액(미해제 합계)과 그 첫 이름.
Map<String, ({int krw, String? name})> _heldByOthers(
  FinancialSnapshot snapshot,
  String? reserveId,
) {
  final reserves = {
    for (final r in snapshot.reserves ?? const <Reserve>[]) r.reserveId: r,
  };
  final held = <String, ({int krw, String? name})>{};
  for (final a in snapshot.allocations ?? const <Allocation>[]) {
    if (a.reserveId == reserveId || a.amountKrw <= a.releasedKrw) continue;
    final prev = held[a.obligationId];
    held[a.obligationId] = (
      krw: (prev?.krw ?? 0) + a.amountKrw - a.releasedKrw,
      name: prev?.name ?? reserves[a.reserveId]?.label,
    );
  }
  return held;
}

/// 2026-11-04: 이번 월급 주기(현재 구간 E)에 있는 예정 지출의 남은 금액. 월급 주기를 정할 수 없으면 빈 맵이다.
Map<String, int> _inPeriodRemaining(HomeCalculation calculation) {
  if (calculation is! HomeCalculationReady) return const {};
  return {
    for (final l in calculation.result.obligationLines ?? const [])
      if (l.placement == calc.ObligationPlacement.inCurrentPeriod &&
          l.remainingKrw > 0)
        l.obligationId: l.remainingKrw,
  };
}

/// 2026-11-04: 남겨둘 돈 [reserveId]가 예정 지출 [obligationId]에 쓸 수 있는 최대 금액(남은 금액 − 다른 남겨둘 돈 몫). 이번 월급
/// 주기 지출이 아니거나 월급 주기를 정할 수 없으면 null이다(새로 고르거나 늘릴 수 없음).
int? planCap(
  FinancialSnapshot snapshot,
  HomeCalculation calculation,
  String? reserveId,
  String obligationId,
) {
  final remaining = _inPeriodRemaining(calculation)[obligationId];
  if (remaining == null) return null;
  return max(
    0,
    remaining - (_heldByOthers(snapshot, reserveId)[obligationId]?.krw ?? 0),
  );
}

/// 2026-11-04: 이번 월급 주기(현재 구간 E)의 활성 예정 지출 중 [chosen]에 없는 것을 예정일 순으로 반환한다. 월급 주기를 정할 수
/// 없으면 빈 목록이다. 남겨둘 돈 [reserveId](추가면 null) 자신의 배정은 다른 남겨둘 돈 몫으로 세지 않는다.
List<PlanCandidate> planCandidates(
  FinancialSnapshot snapshot,
  HomeCalculation calculation,
  String? reserveId,
  Set<String> chosen,
) {
  final remaining = _inPeriodRemaining(calculation);
  final held = _heldByOthers(snapshot, reserveId);
  return [
    for (final o in snapshot.obligations ?? const <Obligation>[])
      if (remaining[o.obligationId] case final left?)
        if (!chosen.contains(o.obligationId))
          (
            obligationId: o.obligationId,
            label: o.label,
            dueDate: o.dueDate,
            maxKrw: max(0, left - (held[o.obligationId]?.krw ?? 0)),
            heldBy: held[o.obligationId]?.name,
          ),
  ]..sort((x, y) => x.dueDate.compareTo(y.dueDate));
}

/// 2026-11-04: 원래 사용 계획 [before]에서 [after]로 바꾸는 배정 변경. 새로 고른 것은 create(총 배정액 = 쓸 금액), 금액을 바꾼
/// 것은 update(총 배정액 = 쓸 금액 + 이미 나간 금액), 빠진 것은 이미 나간 금액이 없으면 remove, 있으면 그 금액까지 update한다.
AllocationChanges allocationChangesOf(
  List<PlanItem> before,
  List<PlanItem> after,
) {
  final kept = {
    for (final p in after)
      if (p.allocationId != null) p.allocationId!: p,
  };
  return AllocationChanges(
    create: [
      for (final p in after)
        if (p.allocationId == null)
          (obligationId: p.obligationId, amountKrw: p.amountKrw),
    ],
    update: [
      for (final b in before)
        if (kept[b.allocationId] case final p?)
          if (p.amountKrw != b.amountKrw)
            (
              allocationId: b.allocationId!,
              amountKrw: p.amountKrw + p.releasedKrw,
            )
          else
            ...[]
        else if (b.releasedKrw > 0)
          (allocationId: b.allocationId!, amountKrw: b.releasedKrw),
    ],
    remove: [
      for (final b in before)
        if (!kept.containsKey(b.allocationId) && b.releasedKrw == 0)
          b.allocationId!,
    ],
  );
}

/// 2026-11-03: [draft]의 칸별 문제를 반환한다. 비어 있는 칸은 문제로 표시하지 않고 저장만 막는다([reserveDraftComplete]).
/// 금액 하한은 이 돈으로 낼 지출의 남은 사용 예정액 합계다.
/// 2026-11-04: 하한을 입력 중인 사용 계획([ReserveDraft.plans])으로 정한다.
DraftProblems reserveDraftProblems(ReserveDraft draft) {
  final length = draft.label.trim().characters.length;
  final label = length > reserveLabelMax
      ? '이름은 $reserveLabelMax자까지 쓸 수 있어요.'
      : null;
  final amount = draft.amountKrw;
  String? amountProblem;
  if (amount != null && amount > maxAbsKrw) {
    amountProblem = '금액이 너무 커요.';
  } else if (amount != null && amount < planFloor(draft.plans)) {
    amountProblem =
        '${planNames(draft.plans)}에 쓸 ${formatKrw(planFloor(draft.plans))}보다 적게 줄일 수 없어요.';
  }
  return (label: label, amount: amountProblem);
}

/// 2026-11-04: 사용 계획 [plans]의 쓸 금액 합계(남겨둘 돈 금액의 하한).
int planFloor(List<PlanItem> plans) =>
    plans.fold(0, (sum, p) => sum + p.amountKrw);

/// 2026-11-03: 모든 칸이 채워지고 문제가 없으면 true다.
bool reserveDraftComplete(ReserveDraft draft) {
  final p = reserveDraftProblems(draft);
  return draft.label.trim().isNotEmpty &&
      draft.amountKrw != null &&
      draft.accountId != null &&
      p.label == null &&
      p.amount == null;
}

/// 2026-11-03: 입력 [draft]로 남겨둘 돈을 추가([facts]가 null) 또는 수정한 미리보기. 입력이 덜 됐거나 문제가 있으면 이유 없는
/// 계산 불가다.
PlanPreview previewReserveDraft(
  FinancialSnapshot snapshot,
  HomeCalculation current,
  ReserveDraft draft,
  ReserveFacts? facts,
) {
  if (!reserveDraftComplete(draft)) {
    return PreviewUnavailable(
      nowKrw: current is HomeCalculationReady ? current.result.u : null,
    );
  }
  final edited = Reserve(
    reserveId: facts?.reserve.reserveId ?? 'draft',
    accountId: draft.accountId!,
    label: draft.label.trim(),
    amountKrw: draft.amountKrw!,
    cancelledAt: null,
  );
  final list = snapshot.reserves ?? const <Reserve>[];
  final kept = {
    for (final p in draft.plans)
      if (p.allocationId != null) p.allocationId!: p,
  };
  final mine = {
    for (final u in facts?.uses ?? const <ReserveUse>[])
      u.allocation.allocationId,
  };
  return previewPlan(
    snapshot,
    current,
    obligations: snapshot.obligations ?? const [],
    allocations: [
      for (final a in snapshot.allocations ?? const <Allocation>[])
        if (!mine.contains(a.allocationId))
          a
        else if (kept[a.allocationId] case final p?)
          Allocation(
            allocationId: a.allocationId,
            reserveId: a.reserveId,
            obligationId: a.obligationId,
            amountKrw: p.amountKrw + a.releasedKrw,
            releasedKrw: a.releasedKrw,
          )
        else if (a.releasedKrw > 0)
          Allocation(
            allocationId: a.allocationId,
            reserveId: a.reserveId,
            obligationId: a.obligationId,
            amountKrw: a.releasedKrw,
            releasedKrw: a.releasedKrw,
          ),
      for (final (i, p) in draft.plans.indexed)
        if (p.allocationId == null)
          Allocation(
            allocationId: 'draft-$i',
            reserveId: edited.reserveId,
            obligationId: p.obligationId,
            amountKrw: p.amountKrw,
            releasedKrw: 0,
          ),
    ],
    reserves: facts == null
        ? [...list, edited]
        : [for (final r in list) r.reserveId == edited.reserveId ? edited : r],
  );
}

/// 2026-11-03: 남겨둘 돈 [facts]를 취소했을 때의 미리보기. 미해제 배정은 해제 누계까지 줄이거나(이력이 있으면) 지운다. 예정
/// 지출은 그대로다.
PlanPreview previewReserveCancel(
  FinancialSnapshot snapshot,
  HomeCalculation current,
  ReserveFacts facts,
  String cancelledAt,
) {
  final id = facts.reserve.reserveId;
  final detached = {for (final u in facts.uses) u.allocation.allocationId};
  return previewPlan(
    snapshot,
    current,
    obligations: snapshot.obligations ?? const [],
    reserves: [
      for (final r in snapshot.reserves ?? const <Reserve>[])
        r.reserveId == id
            ? Reserve(
                reserveId: r.reserveId,
                accountId: r.accountId,
                label: r.label,
                amountKrw: r.amountKrw,
                cancelledAt: cancelledAt,
              )
            : r,
    ],
    allocations: [
      for (final a in snapshot.allocations ?? const <Allocation>[])
        if (!detached.contains(a.allocationId))
          a
        else if (a.releasedKrw > 0)
          Allocation(
            allocationId: a.allocationId,
            reserveId: a.reserveId,
            obligationId: a.obligationId,
            amountKrw: a.releasedKrw,
            releasedKrw: a.releasedKrw,
          ),
    ],
  );
}
