import 'package:flutter/material.dart';

import 'payse_tokens.dart';

/// 2026-10-22: 보조 버튼. 흰 바탕 1px borderStrong, 반경 8, 높이 40(터치 48), 14/600.
class SecondaryButton extends StatelessWidget {
  /// 2026-10-22: 글자 [label]과 누름 [onPressed]로 만든다.
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  /// 2026-10-22: 테두리 버튼을 반환한다. 시각 높이는 40이고 누름 영역은 48을 유지한다.
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: PayseColors.textPrimary,
        backgroundColor: PayseColors.background,
        side: const BorderSide(color: PayseColors.borderStrong),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x4),
        tapTargetSize: MaterialTapTargetSize.padded,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PayseRadius.sm),
        ),
      ),
      child: Text(label),
    );
  }
}
