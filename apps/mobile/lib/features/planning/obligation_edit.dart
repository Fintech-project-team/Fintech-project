import 'package:flutter/widgets.dart' show StringCharacters;

import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../overview/home_calculation.dart';
import '../overview/home_screen.dart' show insufficientMessage;

/// 2026-11-03: 예정 지출 이름의 최대 글자 수(api-contract Label, 앞뒤 공백 제외).
const int obligationLabelMax = 80;

/// 2026-11-03: 이미 남겨둘 돈과 연결된 금액 하나. [reserveLabel]은 남겨둘 돈 이름(볼 수 없으면 null), [unreleasedKrw]는 아직 풀리지
/// 않은 금액(배정 총액 − 해제 누계)이다.
typedef HeldAllocation = ({
  Allocation allocation,
  String? reserveLabel,
  int unreleasedKrw,
});

/// 2026-11-03: 지금 Snapshot에서 본 예정 지출 하나의 수정 제약(29-5a). 화면은 이 값으로 막고, 서버 거절도 같은 의미로 안내한다.
class ObligationFacts {
  /// 2026-11-03: 대상 [obligation], 유효 정산 합계 [settledKrw], 미해제 연결 [held]로 만든다.
  const ObligationFacts({
    required this.obligation,
    required this.settledKrw,
    required this.held,
  });

  final Obligation obligation;
  final int settledKrw;
  final List<HeldAllocation> held;

  /// 2026-11-03: 미해제 연결 합계.
  int get heldKrw => held.fold(0, (sum, h) => sum + h.unreleasedKrw);

  /// 2026-11-03: 줄일 수 있는 최소 금액(유효 정산 합계 + 미해제 연결 합계). 연결을 자동으로 줄이지 않는다.
  int get floorKrw => settledKrw + heldKrw;

  /// 2026-11-03: 출금된 기록이 있으면 출금 계좌를 바꿀 수 없고 취소할 수 없다.
  bool get withdrawn => settledKrw > 0;

  /// 2026-11-03: 저장된 반복 회차면 true다(그 회차만 고친다).
  bool get recurring => obligation.recurringPlanId != null;
}

/// 2026-11-03: [snapshot]에서 예정 지출 [obligationId]의 수정 제약을 반환한다. 없거나 취소됐거나 카드 청구를 대표하면 null이다
/// (편집 대상이 아님).
ObligationFacts? obligationFacts(
  FinancialSnapshot snapshot,
  String obligationId,
) {
  final obligation = (snapshot.obligations ?? const <Obligation>[])
      .where((o) => o.obligationId == obligationId)
      .firstOrNull;
  if (obligation == null ||
      obligation.status != 'active' ||
      obligation.statementId != null) {
    return null;
  }
  var settled = 0;
  for (final s in snapshot.settlements ?? const <Settlement>[]) {
    if (s.obligationId == obligationId && s.invalidatedAt == null) {
      settled += s.allocatedKrw;
    }
  }
  final reserves = {
    for (final r in snapshot.reserves ?? const <Reserve>[]) r.reserveId: r,
  };
  return ObligationFacts(
    obligation: obligation,
    settledKrw: settled,
    held: [
      for (final a in snapshot.allocations ?? const <Allocation>[])
        if (a.obligationId == obligationId && a.amountKrw > a.releasedKrw)
          (
            allocation: a,
            reserveLabel: reserves[a.reserveId]?.label,
            unreleasedKrw: a.amountKrw - a.releasedKrw,
          ),
    ],
  );
}

/// 2026-11-03: 취소 요청에 넣을 미해제 연결 전부(정확한 ID·금액).
List<DetachAllocation> detachAll(ObligationFacts facts) => [
  for (final h in facts.held)
    DetachAllocation(
      allocationId: h.allocation.allocationId,
      unreleasedKrw: h.unreleasedKrw,
    ),
];

/// 2026-11-03: 입력 중인 예정 지출. [amountKrw]는 입력이 없으면 null이다.
typedef ObligationDraft = ({
  String label,
  int? amountKrw,
  String? dueDate,
  String? accountId,
});

