import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/amount_format.dart';
import '../../shared/design/amount_hero.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/status_notice.dart';
import '../../shared/design/payse_tokens.dart';
import 'calculation_detail_screen.dart';
import 'composition_bar.dart';
import 'cycle_moon.dart';
import 'home_calculation.dart';

/// 2026-10-23: 02-1 홈. 공유 계산 결과 [calculation]만 표시하며 금액을 직접 계산하지 않는다.
/// 데이터 오류·예상하지 못한 오류에서는 이전 금액을 보이지 않고 [onReload]로 다시 불러온다.
class HomeScreen extends StatelessWidget {
  /// 2026-10-23: 계산 결과 [calculation]과 다시 불러오기 [onReload]로 만든다.
  /// 2026-10-26: [record]는 4단계 기기 기록에서 판단할 보조 상태이며 3단계에서는 기본값(기록 없음)이다.
  /// [refresh]는 새로고침 진행 상태로, 홈 상태(음수·입금 대기·정보 부족)와 따로 관리한다.
  const HomeScreen({
    super.key,
    required this.calculation,
    required this.onReload,
    this.record = HomeSalaryRecord.none,
    this.refresh = HomeRefresh.idle,
  });

  final HomeCalculation calculation;
  final VoidCallback onReload;
  final HomeSalaryRecord record;
  final HomeRefresh refresh;

  static const String amountLabel = '다음 월급일까지\n쓸 수 있는 돈';

  /// 2026-10-23: 계산 상태에 맞는 홈 화면을 반환한다.
  /// 2026-10-26: 새로고침 중이면 이전 숫자 대신 로딩 틀을, 실패하면 표시할 이전 결과를 유지하거나(없으면 ④) 보인다.
  @override
  Widget build(BuildContext context) {
    if (refresh == HomeRefresh.loading) return const _HomeLoading();
    final failed = refresh == HomeRefresh.failed;
    return switch (calculation) {
      final HomeCalculationReady ready => _HomeReady(
        calculation: ready,
        record: record,
        onReload: onReload,
        refreshFailed: failed,
      ),
      HomeCalculationDataError() || HomeCalculationUnexpectedError()
          when failed =>
        _HomeLoadFailed(onReload: onReload),
      HomeCalculationDataError() => _HomeError(
        key: const ValueKey('home-data-error'),
        title: '받은 금융 정보로는 계산할 수 없어요',
        message:
            '정보 형식이나 연결 기록이 맞지 않아 금액을 표시하지 않았어요. 다시 불러와도 같으면 잠시 후 다시 확인해주세요.',
        onReload: onReload,
      ),
      HomeCalculationUnexpectedError() => _HomeError(
        key: const ValueKey('home-unexpected-error'),
        title: '금액을 계산하지 못했어요',
        message: '예상하지 못한 문제가 생겨 금액을 표시하지 않았어요. 다시 불러와도 같으면 앱을 닫았다가 다시 열어주세요.',
        onReload: onReload,
      ),
    };
  }
}

/// 2026-10-26: 홈 새로고침 진행 상태. 앱 진입 화면이 소유하고 홈은 표시만 한다.
enum HomeRefresh {
  /// 2026-10-26: 새로고침하지 않음.
  idle,

  /// 2026-10-26: 새로고침 중. 이전 숫자를 최신처럼 보이지 않도록 로딩 틀을 보인다.
  loading,

  /// 2026-10-26: 마지막 새로고침이 실패했다. 이전 결과는 그대로 둔다.
  failed,
}

/// 2026-10-26: 4단계 기기 기록에서 판단할 홈 보조 상태. 3단계에서는 호출자가 명시적으로 넘긴다.
enum HomeSalaryRecord {
  /// 2026-10-26: 기록 없음(기본).
  none,

  /// 2026-10-26: 사용자가 지난 회차 월급이 아직 입금되지 않았다고 알렸다. 입금 근거·계산에는 쓰지 않는다.
  reportedNotDeposited,

  /// 2026-10-26: 첫 계산을 정보 부족으로 끝낸 뒤 홈에서 해결했다. 첫 계산 과정을 골라 볼 수 있다.
  resolvedAfterFirstCalc,
}

