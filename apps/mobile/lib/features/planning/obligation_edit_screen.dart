import 'package:flutter/material.dart';

import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/status_notice.dart';
import '../connection/connection_review.dart' show accountById, accountLabel;
import '../connection/salary_settings_screen.dart' show GroupedDigitsFormatter;
import '../overview/accounts_screen.dart' show AccountsWriter;
import '../overview/calculation_detail_screen.dart' show md;
import '../overview/home_calculation.dart';
import '../overview/home_screen.dart' show asOfLabel;
import '../overview/transaction_sheets.dart';
import 'obligation_edit.dart';
import 'obligation_edit_controller.dart';
import 'plan_periods.dart';

/// 2026-11-03: 편집을 마친 결과. 추가·수정이면 저장된 예정일 [dueDate], 취소면 [cancelled]가 true다.
typedef ObligationEditResult = ({String? dueDate, bool cancelled});

/// 2026-11-03: 예정 지출 추가(대상 [obligationId]가 null) 또는 수정 화면을 연다. [viewing]은 계획 탭에서 보고 있던 기간이며,
/// 고른 예정일이 그 밖이면 안내한다. 저장·취소에 성공하면 결과를, 그냥 나가면 null을 돌려준다.
Future<ObligationEditResult?> openObligationEditor(
  BuildContext context, {
  required FinancialSnapshot snapshot,
  required AccountsWriter writer,
  String? obligationId,
  PlanPeriod? viewing,
}) {
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  return Navigator.of(context).push<ObligationEditResult>(
    MaterialPageRoute(
      builder: (_) => ObligationEditScreen(
        snapshot: snapshot,
        writer: writer,
        obligationId: obligationId,
        viewing: viewing,
      ),
    ),
  );
}

/// 2026-11-03: 03-2 예정 지출 추가·수정(29-5a). 하단 탭 없는 화면이며 위에서부터 안내 띠 → 이름 → 금액 → 예정일 → 출금 계좌 →
/// (수정이면) '이 예정 지출 취소', 맨 아래에 미리보기('지금 쓸 수 있는 돈 / 추가하면·수정하면')와 동작 이름 버튼을 고정한다.
class ObligationEditScreen extends StatefulWidget {
  /// 2026-11-03: 지금 Snapshot [snapshot], 저장 연결 [writer], 대상 [obligationId], 보고 있던 기간 [viewing]으로 만든다.
  const ObligationEditScreen({
    super.key,
    required this.snapshot,
    required this.writer,
    this.obligationId,
    this.viewing,
  });

  final FinancialSnapshot snapshot;
  final AccountsWriter writer;
  final String? obligationId;
  final PlanPeriod? viewing;

  /// 2026-11-03: 입력 상태 객체를 반환한다.
  @override
  State<ObligationEditScreen> createState() => _ObligationEditScreenState();
}

/// 2026-11-03: 컨트롤러와 입력칸을 묶는다.
class _ObligationEditScreenState extends State<ObligationEditScreen> {
  late final ObligationEditController _c = ObligationEditController(
    snapshot: widget.snapshot,
    writer: widget.writer,
    obligationId: widget.obligationId,
  )..addListener(_refresh);
  late final TextEditingController _label = TextEditingController(
    text: _c.draft.label,
  );
  late final TextEditingController _amount = TextEditingController(
    text: _c.draft.amountKrw == null
        ? ''
        : formatKrwDigits(_c.draft.amountKrw!),
  );

  bool get _adding => widget.obligationId == null;
  String get _verb => _adding ? '추가' : '수정';

  /// 2026-11-03: 결과를 모르는 요청이 취소면 true다. 하단 '다시 시도하기'와 본문 취소 줄 모두 같은 취소 요청을 다시 보낸다.
  bool get _cancelPending {
    final save = _c.save;
    return save is EditUnknown && save.op == EditOp.cancel;
  }

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

  /// 2026-11-03: 저장하고 성공하면 결과와 함께 닫는다.
  Future<void> _submit() async {
    final ok = await _c.submit();
    if (ok && mounted) {
      Navigator.of(context).pop((dueDate: _c.draft.dueDate, cancelled: false));
    }
  }

  /// 2026-11-03: 취소 확인창을 보이고, 고르면 취소한다.
  Future<void> _cancel() async {
    final facts = _c.facts;
    if (facts == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          _CancelDialog(facts: facts, preview: _c.cancelPreview),
    );
    if (confirmed != true || !mounted) return;
    await _sendCancel();
  }

