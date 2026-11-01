import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'accounts_screen.dart';
import 'calculation_detail_screen.dart';
import 'home_calculation.dart';
import 'home_screen.dart' show asOfLabel;
import 'overview_links.dart';
import 'period_flow.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';
import 'transaction_sheets.dart';
import 'transactions_screen.dart';

/// 2026-10-31: 계좌 이름(별명이 있으면 별명, 없으면 상품명).
String accountTitle(Account account) => account.nickname ?? account.productName;

/// 2026-10-31: 계좌의 '기관명 ····끝 4자리'.
String accountTail(FinancialSnapshot snapshot, Account account) =>
    '${institutionName(snapshot, account.institutionCode)} '
    '····${lastFour(account.maskedNumber)}';

/// 2026-10-31: 대상 [instrument]의 이름. 찾지 못하면 null이다.
String? instrumentTitle(FinancialSnapshot snapshot, Instrument instrument) =>
    switch (instrument) {
      AccountInstrument(:final accountId) => switch (accountById(
        snapshot,
        accountId,
      )) {
        final a? => accountTitle(a),
        null => null,
      },
      CardInstrument(:final cardId) => cardById(snapshot, cardId)?.productName,
    };

/// 2026-10-31: '바꾸기'·'계좌·카드별 보기'에서 고를 수 있는 대상. [scope]가 이번 기간이면 그 조회 대상(계산 포함 계좌와 그
/// 계좌에서 대금이 나가는 카드), 아니면 연결한 계좌·카드 전체다.
List<Instrument> instrumentChoices(
  FinancialSnapshot snapshot,
  InstrumentScope scope,
) {
  if (scope == InstrumentScope.period) {
    final flow = FlowScope.of(snapshot);
    return [
      for (final a in flow.accounts) AccountInstrument(a.accountId),
      for (final c in flow.cards) CardInstrument(c.cardId),
    ];
  }
  return [
    for (final a in snapshot.accounts ?? const <Account>[])
      AccountInstrument(a.accountId),
    for (final c in snapshot.cards ?? const <PaymentCard>[])
      CardInstrument(c.cardId),
  ];
}

/// 2026-10-31: 대상 [instrument]의 보조 줄. 계좌는 '기관명 ····끝 4자리', 카드는 '····끝 4자리 · 출금 계좌 이름'이다.
String instrumentCaption(FinancialSnapshot snapshot, Instrument instrument) {
  switch (instrument) {
    case AccountInstrument(:final accountId):
      final a = accountById(snapshot, accountId);
      return a == null ? '' : accountTail(snapshot, a);
    case CardInstrument(:final cardId):
      final c = cardById(snapshot, cardId);
      if (c == null) return '';
      final withdrawal = c.withdrawalAccountId == null
          ? null
          : accountById(snapshot, c.withdrawalAccountId!);
      return [
        '카드 ····${lastFour(c.maskedNumber)}',
        if (withdrawal != null) '출금 계좌 ${accountTail(snapshot, withdrawal)}',
      ].join(' · ');
  }
}

/// 2026-10-31: 계좌·카드를 고르는 시트를 열고 고른 대상을 반환한다. [current]는 지금 보는 대상이며 표시만 한다.
Future<Instrument?> pickInstrument(
  BuildContext context,
  FinancialSnapshot snapshot,
  InstrumentScope scope, {
  Instrument? current,
}) {
  final choices = instrumentChoices(snapshot, scope);
  final accounts = choices.whereType<AccountInstrument>().toList();
  final cards = choices.whereType<CardInstrument>().toList();
  Widget row(Instrument i) => ChoiceRow(
    key: ValueKey('instrument-choice-${i.id}'),
    title: instrumentTitle(snapshot, i) ?? '',
    caption: instrumentCaption(snapshot, i),
    selected: i == current,
    onTap: () => Navigator.of(context).pop(i),
  );
  return showPayseSheet<Instrument>(
    context,
    InfoSheet(
      title: '계좌·카드별 보기',
      children: [
        if (accounts.isNotEmpty) ...[
          GroupCaption('계좌 ${accounts.length}개'),
          for (final i in accounts) row(i),
        ],
        if (cards.isNotEmpty) ...[
          GroupCaption('카드 ${cards.length}개'),
          for (final i in cards) row(i),
        ],
      ],
    ),
  );
}