/// 2026-10-23: 계산을 마친 홈. 정상·음수·정보 부족·입금 대기를 같은 틀에서 구분해 보인다.
/// 2026-10-26: 확정 시안(v78) 구조로 바꾸고 '계산 내역 보기'로 같은 계산 결과의 02-2를 연다.
class _HomeReady extends StatelessWidget {
  /// 2026-10-26: 스냅샷·결과 [calculation], 기기 기록 상태 [record], 다시 불러오기 [onReload],
  /// 새로고침 실패 여부 [refreshFailed](이전 결과를 유지한 채 안내 띠를 보임)로 만든다.
  const _HomeReady({
    required this.calculation,
    required this.record,
    required this.onReload,
    required this.refreshFailed,
  });

  final HomeCalculationReady calculation;
  final HomeSalaryRecord record;
  final VoidCallback onReload;
  final bool refreshFailed;

  /// 2026-10-26: 머리·주기 줄·금액·상태 안내·장부를 스크롤 영역에 두고 '계산 내역 보기' 띠 버튼을 화면 아래에 고정한다.
  @override
  Widget build(BuildContext context) {
    final result = calculation.result;
    final barState = compositionBarStateOf(result);
    final showBar =
        barState == CompositionBarState.positive ||
        barState == CompositionBarState.zero;
    final awaiting =
        result.salaryCycle?.state == calc.SalaryCycleState.awaitingDeposit;
    final u = result.u;
    final absent =
        u == null &&
        result.insufficient.contains(
          calc.InsufficientReason.receiptEvidenceAbsent,
        );
    final reported = absent && record == HomeSalaryRecord.reportedNotDeposited;
    final resolved =
        u != null && record == HomeSalaryRecord.resolvedAfterFirstCalc;
    final payDay = result.salaryCycle?.previousPayDate?.date;

    final notice = <Widget>[];
    if (u != null && u < 0) {
      notice.add(
        StatusNotice(
          key: const ValueKey('home-negative-notice'),
          kind: StatusNoticeKind.warning,
          title: '계획한 금액보다 잔액이 부족해요',
          message: '모아둘 돈과 예정 지출을 모두 확보하려면 ${formatKrw(-u)}이 더 필요해요.',
        ),
      );
    } else if (awaiting) {
      final waiting =
          result.placementTotals?[calc.ObligationPlacement.awaitingSalary];
      notice.add(
        StatusNotice(
          key: const ValueKey('home-awaiting-notice'),
          kind: StatusNoticeKind.warning,
          title: '월급 입금 확인 전이에요',
          message: waiting == null
              ? null
              : '예정 지출 ${formatKrw(waiting.totalKrw)}은 현재 금액에 포함하지 않았어요. '
                    '입금이 확인되면 다음 기간의 지출과 함께 다시 계산해요.',
        ),
      );
    }

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HomeHeader(onReload: onReload),
                  if (refreshFailed)
                    _RefreshFailedNotice(
                      title: '새 정보를 불러오지 못했어요',
                      body: '이전에 불러온 정보를 보여드려요',
                      onRetry: onReload,
                    ),
                  _padded(
                    _CycleLine(
                      cycle: result.salaryCycle,
                      today: result.context.businessDate,
                      progress: result.cycleProgress,
                      salaryCheck: absent && !reported,
                    ),
                  ),
                  const SizedBox(height: PayseSpace.section),
                  _padded(
                    AmountHero(
                      label: HomeScreen.amountLabel,
                      amountKrw: u,
                      asOfLabel: asOfLabel(result.context.asOf),
                      message: u == null && !reported
                          ? _insufficientText(result, payDay)
                          : null,
                      unavailableLabel: absent && !reported
                          ? '아직 계산할 수 없어요'
                          : null,
                    ),
                  ),
                  if (reported) ...[
                    const SizedBox(height: PayseSpace.x3),
                    _padded(
                      Align(
                        alignment: Alignment.centerLeft,
                        child: StatusLabel(
                          key: const ValueKey('home-reported-label'),
                          text: payDay == null
                              ? '예정 월급 미입금 · 내가 확인한 상태'
                              : '${md(payDay)} 예정 월급 미입금 · 내가 확인한 상태',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _padded(
                      const Text(
                        '현재는 쓸 수 있는 돈을 계산하기 어려워요. 입금되면 아래에서 거래를 선택해 주세요.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 20 / 14,
                          color: PayseColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                  if (absent) ...[
                    const SizedBox(height: PayseSpace.x5),
                    _padded(
                      const _WideOutlinedButton(
                        key: ValueKey('home-salary-check-button'),
                        label: '월급 입금 확인하기',
                        onPressed: null,
                      ),
                    ),
                  ],
                  if (showBar)
                    _padded(CompositionBar(result: result, showLegend: false)),
                  if (notice.isNotEmpty) ...[
                    const SizedBox(height: PayseSpace.x5),
                    ...notice,
                  ],
                  SizedBox(
                    height: notice.isNotEmpty
                        ? PayseSpace.x5
                        : absent
                        ? PayseSpace.x6
                        : PayseSpace.section,
                  ),
                  _padded(
                    _HomeLedger(
                      result: result,
                      chips: showBar,
                      awaiting: awaiting,
                      onOpenDetail: () => _openDetail(context),
                    ),
                  ),
                  if (resolved) ...[
                    const SizedBox(height: PayseSpace.x6),
                    _padded(
                      const _WideOutlinedButton(
                        key: ValueKey('home-first-calc-button'),
                        label: '처음 계산 과정을 단계별로 보기',
                        onPressed: null,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),
          PrimaryButton(
            key: const ValueKey('home-detail-button'),
            label: '계산 내역 보기',
            onPressed: () => _openDetail(context),
          ),
        ],
      ),
    );
  }

  /// 2026-10-26: 같은 계산 결과로 02-2 계산 내역을 연다.
  void _openDetail(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CalculationDetailScreen(calculation: calculation),
      ),
    );
  }

  /// 2026-10-23: 화면 좌우 여백을 적용한다.
  static Widget _padded(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: PayseSpace.screenHorizontal,
    ),
    child: child,
  );

  /// 2026-10-26: 정보 부족 사유 문장. 지난 회차 근거가 없고 예정일을 알면 'M/D에 예정된 월급의 입금 여부를 확인할 정보가 없어요.'다.
  static String _insufficientText(
    calc.CurrentAmountResult result,
    calc.BusinessDate? payDay,
  ) {
    final reasons = result.insufficient;
    final first = reasons.isEmpty ? null : reasons.first;
    if (first == calc.InsufficientReason.receiptEvidenceAbsent &&
        payDay != null) {
      return '${md(payDay)}에 예정된 월급의 입금 여부를 확인할 정보가 없어요.';
    }
    return insufficientMessage(first);
  }
}

/// 2026-10-26: 'PAYSE' 표기와 다시 불러오기 아이콘 버튼.
class _HomeHeader extends StatelessWidget {
  /// 2026-10-26: 다시 불러오기 [onReload]로 만든다. null이면 새로고침 중이라 버튼 대신 '[달] 불러오는 중'을 보인다.
  const _HomeHeader({required this.onReload});

  final VoidCallback? onReload;

  /// 2026-10-26: 머리 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        18,
        PayseSpace.screenHorizontal - 10,
        PayseSpace.x1,
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'PAYSE',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.18 * 19,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          SizedBox(
            height: PayseSize.touchMin,
            child: onReload == null
                ? Semantics(
                    key: const ValueKey('home-refreshing'),
                    liveRegion: true,
                    label: '불러오는 중',
                    excludeSemantics: true,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoadingMoon(),
                          SizedBox(width: PayseSpace.x2),
                          Text(
                            '불러오는 중',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: PayseColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : IconButton(
                    key: const ValueKey('home-reload'),
                    tooltip: '다시 불러오기',
                    icon: const Icon(Icons.refresh, size: 22),
                    color: PayseColors.textPrimary,
                    onPressed: onReload,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-26: 홈 전용 장부(design.md §6). 계좌 잔액 B, 모아둘 돈 R−O, 예정 지출 E를 같은 계산 결과로 보인다.
class _HomeLedger extends StatelessWidget {
  /// 2026-10-26: 계산 결과 [result], 색 칩 표시 [chips], 입금 대기 [awaiting], 02-2 열기 [onOpenDetail]로 만든다.
  const _HomeLedger({
    required this.result,
    required this.chips,
    required this.awaiting,
    required this.onOpenDetail,
  });

  final calc.CurrentAmountResult result;
  final bool chips;
  final bool awaiting;
  final VoidCallback onOpenDetail;

  /// 2026-10-26: 위 구분선과 세 행을 반환한다. 값을 모르면 '계산 불가'이고 화살표를 두지 않는다.
  @override
  Widget build(BuildContext context) {
    final b = result.b;
    final rEff = result.rEff;
    final e = result.e;
    final reserveCount = result.reserveLines?.length;
    final scheduledCount =
        result
            .placementTotals?[calc.ObligationPlacement.inCurrentPeriod]
            ?.count ??
        0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(
          height: 1,
          thickness: 1,
          color: PayseColors.dividerSection,
        ),
        _HomeLedgerRow(
          key: const ValueKey('home-row-balance'),
          name: '계좌 잔액',
          strong: true,
          amount: b == null ? null : formatKrw(b),
        ),
        _HomeLedgerRow(
          key: const ValueKey('home-row-reserve'),
          name: '모아둘 돈',
          chip: chips ? PayseColors.reserve : null,
          subtitle: rEff == null || reserveCount == null
              ? null
              : '$reserveCount건',
          amount: _minus(rEff),
          onTap: rEff == null ? null : onOpenDetail,
        ),
        _HomeLedgerRow(
          key: const ValueKey('home-row-scheduled'),
          name: '예정 지출',
          chip: chips ? PayseColors.scheduled : null,
          label: awaiting ? '입금 확인 대기' : null,
          subtitle: e == null || awaiting ? null : '월급일 전 $scheduledCount건',
          amount: _minus(e),
          onTap: e == null ? null : onOpenDetail,
        ),
      ],
    );
  }

  /// 2026-10-26: 차감 금액 표기. 0원이 아니면 앞에 −, 값이 없으면 null(계산 불가)이다.
  static String? _minus(int? amountKrw) => amountKrw == null
      ? null
      : amountKrw == 0
      ? formatKrw(0)
      : formatKrw(-amountKrw);
}

/// 2026-10-26: 홈 전용 장부 한 행. 이름(+칩·상태 라벨, 보조 줄) … 금액(원 끝선) · 24dp 화살표 칸.
/// 왼쪽 마이너스 선이 없고 금액이 잘리지 않으며(행 폭의 60%를 넘으면 비율 축소), 누를 수 있으면 최소 48dp다.
class _HomeLedgerRow extends StatelessWidget {
  /// 2026-10-26: 이름 [name], 굵게 [strong], 칩 [chip], 상태 라벨 [label], 보조 줄 [subtitle],
  /// 금액 [amount](null이면 '계산 불가'), 누름 [onTap](null이면 화살표 없음)으로 만든다.
  const _HomeLedgerRow({
    super.key,
    required this.name,
    this.strong = false,
    this.chip,
    this.label,
    this.subtitle,
    required this.amount,
    this.onTap,
    this.skeleton = false,
    this.missingText = '계산 불가',
  });

  final String name;
  final bool strong;
  final Color? chip;
  final String? label;
  final String? subtitle;
  final String? amount;
  final VoidCallback? onTap;

  /// 2026-10-26: true면 금액 자리에 회색 로딩 틀을 둔다(새로고침 중).
  final bool skeleton;

  /// 2026-10-26: 금액을 모를 때의 문구(기본 '계산 불가').
  final String missingText;

  /// 2026-10-26: 행을 반환한다.
  @override
  Widget build(BuildContext context) {
    final value = amount;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: name,
                    children: [
                      if (chip != null)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: SizedBox(
                              width: 8,
                              height: 8,
                              child: ColoredBox(color: chip!),
                            ),
                          ),
                        ),
                      if (label != null)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: StatusLabel(text: label!),
                          ),
                        ),
                    ],
                  ),
                  style: PayseTypography.ledgerName.copyWith(
                    fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 18 / 12,
                      color: PayseColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: PayseSpace.x3),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  (MediaQuery.sizeOf(context).width -
                      PayseSpace.screenHorizontal * 2) *
                  0.6,
            ),
            child: skeleton
                ? const SizedBox(
                    width: 88,
                    height: 22,
                    child: Center(child: _Bar(width: 88, height: 14)),
                  )
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      value ?? missingText,
                      key: const ValueKey('home-row-amount'),
                      maxLines: 1,
                      softWrap: false,
                      semanticsLabel: value ?? missingText,
                      style: value == null
                          ? PayseTypography.ledgerName.copyWith(
                              color: PayseColors.textSecondary,
                            )
                          : PayseTypography.ledgerAmount,
                    ),
                  ),
          ),
          SizedBox(
            width: 24,
            child: onTap == null
                ? null
                : const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: PayseColors.textSecondary,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
    const line = Divider(
      height: 1,
      thickness: 1,
      color: PayseColors.dividerRow,
    );
    final body = onTap == null
        ? row
        : Semantics(
            button: true,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PayseSize.touchMin,
                ),
                child: row,
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [body, line],
    );
  }
}

