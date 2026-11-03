import 'package:flutter/material.dart';

import '../../data/connection/financial_api.dart';
import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_symbols.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'home_screen.dart' show asOfLabel;
import 'period_flow.dart' show transferPairs;
import 'pull_refresh.dart';
import 'tab_header.dart';
import 'transaction_feed.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';
import 'transaction_sheets.dart';

/// 2026-10-30: 02-4 거래 내역(apps/mobile/docs/accounts-transactions.md §4, 29-2 명세). 계좌 내역과 카드 기록을 한 목록에
/// 날짜 최신순으로 보이고, 기간·거래 수단·거래 종류는 각자의 선택 시트로 바꾼다. [accountId]가 있으면 그 계좌로 고정한
/// 계좌별 거래이며 거래 수단 대신 입출금만 고른다. 거래를 누르면 읽기 전용 상세 시트를 연다. 조회 조건은 이 화면 안에서만
/// 쓰고 홈 계산 포함 계좌를 바꾸지 않는다.
class TransactionsScreen extends StatefulWidget {
  /// 2026-10-30: 기준 [snapshot], 다음 페이지 조회 [repository](없으면 Snapshot 거래만), 세션 무효 [onSessionInvalid],
  /// 고정 계좌 [accountId]로 만든다.
  /// 2026-10-30: 아래로 당겨 새로고침 [onRefresh], 그 성공 뒤 처리 [onRefreshed], 새로고침으로 이미 받은 거래 전체
  /// [history](자료 버전이 [snapshot]과 같으면 다시 받지 않고 쓴다)를 더했다.
  /// 2026-10-31: 고정 카드 [cardId](사용·환불·취소 기록만), 목록 위 머리 [header], 전체 조회의 '계좌·카드별 보기'
  /// [onPickInstrument](없으면 두지 않음)를 더했다(#163).
  /// 2026-10-31: 처음 기간 [initialPeriod](없으면 이번 달), 기간 시트에 둘 물려받은 월급 주기 [inheritedPeriod], 기간을 바꿀
  /// 때 알림 [onPeriodChanged]를 더했다(#163 후속, 들어온 화면의 기간 유지).
  const TransactionsScreen({
    required this.snapshot,
    this.repository,
    this.onSessionInvalid,
    this.accountId,
    this.cardId,
    this.header,
    this.onPickInstrument,
    this.history,
    this.onRefresh,
    this.onRefreshed,
    this.feed,
    this.initialPeriod,
    this.inheritedPeriod,
    this.onPeriodChanged,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final UserFinancialRepository? repository;
  final VoidCallback? onSessionInvalid;
  final String? accountId;
  final String? cardId;
  final Widget? header;
  final VoidCallback? onPickInstrument;
  final TransactionHistoryReady? history;
  final PullRefresh? onRefresh;
  final ValueChanged<TransactionHistoryReady>? onRefreshed;

  /// 2026-10-31: 함께 쓰는 거래 수집 상태. 있으면 [snapshot]·[repository]·[history] 대신 이 상태를 따른다.
  final TransactionFeed? feed;
  final PeriodSelection? initialPeriod;
  final PeriodSelection? inheritedPeriod;
  final ValueChanged<PeriodSelection>? onPeriodChanged;

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

/// 2026-10-30: 조회 조건·수집 결과를 가진다. 새 Snapshot(자료 버전 변경)이 오면 다시 수집하고 조건은 유지한다.
/// 2026-10-31: 수집은 [TransactionFeed]가 맡는다. [TransactionsScreen.feed]가 있으면 그것을 함께 쓰고, 없으면 직접 만든다.
class _TransactionsScreenState extends State<TransactionsScreen> {
  late TransactionQuery _query = TransactionQuery(
    period: widget.initialPeriod ?? PeriodSelection.thisMonth,
    accountIds: widget.accountId != null
        ? {widget.accountId!}
        : widget.cardId != null
        ? const {}
        : null,
    cardIds: widget.accountId != null
        ? const {}
        : widget.cardId != null
        ? {widget.cardId!}
        : null,
  );
  final ScrollController _scroll = ScrollController();
  TransactionFeed? _own;

  TransactionFeed get _feed => widget.feed ?? (_own ??= _newFeed());

  /// 2026-10-31: 이 화면만 쓰는 수집 상태를 만든다.
  TransactionFeed _newFeed() => TransactionFeed(
    snapshot: widget.snapshot,
    repository: widget.repository,
    onSessionInvalid: widget.onSessionInvalid,
    history: widget.history,
  );

  /// 2026-10-31: 수집 상태가 바뀌면 다시 그린다.
  @override
  void initState() {
    super.initState();
    _feed.addListener(_changed);
  }

  /// 2026-10-31: 수집 상태 변경을 화면에 반영한다.
  void _changed() => setState(() {});

  /// 2026-10-30: 자료 버전이 바뀐 Snapshot이면 다시 수집한다. 새로고침으로 받은 거래가 새로 오면 그것을 쓴다.
  @override
  void didUpdateWidget(covariant TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed) {
      (oldWidget.feed ?? _own)?.removeListener(_changed);
      _feed.addListener(_changed);
    }
    if (widget.feed == null) _feed.update(widget.snapshot, widget.history);
  }

  /// 2026-10-30: 스크롤 컨트롤러와 직접 만든 수집 상태를 폐기한다.
  @override
  void dispose() {
    _feed.removeListener(_changed);
    _own?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  TxLoad get _load => _feed.load;
  bool get _stale => _feed.stale;
  List<SourceTransaction> get _all => _feed.all;
  List<Coverage> get _coverage => _feed.coverage;
  Future<void> _collect() => _feed.collect();

  FinancialSnapshot get _snap => _feed.snapshot;
  QueryBounds get _bounds => QueryBounds.of(_snap, _coverage);
  bool get _fixed => widget.accountId != null;
  bool get _fixedCard => widget.cardId != null;
  bool get _pinned => _fixed || _fixedCard;

  /// 2026-10-30: 조건을 [next]로 바꾸고 목록 맨 위로 간다.
  void _apply(TransactionQuery next) {
    if (next.period != _query.period) widget.onPeriodChanged?.call(next.period);
    setState(() => _query = next);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 2026-10-30: 기간 선택 시트를 연다.
  Future<void> _pickPeriod() async {
    final picked = await showPayseSheet<PeriodSelection>(
      context,
      PeriodSheet(
        bounds: _bounds,
        current: _query.period,
        inherited: widget.inheritedPeriod,
      ),
    );
    if (picked != null) _apply(_query.withPeriod(picked));
  }

  /// 2026-10-30: 거래 수단 선택 시트를 연다.
  Future<void> _pickMeans() async {
    final picked = await showPayseSheet<(Set<String>?, Set<String>?)>(
      context,
      MeansSheet(
        snapshot: _snap,
        accountIds: _query.accountIds,
        cardIds: _query.cardIds,
      ),
    );
    if (picked != null) _apply(_query.withMeans(picked.$1, picked.$2));
  }

  /// 2026-10-30: 거래 종류(계좌별 화면은 입출금) 선택 시트를 연다.
  Future<void> _pickType() async {
    final options = _fixed
        ? const <(TxType?, String)>[
            (null, '입출금 전체'),
            (TxType.accountIn, '입금'),
            (TxType.accountOut, '출금'),
          ]
        : <(TxType?, String)>[
            (null, '모든 내역'),
            for (final t in _query.availableTypes) (t, t.label),
          ];
    final picked = await showPayseSheet<({TxType? value})>(
      context,
      TypeSheet(
        title: _fixed ? '입출금 선택' : '거래 종류 선택',
        options: options,
        current: _query.type,
      ),
    );
    if (picked != null) _apply(_query.withType(picked.value));
  }

  /// 2026-10-30: 거래 [t]의 상세 시트를 연다. 원거래는 ID로 실제 확보했을 때만 넘긴다.
  /// 2026-11-01: 근거 있는 내 계좌 이체면 상대 거래도 넘겨 상세에서 상대 계좌를 보인다.
  void _open(SourceTransaction t) {
    final id = t.originalTransactionId;
    SourceTransaction? original;
    if (id != null) {
      for (final o in _all) {
        if (o.transactionId == id) original = o;
      }
    }
    SourceTransaction? peer;
    for (final (from, to) in transferPairs(
      _all,
      _snap.transactionRelations ?? const [],
    )) {
      if (from.transactionId == t.transactionId) peer = to;
      if (to.transactionId == t.transactionId) peer = from;
    }
    showPayseSheet<void>(
      context,
      TransactionDetailSheet(
        snapshot: _snap,
        transaction: t,
        original: original,
        peer: peer,
      ),
    );
  }

  /// 2026-10-30: 거래 수단 칩 문구.
  String _meansChip() {
    final accounts = _snap.accounts ?? const <Account>[];
    final cards = _snap.cards ?? const <PaymentCard>[];
    final a = _query.accountIds;
    final c = _query.cardIds;
    if (a == null && c == null) return '전체 거래 수단';
    final na = a?.length ?? accounts.length;
    final nc = c?.length ?? cards.length;
    if (na + nc == 1) {
      if (na == 1) {
        final id = a?.single ?? accounts.single.accountId;
        final acc = accountById(_snap, id);
        if (acc != null) {
          return '${institutionName(_snap, acc.institutionCode)} '
              '${acc.nickname ?? acc.productName} ····${lastFour(acc.maskedNumber)}';
        }
      } else {
        final card = cardById(_snap, c?.single ?? cards.single.cardId);
        if (card != null) {
          return '${card.productName} ····${lastFour(card.maskedNumber)}';
        }
      }
    }
    if (nc == 0) return a == null ? '계좌 전체' : '계좌 $na개';
    if (na == 0) return c == null ? '카드 전체' : '카드 $nc개';
    return '계좌 $na개 · 카드 $nc개';
  }

  /// 2026-10-30: 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final bounds = _bounds;
    final month = bounds.monthOf(_query.period);
    final list = _load == TxLoad.ready
        ? filterAndSort(_all, _query, bounds)
        : const <SourceTransaction>[];
    final missing = _missingNotice();
    return PullRefreshScrollView(
      scrollKey: const ValueKey('transactions-list'),
      controller: _scroll,
      onRefresh: widget.onRefresh,
      onDone: widget.onRefreshed,
      slivers: [
        if (!_pinned)
          const SliverToBoxAdapter(
            child: TabPurpose(
              key: ValueKey('tx-purpose'),
              icon: Icons.receipt_long_outlined,
              title: '모든 계좌·카드의 거래',
              description: '연결한 계좌·카드를 계산 포함 여부와 관계없이 보여줘요.',
            ),
          ),
        if (_stale)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('tx-band-stale'),
              title: '새로고침하지 못했어요',
              body: '이전 정보를 보여드려요.',
              onRetry: _collect,
            ),
          ),
        if (missing != null && _load == TxLoad.ready)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('tx-band-partial'),
              title: missing.$1,
              body: missing.$2,
            ),
          ),
        if (widget.header case final header?) SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: const EdgeInsets.symmetric(
            horizontal: PayseSpace.screenHorizontal,
          ),
          sliver: SliverList.list(
            children: [
              if (_pinned)
                Padding(
                  padding: const EdgeInsets.only(top: PayseSpace.x2),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: PayseSpace.x2,
                    children: [
                      _periodHeader(bounds, month, compact: true),
                      TxChip(
                        key: const ValueKey('chip-type'),
                        label: _typeChip(),
                        onTap: _pickType,
                      ),
                    ],
                  ),
                )
              else ...[
                const SizedBox(height: PayseSpace.x2),
                _periodHeader(bounds, month),
                _basis(),
                if (widget.onPickInstrument case final pick?) ...[
                  const SizedBox(height: PayseSpace.x1),
                  TabLinkRow(
                    key: const ValueKey('tx-pick-instrument'),
                    label: '계좌·카드별 보기',
                    trailing:
                        '계좌 ${_snap.accounts?.length ?? 0}개 · '
                        '카드 ${_snap.cards?.length ?? 0}개',
                    onTap: pick,
                  ),
                ],
                Wrap(
                  spacing: PayseSpace.x2,
                  runSpacing: PayseSpace.x2,
                  children: [
                    TxChip(
                      key: const ValueKey('chip-means'),
                      label: _meansChip(),
                      onTap: _pickMeans,
                    ),
                    TxChip(
                      key: const ValueKey('chip-type'),
                      label: _typeChip(),
                      onTap: _pickType,
                    ),
                  ],
                ),
              ],
              if (_pinned &&
                  (_load == TxLoad.loading || !_fixed || widget.header == null))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _basis(),
                ),
              ..._body(list),
              const SizedBox(height: PayseSpace.x6),
            ],
          ),
        ),
      ],
    );
  }

  /// 2026-11-01: 기준 시각 줄(불러오는 중이면 그 안내).
  Widget _basis() => Text(
    _load == TxLoad.loading ? '거래 내역을 불러오는 중이에요' : asOfLabel(_snap.asOf),
    key: const ValueKey('tx-basis'),
    style: PayseTypography.caption,
  );

  /// 2026-10-30: 거래 종류 칩 문구(계좌별은 입출금).
  String _typeChip() {
    final type = _query.type;
    if (_fixed) {
      return switch (type) {
        TxType.accountIn => '입금',
        TxType.accountOut => '출금',
        _ => '입출금 전체',
      };
    }
    return type?.label ?? '모든 내역';
  }

  /// 2026-10-30: 기간 머리. 달 단위면 '‹ 2026년 10월 ▾ ›'(가운데), 최근 기간이면 제목과 실제 범위(화살표 없음).
  /// 2026-10-31: [compact]면 계좌·카드별 조회용으로 왼쪽 정렬하고 거래 종류 칩과 한 줄에 둔다. 월급 주기는 제목이 곧 범위다.
  /// 2026-11-01: 전체 거래(20/700)는 '‹ 기간 ▾ ›' 묶음을 화면 가운데에, 계좌·카드별 조회(17/700)는 왼쪽에 두고
  /// (혜연 요청), 제목이 '‹'·'›' 사이 가운데에 오게 한다. '▾' 아이콘 글자 오른쪽에 약 4dp 빈 공간이 있어
  /// 오른쪽 여백을 그만큼 줄여 보이는 간격을 맞춘다(실기기 픽셀 측정).
  Widget _periodHeader(
    QueryBounds bounds,
    String? month, {
    bool compact = false,
  }) {
    final title = TextButton(
      key: const ValueKey('period-title'),
      onPressed: _pickPeriod,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, PayseSize.touchMin),
        padding: month == null
            ? const EdgeInsets.only(right: PayseSpace.x2)
            : const EdgeInsets.only(left: PayseSpace.x2, right: PayseSpace.x1),
        foregroundColor: PayseColors.textPrimary,
        textStyle: compact
            ? const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)
            : tabKeyStyle,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              bounds.title(_query.period),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 18),
        ],
      ),
    );
    if (month == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          if (_query.period.kind != PeriodKind.cycle)
            Text(
              bounds.rangeText(_query.period),
              key: const ValueKey('period-range'),
              style: PayseTypography.caption,
            ),
        ],
      );
    }
    final prev = bounds.shift(month, -1);
    final next = bounds.shift(month, 1);
    final prevButton = IconButton(
      key: const ValueKey('period-prev'),
      tooltip: '이전 달 보기',
      onPressed: prev == null ? null : () => _apply(_query.withPeriod(prev)),
      icon: const Icon(Icons.chevron_left),
    );
    final nextButton = IconButton(
      key: const ValueKey('period-next'),
      tooltip: '다음 달 보기',
      onPressed: next == null ? null : () => _apply(_query.withPeriod(next)),
      icon: const Icon(Icons.chevron_right),
    );
    final group = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        prevButton,
        Flexible(child: title),
        nextButton,
      ],
    );
    if (compact) return group;
    return Center(child: group);
  }

  /// 2026-10-30: 목록 본문(불러오는 중·조회 실패·없음·날짜별 목록).
  List<Widget> _body(List<SourceTransaction> list) {
    switch (_load) {
      case TxLoad.loading:
        return [const TxSkeleton()];
      case TxLoad.failed:
        return [
          TxEmpty(
            key: const ValueKey('tx-failed'),
            title: '거래 내역을 불러오지 못했어요',
            body: '잠시 후 다시 시도해 주세요.',
            actions: [('다시 시도', _collect)],
          ),
        ];
      case TxLoad.ready:
        break;
    }
    if (list.isEmpty) {
      final isDefaultFixed =
          _pinned &&
          _query.period == PeriodSelection.thisMonth &&
          _query.type == null;
      if (_query.isDefault || isDefaultFixed) {
        return [
          TxEmpty(
            key: const ValueKey('tx-empty-month'),
            title: '이번 달 거래 내역이 없어요',
            actions: [
              (
                '최근 1년 보기',
                () => _apply(
                  _query.withPeriod(const PeriodSelection(PeriodKind.recent1y)),
                ),
              ),
            ],
          ),
        ];
      }
      return [
        TxEmpty(
          key: const ValueKey('tx-no-result'),
          title: '선택한 조건의 거래 내역이 없어요',
          body: _fixed
              ? '기간이나 입출금 조건을 바꿔보세요.'
              : _fixedCard
              ? '기간이나 거래 종류를 바꿔보세요.'
              : '기간이나 거래 수단을 바꿔보세요.',
          actions: [
            ('기간 변경', _pickPeriod),
            if (_fixed)
              ('입출금 전체 보기', () => _apply(_query.withType(null)))
            else if (_fixedCard)
              ('모든 내역 보기', () => _apply(_query.withType(null)))
            else
              ('거래 수단 변경', _pickMeans),
          ],
        ),
      ];
    }
    final out = <Widget>[];
    String? day;
    for (final t in list) {
      final d = recordDate(t)!;
      if (d != day) {
        out.add(
          TxDayHeader(
            dayHeader(d),
            top: day == null ? PayseSpace.x2 : PayseSpace.x4,
          ),
        );
        day = d;
      }
      out.add(
        TxRow(
          key: ValueKey('tx-${t.transactionId}'),
          name: t.merchantName,
          subtitle: subtitle(_snap, t, withMeans: !_pinned),
          icon: kindIcon(t),
          amount: amountText(t),
          labels: [?statusLabel(t), ?reflectionLabel(t)],
          onTap: () => _open(t),
        ),
      );
    }
    return out;
  }

  /// 2026-10-30: 지금 조건에 걸리는 계좌·카드 중 일부만 조회된(partial·failed) 대상이 있으면 (제목, 설명)을 반환한다.
  /// 원인(보관 기간·조회 실패 등)을 단정하지 않는다. 다시 시도 여부는 A 확인 뒤 정한다.
  (String, String)? _missingNotice() {
    bool hit(Coverage c) {
      if (c.status != 'partial' && c.status != 'failed') return false;
      if (c.targetKind == 'account') {
        return _query.hasAccounts &&
            (_query.accountIds?.contains(c.targetId) ?? true) &&
            accountById(_snap, c.targetId) != null;
      }
      return _query.hasCards &&
          (_query.cardIds?.contains(c.targetId) ?? true) &&
          cardById(_snap, c.targetId) != null;
    }

    if (!_coverage.any(hit)) return null;
    return (
      '일부 거래 내역만 확인할 수 있어요',
      '금융사에서 일부 기간의 거래 내역을 받지 못했어요. 목록에 없는 거래가 있을 수 있어요.',
    );
  }
}

