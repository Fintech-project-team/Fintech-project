import 'package:flutter/widgets.dart' show StringCharacters;

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
typedef ReserveDraft = ({String label, int? amountKrw, String? accountId});

/// 2026-11-03: [draft]의 칸별 문제를 반환한다. 비어 있는 칸은 문제로 표시하지 않고 저장만 막는다([reserveDraftComplete]).
/// 금액 하한은 이 돈으로 낼 지출의 남은 사용 예정액 합계다.
DraftProblems reserveDraftProblems(ReserveDraft draft, ReserveFacts? facts) {
  final length = draft.label.trim().characters.length;
  final label = length > reserveLabelMax
      ? '이름은 $reserveLabelMax자까지 쓸 수 있어요.'
      : null;
  final amount = draft.amountKrw;
  String? amountProblem;
  if (amount != null && amount > maxAbsKrw) {
    amountProblem = '금액이 너무 커요.';
  } else if (amount != null && facts != null && amount < facts.floorKrw) {
    amountProblem =
        '${useNames(facts)}에 쓸 ${formatKrw(facts.floorKrw)}보다 적게 줄일 수 없어요.';
  }
  return (label: label, amount: amountProblem);
}

/// 2026-11-03: 모든 칸이 채워지고 문제가 없으면 true다.
bool reserveDraftComplete(ReserveDraft draft, ReserveFacts? facts) {
  final p = reserveDraftProblems(draft, facts);
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
  if (!reserveDraftComplete(draft, facts)) {
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
  return previewPlan(
    snapshot,
    current,
    obligations: snapshot.obligations ?? const [],
    allocations: snapshot.allocations ?? const [],
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
