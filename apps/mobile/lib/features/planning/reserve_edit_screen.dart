import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/status_notice.dart';
import '../connection/connection_review.dart' show accountById, accountLabel;
import '../connection/salary_settings_screen.dart' show GroupedDigitsFormatter;
import '../overview/accounts_screen.dart' show AccountsWriter;
import '../overview/calculation_detail_screen.dart' show mdText;
import '../overview/transaction_sheets.dart';
import 'obligation_edit_controller.dart';
import 'obligation_edit_screen.dart';
import 'reserve_edit.dart';
import 'reserve_edit_controller.dart';
import 'reserve_plan_sheets.dart';

/// 2026-11-03: 남겨둘 돈 편집을 마친 결과. 취소면 [cancelled]가 true다.
typedef ReserveEditResult = ({bool cancelled});

/// 2026-11-03: 남겨둘 돈 추가(대상 [reserveId]가 null) 또는 수정 화면을 연다. 저장·취소에 성공하면 결과를, 그냥 나가면 null을
/// 돌려준다.
Future<ReserveEditResult?> openReserveEditor(
  BuildContext context, {
  required FinancialSnapshot snapshot,
  required AccountsWriter writer,
  String? reserveId,
}) {
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  return Navigator.of(context).push<ReserveEditResult>(
    MaterialPageRoute(
      builder: (_) => ReserveEditScreen(
        snapshot: snapshot,
        writer: writer,
        reserveId: reserveId,
      ),
    ),
  );
}

/// 2026-11-03: 03-5 남겨둘 돈 추가·수정(29-5b). 위에서부터 안내 띠 → (추가면) 한 줄 설명 → 이름 → 금액 → 남겨둘 계좌 → '이 돈으로
/// 낼 지출', 맨 아래에 미리보기와 버튼(수정이면 왼쪽에 '남겨둘 돈 취소하기')을 고정한다.
/// 2026-11-04: '이 돈으로 낼 지출'에서 지출을 고르고 금액을 바꾸거나 사용 계획을 해제한다(29-5c). 저장 전까지는 화면 안에서만 바뀐다.
class ReserveEditScreen extends StatefulWidget {
  /// 2026-11-03: 지금 Snapshot [snapshot], 저장 연결 [writer], 대상 [reserveId]로 만든다.
  const ReserveEditScreen({
    super.key,
    required this.snapshot,
    required this.writer,
    this.reserveId,
  });

  final FinancialSnapshot snapshot;
  final AccountsWriter writer;
  final String? reserveId;

  /// 2026-11-03: 입력 상태 객체를 반환한다.
  @override
  State<ReserveEditScreen> createState() => _ReserveEditScreenState();
}

/// 2026-11-03: 컨트롤러와 입력칸을 묶는다.
class _ReserveEditScreenState extends State<ReserveEditScreen> {
  late final ReserveEditController _c = ReserveEditController(
    snapshot: widget.snapshot,
    writer: widget.writer,
    reserveId: widget.reserveId,
  )..addListener(_refresh);
  late final TextEditingController _label = TextEditingController(
    text: _c.draft.label,
  );
  late final TextEditingController _amount = TextEditingController(
    text: _c.draft.amountKrw == null
        ? ''
        : formatKrwDigits(_c.draft.amountKrw!),
  );

  final GlobalKey _bottom = GlobalKey();

  bool get _adding => widget.reserveId == null;
  String get _verb => _adding ? '추가' : '수정';

  /// 2026-11-03: 컨트롤러 변화를 다시 그린다.
  void _refresh() {
    if (mounted) setState(() {});
  }