/// 2026-11-03: 입력 검사 결과. 고칠 칸의 문구만 담는다(없으면 null).
typedef DraftProblems = ({String? label, String? amount});

/// 2026-11-03: [draft]의 칸별 문제를 반환한다. 비어 있는 칸은 문제로 표시하지 않고 저장만 막는다([draftComplete]).
/// 금액 하한은 [facts](수정일 때)로 정하며, 이유(출금액·연결된 남겨둘 돈)를 한 번만 말한다.
DraftProblems draftProblems(ObligationDraft draft, ObligationFacts? facts) {
  final length = draft.label.trim().characters.length;
  final label = length > obligationLabelMax
      ? '이름은 $obligationLabelMax자까지 쓸 수 있어요.'
      : null;
  final amount = draft.amountKrw;
  String? amountProblem;
  if (amount != null && amount > maxAbsKrw) {
    amountProblem = '금액이 너무 커요.';
  } else if (amount != null && facts != null && amount < facts.floorKrw) {
    amountProblem = _floorReason(facts);
  }
  return (label: label, amount: amountProblem);
}

/// 2026-11-03: 하한보다 작게 줄일 수 없는 이유 문장.
String _floorReason(ObligationFacts facts) {
  final floor = formatKrw(facts.floorKrw);
  if (facts.held.isEmpty) {
    return '${formatKrw(facts.settledKrw)}이 이미 출금됐어요. $floor보다 적게 줄일 수 없어요.';
  }
  final names = [
    for (final h in facts.held)
      "남겨둘 돈 '${h.reserveLabel ?? '이름 없음'}'에 ${formatKrw(h.unreleasedKrw)}",
  ].join(', ');
  final paid = facts.settledKrw > 0
      ? '${formatKrw(facts.settledKrw)}이 이미 출금됐고 '
      : '';
  return '$paid$names이 연결돼 있어 $floor보다 적게 줄일 수 없어요.';
}

/// 2026-11-03: 모든 칸이 채워지고 문제가 없으면 true다.
bool draftComplete(ObligationDraft draft, ObligationFacts? facts) {
  final p = draftProblems(draft, facts);
  return draft.label.trim().isNotEmpty &&
      draft.amountKrw != null &&
      draft.dueDate != null &&
      draft.accountId != null &&
      p.label == null &&
      p.amount == null;
}

/// 2026-11-03: 저장 전 미리보기 결과.
sealed class PlanPreview {
  const PlanPreview();
}

/// 2026-11-03: 지금 [nowKrw]와 저장 뒤 [afterKrw] 쓸 수 있는 돈을 모두 계산했다. 변화량은 [deltaKrw]다(입력 금액으로 추정하지 않음).
final class PreviewReady extends PlanPreview {
  /// 2026-11-03: 두 금액으로 만든다.
  const PreviewReady(this.nowKrw, this.afterKrw);

  final int nowKrw;
  final int afterKrw;

  /// 2026-11-03: 저장 뒤 − 지금.
  int get deltaKrw => afterKrw - nowKrw;
}

/// 2026-11-03: 계산할 수 없다. [nowKrw]는 지금 금액(계산되면), [reason]은 정보 부족 안내(입력 오류 때는 null)다. 0원으로 바꾸지
/// 않는다.
final class PreviewUnavailable extends PlanPreview {
  /// 2026-11-03: 지금 금액 [nowKrw]와 이유 [reason]으로 만든다.
  const PreviewUnavailable({this.nowKrw, this.reason});

  final int? nowKrw;
  final String? reason;
}

/// 2026-11-03: [calculation]의 쓸 수 있는 돈. 계산되지 않았으면 null이다.
int? _amountOf(HomeCalculation calculation) =>
    calculation is HomeCalculationReady ? calculation.result.u : null;

/// 2026-11-03: [calculation]이 계산되지 않은 이유 문장. 계산됐으면 null이다.
String? _reasonOf(HomeCalculation calculation) => switch (calculation) {
  HomeCalculationReady(:final result) when result.u == null =>
    insufficientMessage(result.insufficient.firstOrNull),
  HomeCalculationReady() => null,
  _ => '받은 정보로 계산할 수 없어요.',
};

