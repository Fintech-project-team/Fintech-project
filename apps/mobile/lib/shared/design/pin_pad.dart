import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'payse_tokens.dart';

/// 2026-10-21: PIN 입력 화면 본문(design.md §5 PinPad). 제목 → 6자리 점 → 점 아래 안내·오류 → 키패드.
/// PIN 값과 규칙 검사는 갖지 않고, 입력 개수와 문구만 받아 그린다. 키패드 숫자 순서는 고정이다.
class PinPad extends StatelessWidget {
  /// 2026-10-21: [title], 입력한 자리 수 [filled], 점 아래 문구 [message](오류면 [isError]),
  /// 키 입력 콜백 [onDigit]·[onBackspace]로 만든다. [showKeypad]가 false면 키패드를 숨긴다(09-12).
  /// [secondaryMessage]는 오류 아래 보조 설명, [auxiliaryLabel]·[onAuxiliary]는 왼쪽 아래 보조 행동이다.
  const PinPad({
    super.key,
    required this.title,
    required this.filled,
    required this.onDigit,
    required this.onBackspace,
    this.length = 6,
    this.message,
    this.isError = false,
    this.secondaryMessage,
    this.showKeypad = true,
    this.auxiliaryLabel,
    this.onAuxiliary,
  });

  static const double dotSize = 14;
  static const double dotGap = 16;
  static const double keyHeight = 64;
  static const double pressSize = 56;

  final String title;
  final int filled;
  final int length;
  final String? message;
  final bool isError;
  final String? secondaryMessage;
  final bool showKeypad;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final String? auxiliaryLabel;
  final VoidCallback? onAuxiliary;

  /// 2026-10-21: 세로 배치를 반환한다. 높이가 정해진 부모 안에서 키패드를 아래에 붙인다.
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            height: 1.4,
            fontWeight: FontWeight.w700,
            color: PayseColors.textPrimary,
          ),
        ),
        const SizedBox(height: PayseSpace.x8),
        _ErrorShake(
          error: isError ? message : null,
          child: Column(
            children: [
              PinDots(length: length, filled: filled, isError: isError),
              const SizedBox(height: PayseSpace.x4),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 20),
                child: message == null
                    ? const SizedBox.shrink()
                    : _PinMessage(text: message!, isError: isError),
              ),
            ],
          ),
        ),
        if (secondaryMessage != null) ...[
          const SizedBox(height: PayseSpace.x1),
          Text(
            secondaryMessage!,
            key: const ValueKey('pin-secondary-message'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: PayseColors.textSecondary,
            ),
          ),
        ],
        const Spacer(),
        if (showKeypad)
          _Keypad(
            onDigit: onDigit,
            onBackspace: onBackspace,
            auxiliaryLabel: auxiliaryLabel,
            onAuxiliary: onAuxiliary,
          ),
      ],
    );
  }
}

/// 2026-10-23: 오류가 새로 생기면 점과 문구를 약 0.4초 좌우로 흔들고 짧게 진동한다(design.md §5 PinPad).
/// 기기의 움직임 줄이기 설정이 켜져 있으면 흔들지 않고 진동만 준다.
class _ErrorShake extends StatefulWidget {
  /// 2026-10-23: 현재 오류 문구 [error](오류가 없으면 null)와 흔들 [child]로 만든다.
  const _ErrorShake({required this.error, required this.child});

  final String? error;
  final Widget child;

  /// 2026-10-23: 흔들림 상태 객체를 반환한다.
  @override
  State<_ErrorShake> createState() => _ErrorShakeState();
}

/// 2026-10-23: 흔들림 진행을 보관한다.
class _ErrorShakeState extends State<_ErrorShake>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  /// 2026-10-23: 오류가 없던 상태에서 생기거나 다른 오류로 바뀌면 흔든다. 같은 오류가 유지되면 다시 흔들지 않는다.
  @override
  void didUpdateWidget(covariant _ErrorShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    final error = widget.error;
    if (error == null || error == oldWidget.error) return;
    HapticFeedback.mediumImpact();
    if (MediaQuery.disableAnimationsOf(context)) return;
    _shake.forward(from: 0);
  }

  /// 2026-10-23: 흔들림 컨트롤러를 폐기한다.
  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  /// 2026-10-23: 좌우 이동 폭이 점점 줄어드는 흔들림을 적용한 자식을 반환한다(최대 8dp, 3번 왕복).
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      key: const ValueKey('pin-shake'),
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        final dx = sin(t * pi * 6) * 8 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}