  /// 2026-11-03: 컨트롤러와 입력칸을 폐기한다.
  @override
  void dispose() {
    _c
      ..removeListener(_refresh)
      ..dispose();
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// 2026-11-03: 입력칸 포커스를 풀어 키보드를 닫는다(계좌를 고르거나 입력칸 밖을 누를 때).
  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  /// 2026-11-03: 저장하고 성공하면 결과와 함께 닫는다.
  Future<void> _submit() async {
    final ok = await _c.submit();
    if (!ok || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    Navigator.of(context).pop((cancelled: false));
  }

  /// 2026-11-03: 취소 확인창을 보이고, 고르면 취소한다. 이 돈으로 낼 지출이 있으면 예정 지출은 그대로 남는다고 한 줄로 알린다.
  Future<void> _cancel() async {
    final facts = _c.facts;
    if (facts == null) return;
    _unfocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CancelConfirmDialog(
        title: '${facts.reserve.label} 남겨둘 돈을 취소할까요?',
        lines: [
          if (facts.uses.isNotEmpty)
            '이 돈으로 낼 ${withTopic(useNames(facts))} 예정 지출에 그대로 남아요.',
        ],
        preview: _c.cancelPreview,
      ),
    );
    if (confirmed != true || !mounted) return;
    await _sendCancel();
  }

  /// 2026-11-03: 취소를 보내고(결과 불명 뒤면 같은 요청을 그대로) 성공하면 취소 결과와 함께 닫는다.
  Future<void> _sendCancel() async {
    final ok = await _c.cancel();
    if (!ok || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    Navigator.of(context).pop((cancelled: true));
  }

  /// 2026-11-04: 지출 선택창(R-3)을 열어 고른 지출과 금액을 사용 계획에 더한다.
  Future<void> _pickPlan() async {
    final range = _c.cycleRange;
    if (range == null) return;
    _unfocus();
    final picked = await showPayseSheet<PlanPick>(
      context,
      PlanPickSheet(candidates: _c.candidates, range: range, maxOf: _c.planMax),
    );
    if (picked != null) _c.addPlan(picked.obligationId, picked.amountKrw);
  }

  /// 2026-11-04: 사용 계획 [item]의 시트(R-5a·R-6)를 열어 금액을 바꾸거나 해제한다. 해제하면 하단이 다시 그려진 뒤 그 높이 위에
  /// 되돌리기 알림을 보인다.
  Future<void> _openPlan(PlanItem item) async {
    _unfocus();
    final id = item.obligationId;
    final action = await showPayseSheet<PlanRowAction>(
      context,
      PlanRowSheet(
        item: item,
        maxKrw: _c.planMax(id),
        adjustable: _c.planAdjustable(id),
        cycleKnown: _c.cycleKnown,
      ),
    );
    if (!mounted) return;
    switch (action) {
      case PlanRowAmount(:final amountKrw):
        _c.setPlanAmount(id, amountKrw);
      case PlanRowRelease():
        _c.unplan(id);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              key: const ValueKey('reserve-unplan-notice'),
              content: Text(
                '${withTopic(item.label ?? '예정 지출')} 이 돈으로 내지 않아요. 예정 지출에는 그대로 있어요.',
              ),
              action: SnackBarAction(
                label: '되돌리기',
                textColor: PayseColors.moonYellow,
                onPressed: _c.undoUnplan,
              ),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.fromLTRB(
                PayseSpace.x4,
                0,
                PayseSpace.x4,
                (_bottom.currentContext?.size?.height ?? 0) + PayseSpace.x3,
              ),
            ),
          );
      case null:
        break;
    }
  }

  /// 2026-11-03: 나가기. 결과를 모르는 요청이 있으면 최신 정보를 다시 받아 목록에 반영한다.
  void _leave() {
    if (_c.busy) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    if (_c.locked) refreshLatest(widget.writer);
    Navigator.of(context).pop();
  }

  /// 2026-11-03: 남겨둘 계좌 선택창(계산에 포함한 계좌만)을 열어 고른 계좌를 반영한다.
  Future<void> _pickAccount() async {
    _unfocus();
    final picked = await showPayseSheet<String>(
      context,
      AccountPickSheet(
        snapshot: _c.snapshot,
        selected: _c.draft.accountId,
        title: '남겨둘 계좌',
        includedOnly: true,
      ),
    );
    if (picked != null) _c.setAccount(picked);
  }

