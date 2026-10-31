import 'package:flutter/material.dart';

import '../../data/connection/financial_api.dart';
import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'home_screen.dart' show asOfLabel;
import 'pull_refresh.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';
import 'transaction_sheets.dart';

/// 2026-10-30: 거래 내역 수집 상태.
enum _Load { loading, ready, failed }

/// 2026-10-30: 02-4 거래 내역(apps/mobile/docs/accounts-transactions.md §4, 29-2 명세). 계좌 내역과 카드 기록을 한 목록에
/// 날짜 최신순으로 보이고, 기간·거래 수단·거래 종류는 각자의 선택 시트로 바꾼다. [accountId]가 있으면 그 계좌로 고정한
/// 계좌별 거래이며 거래 수단 대신 입출금만 고른다. 거래를 누르면 읽기 전용 상세 시트를 연다. 조회 조건은 이 화면 안에서만
/// 쓰고 홈 계산 포함 계좌를 바꾸지 않는다.
class TransactionsScreen extends StatefulWidget {
  /// 2026-10-30: 기준 [snapshot], 다음 페이지 조회 [repository](없으면 Snapshot 거래만), 세션 무효 [onSessionInvalid],
  /// 고정 계좌 [accountId]로 만든다.
  /// 2026-10-30: 아래로 당겨 새로고침 [onRefresh], 그 성공 뒤 처리 [onRefreshed], 새로고침으로 이미 받은 거래 전체
  /// [history](자료 버전이 [snapshot]과 같으면 다시 받지 않고 쓴다)를 더했다.
  const TransactionsScreen({
    required this.snapshot,
    this.repository,
    this.onSessionInvalid,
    this.accountId,
    this.history,
    this.onRefresh,
    this.onRefreshed,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final UserFinancialRepository? repository;
  final VoidCallback? onSessionInvalid;
  final String? accountId;
  final TransactionHistoryReady? history;
  final PullRefresh? onRefresh;
  final ValueChanged<TransactionHistoryReady>? onRefreshed;

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

/// 2026-10-30: 조회 조건·수집 결과를 가진다. 새 Snapshot(자료 버전 변경)이 오면 다시 수집하고 조건은 유지한다.
class _TransactionsScreenState extends State<TransactionsScreen> {
  _Load _load = _Load.loading;
  bool _stale = false;
  FinancialSnapshot? _base;
  List<SourceTransaction> _all = const [];
  List<Coverage> _coverage = const [];
  int _request = 0;
  late TransactionQuery _query = widget.accountId == null
      ? const TransactionQuery()
      : TransactionQuery(accountIds: {widget.accountId!}, cardIds: const {});
  final ScrollController _scroll = ScrollController();

  /// 2026-10-30: 처음 수집한다.
  @override
  void initState() {
    super.initState();
    _collect();
  }

  /// 2026-10-30: 자료 버전이 바뀐 Snapshot이면 다시 수집한다. 새로고침으로 받은 거래가 새로 오면 그것을 쓴다.
  @override
  void didUpdateWidget(covariant TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.dataVersion != widget.snapshot.dataVersion ||
        (widget.history != oldWidget.history && _matchingHistory != null)) {
      _collect();
    }
  }

  /// 2026-10-30: 현재 Snapshot과 자료 버전이 같은 받아 둔 거래 전체. 없으면 null이다.
  TransactionHistoryReady? get _matchingHistory {
    final h = widget.history;
    return h != null && h.snapshot.dataVersion == widget.snapshot.dataVersion
        ? h
        : null;
  }

  /// 2026-10-30: 스크롤 컨트롤러를 폐기한다.
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 2026-10-30: 모든 페이지를 받는다. 실패하면 이전 완료 결과가 있으면 유지하고 안내 띠를, 없으면 조회 실패를 보인다.
  Future<void> _collect() async {
    final request = ++_request;
    final repo = widget.repository;
    final first = widget.snapshot;
    setState(() {
      if (_base == null) _load = _Load.loading;
    });
    final TransactionHistoryResult result;
    if (_matchingHistory case final ready?) {
      result = ready;
    } else if (repo == null || first.nextTransactionCursor == null) {
      result = TransactionHistoryReady(
        snapshot: first,
        transactions: first.transactions ?? const [],
        coverage: first.coverage,
      );
    } else {
      result = await TransactionHistoryCollector(repo).collect(first);
    }
    if (!mounted || request != _request) return;
    switch (result) {
      case TransactionHistoryReady(
        :final snapshot,
        :final transactions,
        :final coverage,
      ):
        setState(() {
          _base = snapshot;
          _all = transactions;
          _coverage = coverage;
          _load = _Load.ready;
          _stale = false;
        });
      case TransactionHistorySessionInvalid():
        widget.onSessionInvalid?.call();
      case TransactionHistoryFailed():
        setState(() {
          if (_base == null) {
            _load = _Load.failed;
          } else {
            _stale = true;
          }
        });
    }
  }

  FinancialSnapshot get _snap => _base ?? widget.snapshot;
  QueryBounds get _bounds => QueryBounds.of(_snap, _coverage);
  bool get _fixed => widget.accountId != null;

  /// 2026-10-30: 조건을 [next]로 바꾸고 목록 맨 위로 간다.
  void _apply(TransactionQuery next) {
    setState(() => _query = next);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 2026-10-30: 기간 선택 시트를 연다.
  Future<void> _pickPeriod() async {
    final picked = await showPayseSheet<PeriodSelection>(
      context,
      PeriodSheet(bounds: _bounds, current: _query.period),
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
            (null, '전체'),
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
  void _open(SourceTransaction t) {
    final id = t.originalTransactionId;
    SourceTransaction? original;
    if (id != null) {
      for (final o in _all) {
        if (o.transactionId == id) original = o;
      }
    }
    showPayseSheet<void>(
      context,
      TransactionDetailSheet(
        snapshot: _snap,
        transaction: t,
        original: original,
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
    final list = _load == _Load.ready
        ? filterAndSort(_all, _query, bounds)
        : const <SourceTransaction>[];
    final missing = _missingNotice();
    return PullRefreshScrollView(
      scrollKey: const ValueKey('transactions-list'),
      controller: _scroll,
      onRefresh: widget.onRefresh,
      onDone: widget.onRefreshed,
      slivers: [
        if (_stale)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('tx-band-stale'),
              title: '새로고침하지 못했어요',
              body: '이전 정보를 보여드려요.',
              onRetry: _collect,
            ),
          ),
        if (missing != null && _load == _Load.ready)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('tx-band-partial'),
              title: missing.$1,
              body: missing.$2,
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(
            horizontal: PayseSpace.screenHorizontal,
          ),
          sliver: SliverList.list(
            children: [
              const SizedBox(height: PayseSpace.x3),
              _periodHeader(bounds, month),
              const SizedBox(height: PayseSpace.x2),
              Wrap(
                spacing: PayseSpace.x2,
                runSpacing: PayseSpace.x2,
                children: [
                  if (!_fixed)
                    _Chip(
                      key: const ValueKey('chip-means'),
                      label: _meansChip(),
                      onTap: _pickMeans,
                    ),
                  if (!_fixed || _query.hasAccounts)
                    _Chip(
                      key: const ValueKey('chip-type'),
                      label: _typeChip(),
                      onTap: _pickType,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _load == _Load.loading
                    ? '거래 내역을 불러오는 중이에요'
                    : _fixed
                    ? asOfLabel(_snap.asOf)
                    : '${asOfLabel(_snap.asOf)} · 연결된 계좌와 카드의 거래 내역이에요',
                key: const ValueKey('tx-basis'),
                style: PayseTypography.caption,
              ),
              ..._body(list),
              const SizedBox(height: PayseSpace.x6),
            ],
          ),
        ),
      ],
    );
  }

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
    return type?.label ?? '거래 종류 전체';
  }

  /// 2026-10-30: 기간 머리. 달 단위면 '‹ 2026년 10월 ▾ ›'(가운데), 최근 기간이면 제목과 실제 범위(화살표 없음).
  Widget _periodHeader(QueryBounds bounds, String? month) {
    final title = TextButton(
      key: const ValueKey('period-title'),
      onPressed: _pickPeriod,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, PayseSize.touchMin),
        padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
        foregroundColor: PayseColors.textPrimary,
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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
        children: [
          title,
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const ValueKey('period-prev'),
          tooltip: '이전 달 보기',
          onPressed: prev == null
              ? null
              : () => _apply(_query.withPeriod(prev)),
          icon: const Icon(Icons.chevron_left),
        ),
        Flexible(child: title),
        IconButton(
          key: const ValueKey('period-next'),
          tooltip: '다음 달 보기',
          onPressed: next == null
              ? null
              : () => _apply(_query.withPeriod(next)),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  /// 2026-10-30: 목록 본문(불러오는 중·조회 실패·없음·날짜별 목록).
  List<Widget> _body(List<SourceTransaction> list) {
    switch (_load) {
      case _Load.loading:
        return [const _Skeleton()];
      case _Load.failed:
        return [
          _Empty(
            key: const ValueKey('tx-failed'),
            title: '거래 내역을 불러오지 못했어요',
            body: '잠시 후 다시 시도해 주세요.',
            actions: [('다시 시도', _collect)],
          ),
        ];
      case _Load.ready:
        break;
    }
    if (list.isEmpty) {
      final isDefaultFixed =
          _fixed &&
          _query.period == PeriodSelection.thisMonth &&
          _query.type == null;
      if (_query.isDefault || isDefaultFixed) {
        return [
          _Empty(
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
        _Empty(
          key: const ValueKey('tx-no-result'),
          title: '선택한 조건의 거래 내역이 없어요',
          body: _fixed ? '기간이나 입출금 조건을 바꿔보세요.' : '기간이나 거래 수단을 바꿔보세요.',
          actions: [
            ('기간 변경', _pickPeriod),
            if (_fixed)
              ('입출금 전체 보기', () => _apply(_query.withType(null)))
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
        out.add(_DayHeader(dayHeader(d)));
        day = d;
      }
      out.add(
        _TxRow(
          key: ValueKey('tx-${t.transactionId}'),
          name: t.merchantName,
          subtitle: subtitle(_snap, t, withMeans: !_fixed),
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

/// 2026-10-30: 조건 칩(높이 36·반경 20·테두리 borderStrong, 터치 48).
class _Chip extends StatelessWidget {
  /// 2026-10-30: 문구 [label]과 누르기 [onTap]으로 만든다.
  const _Chip({required this.label, required this.onTap, super.key});

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
class _DayHeader extends StatelessWidget {
  /// 2026-10-30: 문구 [text]로 만든다.
  const _DayHeader(this.text);

  final String text;

  /// 2026-10-30: 날짜 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: PayseSpace.x4),
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
class _TxRow extends StatelessWidget {
  /// 2026-10-30: 거래명 [name], 둘째 줄 [subtitle], 금액 [amount], 상태 라벨 [labels], 누르기 [onTap]으로 만든다.
  const _TxRow({
    required this.name,
    required this.subtitle,
    required this.amount,
    required this.labels,
    required this.onTap,
    super.key,
  });

  final String name;
  final String subtitle;
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
        text: TextSpan(text: l, style: _Label.style),
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
                          _Label(l),
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
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
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
class _Label extends StatelessWidget {
  /// 2026-10-30: 문구 [text]로 만든다.
  const _Label(this.text);

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
class _Empty extends StatelessWidget {
  /// 2026-10-30: 제목 [title], 설명 [body], 버튼 [actions]로 만든다.
  const _Empty({
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
class _Skeleton extends StatelessWidget {
  /// 2026-10-30: 로딩 틀을 만든다.
  const _Skeleton();

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
