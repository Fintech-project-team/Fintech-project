import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/institution_mark.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/secondary_button.dart';
import '../../shared/design/selection_controls.dart';
import '../../shared/design/status_notice.dart';
import 'connection_flow_controller.dart';
import 'connection_illustration.dart';
import 'connection_page.dart';
import 'connection_review.dart';

/// 2026-10-22: 기관 종류 문자열을 표시 종류로 바꾼다. 은행이 아니면 카드사로 그린다.
InstitutionKind _kindOf(Institution i) =>
    i.kind == 'bank' ? InstitutionKind.bank : InstitutionKind.card;

/// 2026-10-22: 기관 보유 개수 문장("계좌 2개"·"카드 1장").
String _holdings(Institution i) =>
    i.kind == 'bank' ? '계좌 ${i.accountCount}개' : '카드 ${i.cardCount}장';

/// 2026-10-22: 화면 여백 안에 [children]을 세로로 쌓은 스크롤 목록.
Widget _paddedList(List<Widget> children) => ListView(
  padding: const EdgeInsets.symmetric(horizontal: PayseSpace.screenHorizontal),
  children: children,
);

/// 2026-10-23: 12-1 진입 로딩 단계. 은행 → 카드사 → 다 찾음 순서로 흐름이 넘긴다.
enum EntryLoadingPhase { banks, cards, done }

/// 2026-10-22: 12-1 진입 전 로딩(2~3초). 다음 화면으로 넘기는 시점은 흐름이 정한다.
/// 2026-10-23: 시안 A·B. 통장·카드 그림과 은행 → 카드사 단계를 보이고, 다 찾으면 찾은 수를 보인다.
/// 개수는 시작 Snapshot의 기관 목록에서 센 값이며 단계 전환 속도만 연출이다.
class InstitutionEntryLoadingScreen extends StatelessWidget {
  /// 2026-10-23: 현재 단계 [phase], 은행 수 [bankCount], 카드사 수 [cardCount], 사용자 이름 [userName](없으면 이름 없이),
  /// 다 찾은 뒤 '다음'을 누르면 부를 [onNext]로 만든다. 자동으로 넘어가지 않는다.
  const InstitutionEntryLoadingScreen({
    super.key,
    required this.phase,
    required this.bankCount,
    required this.cardCount,
    required this.onNext,
    this.userName,
  });

  final ValueListenable<EntryLoadingPhase> phase;
  final int bankCount;
  final int cardCount;
  final VoidCallback onNext;
  final String? userName;