/// 2026-10-26: 전체 폭 테두리 버튼(높이 48·반경 8, 15/600). [onPressed]가 null이면 비활성(회색 글자·경계)이다.
class _WideOutlinedButton extends StatelessWidget {
  /// 2026-10-26: 글자 [label]과 누름 [onPressed]로 만든다.
  const _WideOutlinedButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  /// 2026-10-26: 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x3),
        foregroundColor: PayseColors.textPrimary,
        disabledForegroundColor: PayseColors.textSecondary,
        side: BorderSide(
          color: enabled
              ? PayseColors.borderStrong
              : PayseColors.dividerSection,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PayseRadius.sm),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}

/// 2026-10-23: 정보 부족 사유 [reason]의 안내 문장을 반환한다. 0원으로 대신하지 않는 이유를 알린다.
String insufficientMessage(calc.InsufficientReason? reason) => switch (reason) {
  calc.InsufficientReason.receiptEvidenceAbsent =>
    '지난 월급 입금 정보를 확인할 수 없어 계산하지 않았어요.',
  calc.InsufficientReason.receiptEvidenceUnavailable =>
    '월급 입금 정보를 받지 못해 계산하지 않았어요.',
  calc.InsufficientReason.payDateConflict =>
    '월급 예정일이 겹쳐 다음 월급일까지 쓸 수 있는 돈을 계산하지 못했어요.',
  calc.InsufficientReason.salaryDayMissing ||
  calc.InsufficientReason.salarySettingsMissing => '월급일을 알 수 없어 계산하지 않았어요.',
  calc.InsufficientReason.balanceMissing => '일부 계좌 잔액을 불러오지 못해 계산하지 않았어요.',
  calc.InsufficientReason.balanceAsOfMismatch =>
    '계좌 잔액의 기준 시각이 서로 달라 계산하지 않았어요.',
  calc.InsufficientReason.noIncludedAccount => '계산할 계좌를 고르지 않았어요.',
  calc.InsufficientReason.obligationsMissing ||
  calc.InsufficientReason.settlementsMissing => '예정 지출 정보를 모두 받지 못해 계산하지 않았어요.',
  calc.InsufficientReason.reservesMissing ||
  calc.InsufficientReason.allocationsMissing => '모아둘 돈 정보를 모두 받지 못해 계산하지 않았어요.',
  _ => '필요한 정보를 모두 받지 못해 계산하지 않았어요.',
};