  /// 2026-11-03: 취소를 보내고(결과 불명 뒤면 같은 요청을 그대로) 성공하면 취소 결과와 함께 닫는다.
  Future<void> _sendCancel() async {
    final ok = await _c.cancel();
    if (ok && mounted) {
      Navigator.of(context).pop((dueDate: null, cancelled: true));
    }
  }

  /// 2026-11-03: 나가기. 결과를 모르는 요청이 있으면 최신 정보를 다시 받아 목록에 반영한다.
  void _leave() {
    if (_c.busy) return;
    if (_c.locked) refreshLatest(widget.writer);
    Navigator.of(context).pop();
  }

  /// 2026-11-03: 예정일 시트를 열어 고른 날짜를 반영한다.
  /// 2026-11-03: 입력칸 포커스를 풀어 키보드를 닫는다(날짜·계좌를 고르거나 입력칸 밖을 누를 때).
  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _pickDate() async {
    _unfocus();
    final today = _today();
    final picked = await showPayseSheet<String>(
      context,
      _DateSheet(selected: _c.draft.dueDate, today: today),
    );
    if (picked != null) _c.setDueDate(picked);
  }

  /// 2026-11-03: 출금 계좌 시트를 열어 고른 계좌를 반영한다.
  Future<void> _pickAccount() async {
    _unfocus();
    final picked = await showPayseSheet<String>(
      context,
      _AccountSheet(snapshot: _c.snapshot, selected: _c.draft.accountId),
    );
    if (picked != null) _c.setAccount(picked);
  }

  /// 2026-11-03: Snapshot asOf의 서울 업무 날짜.
  calc.BusinessDate _today() =>
      calc.BusinessDate.inSeoul(DateTime.parse(_c.snapshot.asOf));