  /// 2026-10-23: 단계에 맞는 제목·그림·단계 목록과, 다 찾으면 아래에서 올라오는 '다음' 버튼을 반환한다.
  /// 기기의 움직임 줄이기 설정이 켜져 있으면 버튼이 바로 나타난다.
  @override
  Widget build(BuildContext context) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return ValueListenableBuilder<EntryLoadingPhase>(
      valueListenable: phase,
      builder: (context, current, _) {
        final done = current == EntryLoadingPhase.done;
        final who = userName == null ? '' : '$userName님이 ';
        return ConnectionPage(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConnectionHeading(
                done
                    ? '연결할 수 있는 금융사\n${bankCount + cardCount}곳을 찾았어요'
                    : '$who연결할 수 있는\n금융사를 찾고 있어요',
                subtitle: done
                    ? '이제 불러올 금융사를 골라주세요.'
                    : '은행과 카드사 목록을 차례로 확인하고 있어요.',
              ),
              Expanded(
                child: Center(
                  child: ConnectionIllustration(
                    state: done
                        ? ConnectionIllustrationState.found
                        : ConnectionIllustrationState.searching,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PayseSpace.screenHorizontal,
                  0,
                  PayseSpace.screenHorizontal,
                  40,
                ),
                child: Column(
                  children: [
                    _EntryStep(
                      key: const ValueKey('entry-step-banks'),
                      kind: InstitutionKind.bank,
                      title: '은행',
                      count: bankCount,
                      unit: '곳',
                      finished: current != EntryLoadingPhase.banks,
                    ),
                    _EntryStep(
                      key: const ValueKey('entry-step-cards'),
                      kind: InstitutionKind.card,
                      title: '카드사',
                      count: cardCount,
                      unit: '곳',
                      finished: done,
                      waiting: current == EntryLoadingPhase.banks,
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottom: IgnorePointer(
            ignoring: !done,
            child: ExcludeSemantics(
              excluding: !done,
              child: AnimatedSlide(
                offset: done ? Offset.zero : const Offset(0, 1),
                duration: motion,
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: done ? 1 : 0,
                  duration: motion,
                  child: PrimaryButton(
                    key: const ValueKey('entry-next'),
                    label: '다음',
                    onPressed: onNext,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 2026-10-23: 진입 로딩 단계 한 줄. 찾는 중·기다리는 중·완료를 글자로도 구분한다.
class _EntryStep extends StatelessWidget {
  /// 2026-10-23: 금융사 종류 [kind], 이름 [title], 찾은 수 [count]와 단위 [unit], 완료 여부 [finished],
  /// 아직 시작 전인지 [waiting]으로 만든다.
  const _EntryStep({
    super.key,
    required this.kind,
    required this.title,
    required this.count,
    required this.unit,
    required this.finished,
    this.waiting = false,
  });

  final InstitutionKind kind;
  final String title;
  final int count;
  final String unit;
  final bool finished;
  final bool waiting;

  /// 2026-10-23: 표시·이름·진행 설명·상태를 반환한다.
  @override
  Widget build(BuildContext context) {
    const statusStyle = TextStyle(
      fontSize: 13,
      height: 18 / 13,
      color: PayseColors.textSecondary,
    );
    final detail = finished
        ? '$count$unit 찾았어요'
        : waiting
        ? '곧 확인해요'
        : '목록을 확인하고 있어요';
    final Widget trailing = finished
        ? const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 20,
                child: FittedBox(child: SelectionCheckMark(selected: true)),
              ),
              SizedBox(width: 6),
              Text('완료', style: statusStyle),
            ],
          )
        : waiting
        ? const Text('기다리는 중', style: statusStyle)
        : const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: PayseColors.charcoal,
                  backgroundColor: PayseColors.surfaceMuted,
                ),
              ),
              SizedBox(width: 6),
              Text('찾는 중', style: statusStyle),
            ],
          );
    return MergeSemantics(
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
        ),
        child: Row(
          children: [
            ConnectionGroupMark(card: kind == InstitutionKind.card),
            const SizedBox(width: PayseSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: PayseTypography.ledgerName.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(detail, style: PayseTypography.caption),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// 2026-10-22: 12-1 금융사 고르기. 기본 모두 해제, 은행 1곳 이상이어야 다음 활성.
/// 카드사만 고른 동안에만 버튼 위 경고를 보인다(처음에는 보이지 않음).
class InstitutionSelectScreen extends StatelessWidget {
  /// 2026-10-22: 흐름 상태 [controller]와 다음 [onNext]로 만든다.
  /// 2026-10-23: [devEntry]는 개발 빌드에서만 목록 끝에 붙는 개발 설정 진입이며 릴리스에서는 null이다.
  const InstitutionSelectScreen({
    super.key,
    required this.controller,
    required this.onNext,
    this.devEntry,
  });

  final ConnectionFlowController controller;
  final VoidCallback onNext;
  final Widget? devEntry;

  /// 2026-10-22: 은행·카드사 묶음 목록과 다음 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final banks = [
          for (final i in controller.institutions)
            if (i.kind == 'bank') i,
        ];
        final cards = [
          for (final i in controller.institutions)
            if (i.kind != 'bank') i,
        ];
        Widget row(Institution i) => SelectionListRow(
          key: ValueKey('institution-${i.code}'),
          leading: InstitutionMark(code: i.code, kind: _kindOf(i)),
          title: i.name,
          subtitle: _holdings(i),
          selected: controller.isChosen(i.code),
          onChanged: (_) => controller.toggleChosen(i.code),
        );
        return ConnectionPage(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ConnectionHeading(
                '어느 금융사의 정보를\n불러올까요?',
                subtitle: '계좌를 불러올 은행을 1곳 이상 골라주세요.',
              ),
              Expanded(
                child: _paddedList([
                  if (banks.isNotEmpty) ...[
                    const ConnectionSection('은행'),
                    ...banks.map(row),
                  ],
                  if (cards.isNotEmpty) ...[
                    const ConnectionSection('카드사'),
                    ...cards.map(row),
                  ],
                  const SizedBox(height: PayseSpace.x6),
                  ?devEntry,
                ]),
              ),
            ],
          ),
          bottomNotice: controller.chosenCardOnly
              ? const StatusNotice.attached(
                  kind: StatusNoticeKind.warning,
                  title: '쓸 수 있는 돈을 계산하려면 은행을 1곳 이상 골라주세요.',
                )
              : null,
          bottom: PrimaryButton(
            label: '다음',
            onPressed: controller.hasChosenBank ? onNext : null,
          ),
        );
      },
    );
  }
}

/// 2026-10-22: 12-2 동의. 기본 모두 해제, 은행 1곳 이상 동의해야 진행. 동의는 흐름 메모리에만 둔다.
class ConsentScreen extends StatelessWidget {
  /// 2026-10-22: 흐름 상태 [controller], 뒤로 [onBack], 동의 내용 보기 [onViewItems], 다음 [onNext]로 만든다.
  const ConsentScreen({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onViewItems,
    required this.onNext,
  });

  final ConnectionFlowController controller;
  final VoidCallback onBack;
  final ValueChanged<Institution> onViewItems;
  final VoidCallback onNext;

  static const String bankItems = '계좌 이름·잔액·최근 1년 거래 내역';
  static const String cardItems = '카드 이름·사용 내역·청구서·결제 계좌';

  /// 2026-10-22: 모두 동의 줄, 기관별 동의 줄, 진행 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final chosen = controller.chosenInstitutions;
        final banks = [
          for (final i in chosen)
            if (i.kind == 'bank') i,
        ];
        final cards = [
          for (final i in chosen)
            if (i.kind != 'bank') i,
        ];
        Widget row(Institution i) => SelectionCheckRow(
          key: ValueKey('consent-${i.code}'),
          label: i.name,
          selected: controller.isConsented(i.code),
          onChanged: (_) => controller.toggleConsent(i.code),
          linkLabel: '보기',
          onLink: () => onViewItems(i),
        );
        return ConnectionPage(
          onBack: onBack,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ConnectionHeading(
                '고른 금융사의 정보를\n불러와도 될까요?',
                subtitle: '동의한 금융사의 정보만 불러와요.',
              ),
              Expanded(
                child: _paddedList([
                  const SizedBox(height: PayseSpace.x4),
                  SelectionCheckRow(
                    key: const ValueKey('consent-all'),
                    label: '모두 동의',
                    emphasis: true,
                    selected: controller.allConsented,
                    onChanged: controller.setAllConsent,
                  ),
                  const Divider(color: PayseColors.dividerSection, height: 13),
                  if (banks.isNotEmpty) ...[
                    const ConnectionSection('은행', caption: bankItems),
                    ...banks.map(row),
                  ],
                  if (cards.isNotEmpty) ...[
                    const ConnectionSection('카드사', caption: cardItems),
                    ...cards.map(row),
                  ],
                  const SizedBox(height: PayseSpace.x6),
                ]),
              ),
            ],
          ),
          bottomNotice: controller.consentedCardOnly
              ? const StatusNotice.attached(
                  kind: StatusNoticeKind.warning,
                  title: '은행 1곳 이상 동의해야 계좌를 불러올 수 있어요.',
                )
              : null,
          bottom: PrimaryButton(
            label: '동의하고 불러오기',
            onPressed: controller.hasConsentedBank ? onNext : null,
          ),
        );
      },
    );
  }
}

