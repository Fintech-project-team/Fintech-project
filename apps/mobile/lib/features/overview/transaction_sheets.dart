import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';

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
class _SelectSheet extends StatelessWidget {
  const _SelectSheet({
    required this.title,
    required this.children,
    required this.onApply,
    this.note,
    this.noteIsError = false,
  });

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
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
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
class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

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
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

/// 2026-10-30: '기간 선택' 시트. 선택지는 이름만, 선택한 조회 기간은 적용 위에 한 번. 월 선택은 조회 범위 안의 달만이며
/// 양 끝 부분 월은 '20일부터'·'19일까지'를 붙인다.
class PeriodSheet extends StatefulWidget {
  /// 2026-10-30: 조회 범위 [bounds]와 현재 선택 [current]로 만든다.
  const PeriodSheet({required this.bounds, required this.current, super.key});

  final QueryBounds bounds;
  final PeriodSelection current;

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
    return _SelectSheet(
      title: '기간 선택',
      note: '조회 기간 ${widget.bounds.rangeText(effective)}',
      onApply: () => Navigator.of(context).pop(effective),
      children: [
        for (final kind in PeriodKind.values)
          _RadioRow(
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
    return _SelectSheet(
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
    return _SelectSheet(
      title: widget.title,
      onApply: () => Navigator.of(context).pop((value: _sel)),
      children: [
        for (final (type, label) in widget.options)
          _RadioRow(
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
  const TransactionDetailSheet({
    required this.snapshot,
    required this.transaction,
    this.original,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final SourceTransaction transaction;
  final SourceTransaction? original;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final rows = detailRows(snapshot, t, original: original);
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
                        style: const TextStyle(
                          fontSize: 28,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.84,
                          color: PayseColors.textPrimary,
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
            ],
          ),
        ),
      ],
    );
  }
}
