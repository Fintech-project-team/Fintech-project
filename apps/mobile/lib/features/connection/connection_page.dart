import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-10-22: 연결 흐름 화면 틀. 위 뒤로 가기 줄 → 본문(화면 여백 안) → 아래 붙는 안내 → 아래 버튼 순서다.
/// [fullBleed]는 화면 폭 전체에 그릴 띠형 안내처럼 여백 밖에 놓을 위젯이며 본문 위에 둔다.
class ConnectionPage extends StatelessWidget {
  /// 2026-10-22: 본문 [body], 아래 버튼 [bottom], 버튼 위에 붙는 안내 [bottomNotice], 뒤로 가기 [onBack](null이면 숨김)으로 만든다.
  const ConnectionPage({
    super.key,
    required this.body,
    this.bottom,
    this.bottomNotice,
    this.onBack,
  });

  final Widget body;
  final Widget? bottom;
  final Widget? bottomNotice;
  final VoidCallback? onBack;

  /// 2026-10-22: 안전 영역 안에 화면 요소를 배치해 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerLeft,
                child: onBack == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: PayseSpace.x3),
                        child: IconButton(
                          tooltip: '뒤로',
                          icon: const Icon(Icons.chevron_left, size: 28),
                          onPressed: onBack,
                        ),
                      ),
              ),
            ),
            Expanded(child: body),
            ?bottomNotice,
            ?bottom,
          ],
        ),
      ),
    );
  }
}

/// 2026-10-22: 화면 제목(22/31, 700). 화면 읽기 프로그램에 제목으로 알린다.
class ConnectionHeading extends StatelessWidget {
  /// 2026-10-22: 제목 [title]과 보조 문장 [subtitle]로 만든다.
  const ConnectionHeading(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  /// 2026-10-22: 화면 여백 안에 제목과 보조 문장을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x2,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                height: 31 / 22,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: PayseSpace.x2),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 15,
                height: 22 / 15,
                color: PayseColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-22: 목록 묶음 이름(13/18, 600, textSecondary). [caption]은 아래 보조 설명이다.
class ConnectionSection extends StatelessWidget {
  /// 2026-10-22: 묶음 이름 [title]과 보조 설명 [caption]으로 만든다.
  const ConnectionSection(this.title, {super.key, this.caption});

  final String title;
  final String? caption;

  /// 2026-10-22: 묶음 이름 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: PayseTypography.sectionTitle),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: PayseSpace.x1),
              child: Text(caption!, style: PayseTypography.caption),
            ),
        ],
      ),
    );
  }
}

/// 2026-10-28: 연결 흐름 확인 창(01-1 해제 확인·월급 설정 나가기 확인). 흰 면 반경 8, 덮개 50%, 제목(17, 700) →
/// 설명(14, textSecondary) → 왼쪽 테두리 버튼 [secondaryLabel]과 오른쪽 차콜 버튼 [primaryLabel](높이 48).
/// 차콜 버튼이면 true, 테두리 버튼이면 false, 바깥을 눌러 닫으면 null을 반환한다.
/// 차콜 버튼은 그 상황의 주 행동을 강조한다(진행·머무르기 어느 쪽이든). 두 버튼 글자가 반 폭에 한 줄로 들어가지 않으면
/// 차콜 버튼을 위, 테두리 버튼을 아래로 세로로 쌓는다.
Future<bool?> showConnectionConfirm(
  BuildContext context, {
  required Key key,
  required String title,
  required String body,
  required String secondaryLabel,
  required Key secondaryKey,
  required String primaryLabel,
  required Key primaryKey,
}) {
  const label = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(PayseRadius.sm),
  );
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80242629),
    builder: (context) => Dialog(
      key: key,
      backgroundColor: PayseColors.background,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
      ),
      shape: shape,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                height: 1.45,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: PayseColors.textSecondary,
              ),
            ),
            const SizedBox(height: PayseSpace.x5),
            LayoutBuilder(
              builder: (context, constraints) {
                final secondary = OutlinedButton(
                  key: secondaryKey,
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: PayseColors.textPrimary,
                    side: const BorderSide(color: PayseColors.borderStrong),
                    shape: shape,
                    textStyle: label,
                  ),
                  child: Text(secondaryLabel),
                );
                final primary = FilledButton(
                  key: primaryKey,
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: PayseColors.charcoal,
                    foregroundColor: PayseColors.onCharcoal,
                    shape: shape,
                    textStyle: label,
                  ),
                  child: Text(primaryLabel),
                );
                final half = (constraints.maxWidth - PayseSpace.x2) / 2;
                final scaler = MediaQuery.textScalerOf(context);
                double width(String text) {
                  final painter = TextPainter(
                    text: TextSpan(text: text, style: label),
                    textScaler: scaler,
                    textDirection: TextDirection.ltr,
                    maxLines: 1,
                  )..layout();
                  final w = painter.width;
                  painter.dispose();
                  return w;
                }

                final fits =
                    width(secondaryLabel) + 48 <= half &&
                    width(primaryLabel) + 48 <= half;
                if (!fits) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      primary,
                      const SizedBox(height: PayseSpace.x2),
                      secondary,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: secondary),
                    const SizedBox(width: PayseSpace.x2),
                    Expanded(child: primary),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