/// 2026-10-22: 12-2 '보기'. 그 기관에서 불러오는 정보 항목을 보인다. 문안은 확정 전이다.
class ConsentItemsScreen extends StatelessWidget {
  /// 2026-10-22: 기관 [institution]으로 만든다.
  const ConsentItemsScreen({super.key, required this.institution});

  final Institution institution;

  /// 2026-10-22: 기관 이름과 불러오는 항목을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ConnectionPage(
      onBack: () => Navigator.of(context).pop(),
      body: ConnectionHeading(
        '${institution.name}에서 불러오는 정보',
        subtitle: institution.kind == 'bank'
            ? ConsentScreen.bankItems
            : ConsentScreen.cardItems,
      ),
    );
  }
}

/// 2026-10-22: 12-3 불러오기. 표시 연출이 끝나고 최종 목록 저장(POST)이 성공한 뒤에만 다음으로 간다.
class InstitutionLoadingScreen extends StatelessWidget {
  /// 2026-10-22: 흐름 상태 [controller], 뒤로 [onBack], 저장 성공 뒤 [onSaved],
  /// 거절된 저장 뒤 다시 고르기 [onRestart]로 만든다.
  const InstitutionLoadingScreen({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onSaved,
    required this.onRestart,
  });

  final ConnectionFlowController controller;
  final VoidCallback onBack;
  final VoidCallback onSaved;
  final VoidCallback onRestart;

  /// 2026-10-22: 저장을 요청하고 성공하면 다음 화면으로 넘긴다.
  Future<void> _save() async {
    if (await controller.saveLinks()) onSaved();
  }