/// 2026-10-31: 계산 내역을 [section]을 펼친 채 연다. 지금 계산이 계산을 마친 결과가 아니면 열지 않는다.
void openCalculation(
  BuildContext context,
  OverviewLinks links, {
  CalcSection? section,
}) {
  final calculation = links.state.value.calculation;
  if (calculation is! HomeCalculationReady) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CalculationDetailScreen(
        calculation: calculation,
        links: links,
        section: section,
      ),
    ),
  );
}

/// 2026-10-31: 계좌·카드별 조회 [instrument]를 연다. '바꾸기'는 [scope] 안에서 고른다. [period]는 들어온 화면의 조회 기간이며
/// 없으면 이번 달이다(계좌 관리·계산 내역).
void openInstrument(
  BuildContext context,
  OverviewLinks links,
  Instrument instrument, {
  InstrumentScope scope = InstrumentScope.connected,
  PeriodSelection? period,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => InstrumentPage(
        links: links,
        instrument: instrument,
        scope: scope,
        period: period,
      ),
    ),
  );
}

/// 2026-10-31: 계산에 포함할 계좌 바꾸기(01-1 재사용)를 열고, 저장되면 응답 Snapshot을 앱에 반영한다. 저장 연결이 없으면
/// 아무것도 하지 않는다.
Future<void> changeSelection(BuildContext context, OverviewLinks links) async {
  final w = links.writer;
  if (w == null) return;
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  final next = await Navigator.of(context).push<FinancialSnapshot>(
    MaterialPageRoute(
      builder: (_) => AccountSelectionPage(snapshot: links.snapshot, writer: w),
    ),
  );
  if (next != null) w.onSnapshot(next);
}

/// 2026-10-31: 계좌·카드별 조회 화면(#163). 계좌는 이름·기관·끝 번호·현재 잔액·기준 시각·계산 포함 여부와 그 계좌의 입출금,
/// 카드는 그 카드의 사용·환불·취소 기록이다. 위 '바꾸기'로 같은 화면 안에서 대상을 바꾸며(조회 조건이고 계산 포함 계좌를
/// 바꾸지 않음) 뒤로 가면 처음 들어온 화면으로 돌아간다. 조회 조건은 들어온 화면과 따로이며 대상마다 이번 달부터 시작한다.
class InstrumentPage extends StatefulWidget {
  /// 2026-10-31: 공통 연결 [links], 처음 대상 [instrument], 바꾸기 범위 [scope]로 만든다.
  /// 2026-10-31: 처음 기간 [period](없으면 이번 달)를 더했다. 바꾸기 뒤에는 지금 보고 있는 기간을 유지한다(#163 후속).
  const InstrumentPage({
    required this.links,
    required this.instrument,
    this.scope = InstrumentScope.connected,
    this.period,
    super.key,
  });

  final OverviewLinks links;
  final Instrument instrument;
  final InstrumentScope scope;
  final PeriodSelection? period;

  /// 2026-10-31: 상태 객체를 반환한다.
  @override
  State<InstrumentPage> createState() => _InstrumentPageState();
}

/// 2026-10-31: 지금 보는 대상과 기간을 가진다. 기간은 대상을 바꿔도 이어지고, 들어온 화면의 조건은 바꾸지 않는다.
class _InstrumentPageState extends State<InstrumentPage> {
  late Instrument _instrument = widget.instrument;
  late PeriodSelection _period = widget.period ?? PeriodSelection.thisMonth;

