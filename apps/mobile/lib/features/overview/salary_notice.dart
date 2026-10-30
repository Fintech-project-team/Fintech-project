import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/salary_settings_controller.dart';
import '../connection/salary_settings_screen.dart';

/// 2026-10-29: 홈 월급 입금 확인 안내 연결. [foldedKey]는 이 사용자가 접은 안내 키, [onFoldedKey]는 접기(키)·다시 펴기(null),
/// [onEdit]은 월급 정보 편집 화면 열기다(없으면 버튼이 눌리지 않는다).
typedef SalaryNoticeControl = ({
  String? foldedKey,
  ValueChanged<String?> onFoldedKey,
  VoidCallback? onEdit,
});

/// 2026-10-29: 홈 월급 입금 확인 안내 종류. 계산 결과의 상태를 그대로 나누며 화면에서 다시 판정하지 않는다.
enum SalaryNoticeKind {
  /// 2026-10-29: 입금 대기(awaitingDeposit)이고 확인할 회차 예정일이 오늘보다 이전이다(당일은 기존 입금 확인 전 안내).
  awaiting,

  /// 2026-10-29: 지난 회차 입금 근거가 없어 계산하지 못했다(receiptEvidenceAbsent).
  absent,

  /// 2026-10-29: 입금 근거가 없거나 받지 못한 원인이 월급 계좌 연결 제한으로 확인됐다.
  unlinked,
}

/// 2026-10-29: 지금 홈에 보일 월급 입금 확인 안내. [key]가 같으면 같은 회차·같은 상태·같은 월급 설정의 안내다.
class SalaryNotice {
  /// 2026-10-29: 종류 [kind], 확인할 회차 예정일 [payDate], 접힘 기록 키 [key]로 만든다.
  const SalaryNotice({
    required this.kind,
    required this.payDate,
    required this.key,
  });

  final SalaryNoticeKind kind;
  final calc.BusinessDate? payDate;
  final String key;

  /// 2026-10-29: 큰 안내 제목을 반환한다.
  String get title => kind == SalaryNoticeKind.unlinked
      ? '월급 계좌의 은행이 연결되지 않았어요'
      : '월급 입금 확인이 필요해요';

  /// 2026-10-29: 큰 안내 설명을 반환한다. 예정일이 없으면 날짜 없는 문장이다.
  String get body {
    if (kind == SalaryNoticeKind.unlinked) {
      return '월급 계좌의 입금 내역을 볼 수 없어 입금 여부를 확인하지 못했어요. 월급 계좌가 바뀌었다면 월급 정보에서 수정해 주세요.';
    }
    final date = payDate;
    final when = date == null
        ? '예정된 월급의'
        : '${date.month}월 ${date.day}일에 예정된 월급의';
    return '$when 입금 여부를 확인하지 못했어요. 월급 정보가 바뀌었다면 수정해 주세요.';
  }
}

/// 2026-10-29: [snapshot]과 그 계산 결과 [result]로 보일 안내를 반환한다. 안내할 것이 없으면 null이다.
SalaryNotice? salaryNoticeOf(
  FinancialSnapshot snapshot,
  calc.CurrentAmountResult result,
) {
  final cycle = result.salaryCycle;
  final payDate = cycle?.previousPayDate?.date;
  final salary = snapshot.settings?.salary;
  final SalaryNoticeKind kind;
  final reasons = result.insufficient;
  if (result.u == null &&
      (salary?.salaryAccountRestricted ?? false) &&
      (reasons.contains(calc.InsufficientReason.receiptEvidenceAbsent) ||
          reasons.contains(
            calc.InsufficientReason.receiptEvidenceUnavailable,
          ))) {
    kind = SalaryNoticeKind.unlinked;
  } else if (result.u == null &&
      reasons.contains(calc.InsufficientReason.receiptEvidenceAbsent)) {
    kind = SalaryNoticeKind.absent;
  } else if (cycle?.state == calc.SalaryCycleState.awaitingDeposit &&
      payDate != null &&
      payDate.compareTo(result.context.businessDate) < 0) {
    kind = SalaryNoticeKind.awaiting;
  } else {
    return null;
  }
  final key = [
    kind.name,
    payDate == null ? '-' : '${payDate.year}-${payDate.month}-${payDate.day}',
    salary?.salaryDay ?? '-',
    salary?.salaryAmountKrw ?? '-',
    salary?.salaryAccountId ?? '-',
  ].join('|');
  return SalaryNotice(kind: kind, payDate: payDate, key: key);
}