/// 2026-10-31: 거래 종류 문구 앞 선 아이콘(#163 후속). 내 계좌 이체 양방향, 입금 들어오는 화살표, 출금 나가는 화살표, 카드대금
/// 납부 납부, 카드 사용 카드, 카드 환불·승인 취소 되돌림. 색은 모두 보조 글자색이며 문구를 대신하지 않는다.
/// 2026-11-01: 화살표 모양을 맞추려고 Material Symbols Rounded 부분 글꼴([PayseSymbols])을 쓴다.
IconData kindIcon(SourceTransaction t) {
  if (isAccountEntry(t)) {
    return switch (t.payseTransactionType) {
      'internal_transfer' => transferIcon,
      'card_payment' => PayseSymbols.payments,
      _ =>
        t.direction == 'in' ? PayseSymbols.southWest : PayseSymbols.northEast,
    };
  }
  return t.recordKind == 'card_purchase'
      ? PayseSymbols.creditCard
      : PayseSymbols.undo;
}

/// 2026-11-01: 금액 글자색. '+'로 시작하는 금액(들어온 돈)만 amountIn, 그 밖(−·부호 없음)은 textPrimary다. 부호를 함께
/// 보여 색만으로 구분하지 않는다.
Color amountColor(String amount) =>
    amount.startsWith('+') ? PayseColors.amountIn : PayseColors.textPrimary;