  /// 2026-10-31: 바꾸기 시트를 열고 고른 대상으로 바꾼다.
  Future<void> _switch(FinancialSnapshot snapshot) async {
    final picked = await pickInstrument(
      context,
      snapshot,
      widget.scope,
      current: _instrument,
    );
    if (picked != null && mounted) setState(() => _instrument = picked);
  }

  /// 2026-10-31: 화면을 반환한다. 앱 상태가 바뀌면(새로고침·저장) 그 Snapshot으로 다시 그린다.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OverviewState>(
      valueListenable: widget.links.state,
      builder: (context, state, _) {
        final snapshot = state.calculation.snapshot;
        final w = widget.links.writer;
        final instrument = _instrument;
        final account = instrument is AccountInstrument
            ? accountById(snapshot, instrument.accountId)
            : null;
        final card = instrument is CardInstrument
            ? cardById(snapshot, instrument.cardId)
            : null;
        final title = instrumentTitle(snapshot, instrument);
        return Scaffold(
          backgroundColor: PayseColors.background,
          appBar: AppBar(
            backgroundColor: PayseColors.background,
            surfaceTintColor: PayseColors.background,
            foregroundColor: PayseColors.textPrimary,
            centerTitle: false,
            titleSpacing: 0,
            toolbarHeight: 80,
            title: Padding(
              padding: const EdgeInsets.only(top: PayseSpace.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title ?? '연결 정보를 찾을 수 없어요',
                    key: const ValueKey('account-tx-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.45,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (title != null)
                    Text(
                      account != null
                          ? accountTail(snapshot, account)
                          : '····${lastFour(card!.maskedNumber)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PayseTypography.caption,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('instrument-switch'),
                onPressed: () => _switch(snapshot),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, PayseSize.touchMin),
                  foregroundColor: PayseColors.textPrimary,
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('바꾸기'), Icon(Icons.expand_more, size: 18)],
                ),
              ),
              const SizedBox(width: PayseSpace.x2),
            ],
          ),
          body: title == null
              ? const SizedBox.shrink()
              : TransactionsScreen(
                  key: ValueKey('instrument-${instrument.id}'),
                  snapshot: snapshot,
                  repository: w?.repository,
                  onSessionInvalid: w?.onSessionInvalid,
                  accountId: account?.accountId,
                  cardId: card?.cardId,
                  header: account != null
                      ? _AccountHeader(snapshot: snapshot, account: account)
                      : _CardHeader(snapshot: snapshot, card: card!),
                  history: state.history,
                  onRefresh: widget.links.onRefresh,
                  initialPeriod: _period,
                  inheritedPeriod: widget.period?.kind == PeriodKind.cycle
                      ? widget.period
                      : null,
                  onPeriodChanged: (p) => _period = p,
                ),
        );
      },
    );
  }
}

/// 2026-10-31: 계좌별 조회의 머리. 현재 잔액(원천 값, 없으면 '잔액 미확인')·기준 시각·계산 포함 여부·'입출금 내역' 제목.
class _AccountHeader extends StatelessWidget {
  /// 2026-10-31: [snapshot]의 계좌 [account]로 만든다.
  const _AccountHeader({required this.snapshot, required this.account});

  final FinancialSnapshot snapshot;
  final Account account;

