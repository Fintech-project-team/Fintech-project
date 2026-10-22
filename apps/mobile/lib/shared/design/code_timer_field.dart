import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'payse_text_field.dart';
import 'payse_tokens.dart';

/// 2026-10-21: 인증번호 입력과 표시용 타이머(design.md §5 CodeTimerField).
/// 남은 시간은 호출자가 계산해 넘긴다. 세션 만료·잠금과 관계없고 0:00 아래로 표시하지 않는다.
class CodeTimerField extends StatelessWidget {
  /// 2026-10-21: [label], [controller], 남은 시간 [remaining], 다시 받기 [onResend]로 만든다.
  /// [resendLabel]은 버튼 문구, [resendHint]는 버튼 왼쪽 안내, [errorText]는 오류 문구다.
  const CodeTimerField({
    super.key,
    required this.label,
    required this.controller,
    required this.remaining,
    required this.onResend,
    required this.resendLabel,
    this.resendHint,
    this.errorText,
    this.onChanged,
    this.autofocus = false,
    this.maxLength = 6,
  });

  final String label;
  final TextEditingController controller;
  final Duration remaining;
  final VoidCallback onResend;
  final String resendLabel;
  final String? resendHint;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int maxLength;

  /// 2026-10-21: 남은 시간을 m:ss로 바꿔 반환한다. 음수는 0:00으로 표시한다.
  static String format(Duration remaining) {
    final seconds = remaining.isNegative ? 0 : remaining.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// 2026-10-21: 입력칸(뒤쪽 타이머)과 아래 다시 받기 줄을 반환한다.
  /// 다시 받기는 표시가 0:00이 되는 순간(남은 시간 1초 미만)부터 켜진다. 표시와 같은 경계다.
  @override
  Widget build(BuildContext context) {
    final expired = remaining.inSeconds <= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PayseTextField(
          label: label,
          controller: controller,
          errorText: errorText,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(maxLength),
          ],
          onChanged: onChanged,
          showClearButton: false,
          valueStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 3.4,
            color: PayseColors.textPrimary,
            fontFeatures: PayseTypography.tabular,
          ),
          trailing: Text(
            format(remaining),
            key: const ValueKey('code-timer-text'),
            semanticsLabel: '남은 시간 ${format(remaining)}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: PayseTypography.tabular,
              color: expired
                  ? PayseColors.textPrimary
                  : PayseColors.textSecondary,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: resendHint == null
                  ? const SizedBox.shrink()
                  : Text(
                      resendHint!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: PayseColors.textSecondary,
                      ),
                    ),
            ),
            Semantics(
              button: true,
              enabled: expired,
              label: resendLabel,
              excludeSemantics: true,
              onTap: expired ? onResend : null,
              child: InkWell(
                key: const ValueKey('code-resend'),
                onTap: expired ? onResend : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PayseSize.touchMin,
                    minWidth: PayseSize.touchMin,
                  ),
                  child: Center(
                    child: Text(
                      resendLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: expired
                            ? PayseColors.textPrimary
                            : PayseColors.textSecondary,
                        decoration: expired
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: PayseColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