  /// 2026-11-03: 위쪽 안내 띠. 상태 설명은 회색, 확인이 필요한 상태는 노랑, 거절은 빨강이다.
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
        title: '이 예정 지출은 더 고칠 수 없어요',
        message: '최신 정보에서 취소됐거나 바뀌었어요. 목록에서 다시 확인해 주세요.',
      ),
      EditRejected(:final reason) => StatusNotice(
        key: ValueKey('edit-band-rejected-${reason.name}'),
        kind: StatusNoticeKind.saveFailed,
        title: '예정 지출을 $what할 수 없어요',
        message: switch (reason) {
          EditRejection.historyLocked =>
            '이미 출금된 기록이 생겨 이 내용으로 바꿀 수 없어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.relationConflict => '연결 정보가 바뀌었어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.limit =>
            '남겨둘 돈과 연결된 금액보다 적게 줄일 수 없어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.forbidden => '이 항목을 볼 수 없게 됐어요. 최신 정보를 불러와 확인해 주세요.',
          EditRejection.validation => '입력한 내용을 다시 확인해 주세요.',
          EditRejection.other => '잠시 후 다시 시도해 주세요.',
        },
        actionLabel: reason == EditRejection.validation ? null : '최신 정보 불러오기',
        onAction: reason == EditRejection.validation ? null : _c.reload,
      ),
      EditReloaded() => const _InfoBand(
        key: ValueKey('edit-band-reloaded'),
        title: '최신 정보로 다시 계산했어요',
        body: '그사이 바뀐 내용을 반영했어요. 아래 금액을 확인하고 다시 저장해 주세요.',
      ),
      _ when _c.facts?.recurring ?? false => _InfoBand(
        key: const ValueKey('edit-band-recurring'),
        title: '이 회차만 바뀌어요',
        body:
            '매월 반복되는 예정 지출 중 ${_c.facts!.obligation.dueDate.substring(5, 7).replaceFirst(RegExp('^0'), '')}월 회차예요. '
            '다른 달 일정은 그대로예요.',
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
    final shortfall = account == null
        ? null
        : balanceShortfall(
            amountKrw: draft.amountKrw,
            settledKrw: facts?.settledKrw ?? 0,
            balanceKrw: account.balanceKrw,
          );
    final dueText = draft.dueDate == null ? null : _longDate(draft.dueDate!);
    final viewing = widget.viewing;
    final outside =
        _adding &&
        viewing != null &&
        draft.dueDate != null &&
        !viewing.contains(calc.BusinessDate.parse(draft.dueDate!, 'dueDate'));
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
            '예정 지출 $_verb',
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
                  key: const ValueKey('edit-scroll'),
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
                          '이번 한 건의 예정 지출을 등록해요.',
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
                        key: const ValueKey('edit-label'),
                        label: '이름',
                        controller: _label,
                        enabled: !frozen,
                        hintText: '예: 통신비',
                        textInputAction: TextInputAction.next,
                        onChanged: _c.setLabel,
                        errorText: problems.label,
                      ),
                    ),
                    Padding(
                      padding: gap,
                      child: PayseTextField(
                        key: const ValueKey('edit-amount'),
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
                        helperText: facts != null && facts.withdrawn
                            ? '${formatKrw(facts.settledKrw)}이 이미 출금됐어요. '
                                  '${formatKrw(facts.floorKrw)}보다 적게 줄일 수 없어요.'
                            : null,
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
                        key: const ValueKey('edit-date'),
                        label: '예정일',
                        value: dueText,
                        placeholder: '날짜 선택',
                        locked: _c.locked,
                        helper: outside
                            ? '지금 보고 있는 기간(${viewing.range})에는 표시되지 않아요. '
                                  '저장하면 이 날짜가 있는 기간으로 이동해요.'
                            : null,
                        onTap: frozen ? null : _pickDate,
                      ),
                    ),
                    Padding(
                      padding: gap,
                      child: PayseSelectField(
                        key: const ValueKey('edit-account'),
                        label: '출금 계좌',
                        value: account == null
                            ? null
                            : accountLabel(_c.snapshot, account),
                        placeholder: '계좌 선택',
                        locked: _c.locked || (facts?.withdrawn ?? false),
                        helper: [
                          if (account != null) balanceText(account),
                          if (facts != null && facts.withdrawn)
                            '일부 금액이 이미 출금되어 계좌 변경과 예정 지출 취소는 할 수 없어요.'
                          else if (_c.locked)
                            '결과를 확인할 때까지 내용을 바꿀 수 없어요.'
                          else if (account != null && !account.included)
                            '계산에서 뺀 계좌라 지금 쓸 수 있는 돈에는 반영되지 않아요.',
                        ].join('\n').nullIfEmpty,
                        onTap: frozen ? null : _pickAccount,
                      ),
                    ),
                    if (shortfall != null) _ShortfallNote(shortfall),
                    if (facts != null &&
                        !facts.withdrawn &&
                        (!_c.locked || _cancelPending))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            PayseSpace.screenHorizontal - PayseSpace.x2,
                            PayseSpace.x5,
                            0,
                            0,
                          ),
                          child: TextButton(
                            key: const ValueKey('edit-cancel'),
                            onPressed: _c.busy || _c.needsLatest
                                ? null
                                : _c.locked
                                ? _sendCancel
                                : _cancel,
                            style: TextButton.styleFrom(
                              foregroundColor: PayseColors.textPrimary,
                              minimumSize: const Size(0, PayseSize.touchMin),
                              textStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            child: const _Underlined('이 예정 지출 취소'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _Bottom(
              verb: _verb,
              preview: _c.preview,
              unchanged: _c.unchanged,
              laterNote: _laterNote(),
              label: _c.busy
                  ? '${_cancelPending ? '취소' : _verb}하는 중'
                  : _c.locked
                  ? '다시 시도하기'
                  : '$_verb하기',
              onPressed: !_c.canSave
                  ? null
                  : _cancelPending
                  ? _sendCancel
                  : _submit,
            ),
          ],
        ),
      ),
    );
  }

  /// 2026-11-03: 미리보기 금액이 그대로이고 예정일이 다음 월급일 이후면 그 설명. 아니면 null이다.
  String? _laterNote() {
    final due = _c.draft.dueDate;
    final calculation = _c.calculation;
    if (due == null || calculation is! HomeCalculationReady) return null;
    final end = calculation.result.salaryCycle?.periodEnd;
    final preview = _c.preview;
    if (end == null ||
        _c.unchanged ||
        preview is! PreviewReady ||
        preview.deltaKrw != 0) {
      return null;
    }
    return calc.BusinessDate.parse(due, 'dueDate').isBefore(end)
        ? null
        : '다음 월급일(${md(end)}) 뒤 예정이에요.';
  }
}