  /// 2026-10-31: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    final balance = account.balanceKrw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          balance == null
              ? const Text(
                  '잔액 미확인',
                  key: ValueKey('instrument-balance'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: PayseColors.textSecondary,
                  ),
                )
              : Text.rich(
                  key: const ValueKey('instrument-balance'),
                  semanticsLabel: spokenKrw(balance),
                  TextSpan(
                    text: formatKrwDigits(balance),
                    children: const [
                      TextSpan(
                        text: '원',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(
                    fontSize: 30,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.9,
                    color: PayseColors.textPrimary,
                    fontFeatures: PayseTypography.tabular,
                  ),
                ),
          const SizedBox(height: PayseSpace.x1),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: PayseSpace.x3,
              runSpacing: PayseSpace.x1,
              children: [
                Text(asOfLabel(snapshot.asOf), style: PayseTypography.caption),
                Row(
                  key: const ValueKey('instrument-included'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        account.included ? Icons.check : Icons.remove,
                        size: 18,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: PayseSpace.x1),
                    Text(
                      account.included ? '계산에 포함' : '계산에 포함하지 않음',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: PayseSpace.x4),
          const Divider(height: 1, color: PayseColors.dividerSection),
          const SizedBox(height: PayseSpace.x4),
          const Text('입출금 내역', style: _historyTitle),
        ],
      ),
    );
  }
}

/// 2026-10-31: 카드별 조회의 머리. 출금 계좌(확인될 때만)와 '카드 사용·환불' 제목. 카드 사용액을 잔액으로 보이지 않는다.
class _CardHeader extends StatelessWidget {
  /// 2026-10-31: [snapshot]의 카드 [card]로 만든다.
  const _CardHeader({required this.snapshot, required this.card});

  final FinancialSnapshot snapshot;
  final PaymentCard card;

  /// 2026-10-31: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    final id = card.withdrawalAccountId;
    final withdrawal = id == null ? null : accountById(snapshot, id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            withdrawal == null
                ? '출금 계좌 미확인'
                : '출금 계좌 ${accountTitle(withdrawal)} '
                      '${accountTail(snapshot, withdrawal)}',
            key: const ValueKey('instrument-withdrawal'),
            style: PayseTypography.caption.copyWith(
              color: PayseColors.textPrimary,
            ),
          ),
          const SizedBox(height: PayseSpace.x4),
          const Divider(height: 1, color: PayseColors.dividerSection),
          const SizedBox(height: PayseSpace.x4),
          const Text('카드 사용·환불', style: _historyTitle),
        ],
      ),
    );
  }
}

const TextStyle _historyTitle = TextStyle(
  fontSize: 16,
  height: 24 / 16,
  fontWeight: FontWeight.w700,
  color: PayseColors.textPrimary,
);

/// 2026-10-31: 시트 안 묶음 머리('계좌 4개' 13/600 textSecondary, 위 16dp). [note]가 있으면 같은 줄 뒤에 보조 설명.
class GroupCaption extends StatelessWidget {
  /// 2026-10-31: 머리 [text]와 보조 설명 [note]로 만든다.
  const GroupCaption(this.text, {this.note, super.key});

  final String text;
  final String? note;

  /// 2026-10-31: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x4, bottom: 2),
      child: Text.rich(
        TextSpan(
          text: text,
          children: [
            if (note != null)
              TextSpan(
                text: ' · $note',
                style: const TextStyle(fontWeight: FontWeight.w400),
              ),
          ],
        ),
        style: const TextStyle(
          fontSize: 13,
          height: 19 / 13,
          fontWeight: FontWeight.w600,
          color: PayseColors.textSecondary,
        ),
      ),
    );
  }
}

/// 2026-10-31: 보기 전용 목록 시트 틀(손잡이·제목·닫기 → 스크롤 본문 → 고정 [footer]).
class InfoSheet extends StatelessWidget {
  /// 2026-10-31: 제목 [title], 본문 [children], 아래 고정 영역 [footer]로 만든다.
  const InfoSheet({
    required this.title,
    required this.children,
    this.footer,
    super.key,
  });

  final String title;
  final List<Widget> children;
  final Widget? footer;

  /// 2026-10-31: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: PayseSpace.x2),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: PayseColors.dividerSection,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            PayseSpace.x2,
            PayseSpace.x2,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 22),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              0,
              PayseSpace.screenHorizontal,
              footer == null ? 34 : PayseSpace.x3,
            ),
            children: children,
          ),
        ),
        if (footer case final footer?) ...[
          const Divider(height: 1, color: PayseColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x3,
              PayseSpace.screenHorizontal,
              PayseSpace.x6,
            ),
            child: footer,
          ),
        ],
      ],
    );
  }
}