/// 2026-10-21: PIN 자리 표시 점. 입력한 자리는 charcoal, 오류면 모두 error 색.
class PinDots extends StatelessWidget {
  /// 2026-10-21: 전체 자리 [length], 입력 자리 [filled], 오류 여부 [isError]로 만든다.
  const PinDots({
    super.key,
    required this.length,
    required this.filled,
    this.isError = false,
  });

  final int length;
  final int filled;
  final bool isError;

  /// 2026-10-21: 14dp 점을 16dp 간격으로 늘어놓아 반환한다. 읽기 보조에는 입력 자리 수를 알린다.
  @override
  Widget build(BuildContext context) {
    final ink = isError ? PayseColors.error : PayseColors.charcoal;
    final ring = isError ? PayseColors.error : PayseColors.borderStrong;
    return Semantics(
      label: '$length자리 중 $filled자리 입력',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < length; i++) ...[
            if (i > 0) const SizedBox(width: PinPad.dotGap),
            Container(
              key: ValueKey('pin-dot-$i'),
              width: PinPad.dotSize,
              height: PinPad.dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? ink : null,
                border: i < filled ? null : Border.all(color: ring, width: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-21: 점 아래 13 문구. 오류면 아이콘과 error 색을 함께 쓴다.
class _PinMessage extends StatelessWidget {
  /// 2026-10-21: 문구 [text]와 오류 여부 [isError]로 만든다.
  const _PinMessage({required this.text, required this.isError});

  final String text;
  final bool isError;

  /// 2026-10-21: 가운데 정렬한 안내 한 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final color = isError ? PayseColors.error : PayseColors.textSecondary;
    return Row(
      key: const ValueKey('pin-message'),
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isError) ...[
          Icon(Icons.error_outline, size: 14, color: color),
          const SizedBox(width: PayseSpace.x1),
        ],
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: color),
          ),
        ),
      ],
    );
  }
}

/// 2026-10-21: 흰 바탕 3×4 키패드. 1~9, 보조 행동, 0, 지우기 순서로 고정한다.
class _Keypad extends StatelessWidget {
  /// 2026-10-21: 숫자 [onDigit], 지우기 [onBackspace], 보조 행동 [auxiliaryLabel]·[onAuxiliary]로 만든다.
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    this.auxiliaryLabel,
    this.onAuxiliary,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final String? auxiliaryLabel;
  final VoidCallback? onAuxiliary;

  /// 2026-10-21: 네 줄의 키를 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget digit(int d) => _Key(
      key: ValueKey('pin-key-$d'),
      semanticLabel: '$d',
      onTap: () => onDigit(d),
      child: Text(
        '$d',
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w600,
          color: PayseColors.textPrimary,
          fontFeatures: PayseTypography.tabular,
        ),
      ),
    );
    final auxiliary = auxiliaryLabel != null && onAuxiliary != null
        ? _Key(
            key: const ValueKey('pin-key-auxiliary'),
            semanticLabel: auxiliaryLabel!,
            onTap: onAuxiliary!,
            child: Text(
              auxiliaryLabel!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: PayseColors.textSecondary,
              ),
            ),
          )
        : const SizedBox(height: PinPad.keyHeight);
    final backspace = _Key(
      key: const ValueKey('pin-key-backspace'),
      semanticLabel: '지우기',
      onTap: onBackspace,
      child: const Icon(
        Icons.backspace_outlined,
        size: 26,
        color: PayseColors.textPrimary,
      ),
    );
    final rows = [
      [digit(1), digit(2), digit(3)],
      [digit(4), digit(5), digit(6)],
      [digit(7), digit(8), digit(9)],
      [auxiliary, digit(0), backspace],
    ];
    return Column(
      key: const ValueKey('pin-keypad'),
      children: [
        for (final row in rows)
          Row(children: [for (final key in row) Expanded(child: key)]),
      ],
    );
  }
}

/// 2026-10-21: 키 하나. 테두리 없이 누르면 56dp 원 surfaceMuted가 보인다.
class _Key extends StatelessWidget {
  /// 2026-10-21: 표시 [child], 읽기 이름 [semanticLabel], 누름 콜백 [onTap]으로 만든다.
  const _Key({
    super.key,
    required this.child,
    required this.semanticLabel,
    required this.onTap,
  });

  final Widget child;
  final String semanticLabel;
  final VoidCallback onTap;

  /// 2026-10-21: 높이 64dp의 누를 수 있는 키를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox(
        height: PinPad.keyHeight,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: onTap,
            radius: PinPad.pressSize / 2,
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            highlightColor: PayseColors.surfaceMuted,
            splashColor: Colors.transparent,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
