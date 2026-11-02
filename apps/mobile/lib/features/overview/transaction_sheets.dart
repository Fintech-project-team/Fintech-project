import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../data/statement_relations.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import '../planning/card_bill_screen.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';
import 'transactions_screen.dart' show amountColor;

/// 2026-10-30: 흰 면·위 반경 16·덮개 50%·화면 85%까지의 바텀시트를 열고 고른 값을 반환한다(§7 바텀시트).
Future<T?> showPayseSheet<T>(BuildContext context, Widget child) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      backgroundColor: PayseColors.background,
      barrierColor: const Color(0x80242629),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(PayseRadius.lg),
        ),
      ),
      builder: (_) => child,
    );

/// 2026-10-30: 선택 시트 틀. 손잡이·제목·닫기 → 본문(스크롤) → 보조 문구 → 고정 '적용'. 닫으면 null(기존 조건 유지).
class SelectSheet extends StatelessWidget {
  /// 2026-10-30: 제목 [title], 본문 [children], 적용 [onApply](null이면 비활성), 적용 위 문구 [note]와 오류 색 여부
  /// [noteIsError]로 만든다. [header]는 제목 아래 고정 영역(본문과 함께 스크롤하지 않음)이다.
  const SelectSheet({
    required this.title,
    required this.children,
    required this.onApply,
    this.note,
    this.noteIsError = false,
    this.header,
    super.key,
  });

  final Widget? header;

  /// 2026-11-02: 본문 끝과 적용 위 선 사이 여백. 기기 하단 안전 영역과 무관하게 같다.
  static const double bottomGap = PayseSpace.x6;