  /// 2026-10-22: 진행 상태에 맞는 제목·목록·안내·버튼을 반환한다. 진행 중에는 뒤로 갈 수 없다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rows = controller.loadingInstitutions;
        final failed = controller.failedInstitutions;
        final busy = controller.loadInProgress;
        final save = controller.linkSave;
        final saving = save is SaveInProgress;
        final doneCount = rows
            .where(
              (i) =>
                  controller.loadStatusOf(i.code) == InstitutionLoadStatus.done,
            )
            .length;
        final title = busy
            ? '금융사 정보를\n불러오고 있어요'
            : failed.isEmpty
            ? '금융사 정보를\n다 불러왔어요'
            : '${failed.length}곳의 정보를\n불러오지 못했어요';
        final current = rows
            .where(
              (i) =>
                  controller.loadStatusOf(i.code) ==
                  InstitutionLoadStatus.loading,
            )
            .firstOrNull;
        final subtitle = busy
            ? current == null
                  ? '곧 불러올게요.'
                  : '${current.name} 정보를 불러오는 중이에요.'
            : failed.isEmpty
            ? null
            : '다시 시도하거나, 빼고 계속할 수 있어요.';
        return PopScope(
          canPop: !busy && !saving,
          child: ConnectionPage(
            onBack: busy || saving ? null : onBack,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConnectionHeading(title, subtitle: subtitle),
                _LoadProgress(done: doneCount, total: rows.length),
                if (save is SaveFailed) ...[
                  const SizedBox(height: PayseSpace.x5),
                  _saveFailureNotice(save.failure, '연결', controller),
                ],
                Expanded(
                  child: _paddedList([
                    const SizedBox(height: PayseSpace.x2),
                    for (final i in rows) _LoadRow(controller, i),
                  ]),
                ),
              ],
            ),
            bottomNotice: !busy && failed.isNotEmpty && !controller.finalHasBank
                ? const StatusNotice.attached(
                    kind: StatusNoticeKind.warning,
                    title: '계산할 은행 계좌가 없어요. 은행을 다시 시도해주세요.',
                  )
                : null,
            bottom: _button(busy, saving, failed, save),
          ),
        );
      },
    );
  }

  /// 2026-10-22: 상태에 맞는 아래 버튼을 반환한다.
  Widget _button(
    bool busy,
    bool saving,
    List<Institution> failed,
    ConnectionSaveState save,
  ) {
    if (busy) return const PrimaryButton(label: '불러오는 중이에요', onPressed: null);
    if (saving) return const PrimaryButton(label: '저장하고 있어요', onPressed: null);
    if (save case SaveFailed(:final failure)) {
      return switch (failure) {
        ConnectionSaveFailure.retryable => PrimaryButton(
          label: '다시 시도',
          onPressed: _save,
        ),
        ConnectionSaveFailure.outdated => _reloadButton(controller),
        ConnectionSaveFailure.rejected => PrimaryButton(
          label: '금융사 다시 고르기',
          onPressed: onRestart,
        ),
      };
    }
    final label = failed.isEmpty
        ? '계속하기'
        : failed.length == 1
        ? '${failed.single.name} 제외하고 계속하기'
        : '${failed.length}곳 제외하고 계속하기';
    return PrimaryButton(
      label: label,
      onPressed: controller.finalHasBank ? _save : null,
    );
  }
}

/// 2026-10-23: 12-3 진행률(시안 E). 완료 기관 수 ÷ 전체 기관 수만 쓰며 기관 사이 중간값을 꾸며 내지 않는다.
class _LoadProgress extends StatelessWidget {
  /// 2026-10-23: 완료 기관 수 [done]과 전체 기관 수 [total]로 만든다.
  const _LoadProgress({required this.done, required this.total});

  final int done;
  final int total;