/// 2026-10-31: 내 계좌 이체 아이콘(묶은 이체 행도 같다).
const IconData transferIcon = PayseSymbols.compareArrows;

/// 2026-10-30: 조건 칩(높이 36·반경 20·테두리 borderStrong, 터치 48).
class TxChip extends StatelessWidget {
  /// 2026-10-30: 문구 [label]과 누르기 [onTap]으로 만든다.
  const TxChip({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  /// 2026-10-30: 칩을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: PayseSize.touchMin),
      child: Center(
        widthFactor: 1,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.only(left: 14, right: 10),
            foregroundColor: PayseColors.textPrimary,
            side: const BorderSide(color: PayseColors.borderStrong),
            shape: const StadiumBorder(),
            tapTargetSize: MaterialTapTargetSize.padded,
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-30: 날짜 머리('10월 17일 토요일', 아래 진한 선).
class TxDayHeader extends StatelessWidget {
  /// 2026-10-30: 문구 [text]로 만든다.
  /// 2026-11-01: 위 여백 [top](목록 첫 날짜는 조건 줄에 붙도록 8dp, 그 밖 16dp)을 더했다.
  const TxDayHeader(this.text, {this.top = PayseSpace.x4, super.key});

  final String text;
  final double top;

  /// 2026-10-30: 날짜 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(top: top),
      constraints: const BoxConstraints(minHeight: 36),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerSection)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: PayseColors.textSecondary,
        ),
      ),
    );
  }
}

