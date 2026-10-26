import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/amount_format.dart';
import '../../shared/design/amount_hero.dart';
import '../../shared/design/ledger_row.dart';
import '../../shared/design/moon_glyph.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/status_notice.dart';
import '../../shared/design/payse_tokens.dart';
import 'calculation_detail_screen.dart';
import 'home_calculation.dart';

/// 2026-10-23: 02-1 홈. 공유 계산 결과 [calculation]만 표시하며 금액을 직접 계산하지 않는다.
/// 데이터 오류·예상하지 못한 오류에서는 이전 금액을 보이지 않고 [onReload]로 다시 불러온다.
class HomeScreen extends StatelessWidget {
  /// 2026-10-23: 계산 결과 [calculation]과 다시 불러오기 [onReload]로 만든다.
  const HomeScreen({
    super.key,
    required this.calculation,
    required this.onReload,
  });

  final HomeCalculation calculation;
  final VoidCallback onReload;

  static const String amountLabel = '다음 월급일까지 쓸 수 있는 돈';

  /// 2026-10-23: 계산 상태에 맞는 홈 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return switch (calculation) {
      final HomeCalculationReady ready => _HomeReady(calculation: ready),
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

/// 2026-10-23: 계산을 마친 홈. 정상·음수·정보 부족·입금 대기를 같은 틀에서 구분해 보인다.
/// 2026-10-26: '계산 내역 보기'로 같은 계산 결과의 02-2를 연다.
class _HomeReady extends StatelessWidget {
  /// 2026-10-23: 계산 결과로 만든다.
  /// 2026-10-26: 02-2에 그대로 넘기도록 스냅샷과 결과를 함께 담은 [calculation]을 받는다.
  const _HomeReady({required this.calculation});

  final HomeCalculationReady calculation;

  /// 2026-10-23: 주기 줄·금액·안내·장부를 세로로 반환한다.
  /// 2026-10-26: 장부 아래 '계산 내역 보기' 버튼을 붙인다.
  @override
  Widget build(BuildContext context) {
    final result = calculation.result;
    final awaiting = [
      for (final line
          in result.obligationLines ?? const <calc.ObligationLine>[])
        if (line.placement == calc.ObligationPlacement.awaitingSalary) line,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _padded(
              const Padding(
                padding: EdgeInsets.only(top: PayseSpace.x4),
                child: Text('PAYSE', style: PayseTypography.meta),
              ),
            ),
            _padded(
              _CycleLine(
                cycle: result.salaryCycle,
                today: result.context.businessDate,
              ),
            ),
            const Divider(
              height: 1,
              thickness: 1,
              color: PayseColors.dividerSection,
            ),
            const SizedBox(height: PayseSpace.section),
            _padded(
              AmountHero(
                label: HomeScreen.amountLabel,
                amountKrw: result.u,
                asOfLabel: asOfLabel(result.context.asOf),
                message: _heroMessage(result),
              ),
            ),
            if (result.salaryCycle?.state ==
                    calc.SalaryCycleState.awaitingDeposit &&
                awaiting.isNotEmpty) ...[
              const SizedBox(height: PayseSpace.x5),
              StatusNotice(
                key: const ValueKey('home-awaiting-notice'),
                kind: StatusNoticeKind.warning,
                title: '월급 입금이 확인되면 반영할 예정 지출이 있어요',
                message:
                    '${awaiting.length}건 · ${formatKrw(_sum(awaiting))}을 아직 빼지 않았어요. 취소되거나 낸 것으로 바뀐 것은 아니에요.',
              ),
            ],
            const SizedBox(height: PayseSpace.section),
            const Divider(
              height: 1,
              thickness: 1,
              color: PayseColors.dividerSection,
            ),
            ..._ledger(result),
            const SizedBox(height: 22),
            PrimaryButton(
              key: const ValueKey('home-detail-button'),
              label: '계산 내역 보기',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CalculationDetailScreen(calculation: calculation),
                ),
              ),
            ),
            const SizedBox(height: PayseSpace.x6),
          ],
        ),
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

  /// 2026-10-23: 장부 행(계좌 잔액 B, 모아둘 돈 R−O, 예정 지출 E)을 반환한다. 값이 없는 행은 그리지 않는다.
  /// 세 행의 금액은 U=B−E−(R−O)와 같은 계산 결과에서 가져온다.
  static List<Widget> _ledger(calc.CurrentAmountResult result) {
    final rows = <Widget>[];
    void add(Widget row) {
      if (rows.isNotEmpty) {
        rows.add(
          _padded(
            const Divider(
              height: 1,
              thickness: 1,
              color: PayseColors.dividerRow,
            ),
          ),
        );
      }
      rows.add(_padded(row));
    }

    final b = result.b;
    if (b != null) {
      add(LedgerRow(name: '계좌 잔액', amountKrw: b, emphasizeName: true));
    }
    final rEff = result.rEff;
    if (rEff != null) {
      final o = result.o ?? 0;
      add(
        LedgerRow(
          name: '모아둘 돈',
          amountKrw: rEff,
          isDeduction: true,
          chipColor: PayseColors.reserve,
          subtitle: o > 0
              ? '설정 ${formatKrw(result.r!)} 중 예정 지출에 들어 있는 ${formatKrw(o)}은 모아둘 돈에서 다시 빼지 않아요'
              : null,
        ),
      );
    }
    final e = result.e;
    if (e != null) {
      final count = (result.obligationLines ?? const <calc.ObligationLine>[])
          .where((l) => l.placement == calc.ObligationPlacement.inCurrentPeriod)
          .length;
      add(
        LedgerRow(
          name: '예정 지출',
          amountKrw: e,
          isDeduction: true,
          chipColor: PayseColors.scheduled,
          subtitle: '월급일 전 $count건',
        ),
      );
    }
    return rows;
  }

  /// 2026-10-23: 음수 부족 문장 또는 정보 부족 사유 문장을 반환한다. 정상이면 null이다.
  static String? _heroMessage(calc.CurrentAmountResult result) {
    final u = result.u;
    if (u != null) {
      return u < 0 ? '모아둘 돈과 예정 지출을 빼면 ${formatKrw(-u)}이 부족해요.' : null;
    }
    final reasons = result.insufficient;
    return insufficientMessage(reasons.isEmpty ? null : reasons.first);
  }

  /// 2026-10-23: 의무 잔여액 합계를 반환한다(표시용 합계이며 계산 패키지의 E와 별개다).
  static int _sum(List<calc.ObligationLine> lines) =>
      lines.fold(0, (total, line) => total + line.remainingKrw);
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
  const _CycleLine({required this.cycle, required this.today});

  final calc.SalaryCycle? cycle;
  final calc.BusinessDate today;

  /// 2026-10-23: 상태 문장을 반환한다. 남은 날수는 구간 끝과 기준 날짜의 날짜 차이다.
  String get text {
    final c = cycle;
    if (c == null || c.state == calc.SalaryCycleState.insufficientData) {
      return '월급 정보 확인 필요';
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
  @override
  Widget build(BuildContext context) {
    final r = range;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const MoonGlyph(),
          const SizedBox(width: PayseSpace.x2),
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