/// 2026-10-29: 큰 안내 띠. 홈 새로고침 실패 띠와 같은 면(회색 전폭·아이콘·제목+설명·밑줄 글자 버튼)에
/// '월급 정보 확인'·'나중에 확인' 두 버튼을 둔다.
class SalaryNoticeBand extends StatelessWidget {
  /// 2026-10-29: 안내 [notice], 월급 정보 확인 [onEdit], 나중에 확인 [onLater]로 만든다.
  const SalaryNoticeBand({
    super.key,
    required this.notice,
    required this.onEdit,
    required this.onLater,
  });

  final SalaryNotice notice;
  final VoidCallback? onEdit;
  final VoidCallback onLater;

  /// 2026-10-29: 안내 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    ButtonStyle link(FontWeight weight, Color color) => TextButton.styleFrom(
      minimumSize: const Size(44, PayseSize.touchMin),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      foregroundColor: color,
      textStyle: TextStyle(
        fontSize: 14,
        fontWeight: weight,
        decoration: TextDecoration.underline,
      ),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: PayseColors.insufficientNoticeSurface,
          border: Border.symmetric(
            horizontal: BorderSide(color: PayseColors.border),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            PayseSpace.x3,
            PayseSpace.screenHorizontal,
            PayseSpace.x1,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.error_outline,
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
                      notice.title,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    Text(
                      notice.body,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 19 / 13,
                        color: PayseColors.textSecondary,
                      ),
                    ),
                    Wrap(
                      spacing: PayseSpace.x3,
                      children: [
                        TextButton(
                          key: const ValueKey('salary-notice-edit'),
                          onPressed: onEdit,
                          style: link(FontWeight.w700, PayseColors.textPrimary),
                          child: const Text('월급 정보 확인'),
                        ),
                        TextButton(
                          key: const ValueKey('salary-notice-later'),
                          onPressed: onLater,
                          style: link(
                            FontWeight.w500,
                            PayseColors.textSecondary,
                          ),
                          child: const Text('나중에 확인'),
                        ),
                      ],
                    ),
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

/// 2026-10-29: 접힌 안내 자리의 작은 표시 '월급 입금 확인 필요 ›'. 누르면 큰 안내를 다시 연다.
class SalaryNoticeFolded extends StatelessWidget {
  /// 2026-10-29: 다시 열기 [onOpen]으로 만든다.
  const SalaryNoticeFolded({super.key, required this.onOpen});

  final VoidCallback onOpen;

  /// 2026-10-29: 작은 표시를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('salary-notice-open'),
        onPressed: onOpen,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, PayseSize.touchMin),
          padding: EdgeInsets.zero,
          foregroundColor: PayseColors.textPrimary,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 16,
              color: PayseColors.textSecondary,
            ),
            SizedBox(width: 6),
            Text('월급 입금 확인 필요'),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: PayseColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-29: 월급 정보 편집 화면(01-2 '확인·수정'과 같은 화면)을 연다. 저장에 성공하면 화면을 닫고 응답 Snapshot을
/// [onSnapshot]으로 넘긴 뒤 연 화면의 아래 [bottomGap] 위에 '월급 정보를 저장했어요'를 띄운다. 입금 확인으로 표현하지 않는다.
Future<void> openSalaryEditor(
  BuildContext context, {
  required FinancialSnapshot snapshot,
  double bottomGap = PayseSpace.x3,
  required UserFinancialRepository repository,
  required VoidCallback onSessionInvalid,
  required ValueChanged<FinancialSnapshot> onSnapshot,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context)?..hideCurrentSnackBar();
  final controller = SalarySettingsController(
    repository: repository,
    snapshot: snapshot,
    onSessionInvalid: onSessionInvalid,
  );
  final saved = await Navigator.of(context).push<FinancialSnapshot>(
    MaterialPageRoute(
      builder: (route) => SalarySettingsScreen(
        controller: controller,
        onSnapshot: onSnapshot,
        onBack: () => Navigator.of(route).pop(),
        onSaved: (next) => Navigator.of(route).pop(next),
      ),
    ),
  );
  controller.dispose();
  if (saved == null) return;
  onSnapshot(saved);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('salary-saved'),
        content: const Text('월급 정보를 저장했어요'),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(PayseSpace.x4, 0, PayseSpace.x4, bottomGap),
      ),
    );
}