/// 2026-10-23: 기준 시각 [asOf](오프셋 포함)를 서울 시각 'M월 D일 HH:mm 기준'으로 바꾼다. 다른 계산은 하지 않는다.
String asOfLabel(String asOf) {
  final seoul = DateTime.parse(asOf).toUtc().add(const Duration(hours: 9));
  final hh = seoul.hour.toString().padLeft(2, '0');
  final mm = seoul.minute.toString().padLeft(2, '0');
  return '${seoul.month}월 ${seoul.day}일 $hh:$mm 기준';
}

/// 2026-10-23: 달 그림과 월급 주기 상태 줄(09-14·09-15 포함).
class _CycleLine extends StatelessWidget {
  /// 2026-10-23: 월급 구간 [cycle](null이면 월급 설정 미수신)과 기준 날짜 [today]로 만든다.
  /// 2026-10-26: 계산 패키지의 주기 진행률 [progress]로 달을 그리고, 지난 회차 입금 확인이 필요한 정보 부족이면
  /// [salaryCheck]로 상태명을 '월급 입금 확인 필요'로 쓴다.
  const _CycleLine({
    required this.cycle,
    required this.today,
    required this.progress,
    required this.salaryCheck,
  });

  final calc.SalaryCycle? cycle;
  final calc.BusinessDate today;
  final double? progress;
  final bool salaryCheck;