  /// 2026-10-23: 백분율·완료 수·진행 막대를 반환한다.
  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : done / total;
    return Padding(
      key: const ValueKey('load-progress'),
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x6,
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
      ),
      child: Semantics(
        label: '$total곳 중 $done곳 완료',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${(ratio * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 28,
                    height: 34 / 28,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: PayseColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  '$total곳 중 $done곳 완료',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 18 / 13,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: PayseColors.surfaceMuted),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: ratio,
                      child: const ColoredBox(color: PayseColors.charcoal),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-22: 12-3 기관 한 줄. 완료·불러오는 중·기다리는 중·실패(다시 시도)를 글자로도 구분한다.
class _LoadRow extends StatelessWidget {
  /// 2026-10-22: 흐름 상태 [controller]와 기관 [institution]으로 만든다.
  const _LoadRow(this.controller, this.institution);

  final ConnectionFlowController controller;
  final Institution institution;

  /// 2026-10-22: 기관 표시·이름·상태를 반환한다.
  /// 2026-10-23: 연결 저장 중에는 실패 행의 다시 시도 대신 '제외'를 보인다.
  @override
  Widget build(BuildContext context) {
    final status = controller.loadStatusOf(institution.code);
    final failed = status == InstitutionLoadStatus.failed;
    final saving = controller.linkSave is SaveInProgress;
    const statusStyle = TextStyle(
      fontSize: 13,
      height: 18 / 13,
      color: PayseColors.textSecondary,
    );
    final trailing = switch (status) {
      InstitutionLoadStatus.done => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 20,
            child: FittedBox(child: SelectionCheckMark(selected: true)),
          ),
          SizedBox(width: 6),
          Text('완료', style: statusStyle),
        ],
      ),
      InstitutionLoadStatus.loading => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: PayseColors.charcoal,
              backgroundColor: PayseColors.surfaceMuted,
            ),
          ),
          SizedBox(width: 6),
          Text('불러오는 중', style: statusStyle),
        ],
      ),
      InstitutionLoadStatus.waiting => const Text('기다리는 중', style: statusStyle),
      InstitutionLoadStatus.failed when saving => const Text(
        '제외',
        style: statusStyle,
      ),
      InstitutionLoadStatus.failed => SecondaryButton(
        key: ValueKey('retry-${institution.code}'),
        label: '다시 시도',
        onPressed: () => controller.retry(institution.code),
      ),
    };
    return Container(
      key: ValueKey('load-${institution.code}'),
      constraints: const BoxConstraints(minHeight: 64),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        children: [
          InstitutionMark(code: institution.code, kind: _kindOf(institution)),
          const SizedBox(width: PayseSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  institution.name,
                  style: PayseTypography.ledgerName.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  failed ? '불러오지 못했어요' : _holdings(institution),
                  style: PayseTypography.caption.copyWith(
                    color: failed ? PayseColors.error : null,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

/// 2026-10-22: 저장 실패 종류별 띠형 안내. [what]은 저장 대상 이름("연결"·"계좌 선택")이다.
/// 2026-10-23: 버전 충돌 뒤 다시 읽기에 실패했으면 [controller]의 상태로 그 사실을 알린다.
Widget _saveFailureNotice(
  ConnectionSaveFailure failure,
  String what,
  ConnectionFlowController controller,
) => switch (failure) {
  ConnectionSaveFailure.retryable => StatusNotice(
    kind: StatusNoticeKind.saveFailed,
    title: '$what을 저장하지 못했어요',
    message: '인터넷 연결을 확인하고 다시 시도해주세요. 고른 내용은 그대로 남아 있어요.',
  ),
  ConnectionSaveFailure.outdated
      when controller.reloadStatus == ReloadStatus.failed =>
    const StatusNotice(
      kind: StatusNoticeKind.versionConflict,
      title: '최신 정보를 불러오지 못했어요',
      message: '인터넷 연결을 확인하고 다시 불러와주세요. 고른 내용은 그대로 남아 있어요.',
    ),
  ConnectionSaveFailure.outdated => const StatusNotice(
    kind: StatusNoticeKind.versionConflict,
    title: '저장 전에 정보가 바뀌었어요',
    message: '최신 정보를 다시 불러온 뒤 계속해주세요.',
  ),
  ConnectionSaveFailure.rejected => StatusNotice(
    kind: StatusNoticeKind.saveFailed,
    title: '$what을 저장할 수 없어요',
    message: '고른 내용을 다시 확인해주세요.',
  ),
};

/// 2026-10-23: 버전 충돌 뒤 아래 버튼. [controller]가 다시 읽는 중이면 누를 수 없게 보인다.
Widget _reloadButton(ConnectionFlowController controller) =>
    controller.reloadStatus == ReloadStatus.loading
    ? const PrimaryButton(label: '불러오고 있어요', onPressed: null)
    : PrimaryButton(label: '다시 불러오기', onPressed: controller.reload);

/// 2026-10-22: 01-1 계좌 고르기. 입출금 기본 선택, 예금·적금 기본 해제. 0개면 진행 불가.
/// 모아둘 돈이 있는 계좌를 해제할 때마다 09-10 안내를 보인다.
class AccountSelectScreen extends StatelessWidget {
  /// 2026-10-22: 흐름 상태 [controller], 뒤로 [onBack], 저장 성공 뒤 [onSaved]로 만든다.
  /// 2026-10-23: [devEntry]는 개발 빌드에서만 목록 끝에 붙는 개발 설정 진입이며 릴리스에서는 null이다.
  const AccountSelectScreen({
    super.key,
    required this.controller,
    required this.onSaved,
    this.onBack,
    this.devEntry,
  });

  final ConnectionFlowController controller;
  final VoidCallback? onBack;
  final VoidCallback onSaved;
  final Widget? devEntry;

  /// 2026-10-22: 선택을 저장하고 성공하면 다음 화면으로 넘긴다.
  Future<void> _save() async {
    if (await controller.saveSelection()) onSaved();
  }

  /// 2026-10-22: 계좌 묶음 목록·안내·버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final demand = [
          for (final a in controller.accounts)
            if (a.productType == 'demand') a,
        ];
        final others = [
          for (final a in controller.accounts)
            if (a.productType != 'demand') a,
        ];
        final save = controller.selectionSave;
        final saving = save is SaveInProgress;
        final noticeId = controller.reserveNoticeAccount;
        final noticeAccount = noticeId == null
            ? null
            : accountById(snapshot, noticeId);
        Widget row(Account a) {
          final balance = a.balanceKrw;
          return SelectionListRow(
            key: ValueKey('account-${a.accountId}'),
            title: a.productName,
            subtitle: [
              '${institutionName(snapshot, a.institutionCode)} '
                  '····${a.maskedNumber.substring(a.maskedNumber.length - 4)}',
              if (controller.reservesOf(a.accountId).isNotEmpty) '모아둘 돈 있음',
            ].join(' · '),
            trailing: Text(
              balance == null ? '잔액 미확인' : formatKrw(balance),
              style: PayseTypography.ledgerAmount.copyWith(
                color: balance == null ? PayseColors.textSecondary : null,
              ),
            ),
            trailingLabel: balance == null ? '잔액 미확인' : spokenKrw(balance),
            selected: controller.isAccountSelected(a.accountId),
            onChanged: saving
                ? null
                : (_) => controller.toggleAccount(a.accountId),
          );
        }

        return PopScope(
          canPop: !saving,
          child: ConnectionPage(
            onBack: saving ? null : onBack,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ConnectionHeading(
                  '쓸 수 있는 돈을 계산할\n계좌를 골라주세요',
                  subtitle: "고른 계좌의 잔액과 거래로 계산해요. 나중에 '내 정보'에서 바꿀 수 있어요.",
                ),
                if (save is SaveFailed) ...[
                  const SizedBox(height: PayseSpace.x4),
                  _saveFailureNotice(save.failure, '계좌 선택', controller),
                ] else if (noticeAccount != null) ...[
                  const SizedBox(height: PayseSpace.x4),
                  StatusNotice(
                    key: const ValueKey('reserve-notice'),
                    kind: StatusNoticeKind.warning,
                    title: '모아둘 돈이 있는 계좌예요',
                    message:
                        '${accountLabel(snapshot, noticeAccount)}을 빼면 이 계좌의 모아둘 돈'
                        '(${controller.reservesOf(noticeAccount.accountId).map((r) => r.label).join(', ')})도 '
                        '계산에서 빠져요.',
                  ),
                ],
                Expanded(
                  child: _paddedList([
                    if (demand.isNotEmpty) ...[
                      const ConnectionSection('입출금'),
                      ...demand.map(row),
                    ],
                    if (others.isNotEmpty) ...[
                      const ConnectionSection('예금·적금'),
                      ...others.map(row),
                    ],
                    const SizedBox(height: PayseSpace.x6),
                    ?devEntry,
                  ]),
                ),
              ],
            ),
            bottomNotice: controller.canSaveSelection
                ? null
                : const StatusNotice.attached(
                    kind: StatusNoticeKind.warning,
                    title: '계좌를 1개 이상 골라주세요.',
                  ),
            bottom: switch (save) {
              SaveInProgress() => const PrimaryButton(
                label: '저장하고 있어요',
                onPressed: null,
              ),
              SaveFailed(failure: ConnectionSaveFailure.outdated) =>
                _reloadButton(controller),
              SaveFailed(failure: ConnectionSaveFailure.retryable) =>
                PrimaryButton(
                  label: '다시 시도',
                  onPressed: controller.canSaveSelection ? _save : null,
                ),
              _ => PrimaryButton(
                label: '이 계좌로 계산하기',
                onPressed: controller.canSaveSelection ? _save : null,
              ),
            },
          ),
        );
      },
    );
  }
}