/// 2026-11-03: 지금 Snapshot [snapshot]과 계산 [current]에 예정 지출 바꾸기([obligations]·[allocations] 전체, 남겨둘 돈은
/// [reserves]가 있으면 그것)를 적용했을 때의 미리보기를 계산한다. 원본 Snapshot·홈 결과는 바꾸지 않으며 결과는 메모리에만 둔다.
PlanPreview previewPlan(
  FinancialSnapshot snapshot,
  HomeCalculation current, {
  required List<Obligation> obligations,
  required List<Allocation> allocations,
  List<Reserve>? reserves,
}) {
  final now = _amountOf(current);
  if (now == null) {
    return PreviewUnavailable(reason: _reasonOf(current));
  }
  final after = computeHomeCalculation(
    snapshot.withPlan(
      obligations: obligations,
      allocations: allocations,
      reserves: reserves,
    ),
  );
  final value = _amountOf(after);
  return value == null
      ? PreviewUnavailable(nowKrw: now, reason: _reasonOf(after))
      : PreviewReady(now, value);
}

/// 2026-11-03: 입력 [draft]를 추가(대상 [facts]가 null) 또는 수정한 미리보기. 입력이 덜 됐거나 문제가 있으면 이유 없는 계산 불가다.
PlanPreview previewDraft(
  FinancialSnapshot snapshot,
  HomeCalculation current,
  ObligationDraft draft,
  ObligationFacts? facts,
) {
  if (!draftComplete(draft, facts)) {
    return PreviewUnavailable(nowKrw: _amountOf(current));
  }
  final edited = Obligation(
    obligationId: facts?.obligation.obligationId ?? 'draft',
    label: draft.label.trim(),
    withdrawalAccountId: draft.accountId!,
    amountKrw: draft.amountKrw!,
    dueDate: draft.dueDate!,
    status: 'active',
    recurringPlanId: facts?.obligation.recurringPlanId,
  );
  final list = snapshot.obligations ?? const <Obligation>[];
  return previewPlan(
    snapshot,
    current,
    obligations: facts == null
        ? [...list, edited]
        : [
            for (final o in list)
              o.obligationId == edited.obligationId ? edited : o,
          ],
    allocations: snapshot.allocations ?? const [],
  );
}

/// 2026-11-03: 예정 지출 [facts]를 취소했을 때의 미리보기. 미해제 연결은 해제 누계까지 줄이거나(이력이 있으면) 지운다.
/// 남겨둘 돈 설정액은 바꾸지 않는다.
PlanPreview previewCancel(
  FinancialSnapshot snapshot,
  HomeCalculation current,
  ObligationFacts facts,
) {
  final id = facts.obligation.obligationId;
  final detached = {for (final h in facts.held) h.allocation.allocationId};
  return previewPlan(
    snapshot,
    current,
    obligations: [
      for (final o in snapshot.obligations ?? const <Obligation>[])
        o.obligationId == id
            ? Obligation(
                obligationId: o.obligationId,
                label: o.label,
                withdrawalAccountId: o.withdrawalAccountId,
                amountKrw: o.amountKrw,
                dueDate: o.dueDate,
                status: 'cancelled',
                statementId: o.statementId,
                recurringPlanId: o.recurringPlanId,
              )
            : o,
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

/// 2026-11-03: 아직 나가지 않은 금액([amountKrw] − 유효 정산 [settledKrw])이 출금 계좌의 현재 잔액 [balanceKrw]보다 많은 금액.
/// 많지 않거나 금액·잔액을 모르면 null이다. 미래 출금 가능 여부를 판정하지 않고 저장도 막지 않는다.
int? balanceShortfall({
  required int? amountKrw,
  required int settledKrw,
  required int? balanceKrw,
}) {
  if (amountKrw == null || balanceKrw == null) return null;
  final over = amountKrw - settledKrw - balanceKrw;
  return over > 0 ? over : null;
}
