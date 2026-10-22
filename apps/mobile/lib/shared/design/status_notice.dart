import 'package:flutter/material.dart';

import 'payse_theme.dart';
import 'payse_tokens.dart';

/// 2026-10-20: 안내 종류. 저장 실패와 버전 충돌을 같은 모양으로 합치지 않는다.
enum StatusNoticeKind { saveFailed, versionConflict, insufficientInfo, warning }

/// 2026-10-20: 상태 안내 블록. 색만으로 구분하지 않고 아이콘·문구·행동을 함께 보인다.
class StatusNotice extends StatelessWidget {
  /// 2026-10-20: [kind]·[title]·[message]와 선택 행동([actionLabel]·[onAction])으로 만든다.
  /// 행동 인자는 둘 다 있을 때만 버튼을 보인다.
  const StatusNotice({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final StatusNoticeKind kind;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 2026-10-20: 종류별 색·아이콘을 적용한 안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    final finance = Theme.of(context).extension<PayseFinanceColors>()!;
    final (Color ink, Color fill, Color line, IconData icon) = switch (kind) {
      StatusNoticeKind.saveFailed => (
        finance.error,
        finance.errorContainer,
        finance.errorBorder,
        Icons.error_outline,
      ),
      StatusNoticeKind.versionConflict => (
        finance.warning,
        finance.warningContainer,
        finance.warning.withValues(alpha: 0.35),
        Icons.sync_problem,
      ),
      StatusNoticeKind.insufficientInfo => (
        PayseColors.textPrimary,
        PayseColors.background,
        PayseColors.borderStrong,
        Icons.info_outline,
      ),
      StatusNoticeKind.warning => (
        finance.warning,
        finance.warningContainer,
        finance.warning.withValues(alpha: 0.35),
        Icons.warning_amber_rounded,
      ),
    };

    return Container(
      key: ValueKey('status-${kind.name}'),
      width: double.infinity,
      padding: const EdgeInsets.all(PayseSpace.x4),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(PayseRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: ink),
              const SizedBox(width: PayseSpace.x2),
              Expanded(
                child: Text(
                  title,
                  style: PayseTypography.meta.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: PayseSpace.x1),
            Text(
              message!,
              style: PayseTypography.caption.copyWith(
                fontSize: 13,
                color: PayseColors.textPrimary,
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: PayseSpace.x3),
            OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                foregroundColor: PayseColors.textPrimary,
                backgroundColor: PayseColors.background,
                side: const BorderSide(color: PayseColors.borderStrong),
                minimumSize: const Size(0, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PayseRadius.sm),
                ),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