  /// 2026-10-23: 상태 문장을 반환한다. 남은 날수는 구간 끝과 기준 날짜의 날짜 차이다.
  String get text {
    final c = cycle;
    if (c == null || c.state == calc.SalaryCycleState.insufficientData) {
      return salaryCheck ? '월급 입금 확인 필요' : '월급 정보 확인 필요';
    }
    if (c.state == calc.SalaryCycleState.awaitingDeposit) {
      return c.previousPayDate!.date == today
          ? '오늘은 월급일 · 입금 확인 전'
          : '월급 입금 확인 전';
    }
    final end = c.periodEnd!;
    final days = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    return '월급까지 $days일';
  }

  /// 2026-10-23: 정상 구간이면 'M/D – M/D'(끝 전날까지)를, 시작을 모르면 '~ M/D'를 반환한다. 그 밖에는 null이다.
  String? get range {
    final c = cycle;
    if (c == null || c.state != calc.SalaryCycleState.normal) return null;
    final last = c.periodEnd!.addDays(-1);
    final start = c.periodStart;
    final end = '${last.month}/${last.day}';
    return start == null ? '~ $end' : '${start.month}/${start.day} – $end';
  }

  /// 2026-10-23: 달 그림·상태 문장과 오른쪽 구간 날짜를 반환한다.
  /// 2026-10-26: 확정 시안(v78)대로 달 39dp·간격 12, 줄 아래 구분선을 화면 여백 안에 둔다.
  @override
  Widget build(BuildContext context) {
    final r = range;
    final c = cycle;
    final lit = c == null || c.state == calc.SalaryCycleState.insufficientData
        ? null
        : moonLitFraction(
            progress: progress,
            awaiting: c.state == calc.SalaryCycleState.awaitingDeposit,
          );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerSection)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            CycleMoon(key: const ValueKey('home-cycle-moon'), lit: lit),
            const SizedBox(width: PayseSpace.x3),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: PayseSpace.x2,
                children: [
                  Text(text, style: PayseTypography.meta),
                  if (r != null) Text(r, style: PayseTypography.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-23: 데이터·예상 못한 오류 화면. 이전 금액을 보이지 않고 다시 불러오기를 준다.
class _HomeError extends StatelessWidget {
  /// 2026-10-23: 제목 [title], 설명 [message], 다시 불러오기 [onReload]로 만든다.
  const _HomeError({
    super.key,
    required this.title,
    required this.message,
    required this.onReload,
  });

  final String title;
  final String message;
  final VoidCallback onReload;

  /// 2026-10-23: 안내와 다시 불러오기 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: PayseSpace.section),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
            ),
            child: Text(
              HomeScreen.amountLabel,
              style: PayseTypography.amountLabel,
            ),
          ),
          const SizedBox(height: PayseSpace.x4),
          StatusNotice(
            kind: StatusNoticeKind.saveFailed,
            title: title,
            message: message,
          ),
          const Spacer(),
          PrimaryButton(label: '다시 불러오기', onPressed: onReload),
        ],
      ),
    );
  }
}

