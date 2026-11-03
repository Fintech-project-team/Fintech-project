import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/payse_tokens.dart';
import '../overview/transaction_sheets.dart' show RadioRow, SelectSheet;
import 'plan_periods.dart';

/// 2026-11-02: 계획 탭 '기간 선택' 시트. 위에서 월급 기간/달력 월을 전환하고, 월급 기간은 확인된 주기 목록, 달력 월은 연도
/// 선택(좌우 이동·연도 목록)과 3열 4행 격자다. 범위 밖 달만 비활성이고 빈 달은 고를 수 있다. 열면 현재 적용값이 선택돼 있고
/// '적용'을 눌러야 고른 기간을 반환한다(닫으면 null). 조회 기간 줄은 달력 월에만 둔다(월급 기간은 목록에 범위가 있음).
class PlanPeriodSheet extends StatefulWidget {
  /// 2026-11-02: 월급 기간 목록 [salary](없으면 달력 월만), 달력 월 목록 [months], 적용 중인 기간 [current], 기준일 [today]로
  /// 만든다.
  const PlanPeriodSheet({
    required this.salary,
    required this.months,
    required this.current,
    required this.today,
    super.key,
  });

  final List<PlanPeriod>? salary;
  final List<PlanPeriod> months;
  final PlanPeriod current;
  final calc.BusinessDate today;

  /// 2026-11-02: 상태 객체를 반환한다.
  @override
  State<PlanPeriodSheet> createState() => _PlanPeriodSheetState();
}

/// 2026-11-02: 고른 종류·기간·보고 있는 연도·연도 목록 펼침을 가진다.
class _PlanPeriodSheetState extends State<PlanPeriodSheet> {
  late PlanPeriodKind _kind = widget.current.kind;
  late PlanPeriod _picked = widget.current;
  late int _year =
      (widget.current.kind == PlanPeriodKind.month
              ? widget.current
              : monthOf(widget.today))
          .start!
          .year;
  bool _years = false;

  /// 2026-11-02: 고를 수 있는 연도(오래된 순).
  List<int> get _yearList =>
      {for (final m in widget.months) m.start!.year}.toList();