/// 2026-10-22: 01-2 불러온 정보 확인. 저장 응답 Snapshot의 값을 형식만 바꿔 보이며 계산하지 않는다.
/// 수정 진입(03-7·03-8)은 #29에서 연결한다.
/// 2026-10-23: 시안 F·G. 일부만 연결해도 오류로 보이지 않고 연결 범위만 중립적으로 알린다. 미연결 계좌는 해당 줄의
/// '연결 안 함' 라벨로, 모아둘 돈·예정 지출은 정상적으로 없음과 연결하지 않아 볼 수 없음을 다른 문장으로 보인다.
class ConnectionReviewScreen extends StatelessWidget {
  /// 2026-10-22: 최신 Snapshot [snapshot], 뒤로 [onBack], 확인 [onConfirmed]로 만든다.
  const ConnectionReviewScreen({
    super.key,
    required this.snapshot,
    required this.onBack,
    required this.onConfirmed,
  });

  final FinancialSnapshot snapshot;
  final VoidCallback onBack;
  final VoidCallback onConfirmed;

  /// 2026-10-22: 계좌 [accountId]의 이름을 반환한다. 응답에 없으면 "계좌 정보 없음"이다.
  String _account(String accountId) {
    final a = accountById(snapshot, accountId);
    return a == null ? '계좌 정보 없음' : accountLabel(snapshot, a);
  }