/// 2026-10-26: 회색 로딩 틀 막대.
class _Bar extends StatelessWidget {
  /// 2026-10-26: 폭 [width](null이면 가능한 만큼)과 높이 [height]로 만든다.
  const _Bar({this.width, required this.height, this.radius = 4});

  final double? width;
  final double height;
  final double radius;

  /// 2026-10-26: 막대를 반환한다.
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: PayseColors.surfaceMuted,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// 2026-10-26: 새로고침 실패 안내 띠(design.md §6). 옅은 중립 바탕, 빨간 안내 아이콘, 오른쪽 '다시 시도' 글자 버튼.
/// 좁은 화면·큰 글자에서는 버튼이 설명 바로 아래로 붙는다. 원인을 모를 수 있어 인터넷 문제로 단정하지 않는다.
class _RefreshFailedNotice extends StatelessWidget {
  /// 2026-10-26: 제목 [title], 설명 [body], 다시 시도 [onRetry]로 만든다.
  const _RefreshFailedNotice({
    required this.title,
    required this.body,
    required this.onRetry,
  });

  final String title;
  final String body;
  final VoidCallback onRetry;

  /// 2026-10-26: 안내 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('home-refresh-failed'),
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        liveRegion: true,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: PayseColors.insufficientNoticeSurface,
            border: Border.symmetric(
              horizontal: BorderSide(color: PayseColors.border),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
              vertical: PayseSpace.x3,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.error_outline,
                    size: 18,
                    color: PayseColors.error,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    spacing: PayseSpace.x3,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
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
                          Text(
                            body,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 19 / 13,
                              color: PayseColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      TextButton(
                        key: const ValueKey('home-refresh-retry'),
                        onPressed: onRetry,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(44, PayseSize.touchMin),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          foregroundColor: PayseColors.textPrimary,
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 새로고침 중 홈(최초 로딩과 같은 화면). 이전 숫자를 보이지 않고 같은 크기의 로딩 틀만 둔다.
class _HomeLoading extends StatelessWidget {
  /// 2026-10-26: 인자 없이 만든다.
  const _HomeLoading();

  /// 2026-10-26: 머리 로딩 표시·로딩 틀·비활성 '계산 내역 보기'를 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget padded(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
      ),
      child: child,
    );
    return SafeArea(
      key: const ValueKey('home-loading'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _HomeHeader(onReload: null),
                  padded(
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: PayseColors.dividerSection),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            MoonSkeleton(),
                            SizedBox(width: PayseSpace.x3),
                            _Bar(width: 96, height: 14),
                            Spacer(),
                            _Bar(width: 72, height: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: PayseSpace.section),
                  padded(
                    const Text(
                      HomeScreen.amountLabel,
                      style: PayseTypography.amountLabel,
                    ),
                  ),
                  const SizedBox(height: PayseSpace.x2),
                  padded(
                    const FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: 0.62,
                      child: _Bar(height: 48, radius: 8),
                    ),
                  ),
                  const SizedBox(height: 10),
                  padded(
                    const Text(
                      '금융 정보를 불러오고 있어요',
                      style: PayseTypography.caption,
                    ),
                  ),
                  padded(
                    const Padding(
                      padding: EdgeInsets.only(top: PayseSpace.x6),
                      child: _Bar(height: 6, radius: 3),
                    ),
                  ),
                  const SizedBox(height: PayseSpace.section),
                  padded(
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: PayseColors.dividerSection,
                        ),
                        _HomeLedgerRow(
                          name: '계좌 잔액',
                          strong: true,
                          amount: null,
                          skeleton: true,
                        ),
                        _HomeLedgerRow(
                          name: '모아둘 돈',
                          amount: null,
                          skeleton: true,
                        ),
                        _HomeLedgerRow(
                          name: '예정 지출',
                          amount: null,
                          skeleton: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),
          const PrimaryButton(
            key: ValueKey('home-detail-button'),
            label: '계산 내역 보기',
            onPressed: null,
          ),
        ],
      ),
    );
  }
}