/// 2026-10-30: 거래 한 줄. 첫 줄 거래명(말줄임)·상태 라벨 … 금액(줄바꿈 없음), 둘째 줄 거래 종류·거래 수단. 위아래 16dp,
/// 최소 76dp, 아래 연한 선. 누르면 상세 시트.
class TxRow extends StatelessWidget {
  /// 2026-10-30: 거래명 [name], 둘째 줄 [subtitle], 금액 [amount], 상태 라벨 [labels], 누르기 [onTap]으로 만든다.
  const TxRow({
    required this.name,
    required this.subtitle,
    this.icon,
    required this.amount,
    required this.labels,
    required this.onTap,
    super.key,
  });

  final String name;
  final String subtitle;

  /// 2026-10-31: 행 왼쪽 24dp 칸의 20dp 선 아이콘(textSecondary, 배경 없음, 읽기 제외). 거래 종류 문구는 둘째 줄에 그대로
  /// 둔다. 없으면 아이콘 칸 없이 그린다.
  final IconData? icon;
  final String amount;
  final List<String> labels;
  final VoidCallback onTap;

  /// 2026-10-30: 라벨 옆에 남겨 둘 거래명 최소 폭. 이보다 좁아지면(좁은 화면·큰 글씨) 라벨을 거래명 아래 줄로 내린다.
  static const double _minNameWidth = 56;