/// 2026-11-03: 'YYYY년 M월 D일 (요일)'.
String _longDate(String date) {
  final d = DateTime.parse(date);
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  return '${d.year}년 ${d.month}월 ${d.day}일 (${days[d.weekday - 1]})';
}

/// 2026-11-03: 변화량 표기. 쓸 수 있는 돈 기준 부호를 늘 붙인다.
String _delta(int krw) => krw == 0
    ? '현재 금액 변화 없음'
    : '${krw > 0 ? '+' : '−'}${formatKrwDigits(krw.abs())}원';

/// 2026-11-03: 하단 고정 영역(위 선 → 미리보기 → 버튼).
class _Bottom extends StatelessWidget {
  /// 2026-11-03: 동작 이름 [verb], 미리보기 [preview](null이면 다시 계산 안내), 바꾼 내용 없음 [unchanged], 다음 월급일 뒤
  /// 설명 [laterNote], 버튼 [label]·[onPressed]로 만든다.
  const _Bottom({
    required this.verb,
    required this.preview,
    required this.unchanged,
    required this.laterNote,
    required this.label,
    required this.onPressed,
  });

  final String verb;
  final PlanPreview? preview;
  final bool unchanged;
  final String? laterNote;
  final String label;
  final VoidCallback? onPressed;

  /// 2026-11-03: 영역을 반환한다.
  @override
  Widget build(BuildContext context) {
    final p = preview;
    final note = switch (p) {
      _ when unchanged => '바꾼 내용이 없어요.',
      PreviewUnavailable(:final reason?) => reason,
      PreviewReady() => laterNote,
      _ => null,
    };
    return Container(
      decoration: const BoxDecoration(
        color: PayseColors.background,
        border: Border(top: BorderSide(color: PayseColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x3,
        PayseSpace.screenHorizontal,
        PayseSpace.x3,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          key: const ValueKey('edit-preview'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (p == null)
              const Text(
                '최신 정보를 불러오면 쓸 수 있는 돈을 다시 계산해 보여드려요.',
                key: ValueKey('edit-preview-pending'),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: PayseColors.textPrimary,
                ),
              )
            else ...[
              PreviewLine(
                label: '지금 쓸 수 있는 돈',
                amount: switch (p) {
                  PreviewReady(:final nowKrw) => nowKrw,
                  PreviewUnavailable(:final nowKrw) => nowKrw,
                },
              ),
              const SizedBox(height: 2),
              PreviewLine(
                key: const ValueKey('edit-preview-after'),
                label: '$verb하면',
                strong: true,
                amount: p is PreviewReady && !unchanged ? p.afterKrw : null,
                same: unchanged && p is PreviewReady ? p.nowKrw : null,
                delta: p is PreviewReady && !unchanged
                    ? _delta(p.deltaKrw)
                    : null,
              ),
            ],
            if (note != null) ...[
              const SizedBox(height: PayseSpace.x1),
              Text(note, style: PayseTypography.caption),
            ],
            const SizedBox(height: PayseSpace.x3),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('edit-save'),
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: PayseColors.charcoal,
                  foregroundColor: PayseColors.onCharcoal,
                  disabledBackgroundColor: PayseColors.surfaceMuted,
                  disabledForegroundColor: PayseColors.textSecondary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PayseRadius.sm),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-11-03: 미리보기 한 줄. 왼쪽 이름, 오른쪽 끝 금액(없으면 보통 굵기 '계산 불가'). 강조 줄은 최종 금액을 크게 굵게 보이고
/// 바로 왼쪽에 변화량 [delta]를 작게 붙인다. 좁으면 변화량이 금액 위로 올라간다. 음수 금액은 오류색이다.
class PreviewLine extends StatelessWidget {
  /// 2026-11-03: 이름 [label], 금액 [amount], 강조 [strong], 변화량 [delta], 바꾼 내용이 없을 때의 같은 금액 [same]으로 만든다.
  const PreviewLine({
    super.key,
    required this.label,
    required this.amount,
    this.strong = false,
    this.delta,
    this.same,
  });

  final String label;
  final int? amount;
  final bool strong;
  final String? delta;
  final int? same;

  /// 2026-11-03: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final value = amount ?? same;
    final valueText = value == null ? '계산 불가' : formatKrw(value);
    final valueStyle = value == null
        ? const TextStyle(fontSize: 15, color: PayseColors.textSecondary)
        : TextStyle(
            fontSize: strong ? 17 : 15,
            fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
            color: value < 0
                ? PayseColors.error
                : strong
                ? PayseColors.textPrimary
                : PayseColors.textSecondary,
            fontFeatures: PayseTypography.tabular,
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            label,
            style: strong
                ? const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: PayseColors.textPrimary,
                  )
                : PayseTypography.caption,
          ),
        ),
        const SizedBox(width: PayseSpace.x3),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: PayseSpace.x3,
            children: [
              if (delta case final delta?)
                Text(
                  delta,
                  key: const ValueKey('preview-delta'),
                  style: const TextStyle(
                    fontSize: 14,
                    color: PayseColors.textSecondary,
                    fontFeatures: PayseTypography.tabular,
                  ),
                ),
              Text(valueText, style: valueStyle),
            ],
          ),
        ),
      ],
    );
  }
}