/// 2026-10-26: 표시할 이전 결과 없이 새로고침이 실패한 홈(④). 금액 자리에 '아직 계산할 수 없어요'만 두고
/// 기준 시각·설명·버튼은 넣지 않는다. 실패 원인과 다시 시도는 위쪽 안내 띠에 있다.
class _HomeLoadFailed extends StatelessWidget {
  /// 2026-10-26: 다시 시도 [onReload]로 만든다.
  const _HomeLoadFailed({required this.onReload});

  final VoidCallback onReload;

  /// 2026-10-26: 홈 틀과 실패 안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget padded(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
      ),
      child: child,
    );
    return SafeArea(
      key: const ValueKey('home-load-failed'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HomeHeader(onReload: onReload),
                  _RefreshFailedNotice(
                    title: '금융 정보를 불러오지 못했어요',
                    body: '정보를 불러온 뒤 쓸 수 있는 돈을 계산할 수 있어요',
                    onRetry: onReload,
                  ),
                  padded(
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: PayseColors.dividerSection),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            CycleMoon(
                              key: ValueKey('home-cycle-moon'),
                              lit: null,
                            ),
                            SizedBox(width: PayseSpace.x3),
                            Expanded(
                              child: Text(
                                '월급 주기를 확인할 수 없어요',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                  color: PayseColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: PayseSpace.section),
                  padded(
                    const AmountHero(
                      label: HomeScreen.amountLabel,
                      amountKrw: null,
                      unavailableLabel: '아직 계산할 수 없어요',
                    ),
                  ),
                  const SizedBox(height: PayseSpace.section),
                  padded(
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: PayseColors.dividerSection,
                        ),
                        _HomeLedgerRow(
                          name: '계좌 잔액',
                          strong: true,
                          amount: null,
                          missingText: '불러오지 못함',
                        ),
                        _HomeLedgerRow(
                          name: '모아둘 돈',
                          amount: null,
                          missingText: '불러오지 못함',
                        ),
                        _HomeLedgerRow(
                          name: '예정 지출',
                          amount: null,
                          missingText: '불러오지 못함',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),
          const PrimaryButton(
            key: ValueKey('home-detail-button'),
            label: '계산 내역 보기',
            onPressed: null,
          ),
        ],
      ),
    );
  }
}