/// 2026-10-31: 시트 안의 누를 수 있는 한 줄(이름·보조 줄 … '›', 최소 64dp). [selected]면 '보는 중' 라벨을 붙인다.
class ChoiceRow extends StatelessWidget {
  /// 2026-10-31: 이름 [title], 보조 줄 [caption], 지금 보는 대상 [selected], 누르기 [onTap](없으면 화살표 없음)으로 만든다.
  const ChoiceRow({
    required this.title,
    required this.caption,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final String title;
  final String caption;
  final bool selected;
  final VoidCallback? onTap;

  /// 2026-10-31: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: title,
                      children: [
                        if (selected)
                          const WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: TxLabel('보는 중'),
                            ),
                          ),
                      ],
                    ),
                    style: const TextStyle(
                      fontSize: 15,
                      height: 22 / 15,
                      fontWeight: FontWeight.w600,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                  if (caption.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(caption, style: PayseTypography.caption),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: PayseColors.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-31: 근거 있는 내 계좌 이체 상세. 금액·보낸 계좌·받은 계좌·계산 계좌 잔액에 주는 방향과 원본 출금·입금 거래 보기.
class TransferDetailSheet extends StatelessWidget {
  /// 2026-10-31: [snapshot]의 이체 [transfer]로 만든다.
  const TransferDetailSheet({
    required this.snapshot,
    required this.transfer,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final FlowTransfer transfer;

  /// 2026-10-31: 원본 거래 [t]의 상세 시트를 연다.
  void _open(BuildContext context, SourceTransaction t) {
    showPayseSheet<void>(
      context,
      TransactionDetailSheet(snapshot: snapshot, transaction: t),
    );
  }

  /// 2026-10-31: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final from = transfer.from;
    final to = transfer.to;
    final effect = switch (transfer.effect) {
      TransferEffect.inside => ('변동 없음', '두 계좌가 모두 계산에 포함돼 있어요.'),
      TransferEffect.intoScope => (
        '+${formatKrw(from.amountKrw)}',
        '계산에서 제외한 계좌에서 들어온 돈이에요.',
      ),
      TransferEffect.outOfScope => (
        '−${formatKrw(from.amountKrw)}',
        '계산에서 제외한 계좌로 옮긴 돈이에요.',
      ),
    };
    Widget row(String label, String value) => Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: PayseTypography.caption),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 15, color: amountColor(value)),
            ),
          ),
        ],
      ),
    );
    return InfoSheet(
      title: '내 계좌 이체',
      children: [
        Text(
          formatKrw(from.amountKrw),
          key: const ValueKey('transfer-amount'),
          style: const TextStyle(
            fontSize: 28,
            height: 1.25,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.84,
            color: PayseColors.textPrimary,
            fontFeatures: PayseTypography.tabular,
          ),
        ),
        const SizedBox(height: PayseSpace.x4),
        const Divider(height: 1, color: PayseColors.dividerSection),
        row('보낸 계좌', meansLabel(snapshot, from) ?? '계좌 미확인'),
        row('받은 계좌', meansLabel(snapshot, to) ?? '계좌 미확인'),
        row('거래 일시', longDate(transfer.date)),
        row('계산 계좌 잔액', effect.$1),
        Padding(
          padding: const EdgeInsets.only(top: PayseSpace.x2),
          child: Text(effect.$2, style: PayseTypography.caption),
        ),
        const SizedBox(height: PayseSpace.x3),
        ChoiceRow(
          key: const ValueKey('transfer-open-out'),
          title: '출금 거래 보기',
          caption: from.merchantName,
          onTap: () => _open(context, from),
        ),
        ChoiceRow(
          key: const ValueKey('transfer-open-in'),
          title: '입금 거래 보기',
          caption: to.merchantName,
          onTap: () => _open(context, to),
        ),
      ],
    );
  }
}