/// 2026-11-03: 회색 상태 설명 띠(정보 아이콘, 제목 14/600 + 설명 13). 위 막대 바로 아래에 붙는다.
class _InfoBand extends StatelessWidget {
  /// 2026-11-03: 제목 [title]과 설명 [body]로 만든다.
  const _InfoBand({super.key, required this.title, required this.body});

  final String title;
  final String body;

  /// 2026-11-03: 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: PayseSpace.screenHorizontal,
          vertical: PayseSpace.x4,
        ),
        decoration: const BoxDecoration(
          color: PayseColors.insufficientNoticeSurface,
          border: Border(bottom: BorderSide(color: PayseColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.info_outline,
                size: 18,
                color: PayseColors.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w600,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: PayseSpace.x1),
                  Text(
                    body,
                    style: PayseTypography.caption.copyWith(
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-11-03: 취소 확인창(공통 확인창과 같은 폭, 금액 앞 구분선 없이 여백만, 금액과 변화량은 글자 기준선 맞춤). 제목, 미해제 연결 해제 한 줄(연결마다), '취소 후 쓸 수 있는 돈'과 '금액 (변화량)', 돌아가기·취소하기.
class _CancelDialog extends StatelessWidget {
  /// 2026-11-03: 대상 [facts]와 미리보기 [preview]로 만든다.
  const _CancelDialog({required this.facts, required this.preview});

  final ObligationFacts facts;
  final PlanPreview? preview;

  /// 2026-11-03: 확인창을 반환한다.
  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Dialog(
      backgroundColor: PayseColors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${facts.obligation.label} 예정 지출을 취소할까요?',
              style: const TextStyle(
                fontSize: 17,
                height: 1.45,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
              ),
            ),
            if (facts.held.isNotEmpty) const SizedBox(height: PayseSpace.x3),
            for (final h in facts.held)
              Text(
                '${h.reserveLabel ?? '남겨둘 돈'}과 연결한 '
                '${formatKrw(h.unreleasedKrw)}도 연결 해제돼요.',
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.55,
                  color: PayseColors.textPrimary,
                ),
              ),
            const SizedBox(height: PayseSpace.x5),
            const Text('취소 후 쓸 수 있는 돈', style: PayseTypography.caption),
            const SizedBox(height: 2),
            switch (p) {
              PreviewReady(:final afterKrw, :final deltaKrw) => Text.rich(
                key: const ValueKey('cancel-preview'),
                TextSpan(
                  children: [
                    TextSpan(
                      text: formatKrw(afterKrw),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: afterKrw < 0
                            ? PayseColors.error
                            : PayseColors.textPrimary,
                      ),
                    ),
                    const WidgetSpan(child: SizedBox(width: PayseSpace.x2)),
                    TextSpan(
                      text: '(${_delta(deltaKrw)})',
                      style: const TextStyle(
                        fontSize: 14,
                        color: PayseColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(fontFeatures: PayseTypography.tabular),
              ),
              _ => const Text(
                '계산 불가',
                key: ValueKey('cancel-preview'),
                style: TextStyle(
                  fontSize: 15,
                  color: PayseColors.textSecondary,
                ),
              ),
            },
            const SizedBox(height: PayseSpace.x5),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: PayseColors.textPrimary,
                        side: const BorderSide(color: PayseColors.borderStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(PayseRadius.sm),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('돌아가기'),
                    ),
                  ),
                ),
                const SizedBox(width: PayseSpace.x2),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      key: const ValueKey('cancel-confirm'),
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: PayseColors.charcoal,
                        foregroundColor: PayseColors.onCharcoal,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(PayseRadius.sm),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('취소하기'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-11-03: 예정일 선택 시트. 위 '‹ YYYY년 M월 ›'과 일~토 7칸 달력에서 날짜를 고르고 '적용'으로 반영한다. 기준일 1년 전부터
/// 2년 뒤 연말까지만 고른다. 앱에 다른 언어 달력 설정이 없어 한국어 달력을 직접 그린다(계획 탭 달력 월 칸과 같은 색 규칙).
class _DateSheet extends StatefulWidget {
  /// 2026-11-03: 지금 값 [selected](YYYY-MM-DD)와 기준일 [today]로 만든다.
  const _DateSheet({required this.selected, required this.today});

  final String? selected;
  final calc.BusinessDate today;

  /// 2026-11-03: 고른 날짜 상태를 반환한다.
  @override
  State<_DateSheet> createState() => _DateSheetState();
}

/// 2026-11-03: 보고 있는 달과 고른 날짜를 보관한다.
class _DateSheetState extends State<_DateSheet> {
  late DateTime _picked = widget.selected == null
      ? DateTime(widget.today.year, widget.today.month, widget.today.day)
      : DateTime.parse(widget.selected!);
  late DateTime _month = DateTime(_picked.year, _picked.month);

  DateTime get _first =>
      DateTime(widget.today.year - 1, widget.today.month, widget.today.day);
  DateTime get _last => DateTime(widget.today.year + 2, 12, 31);

  /// 2026-11-03: [d]가 고를 수 있는 범위면 true다.
  bool _inRange(DateTime d) => !d.isBefore(_first) && !d.isAfter(_last);

  /// 2026-11-03: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final prev = DateTime(_month.year, _month.month - 1);
    final next = DateTime(_month.year, _month.month + 1);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = DateTime(_month.year, _month.month).weekday % 7;
    final today = DateTime(
      widget.today.year,
      widget.today.month,
      widget.today.day,
    );
    return SelectSheet(
      title: '예정일',
      onApply: () => Navigator.of(context).pop(
        '${_picked.year.toString().padLeft(4, '0')}-'
        '${_picked.month.toString().padLeft(2, '0')}-'
        '${_picked.day.toString().padLeft(2, '0')}',
      ),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const ValueKey('edit-date-prev'),
              tooltip: '이전 달',
              color: PayseColors.textPrimary,
              onPressed: DateTime(_month.year, _month.month, 0).isBefore(_first)
                  ? null
                  : () => setState(() => _month = prev),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '${_month.year}년 ${_month.month}월',
              key: const ValueKey('edit-date-month'),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
              ),
            ),
            IconButton(
              key: const ValueKey('edit-date-next'),
              tooltip: '다음 달',
              color: PayseColors.textPrimary,
              onPressed: next.isAfter(_last)
                  ? null
                  : () => setState(() => _month = next),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: PayseSpace.x2),
        Row(
          children: [
            for (final w in const ['일', '월', '화', '수', '목', '금', '토'])
              Expanded(
                child: Text(
                  w,
                  textAlign: TextAlign.center,
                  style: PayseTypography.caption,
                ),
              ),
          ],
        ),
        const SizedBox(height: PayseSpace.x2),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var k = 0; k < lead; k++) const SizedBox.shrink(),
            for (var d = 1; d <= days; d++)
              _DayCell(
                day: d,
                enabled: _inRange(DateTime(_month.year, _month.month, d)),
                selected: _picked == DateTime(_month.year, _month.month, d),
                isToday: today == DateTime(_month.year, _month.month, d),
                onTap: () => setState(
                  () => _picked = DateTime(_month.year, _month.month, d),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 2026-11-03: 달력 날짜 칸(터치 48). 고른 날은 차콜 원·흰 글자, 오늘은 진한 테두리, 고를 수 없는 날은 흐린 글자다.
class _DayCell extends StatelessWidget {
  /// 2026-11-03: 날 [day], 선택 가능 [enabled], 선택 [selected], 오늘 [isToday], 누르기 [onTap]으로 만든다.
  const _DayCell({
    required this.day,
    required this.enabled,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  final int day;
  final bool enabled;
  final bool selected;
  final bool isToday;
  final VoidCallback onTap;

  /// 2026-11-03: 칸을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? PayseColors.charcoal : null,
              border: isToday && !selected
                  ? Border.all(color: PayseColors.borderStrong)
                  : null,
            ),
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected || isToday
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: selected
                    ? PayseColors.onCharcoal
                    : enabled
                    ? PayseColors.textPrimary
                    : PayseColors.scheduled,
                fontFeatures: PayseTypography.tabular,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-11-03: 출금 계좌 선택 시트. 연결된 계좌를 모두 보이고, 계산에서 뺀 계좌는 보조 줄로 알린다(고르는 것은 막지 않음).
/// 계좌마다 보조 줄에 현재 잔액을, 제목 아래에 자료 기준 시각을 한 번 보인다. 잔액으로 고르기를 막지 않는다.
class _AccountSheet extends StatefulWidget {
  /// 2026-11-03: [snapshot]과 지금 값 [selected]로 만든다.
  const _AccountSheet({required this.snapshot, required this.selected});

  final FinancialSnapshot snapshot;
  final String? selected;

  /// 2026-11-03: 고른 계좌 상태를 반환한다.
  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

/// 2026-11-03: 고른 계좌를 보관한다.
class _AccountSheetState extends State<_AccountSheet> {
  late String? _picked = widget.selected;

  /// 2026-11-03: 시트를 반환한다. 계산 포함 계좌를 먼저 둔다.
  @override
  Widget build(BuildContext context) {
    final accounts = [...?widget.snapshot.accounts]
      ..sort((a, b) => (b.included ? 1 : 0) - (a.included ? 1 : 0));
    return SelectSheet(
      title: '출금 계좌',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          PayseSpace.screenHorizontal,
          0,
          PayseSpace.screenHorizontal,
          PayseSpace.x1,
        ),
        child: Text(
          '${asOfLabel(widget.snapshot.asOf)} 잔액',
          key: const ValueKey('edit-account-asof'),
          style: PayseTypography.caption,
        ),
      ),
      onApply: _picked == null
          ? null
          : () => Navigator.of(context).pop(_picked),
      children: [
        for (final a in accounts)
          RadioRow(
            key: ValueKey('edit-account-${a.accountId}'),
            label: accountLabel(widget.snapshot, a),
            caption: [balanceText(a), if (!a.included) '계산에서 뺀 계좌'].join(' · '),
            selected: _picked == a.accountId,
            onTap: () => setState(() => _picked = a.accountId),
          ),
      ],
    );
  }
}

/// 2026-11-03: 글꼴 밑줄 대신 글자 아래에 선을 그은 글자. 띄어쓰기에서 밑줄 높이가 달라지지 않는다.
class _Underlined extends StatelessWidget {
  /// 2026-11-03: 글자 [text]로 만든다.
  const _Underlined(this.text);

  final String text;

  /// 2026-11-03: 글자와 아래 선을 반환한다. 선 색은 버튼 글자색을 따른다.
  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: color ?? PayseColors.textPrimary),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: Text(text),
      ),
    );
  }
}

/// 2026-11-03: 계좌 [account]의 현재 잔액 문구. 모르면 0원으로 바꾸지 않고 '잔액 확인 불가'다.
String balanceText(Account account) => switch (account.balanceKrw) {
  final krw? => '잔액 ${formatKrw(krw)}',
  null => '잔액 확인 불가',
};

extension on String {
  /// 2026-11-03: 빈 문자열이면 null.
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// 2026-11-03: 출금 계좌 아래 주의 안내. 아직 나가지 않은 금액이 현재 잔액보다 [overKrw]만큼 많을 때 보인다.
/// 오류가 아니라 주의 색이며 저장을 막지 않고, 미래 출금 실패를 단정하지 않는다.
class _ShortfallNote extends StatelessWidget {
  /// 2026-11-03: 초과 금액 [overKrw]로 만든다.
  const _ShortfallNote(this.overKrw);

  final int overKrw;

  /// 2026-11-03: 아이콘과 두 문장을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('edit-balance-note'),
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        6,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, right: 4),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: PayseColors.warning,
            ),
          ),
          Expanded(
            child: Text(
              '현재 잔액보다 ${formatKrw(overKrw)} 많아요. '
              '예정일까지 잔액을 확인해 주세요.',
              style: const TextStyle(
                fontSize: 12,
                height: 18 / 12,
                color: PayseColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