  /// 2026-11-02: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final salary = widget.salary;
    return SelectSheet(
      title: '기간 선택',
      note: _kind == PlanPeriodKind.month
          ? '조회 기간 ${_longRange(_picked)}'
          : null,
      onApply: _picked.kind == _kind
          ? () => Navigator.of(context).pop(_picked)
          : null,
      header: salary == null ? null : _toggle(),
      children: _kind == PlanPeriodKind.salary && salary != null
          ? _salaryRows(salary)
          : _monthBody(),
    );
  }

  /// 2026-11-02: '월급 기간 / 달력 월' 전환.
  Widget _toggle() {
    Widget tab(PlanPeriodKind kind, String label) {
      final on = _kind == kind;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: InkWell(
            key: ValueKey('plan-kind-${kind.name}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() {
              _kind = kind;
              _years = false;
              if (_picked.kind != kind) {
                _picked = kind == PlanPeriodKind.month
                    ? _monthOrFirst(monthOf(widget.today))
                    : widget.salary!.firstWhere(
                        (p) => p.role == SalaryRole.current,
                      );
              }
            }),
            child: Container(
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? PayseColors.background : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: on
                    ? Border.all(color: PayseColors.dividerSection)
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on
                      ? PayseColors.textPrimary
                      : PayseColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
      ),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Row(
        children: [
          tab(PlanPeriodKind.salary, '월급 기간'),
          const SizedBox(width: 4),
          tab(PlanPeriodKind.month, '달력 월'),
        ],
      ),
    );
  }

  /// 2026-11-02: [month]가 목록에 있으면 그 달, 없으면 첫 달.
  PlanPeriod _monthOrFirst(PlanPeriod month) =>
      widget.months.contains(month) ? month : widget.months.first;

  /// 2026-11-02: 월급 기간 목록(확인된 주기만)과 그 전 기간 안내.
  List<Widget> _salaryRows(List<PlanPeriod> salary) => [
    for (final p in salary)
      RadioRow(
        key: ValueKey('plan-salary-${p.start}-${p.end}'),
        label: p.range,
        caption: p.role == SalaryRole.current ? '다음 월급일까지' : p.caption,
        selected: _picked == p,
        onTap: () => setState(() => _picked = p),
      ),
    const Padding(
      padding: EdgeInsets.only(top: PayseSpace.x2),
      child: Text('그 전 기간은 달력 월로 볼 수 있어요.', style: PayseTypography.caption),
    ),
  ];

  /// 2026-11-02: 연도 막대와 12개월 격자(또는 연도 목록).
  List<Widget> _monthBody() {
    final years = _yearList;
    final i = years.indexOf(_year);
    return [
      Padding(
        padding: const EdgeInsets.only(top: PayseSpace.x2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const ValueKey('plan-year-prev'),
              tooltip: '이전 연도',
              color: PayseColors.textPrimary,
              onPressed: i > 0
                  ? () => setState(() => _year = years[i - 1])
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            TextButton(
              key: const ValueKey('plan-year'),
              onPressed: () => setState(() => _years = !_years),
              style: TextButton.styleFrom(
                foregroundColor: PayseColors.textPrimary,
                minimumSize: const Size(48, PayseSize.touchMin),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$_year년'),
                  Icon(_years ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('plan-year-next'),
              tooltip: '다음 연도',
              color: PayseColors.textPrimary,
              onPressed: i >= 0 && i < years.length - 1
                  ? () => setState(() => _year = years[i + 1])
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
      if (_years)
        for (final y in years)
          RadioRow(
            key: ValueKey('plan-year-$y'),
            label: '$y년',
            selected: y == _year,
            onTap: () => setState(() {
              _year = y;
              _years = false;
            }),
          )
      else
        _grid(),
    ];
  }

  /// 2026-11-02: [_year]의 1~12월 격자. 목록에 없는 달은 비활성이다.
  Widget _grid() {
    final thisMonth = monthOf(widget.today);
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: PayseSpace.x2),
      mainAxisSpacing: PayseSpace.x2,
      crossAxisSpacing: PayseSpace.x2,
      childAspectRatio: 1.7,
      children: [
        for (var m = 1; m <= 12; m++)
          _MonthCell(
            month: m,
            period: monthOf(calc.BusinessDate(_year, m, 1)),
            enabled: widget.months.contains(
              monthOf(calc.BusinessDate(_year, m, 1)),
            ),
            selected: _picked == monthOf(calc.BusinessDate(_year, m, 1)),
            isThisMonth: thisMonth == monthOf(calc.BusinessDate(_year, m, 1)),
            onTap: (p) => setState(() => _picked = p),
          ),
      ],
    );
  }

  /// 2026-11-02: 적용 위 조회 기간 문구('9월 25일 ~ 10월 24일', 달력 월은 '2026년 8월 1일 ~ 8월 31일').
  static String _longRange(PlanPeriod p) {
    final last = p.end.addDays(-1);
    final s = p.start;
    final tail = '${last.month}월 ${last.day}일';
    if (s == null) return '~ $tail';
    final head = '${s.month}월 ${s.day}일';
    return p.kind == PlanPeriodKind.month
        ? '${s.year}년 $head ~ $tail'
        : '$head ~ $tail';
  }
}

/// 2026-11-02: 달력 월 한 칸. 선택은 차콜 채움, 이번 달은 진한 테두리와 '이번 달'(선택되면 노란 글자), 범위 밖은 흐린 비활성.
class _MonthCell extends StatelessWidget {
  /// 2026-11-02: 달 [month], 그 기간 [period], 선택 가능 [enabled], 선택 [selected], 이번 달 [isThisMonth], 누르기 [onTap]으로
  /// 만든다.
  const _MonthCell({
    required this.month,
    required this.period,
    required this.enabled,
    required this.selected,
    required this.isThisMonth,
    required this.onTap,
  });

  final int month;
  final PlanPeriod period;
  final bool enabled;
  final bool selected;
  final bool isThisMonth;
  final ValueChanged<PlanPeriod> onTap;

  /// 2026-11-02: 칸을 반환한다.
  @override
  Widget build(BuildContext context) {
    final fill = selected
        ? PayseColors.charcoal
        : enabled
        ? PayseColors.background
        : PayseColors.insufficientNoticeSurface;
    final border = selected || !enabled
        ? null
        : Border.all(
            color: isThisMonth
                ? PayseColors.borderStrong
                : PayseColors.dividerSection,
          );
    final text = selected
        ? PayseColors.onCharcoal
        : enabled
        ? PayseColors.textPrimary
        : PayseColors.scheduled;
    return Semantics(
      button: enabled,
      selected: selected,
      enabled: enabled,
      label: enabled ? null : '$month월, 조회할 수 없는 달',
      child: InkWell(
        key: ValueKey('plan-month-${period.start}'),
        borderRadius: BorderRadius.circular(PayseRadius.sm),
        onTap: enabled ? () => onTap(period) : null,
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(PayseRadius.sm),
            border: border,
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$month월',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected
                      ? FontWeight.w700
                      : isThisMonth
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: text,
                ),
              ),
              if (isThisMonth)
                Text(
                  '이번 달',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? PayseColors.moonYellow
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