  /// 2026-10-22: 월급·카드 결제일·모아둘 돈·예정 지출 묶음과 확인 버튼을 반환한다.
  /// 2026-10-23: 일부 금융사만 연결했으면 제목 아래에 연결 범위 보조 설명을 더한다. 경고 띠는 쓰지 않는다.
  @override
  Widget build(BuildContext context) {
    final basis = snapshot.asOf.substring(0, 10);
    final salary = snapshot.settings?.salary;
    final cards = snapshot.cards ?? const <PaymentCard>[];
    final reserves = activeReserves(snapshot);
    final obligations = activeObligations(snapshot);
    final partial =
        snapshot.institutionLinkCount < snapshot.institutions.length;
    return ConnectionPage(
      onBack: onBack,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ConnectionHeading(
            '불러온 정보를\n확인해주세요',
            subtitle: '선택한 금융사의 정보를 불러왔어요.',
          ),
          if (partial)
            const Padding(
              key: ValueKey('review-scope-note'),
              padding: EdgeInsets.fromLTRB(
                PayseSpace.screenHorizontal,
                2,
                PayseSpace.screenHorizontal,
                0,
              ),
              child: Text(
                '연결하지 않은 금융사의 정보는 포함되지 않았어요.',
                style: PayseTypography.caption,
              ),
            ),
          Expanded(
            child: _paddedList([
              const _ReviewSection('월급'),
              if (salary == null)
                const _ReviewRow(name: '월급 정보 없음', muted: true)
              else
                _ReviewRow(
                  key: const ValueKey('review-salary'),
                  name: salary.salaryDay == null
                      ? '월급일 미입력'
                      : '매월 ${salary.salaryDay}일',
                  detail: salary.salaryAccountRestricted
                      ? '급여 계좌'
                      : salary.salaryAccountId == null
                      ? '급여 계좌 미선택'
                      : '${_account(salary.salaryAccountId!)}로 입금',
                  unlinked: salary.salaryAccountRestricted,
                  value: salary.salaryAmountKrw == null
                      ? const _ReviewValue.status('금액 미입력')
                      : _ReviewValue.amount(formatKrw(salary.salaryAmountKrw!)),
                ),
              if (cards.isNotEmpty) ...[
                const _ReviewSection('카드 결제일'),
                for (final c in cards)
                  _ReviewRow(
                    key: ValueKey('review-card-${c.cardId}'),
                    name: institutionName(snapshot, c.institutionCode),
                    detail: c.withdrawalAccountRestricted
                        ? '출금 계좌'
                        : c.withdrawalAccountId == null
                        ? '출금 계좌 확인 안 됨'
                        : '${_account(c.withdrawalAccountId!)}에서 출금',
                    unlinked: c.withdrawalAccountRestricted,
                    value: switch (cardPaymentDay(snapshot, c)) {
                      PlannedPaymentDay(:final day) => _ReviewValue.text(
                        '매월 $day일',
                      ),
                      NextConfirmedDue(:final date) => _ReviewValue.text(
                        '다음 결제 ${formatBusinessDate(date, basis)}',
                      ),
                      NoUpcomingDue() => const _ReviewValue.status(
                        '예정된 결제일 정보 없음',
                      ),
                    },
                  ),
              ],
              const _ReviewSection('모아둘 돈'),
              ..._group(
                kind: '모아둘 돈',
                restricted: snapshot.reservesRestricted,
                rows: [
                  for (final r in reserves)
                    _ReviewRow(
                      key: ValueKey('review-reserve-${r.reserveId}'),
                      name: r.label,
                      detail: _account(r.accountId),
                      value: _ReviewValue.amount(formatKrw(r.amountKrw)),
                    ),
                ],
              ),
              const _ReviewSection('예정 지출'),
              ..._group(
                kind: '예정 지출',
                restricted: snapshot.obligationsRestricted,
                rows: [
                  for (final o in obligations)
                    _ReviewRow(
                      key: ValueKey('review-obligation-${o.obligationId}'),
                      name: o.label,
                      detail:
                          '${formatBusinessDate(o.dueDate, basis)} · ${_account(o.withdrawalAccountId)}',
                      value: _ReviewValue.amount(formatKrw(o.amountKrw)),
                    ),
                ],
              ),
              const SizedBox(height: PayseSpace.x6),
            ]),
          ),
        ],
      ),
      bottom: PrimaryButton(label: '확인했어요', onPressed: onConfirmed),
    );
  }

  /// 2026-10-23: 모아둘 돈·예정 지출 묶음 [kind]의 줄 [rows]를 반환한다. 연결 제한 여부 [restricted]에 따라
  /// 정상적으로 없음 / 연결하지 않아 하나도 볼 수 없음 / 일부만 보임을 다른 문장으로 보인다.
  static List<Widget> _group({
    required String kind,
    required bool restricted,
    required List<Widget> rows,
  }) {
    if (rows.isEmpty) {
      return [
        _ReviewRow(
          name: restricted ? '연결한 계좌에서 확인되는 $kind이 없어요.' : '등록된 $kind이 없어요.',
          muted: true,
        ),
      ];
    }
    return [
      ...rows,
      if (restricted) const _RestrictedNote('연결한 계좌 기준으로 보여드려요.'),
    ];
  }
}