  /// 2026-11-03: 위쪽 안내 띠. 결과 불명은 노랑, 충돌은 노랑(최신 정보 불러오기), 거절은 빨강이다(29-5a와 같은 규칙).
  Widget? _band() {
    final save = _c.save;
    final what = switch (save) {
      EditUnknown(op: EditOp.cancel) || EditRejected(op: EditOp.cancel) => '취소',
      _ => _verb,
    };
    return switch (save) {
      EditUnknown(:final connection) => StatusNotice(
        key: const ValueKey('edit-band-unknown'),
        kind: StatusNoticeKind.warning,
        title: '$what 결과를 확인하지 못했어요',
        message:
            '${connection ? '연결이 끊겨 결과를 확인하지 못했어요.' : '요청 결과를 받지 못했어요.'} '
            '입력한 내용은 유지돼요. 연결 상태를 확인한 뒤 다시 시도해 주세요.',
      ),
      EditStale() => StatusNotice(
        key: const ValueKey('edit-band-stale'),
        kind: StatusNoticeKind.versionConflict,
        title: '저장 전에 정보가 바뀌었어요',
        message: '저장하지 않았어요. 최신 정보로 다시 계산한 뒤 확인하고 저장해 주세요. 입력한 내용은 그대로 남아 있어요.',
        actionLabel: '최신 정보 불러오기',
        onAction: _c.reload,
      ),
      EditReloadFailed() => StatusNotice(
        key: const ValueKey('edit-band-reload-failed'),
        kind: StatusNoticeKind.versionConflict,
        title: '최신 정보를 불러오지 못했어요',
        message: '입력한 내용은 그대로 남아 있어요. 다시 불러와 주세요.',
        actionLabel: '다시 불러오기',
        onAction: _c.reload,
      ),
      EditGone() => const StatusNotice(
        key: ValueKey('edit-band-gone'),
        kind: StatusNoticeKind.saveFailed,
        title: '이 남겨둘 돈은 더 고칠 수 없어요',
        message: '최신 정보에서 취소됐거나 바뀌었어요. 목록에서 다시 확인해 주세요.',
      ),
      EditRejected(reason: EditRejection.limit) => const StatusNotice(
        key: ValueKey('edit-band-rejected-limit'),
        kind: StatusNoticeKind.saveFailed,
        title: '남겨둘 수 있는 금액을 넘었어요',
        message: '계좌에 있는 돈보다 많이 남겨둘 수는 없어요. 금액을 줄여 주세요.',
      ),
      EditRejected(:final reason) => StatusNotice(
        key: ValueKey('edit-band-rejected-${reason.name}'),
        kind: StatusNoticeKind.saveFailed,
        title: '남겨둘 돈을 $what할 수 없어요',
        message: switch (reason) {
          EditRejection.relationConflict ||
          EditRejection.historyLocked => '정보가 바뀌었어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.forbidden => '이 항목을 볼 수 없게 됐어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.validation => '입력한 내용을 다시 확인해 주세요.',
          EditRejection.limit || EditRejection.other => '잠시 후 다시 시도해 주세요.',
        },
        actionLabel: reason == EditRejection.validation ? null : '최신 정보 불러오기',
        onAction: reason == EditRejection.validation ? null : _c.reload,
      ),
      EditReloaded() => const PlanInfoBand(
        key: ValueKey('edit-band-reloaded'),
        title: '최신 정보로 다시 계산했어요',
        body: '그사이 바뀐 내용을 반영했어요. 아래 금액을 확인하고 다시 저장해 주세요.',
      ),
      _ => null,
    };
  }

