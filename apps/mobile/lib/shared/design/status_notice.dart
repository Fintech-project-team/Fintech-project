import 'package:flutter/material.dart';

import 'payse_theme.dart';
import 'payse_tokens.dart';
import 'secondary_button.dart';

/// 2026-10-20: 안내 종류. 저장 실패와 버전 충돌을 같은 모양으로 합치지 않는다.
enum StatusNoticeKind { saveFailed, versionConflict, insufficientInfo, warning }

/// 2026-10-20: 상태 안내 블록. 색만으로 구분하지 않고 아이콘·문구·행동을 함께 보인다.
/// 2026-10-22: 둥근 상자 대신 띠형(반경 없음, 위아래 경계선)으로 그린다. 상위 화면이 화면 폭 전체에 배치하며
/// 안쪽 좌우 여백 [horizontalPadding]으로 글자 시작선을 화면 여백에 맞춘다.
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
    this.horizontalPadding = PayseSpace.screenHorizontal,
  }) : attached = false;

  /// 2026-10-22: 아래 버튼 바로 위에 붙는 한 줄 안내. 경계선 없이 면만 그리며 [title]만 보인다.
  const StatusNotice.attached({
    super.key,
    required this.kind,
    required this.title,
    this.horizontalPadding = PayseSpace.screenHorizontal,
  }) : message = null,
       actionLabel = null,
       onAction = null,
       attached = true;

  final StatusNoticeKind kind;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final double horizontalPadding;
  final bool attached;

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
        finance.warningBorder,
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
        finance.warningBorder,
        Icons.warning_amber_rounded,
      ),
    };

    if (attached) {
      return Container(
        key: ValueKey('status-${kind.name}'),
        width: double.infinity,
        color: fill,
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: PayseSpace.x3,
        ),
        child: Semantics(
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 16, color: ink),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: PayseTypography.caption.copyWith(
                    fontSize: 13,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      key: ValueKey('status-${kind.name}'),
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: fill,
        border: Border(
          top: BorderSide(color: line),
          bottom: BorderSide(color: line),
        ),
      ),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 20, color: ink),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: PayseTypography.meta.copyWith(
                      fontSize: 15,
                      height: 22 / 15,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      message!,
                      style: PayseTypography.caption.copyWith(
                        fontSize: 13,
                        height: 19 / 13,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: PayseSpace.x3),
                    SecondaryButton(label: actionLabel!, onPressed: onAction!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