  /// 2026-10-30: 라벨들이 한 줄에서 차지하는 폭(앞 간격 포함).
  double _labelsWidth(BuildContext context) {
    var width = 0.0;
    for (final l in labels) {
      final painter = TextPainter(
        text: TextSpan(text: l, style: TxLabel.style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      width += painter.width + PayseSpace.x2 * 3;
      painter.dispose();
    }
    return width;
  }

  /// 2026-10-30: 거래 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.symmetric(vertical: PayseSpace.x4),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
        ),
        child: Row(
          children: [
            if (icon case final icon?) ...[
              ExcludeSemantics(
                child: SizedBox(
                  width: 24,
                  child: Icon(
                    icon,
                    key: const ValueKey('tx-kind-icon'),
                    size: 20,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: PayseSpace.x3),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, c) {
                      final title = Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 22 / 15,
                          fontWeight: FontWeight.w600,
                          color: PayseColors.textPrimary,
                        ),
                      );
                      if (labels.isEmpty) return title;
                      final inline =
                          c.maxWidth - _labelsWidth(context) >= _minNameWidth;
                      final tags = [
                        for (final (i, l) in labels.indexed) ...[
                          if (i > 0 || inline)
                            const SizedBox(width: PayseSpace.x2),
                          TxLabel(l),
                        ],
                      ];
                      if (inline) {
                        return Row(
                          children: [
                            Flexible(child: title),
                            ...tags,
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 4),
                          Wrap(runSpacing: 4, children: tags),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PayseTypography.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: PayseSpace.x4),
            Text(
              amount,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: amountColor(amount),
                fontFeatures: PayseTypography.tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-30: 상태 라벨(surfaceMuted, 높이 22·좌우 8·반경 8, 13/500 textSecondary, 글자 폭만큼).
class TxLabel extends StatelessWidget {
  /// 2026-10-30: 문구 [text]로 만든다.
  const TxLabel(this.text, {super.key});

  final String text;

  static const TextStyle style = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: PayseColors.textSecondary,
  );

  /// 2026-10-30: 라벨을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Align(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(text, style: style),
      ),
    );
  }
}

/// 2026-10-30: 빈 상태(제목·설명·테두리 버튼들).
class TxEmpty extends StatelessWidget {
  /// 2026-10-30: 제목 [title], 설명 [body], 버튼 [actions]로 만든다.
  const TxEmpty({
    required this.title,
    this.body,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? body;
  final List<(String, VoidCallback)> actions;

  /// 2026-10-30: 빈 상태를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: PayseColors.textPrimary,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 4),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: PayseColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: PayseSpace.x5),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: PayseSpace.x2,
            runSpacing: PayseSpace.x2,
            children: [
              for (final (label, onTap) in actions)
                SizedBox(
                  height: PayseSize.touchMin,
                  child: OutlinedButton(
                    key: ValueKey('tx-action-$label'),
                    onPressed: onTap,
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
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 2026-10-30: 불러오는 중 로딩 틀(실제 행 크기).
class TxSkeleton extends StatelessWidget {
  /// 2026-10-30: 로딩 틀을 만든다.
  const TxSkeleton({super.key});

  /// 2026-10-30: 로딩 틀을 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    Widget row(double w1, double w2) => Container(
      height: 76,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [bar(w1, 18), const SizedBox(height: 6), bar(190, 15)],
            ),
          ),
          bar(w2, 18),
        ],
      ),
    );
    return ExcludeSemantics(
      child: Column(
        key: const ValueKey('tx-loading'),
        children: [
          const SizedBox(height: PayseSpace.x4),
          row(112, 84),
          row(88, 72),
          row(96, 92),
          row(120, 80),
        ],
      ),
    );
  }
}