  /// 2026-11-03: 입력칸·안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    final facts = _c.facts;
    final draft = _c.draft;
    final problems = _c.problems;
    final frozen = _c.locked || _c.busy;
    final band = _band();
    final account = draft.accountId == null
        ? null
        : accountById(_c.snapshot, draft.accountId!);
    final accountHelp = [
      if (account != null) balanceText(account),
      if (_c.locked)
        '결과를 확인할 때까지 내용을 바꿀 수 없어요.'
      else if (account != null && !account.included)
        '쓸 수 있는 돈에 넣지 않는 계좌예요. 여기에 남겨둔 돈은 쓸 수 있는 돈에서 빼지 않아요.',
    ].join('\n');
    const gap = EdgeInsets.fromLTRB(
      PayseSpace.screenHorizontal,
      PayseSpace.x5,
      PayseSpace.screenHorizontal,
      0,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: PayseColors.background,
        appBar: AppBar(
          backgroundColor: PayseColors.background,
          surfaceTintColor: PayseColors.background,
          foregroundColor: PayseColors.textPrimary,
          centerTitle: false,
          titleSpacing: 0,
          leading: BackButton(onPressed: _leave),
          title: Text(
            '남겨둘 돈 $_verb',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          shape: const Border(bottom: BorderSide(color: PayseColors.border)),
        ),
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _unfocus,
                child: ListView(
                  key: const ValueKey('reserve-edit-scroll'),
                  padding: const EdgeInsets.only(bottom: PayseSpace.x6),
                  children: [
                    ?band,
                    if (_adding)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(
                          PayseSpace.screenHorizontal,
                          PayseSpace.x4,
                          PayseSpace.screenHorizontal,
                          0,
                        ),
                        child: Text(
                          '이체하지 않고 계좌에 남겨둬요. 쓸 수 있는 돈 계산에서만 빼요.',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: PayseColors.textPrimary,
                          ),
                        ),
                      ),
                    Padding(
                      padding: gap,
                      child: PayseTextField(
                        key: const ValueKey('reserve-label'),
                        label: '이름',
                        controller: _label,
                        enabled: !frozen,
                        hintText: '예: 비상금',
                        textInputAction: TextInputAction.next,
                        onChanged: _c.setLabel,
                        errorText: problems.label,
                      ),
                    ),
                    Padding(
                      padding: gap,
                      child: PayseTextField(
                        key: const ValueKey('reserve-amount'),
                        label: '금액',
                        controller: _amount,
                        enabled: !frozen,
                        hintText: '0',
                        textAlign: TextAlign.end,
                        keyboardType: TextInputType.number,
                        inputFormatters: const [GroupedDigitsFormatter()],
                        textInputAction: TextInputAction.done,
                        onChanged: (text) =>
                            _c.setAmount(text.replaceAll(',', '')),
                        errorText: problems.amount,
                        valueStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: PayseColors.textPrimary,
                          fontFeatures: PayseTypography.tabular,
                        ),
                        trailing: const Text(
                          '원',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: PayseColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: gap,
                      child: PayseSelectField(
                        key: const ValueKey('reserve-account'),
                        label: '남겨둘 계좌',
                        value: account == null
                            ? null
                            : accountLabel(_c.snapshot, account),
                        placeholder: '계좌 선택',
                        locked: _c.locked,
                        helper: accountHelp.isEmpty ? null : accountHelp,
                        onTap: frozen ? null : _pickAccount,
                      ),
                    ),
                    Padding(
                      padding: gap,
                      child: _Plans(
                        controller: _c,
                        frozen: frozen,
                        onPick: _pickPlan,
                        onOpen: _openPlan,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            EditBottom(
              key: _bottom,
              verb: _verb,
              preview: _c.preview,
              unchanged: _c.unchanged,
              laterNote: null,
              cancelLabel: facts != null && !_c.locked ? '남겨둘 돈 취소하기' : null,
              onCancel: _c.busy || _c.needsLatest ? null : _cancel,
              label: _c.busy
                  ? '${_c.cancelPending ? '취소' : _verb}하는 중'
                  : _c.locked
                  ? '다시 시도하기'
                  : '$_verb하기',
              onPressed: !_c.canSave
                  ? null
                  : _c.cancelPending
                  ? _sendCancel
                  : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-11-04: '이 돈으로 낼 지출 (선택)'. 고른 지출이 없으면 '지출 선택' 선택 행과 보조 문구, 있으면 지출마다 이름 / M/D 예정
/// (다음 월급 기간이면 표시) … 쓸 금액 › 행과 '+ 지출 더 선택하기'를 보인다. 새로 고를 수 없으면 고르기를 흐리게 하고 이유를 한 줄로
/// 붙인다.
class _Plans extends StatelessWidget {
  /// 2026-11-04: 편집 [controller], 입력 잠김 [frozen], 고르기 [onPick], 행 누르기 [onOpen]으로 만든다.
  const _Plans({
    required this.controller,
    required this.frozen,
    required this.onPick,
    required this.onOpen,
  });

  final ReserveEditController controller;
  final bool frozen;
  final VoidCallback onPick;
  final ValueChanged<PlanItem> onOpen;

  /// 2026-11-04: 제목·행·고르기를 반환한다.
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final plans = c.plans;
    final reason = !c.cycleKnown
        ? '월급 주기를 확인할 수 없어 지출을 새로 고를 수 없어요.'
        : c.candidates.isEmpty
        ? '이번 월급 주기에 고를 수 있는 예정 지출이 없어요.'
        : null;
    final canPick = !frozen && reason == null;
    final note = Text(
      plans.isEmpty
          ? reason ??
                (c.reserveId == null
                    ? '남겨둘 돈에서 낼 예정 지출이 있으면 골라 주세요.'
                    : '예정 지출에 쓸 몫은 두 번 빼지 않아요.')
          : reason ?? '',
      key: const ValueKey('reserve-plan-note'),
      style: PayseTypography.caption,
    );
    return Column(
      key: const ValueKey('reserve-plans'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text.rich(
          TextSpan(
            text: '이 돈으로 낼 지출 ',
            children: [
              TextSpan(
                text: '(선택)',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  color: PayseColors.textSecondary,
                ),
              ),
            ],
          ),
          style: TextStyle(
            fontSize: 13,
            height: 18 / 13,
            fontWeight: FontWeight.w600,
            color: PayseColors.textPrimary,
          ),
        ),
        if (plans.isEmpty) ...[
          const SizedBox(height: 6),
          Opacity(
            opacity: canPick ? 1 : .45,
            child: InkWell(
              key: const ValueKey('reserve-plan-pick'),
              onTap: canPick ? onPick : null,
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: PayseColors.borderStrong),
                  ),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '지출 선택',
                        style: TextStyle(
                          fontSize: 17,
                          color: PayseColors.textSecondary,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: PayseColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          note,
        ] else ...[
          for (final p in plans) _planRow(p),
          Opacity(
            opacity: canPick ? 1 : .45,
            child: InkWell(
              key: const ValueKey('reserve-plan-more'),
              onTap: canPick ? onPick : null,
              child: const SizedBox(
                height: 52,
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18, color: PayseColors.textPrimary),
                    SizedBox(width: 6),
                    Text(
                      '지출 더 선택하기',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (reason != null) note,
        ],
      ],
    );
  }

  /// 2026-11-04: 사용 계획 [p] 한 줄. 다음 월급 기간 지출은 금액을 회색으로 보인다.
  Widget _planRow(PlanItem p) {
    final later =
        controller.cycleKnown && !controller.planAdjustable(p.obligationId);
    return InkWell(
      key: ValueKey('reserve-plan-${p.obligationId}'),
      onTap: frozen ? null : () => onOpen(p),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.label ?? '예정 지출',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                  Text(
                    [
                      if (p.dueDate case final due?) '${mdText(due)} 예정',
                      if (later) '다음 월급 기간',
                    ].join(' · '),
                    style: PayseTypography.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: PayseSpace.x3),
            Text(
              formatKrw(p.amountKrw),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: later
                    ? PayseColors.textSecondary
                    : PayseColors.textPrimary,
                fontFeatures: PayseTypography.tabular,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: PayseColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-11-03: [noun] 뒤에 받침에 맞는 주제 조사(은·는)를 붙인다. 한글로 끝나지 않으면 '은(는)'이다.
String withTopic(String noun) {
  if (noun.isEmpty) return noun;
  final last = noun.codeUnitAt(noun.length - 1);
  if (last < 0xAC00 || last > 0xD7A3) return '$noun은(는)';
  return (last - 0xAC00) % 28 == 0 ? '$noun는' : '$noun은';
}