  final String title;
  final List<Widget> children;
  final VoidCallback? onApply;
  final String? note;
  final bool noteIsError;

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
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: PayseColors.textPrimary,
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
        ?header,
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              0,
              PayseSpace.screenHorizontal,
              bottomGap,
            ),
            children: children,
          ),
        ),
        const Divider(height: 1, color: PayseColors.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            PayseSpace.x3,
            PayseSpace.screenHorizontal,
            PayseSpace.x6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (note != null) ...[
                Text(
                  note!,
                  key: const ValueKey('sheet-note'),
                  style: PayseTypography.caption.copyWith(
                    color: noteIsError ? PayseColors.error : null,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('sheet-apply'),
                  onPressed: onApply,
                  style: FilledButton.styleFrom(
                    backgroundColor: PayseColors.charcoal,
                    foregroundColor: PayseColors.onCharcoal,
                    disabledBackgroundColor: PayseColors.surfaceMuted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(PayseRadius.sm),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('적용'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 2026-10-30: 라디오 줄(최소 56dp).
class RadioRow extends StatelessWidget {
  /// 2026-10-30: 문구 [label], 선택 [selected], 누르기 [onTap]으로 만든다.
  /// 2026-11-02: [caption]은 문구 아래 보조 줄(계획 탭 월급 기간 위치)이다.
  const RadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.caption,
    super.key,
  });

  final String? caption;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 22,
                color: selected
                    ? PayseColors.charcoal
                    : PayseColors.borderStrong,
              ),
              const SizedBox(width: PayseSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    if (caption case final caption?)
                      Text(caption, style: PayseTypography.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-30: '기간 선택' 시트. 선택지는 이름만, 선택한 조회 기간은 적용 위에 한 번. 월 선택은 조회 범위 안의 달만이며
/// 양 끝 부분 월은 '20일부터'·'19일까지'를 붙인다.
class PeriodSheet extends StatefulWidget {
  /// 2026-10-30: 조회 범위 [bounds]와 현재 선택 [current]로 만든다.
  /// 2026-10-31: [inherited]는 들어온 화면에서 물려받은 월급 주기이며, 있으면 맨 위 선택지로 둔다.
  const PeriodSheet({
    required this.bounds,
    required this.current,
    this.inherited,
    super.key,
  });

  final QueryBounds bounds;
  final PeriodSelection current;
  final PeriodSelection? inherited;

  @override
  State<PeriodSheet> createState() => _PeriodSheetState();
}

class _PeriodSheetState extends State<PeriodSheet> {
  late PeriodSelection _sel = widget.current;
  late String _month =
      widget.current.month ?? widget.bounds.last.substring(0, 7);

  @override
  Widget build(BuildContext context) {
    final monthMode = _sel.kind == PeriodKind.month;
    final effective = monthMode
        ? (_month == widget.bounds.last.substring(0, 7)
              ? PeriodSelection.thisMonth
              : PeriodSelection(PeriodKind.month, month: _month))
        : _sel;
    return SelectSheet(
      title: '기간 선택',
      note: '조회 기간 ${widget.bounds.rangeText(effective)}',
      onApply: () => Navigator.of(context).pop(effective),
      children: [
        if (widget.inherited case final inherited?)
          RadioRow(
            key: const ValueKey('period-cycle'),
            label: inherited.name,
            selected: _sel == inherited,
            onTap: () => setState(() => _sel = inherited),
          ),
        for (final kind in PeriodKind.values)
          if (kind != PeriodKind.cycle)
            RadioRow(
              key: ValueKey('period-${kind.name}'),
              label: PeriodSelection(kind).name,
              selected: _sel.kind == kind,
              onTap: () => setState(
                () => _sel = PeriodSelection(
                  kind,
                  month: kind == PeriodKind.month ? _month : null,
                ),
              ),
            ),
        if (monthMode) _monthGrid(),
      ],
    );
  }

  Widget _monthGrid() {
    final byYear = <String, List<String>>{};
    for (final m in widget.bounds.months) {
      byYear.putIfAbsent(m.substring(0, 4), () => []).add(m);
    }
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in byYear.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: PayseSpace.x2, bottom: 4),
              child: Text('${entry.key}년', style: PayseTypography.caption),
            ),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: PayseSpace.x2,
              crossAxisSpacing: PayseSpace.x2,
              childAspectRatio: 1.6,
              children: [for (final m in entry.value) _monthCell(m)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _monthCell(String month) {
    final on = month == _month;
    final note = widget.bounds.partialNote(month);
    return Semantics(
      button: true,
      selected: on,
      child: InkWell(
        key: ValueKey('month-$month'),
        borderRadius: BorderRadius.circular(PayseRadius.sm),
        onTap: () => setState(() {
          _month = month;
          _sel = PeriodSelection(PeriodKind.month, month: month);
        }),
        child: Container(
          decoration: BoxDecoration(
            color: on ? PayseColors.charcoal : PayseColors.background,
            borderRadius: BorderRadius.circular(PayseRadius.sm),
            border: on ? null : Border.all(color: PayseColors.border),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${int.parse(month.substring(5))}월',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? PayseColors.onCharcoal : PayseColors.textPrimary,
                ),
              ),
              if (note != null)
                Text(
                  note,
                  style: TextStyle(
                    fontSize: 11,
                    color: on
                        ? PayseColors.onCharcoal
                        : PayseColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-30: 체크박스 묶음 상태.
enum _Check { on, some, off }

/// 2026-10-30: 체크박스 줄. 묶음은 일부 선택(—)을 표시한다.
/// 2026-10-30: 체크 행. 묶음 머리([bold])는 52dp에 위 진한 선([topLine]), 묶음 안 항목은 48dp에 상자 폭만큼 들여 쓰며
/// 행 사이 선이 없다(전체 / 계좌 묶음 / 카드 묶음이 한 덩어리로 보이게).
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.state,
    required this.onTap,
    this.bold = false,
    this.indent = false,
    this.topLine = false,
    super.key,
  });

  final String label;
  final _Check state;
  final VoidCallback onTap;
  final bool bold;
  final bool indent;
  final bool topLine;

  /// 2026-10-30: 묶음 안 항목 들여쓰기(상자 24 + 간격 12, 머리 글자 위치).
  static const double indentWidth = 36;

  @override
  Widget build(BuildContext context) {
    final box = switch (state) {
      _Check.on => Icons.check_box,
      _Check.some => Icons.indeterminate_check_box,
      _Check.off => Icons.check_box_outline_blank,
    };
    return Semantics(
      checked: state == _Check.on,
      mixed: state == _Check.some,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: bold ? 52 : 48),
          padding: EdgeInsets.only(left: indent ? indentWidth : 0),
          decoration: topLine
              ? const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: PayseColors.dividerSection),
                  ),
                )
              : null,
          child: Row(
            children: [
              Icon(
                box,
                size: 24,
                color: state == _Check.off
                    ? PayseColors.borderStrong
                    : PayseColors.charcoal,
              ),
              const SizedBox(width: PayseSpace.x3),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                    color: PayseColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-30: '거래 수단 선택' 시트(복수 선택). 전체·계좌 전체·카드 전체는 묶음 선택이며 0개면 적용을 막는다.
/// 적용하면 (계좌 ID 집합, 카드 ID 집합)을 반환하며 묶음 전체면 null이다.
class MeansSheet extends StatefulWidget {
  /// 2026-10-30: [snapshot]의 계좌·카드와 현재 선택 [accountIds]·[cardIds]로 만든다.
  const MeansSheet({
    required this.snapshot,
    required this.accountIds,
    required this.cardIds,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final Set<String>? accountIds;
  final Set<String>? cardIds;

  @override
  State<MeansSheet> createState() => _MeansSheetState();
}

class _MeansSheetState extends State<MeansSheet> {
  late final List<Account> _accounts = widget.snapshot.accounts ?? const [];
  late final List<PaymentCard> _cards = widget.snapshot.cards ?? const [];
  late final Set<String> _a = {
    ...widget.accountIds ?? {for (final a in _accounts) a.accountId},
  };
  late final Set<String> _c = {
    ...widget.cardIds ?? {for (final c in _cards) c.cardId},
  };

  _Check _group(Set<String> sel, Iterable<String> all) {
    final n = all.where(sel.contains).length;
    if (n == 0) return _Check.off;
    return n == all.length ? _Check.on : _Check.some;
  }

  void _toggleGroup(Set<String> sel, Iterable<String> all) => setState(() {
    if (_group(sel, all) == _Check.on) {
      sel.removeAll(all);
    } else {
      sel.addAll(all);
    }
  });

  @override
  Widget build(BuildContext context) {
    final accIds = [for (final a in _accounts) a.accountId];
    final cardIds = [for (final c in _cards) c.cardId];
    final count = _a.length + _c.length;
    final everything = _group({..._a, ..._c}, [...accIds, ...cardIds]);
    String? lastBank;
    final rows = <Widget>[
      _CheckRow(
        key: const ValueKey('means-all'),
        label: '전체',
        bold: true,
        state: everything,
        onTap: () => setState(() {
          final on = everything == _Check.on;
          for (final pair in [(_a, accIds), (_c, cardIds)]) {
            on ? pair.$1.clear() : pair.$1.addAll(pair.$2);
          }
        }),
      ),
      _CheckRow(
        key: const ValueKey('means-accounts'),
        label: '계좌 전체',
        bold: true,
        topLine: true,
        state: _group(_a, accIds),
        onTap: () => _toggleGroup(_a, accIds),
      ),
    ];
    final order = [for (final i in widget.snapshot.institutions) i.code];
    final byBank = [..._accounts]
      ..sort((x, y) {
        final i = order.indexOf(x.institutionCode);
        final j = order.indexOf(y.institutionCode);
        return i.compareTo(j);
      });
    for (final a in byBank) {
      final bank = institutionName(widget.snapshot, a.institutionCode);
      if (bank != lastBank) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(
              top: PayseSpace.x2,
              left: _CheckRow.indentWidth,
            ),
            child: Text(bank, style: PayseTypography.caption),
          ),
        );
        lastBank = bank;
      }
      rows.add(
        _CheckRow(
          key: ValueKey('means-${a.accountId}'),
          label:
              '${a.nickname ?? a.productName} ····${lastFour(a.maskedNumber)}',
          indent: true,
          state: _a.contains(a.accountId) ? _Check.on : _Check.off,
          onTap: () => setState(
            () => _a.contains(a.accountId)
                ? _a.remove(a.accountId)
                : _a.add(a.accountId),
          ),
        ),
      );
    }
    if (_cards.isNotEmpty) {
      rows.add(const SizedBox(height: PayseSpace.x2));
      rows.add(
        _CheckRow(
          key: const ValueKey('means-cards'),
          label: '카드 전체',
          bold: true,
          topLine: true,
          state: _group(_c, cardIds),
          onTap: () => _toggleGroup(_c, cardIds),
        ),
      );
      for (final c in _cards) {
        rows.add(
          _CheckRow(
            key: ValueKey('means-${c.cardId}'),
            label: '${c.productName} ····${lastFour(c.maskedNumber)}',
            indent: true,
            state: _c.contains(c.cardId) ? _Check.on : _Check.off,
            onTap: () => setState(
              () => _c.contains(c.cardId)
                  ? _c.remove(c.cardId)
                  : _c.add(c.cardId),
            ),
          ),
        );
      }
    }
    return SelectSheet(
      title: '거래 수단 선택',
      note: count == 0 ? '거래 수단을 1개 이상 골라 주세요' : '$count개 선택',
      noteIsError: count == 0,
      onApply: count == 0
          ? null
          : () => Navigator.of(context).pop((
              _a.length == accIds.length ? null : Set<String>.of(_a),
              _c.length == cardIds.length ? null : Set<String>.of(_c),
            )),
      children: rows,
    );
  }
}

/// 2026-10-30: 거래 종류(또는 계좌별 화면의 입출금) 선택 시트. [options]의 null은 '전체'이며 적용하면 고른 값을 감싸 반환한다.
class TypeSheet extends StatefulWidget {
  /// 2026-10-30: 제목 [title], 선택지 [options](라벨), 현재 선택 [current]로 만든다.
  const TypeSheet({
    required this.title,
    required this.options,
    required this.current,
    super.key,
  });

  final String title;
  final List<(TxType?, String)> options;
  final TxType? current;

  @override
  State<TypeSheet> createState() => _TypeSheetState();
}

class _TypeSheetState extends State<TypeSheet> {
  late TxType? _sel = widget.current;

  @override
  Widget build(BuildContext context) {
    return SelectSheet(
      title: widget.title,
      onApply: () => Navigator.of(context).pop((value: _sel)),
      children: [
        for (final (type, label) in widget.options)
          RadioRow(
            key: ValueKey('type-${type?.name ?? 'all'}'),
            label: label,
            selected: _sel == type,
            onTap: () => setState(() => _sel = type),
          ),
      ],
    );
  }
}

/// 2026-10-30: 읽기 전용 거래 상세 시트. 위에 거래명·금액, 아래 정보 줄([detailRows]). 편집·저장 없음.
class TransactionDetailSheet extends StatelessWidget {
  /// 2026-10-30: [snapshot]의 거래 [transaction]과 확보한 원거래 [original]로 만든다.
  /// 2026-11-01: 근거 있는 내 계좌 이체의 상대 거래 [peer]를 더했다.
  /// 2026-11-02: [transactions]는 받은 거래 전체(같은 자료 버전)이며 카드 결제 상세에서 청구 항목의 거래를 찾는 데 쓴다.
  const TransactionDetailSheet({
    required this.snapshot,
    required this.transaction,
    this.original,
    this.peer,
    this.transactions = const [],
    super.key,
  });

  final FinancialSnapshot snapshot;
  final SourceTransaction transaction;
  final SourceTransaction? original;
  final SourceTransaction? peer;
  final List<SourceTransaction> transactions;

  /// 2026-11-02: 시트를 닫고 청구 [statementId]의 카드 결제 상세를 연다. 뒤로 가면 시트를 열었던 목록으로 돌아간다.
  void _openBill(BuildContext context, String statementId) {
    Navigator.of(context)
      ..pop()
      ..push(
        MaterialPageRoute<void>(
          builder: (_) => CardBillScreen(
            snapshot: snapshot,
            statementId: statementId,
            transactions: transactions,
          ),
        ),
      );
  }

  /// 2026-11-02: 거래 상세의 청구 연결(T6). 카드 기록은 그 거래를 포함한 청구 전부('포함된 청구'), 계좌 출금은 유효 정산 →
  /// 예정 지출 → 청구가 이어질 때만 '결제한 카드 대금'이다. 관계가 없으면 null, 제한 표식으로 끊겼으면 안내만 둔다.
  Widget? _statementLinks(BuildContext context) {
    final t = transaction;
    final relations = StatementRelations(snapshot);
    final List<Statement> statements;
    final String title;
    var restricted = false;
    if (!isAccountEntry(t)) {
      statements = relations.statementsIncluding(t.transactionId);
      title = '포함된 청구';
    } else if (t.direction == 'out') {
      final paid = relations.paidStatements(t.transactionId);
      statements = paid.statements;
      restricted = paid.restricted;
      title = '결제한 카드 대금';
    } else {
      return null;
    }
    if (statements.isEmpty && !restricted) return null;
    return Column(
      key: const ValueKey('detail-statements'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: PayseSpace.x6,
            bottom: PayseSpace.x1,
          ),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: PayseColors.textSecondary,
            ),
          ),
        ),
        const Divider(height: 1, color: PayseColors.dividerSection),
        for (final s in statements)
          _StatementLink(
            key: ValueKey('detail-statement-${s.statementId}'),
            snapshot: snapshot,
            statement: s,
            byCard: isAccountEntry(t),
            onTap: () => _openBill(context, s.statementId),
          ),
        if (restricted)
          const Padding(
            padding: EdgeInsets.only(top: PayseSpace.x3),
            child: Text(
              '연결된 청구를 확인할 수 없어요',
              key: ValueKey('detail-statement-restricted'),
              style: PayseTypography.caption,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final rows = detailRows(snapshot, t, original: original, peer: peer);
    final links = _statementLinks(context);
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: PayseSpace.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.merchantName,
                        key: const ValueKey('detail-title'),
                        style: const TextStyle(
                          fontSize: 17,
                          height: 25 / 17,
                          fontWeight: FontWeight.w600,
                          color: PayseColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        amountText(t),
                        key: const ValueKey('detail-amount'),
                        style: TextStyle(
                          fontSize: 28,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.84,
                          color: amountColor(amountText(t)),
                          fontFeatures: PayseTypography.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('detail-close'),
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
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x5,
              PayseSpace.screenHorizontal,
              34,
            ),
            children: [
              const Divider(height: 1, color: PayseColors.dividerSection),
              for (final (label, value, note) in rows)
                Container(
                  key: ValueKey('detail-row-$label'),
                  padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: PayseColors.dividerRow),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 22 / 15,
                            color: PayseColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: PayseSpace.x4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              value,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 22 / 15,
                                color: PayseColors.textPrimary,
                              ),
                            ),
                            if (note != null)
                              Text(
                                note,
                                textAlign: TextAlign.right,
                                style: PayseTypography.caption,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ?links,
            ],
          ),
        ),
      ],
    );
  }
}

/// 2026-11-02: 거래 상세의 청구 한 줄. 카드 기록에서는 결제 예정일 중심, 계좌 출금에서는 결제한 카드 중심으로 보이고 누르면
/// 카드 결제 상세로 간다. 결제 예정일이 없으면 '결제 예정일 미확인'이며 다른 날짜로 채우지 않는다.
class _StatementLink extends StatelessWidget {
  /// 2026-11-02: [snapshot]의 청구 [statement], 카드 중심 표시 [byCard], 누르기 [onTap]으로 만든다.
  const _StatementLink({
    required this.snapshot,
    required this.statement,
    required this.byCard,
    required this.onTap,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final Statement statement;
  final bool byCard;
  final VoidCallback onTap;

  /// 2026-11-02: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final s = statement;
    final card = cardById(snapshot, s.cardId);
    final cardText = card == null
        ? '카드 정보 없음'
        : '${card.productName} ····${lastFour(card.maskedNumber)}';
    final due = s.dueDate;
    final dueText = due == null
        ? '결제 예정일 미확인 청구'
        : '${int.parse(due.substring(5, 7))}월 ${int.parse(due.substring(8, 10))}일 결제 청구';
    final amount = '청구 금액 ${formatKrw(s.amountKrw)}';
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
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
                    Text(
                      byCard ? cardText : dueText,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 22 / 15,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    Text(
                      byCard ? '$dueText · $amount' : '$cardText · $amount',
                      style: PayseTypography.caption,
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: PayseColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