/// 2026-10-23: 01-2 줄의 오른쪽 값. 실제 금액만 16/700으로 강조하고 날짜는 15/500, 상태 문구(미입력·정보 없음)는 15/500 보조색이다.
class _ReviewValue {
  /// 2026-10-23: 실제 금액 [text]로 만든다.
  const _ReviewValue.amount(this.text) : kind = _ReviewValueKind.amount;

  /// 2026-10-23: 날짜 같은 일반 값 [text]로 만든다.
  const _ReviewValue.text(this.text) : kind = _ReviewValueKind.text;

  /// 2026-10-23: '금액 미입력' 같은 상태 문구 [text]로 만든다.
  const _ReviewValue.status(this.text) : kind = _ReviewValueKind.status;

  final String text;
  final _ReviewValueKind kind;

  /// 2026-10-23: 종류에 맞는 글자 모양을 반환한다.
  TextStyle get style => switch (kind) {
    _ReviewValueKind.amount => PayseTypography.ledgerAmount.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w700,
    ),
    _ReviewValueKind.text => PayseTypography.ledgerName,
    _ReviewValueKind.status => PayseTypography.ledgerName.copyWith(
      color: PayseColors.textSecondary,
    ),
  };
}

/// 2026-10-22: 01-2 묶음 이름. 아래에 dividerSection 선을 긋는다.
/// 2026-10-23: 글자는 연결 화면 섹션 제목 토큰(14/600)을 쓴다.
class _ReviewSection extends StatelessWidget {
  /// 2026-10-22: 묶음 이름 [title]로 만든다.
  const _ReviewSection(this.title);

  final String title;

  /// 2026-10-22: 이름과 아래 선을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: PayseSpace.x5),
      padding: const EdgeInsets.only(bottom: PayseSpace.x2),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerSection)),
      ),
      child: Semantics(
        header: true,
        child: Text(title, style: PayseTypography.sectionTitle),
      ),
    );
  }
}

/// 2026-10-23: 01-2 값 종류.
enum _ReviewValueKind { amount, text, status }

/// 2026-10-22: 01-2 한 줄. 이름·보조 설명 … 값. [muted]면 이름을 보조 색으로 보인다(정보 없음 문장).
/// 2026-10-23: 값은 줄 폭의 60%를 넘으면 한 줄 그대로 비율 축소해 잘리지 않는다(장부 규칙과 같음).
/// [unlinked]면 보조 설명 뒤에 '연결 안 함' 라벨을 붙인다.
class _ReviewRow extends StatelessWidget {
  /// 2026-10-22: 이름 [name], 보조 설명 [detail], 값 [value]로 만든다.
  const _ReviewRow({
    super.key,
    required this.name,
    this.detail,
    this.value,
    this.muted = false,
    this.unlinked = false,
  });

  final String name;
  final String? detail;
  final _ReviewValue? value;
  final bool muted;
  final bool unlinked;

  static const double valueMaxWidthFactor = 0.6;

  /// 2026-10-22: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final v = value;
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: PayseTypography.ledgerName.copyWith(
                        color: muted ? PayseColors.textSecondary : null,
                        fontWeight: muted ? FontWeight.w400 : null,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: PayseSpace.x1),
                      Wrap(
                        spacing: 6,
                        runSpacing: PayseSpace.x1,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(detail!, style: PayseTypography.caption),
                          if (unlinked) const _StatusLabel('연결 안 함'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (v != null) ...[
                const SizedBox(width: PayseSpace.x3),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * valueMaxWidthFactor,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      v.text,
                      key: ValueKey('review-value-${v.kind.name}'),
                      maxLines: 1,
                      softWrap: false,
                      style: v.style,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-23: 중립 상태 라벨(design.md §5). 회색 바탕·테두리 없음·13/500. 누를 수 없고 오류·경고 색을 쓰지 않는다.
class _StatusLabel extends StatelessWidget {
  /// 2026-10-23: 라벨 글자 [text]로 만든다.
  const _StatusLabel(this.text);

  final String text;

  /// 2026-10-23: 라벨을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('status-label'),
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Text(
        text,
        style: PayseTypography.caption.copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// 2026-10-22: 연결 제한으로 일부가 숨겨졌음을 알리는 보조 문장. 숨긴 개수·금액은 쓰지 않는다.
class _RestrictedNote extends StatelessWidget {
  /// 2026-10-22: 문장 [text]로 만든다.
  const _RestrictedNote(this.text);

  final String text;

  /// 2026-10-22: 보조 문장을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x2),
      child: Text(text, style: PayseTypography.caption),
    );
  }
}
