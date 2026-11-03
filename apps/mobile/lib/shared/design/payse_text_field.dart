import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'payse_tokens.dart';

/// 2026-10-21: 밑줄형 입력 필드(design.md §5 PayseTextField). 화면 문구·검사 규칙을 넣지 않는다.
/// 라벨 위 → 값 → 도움말·오류 아래. 선은 기본 1px borderStrong, 포커스 2px charcoal, 오류 2px error.
/// [enabled]가 false면 수정할 수 없는 값을 점선 아래에 보여 주기만 한다.
/// 2026-11-03: 한 줄 순서는 값 → 뒤쪽 위젯(단위 등) → 지우기 버튼이다(29-5a 혜연 결정). 지우기 버튼은 포커스와 관계없이 늘 같은
/// 자리에 두고 값이 있을 때만 누를 수 있으며(비면 흐리게 비활성), 누르면 값을 지우고 이 칸에 포커스를 준다. 수정할 수 없는 칸은
/// 버튼 없이 자리만 남겨 값 위치를 맞춘다.
class PayseTextField extends StatefulWidget {
  /// 2026-10-21: [label]과 입력 [controller]로 만든다. [errorText]가 있으면 오류 상태, [helperText]는 보조 설명,
  /// [trailing]은 값 뒤·지우기 버튼 앞에 붙일 위젯(예: 단위, 인증 타이머)이다.
  /// 2026-11-03: [textAlign]은 값 정렬이다(금액은 오른쪽).
  const PayseTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hintText,
    this.errorText,
    this.helperText,
    this.enabled = true,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
    this.showClearButton = true,
    this.trailing,
    this.valueStyle,
    this.textAlign = TextAlign.start,
  });

  static const double fieldHeight = 52;
  static const double borderWidth = 1;
  static const double focusedBorderWidth = 2;
  static const double clearCircleSize = 20;

  final String label;
  final TextEditingController controller;
  final String? hintText;
  final String? errorText;
  final String? helperText;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool showClearButton;
  final Widget? trailing;
  final TextStyle? valueStyle;
  final TextAlign textAlign;

  /// 2026-10-21: 포커스·값 변화를 추적하는 상태 객체를 반환한다.
  @override
  State<PayseTextField> createState() => _PayseTextFieldState();
}

/// 2026-10-21: 포커스 여부에 따라 밑줄 굵기를 바꾸고 지우기 버튼 표시를 갱신한다.
class _PayseTextFieldState extends State<PayseTextField> {
  FocusNode? _ownFocus;

  /// 2026-10-21: 외부에서 받은 포커스 노드나 자체 노드를 반환한다.
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  /// 2026-10-21: 포커스·값 변화 감시를 시작한다.
  @override
  void initState() {
    super.initState();
    _focus.addListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  /// 2026-10-21: 바뀐 controller·포커스 노드로 감시 대상을 옮긴다.
  @override
  void didUpdateWidget(covariant PayseTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_refresh);
      _focus.addListener(_refresh);
    }
  }

  /// 2026-10-21: 감시를 해제하고 자체 포커스 노드를 폐기한다.
  @override
  void dispose() {
    _focus.removeListener(_refresh);
    widget.controller.removeListener(_refresh);
    _ownFocus?.dispose();
    super.dispose();
  }

  /// 2026-10-21: 화면을 다시 그린다. 반환값 없음.
  void _refresh() {
    if (mounted) setState(() {});
  }

  /// 2026-10-21: 라벨·입력 줄·도움말을 세로로 쌓아 반환한다.
  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null;
    final focused = _focus.hasFocus;
    final valueStyle =
        widget.valueStyle ??
        const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w500,
          color: PayseColors.textPrimary,
        );
    final line = !widget.enabled
        ? null
        : BorderSide(
            color: hasError
                ? PayseColors.error
                : focused
                ? PayseColors.charcoal
                : PayseColors.borderStrong,
            width: hasError || focused
                ? PayseTextField.focusedBorderWidth
                : PayseTextField.borderWidth,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: PayseColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          key: const ValueKey('payse-text-field-box'),
          height: PayseTextField.fieldHeight,
          decoration: line == null
              ? null
              : BoxDecoration(border: Border(bottom: line)),
          foregroundDecoration: null,
          child: widget.enabled
              ? _editableRow(valueStyle)
              : CustomPaint(
                  key: const ValueKey('payse-text-field-dashed'),
                  painter: const _DashedBottomLine(PayseColors.dividerSection),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.controller.text,
                          textAlign: widget.textAlign,
                          style: valueStyle.copyWith(
                            color: PayseColors.textSecondary,
                          ),
                        ),
                      ),
                      ..._tail(null),
                    ],
                  ),
                ),
        ),
        if (hasError || widget.helperText != null) ...[
          const SizedBox(height: 6),
          _HelperLine(
            text: widget.errorText ?? widget.helperText!,
            isError: hasError,
          ),
        ],
      ],
    );
  }

  /// 2026-10-21: 입력칸, 값이 있을 때의 지우기 버튼, 뒤쪽 위젯을 한 줄로 반환한다.
  /// 2026-11-03: 값 → 뒤쪽 위젯 → 지우기 버튼 순서다.
  Widget _editableRow(TextStyle valueStyle) {
    final hasValue = widget.controller.text.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            label: widget.label,
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              keyboardType: widget.keyboardType,
              inputFormatters: widget.inputFormatters,
              textInputAction: widget.textInputAction,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textAlign: widget.textAlign,
              style: valueStyle,
              cursorColor: PayseColors.charcoal,
              decoration: InputDecoration.collapsed(
                hintText: widget.hintText,
                hintStyle: valueStyle.copyWith(
                  fontWeight: FontWeight.w400,
                  color: PayseColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        ..._tail(
          hasValue
              ? () {
                  widget.controller.clear();
                  widget.onChanged?.call('');
                  _focus.requestFocus();
                }
              : null,
        ),
      ],
    );
  }

  /// 2026-11-03: 값 뒤에 붙는 뒤쪽 위젯과 지우기 버튼 자리를 반환한다. [onClear]가 null이면 버튼이 흐리게 비활성이고,
  /// 수정할 수 없는 칸은 버튼 없이 자리만 둔다.
  List<Widget> _tail(VoidCallback? onClear) => [
    if (widget.trailing != null) ...[
      const SizedBox(width: PayseSpace.x1),
      widget.trailing!,
    ],
    if (widget.showClearButton) ...[
      const SizedBox(width: PayseSpace.x2),
      SizedBox(
        width: PayseSize.touchMin,
        height: PayseSize.touchMin,
        child: !widget.enabled
            ? null
            : Opacity(
                opacity: onClear == null ? 0.4 : 1,
                child: IconButton(
                  key: const ValueKey('payse-text-field-clear'),
                  tooltip: '${widget.label} 지우기',
                  padding: EdgeInsets.zero,
                  icon: Container(
                    key: const ValueKey('payse-text-field-clear-circle'),
                    width: PayseTextField.clearCircleSize,
                    height: PayseTextField.clearCircleSize,
                    decoration: const BoxDecoration(
                      color: PayseColors.dividerSection,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 13,
                      color: PayseColors.onCharcoal,
                    ),
                  ),
                  onPressed: onClear,
                ),
              ),
      ),
    ],
  ];
}

/// 2026-10-21: 입력칸 아래 도움말 한 줄. 오류면 아이콘과 error 색을 함께 쓴다.
class _HelperLine extends StatelessWidget {
  /// 2026-10-21: 문구 [text]와 오류 여부 [isError]로 만든다.
  const _HelperLine({required this.text, required this.isError});

  final String text;
  final bool isError;

  /// 2026-10-21: 아이콘(오류일 때)과 12/18 문구를 반환한다.
  @override
  Widget build(BuildContext context) {
    final color = isError ? PayseColors.error : PayseColors.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isError) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline, size: 14, color: color),
          ),
          const SizedBox(width: PayseSpace.x1),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, height: 18 / 12, color: color),
          ),
        ),
      ],
    );
  }
}

/// 2026-10-28: 누르면 선택 화면을 여는 밑줄 칸. PayseTextField와 같은 라벨(13/600)·높이 52·1px borderStrong 밑줄·
/// 값(17/500)·도움말(12/18)에 오른쪽 › 18을 둔다. 값이 없으면 [placeholder]를 보조 글자색으로 보인다.
/// 2026-11-03: 월급 편집 화면 안에 있던 위젯을 예정 지출 편집과 함께 쓰도록 공통으로 옮겼다(29-5a). [locked]면 고를 수 없는 값을
/// PayseTextField 비활성과 같은 점선 아래 보조 글자색으로 보이고 ›를 두지 않는다.
class PayseSelectField extends StatelessWidget {
  /// 2026-10-28: 라벨 [label], 값 [value], 빈 값 문구 [placeholder], 도움말 [helper], 누름 [onTap](null이면 비활성),
  /// 값을 보조 글자색으로 보일지 [muted]로 만든다.
  /// 2026-11-03: [helper]를 생략할 수 있고, 잠금 [locked]를 더했다.
  const PayseSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.helper,
    this.muted = false,
    this.locked = false,
  });

  final String label;
  final String? value;
  final String placeholder;
  final String? helper;
  final VoidCallback? onTap;
  final bool muted;
  final bool locked;

  /// 2026-10-28: 라벨·값 줄·도움말을 반환한다.
  @override
  Widget build(BuildContext context) {
    final shown = value ?? placeholder;
    final secondary = locked || muted || value == null;
    final text = Text(
      shown,
      style: TextStyle(
        fontSize: 17,
        fontWeight: value == null ? FontWeight.w400 : FontWeight.w500,
        color: secondary ? PayseColors.textSecondary : PayseColors.textPrimary,
      ),
    );
    final line = Container(
      constraints: const BoxConstraints(minHeight: PayseTextField.fieldHeight),
      decoration: locked
          ? null
          : const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: PayseColors.borderStrong),
              ),
            ),
      child: Row(
        children: [
          Expanded(child: text),
          if (!locked) ...[
            const SizedBox(width: PayseSpace.x2),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: PayseColors.borderStrong,
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: !locked,
      enabled: !locked && onTap != null,
      label: '$label, $shown',
      excludeSemantics: true,
      child: InkWell(
        onTap: locked ? null : onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w600,
                color: PayseColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            if (locked)
              CustomPaint(
                painter: const _DashedBottomLine(PayseColors.dividerSection),
                child: line,
              )
            else
              line,
            if (helper case final helper?) ...[
              const SizedBox(height: 6),
              Text(
                helper,
                style: const TextStyle(
                  fontSize: 12,
                  height: 18 / 12,
                  color: PayseColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 2026-10-21: 위젯 아래쪽에 1px 점선을 그린다(수정 불가 값 표시).
class _DashedBottomLine extends CustomPainter {
  /// 2026-10-21: 선 색 [color]로 만든다.
  const _DashedBottomLine(this.color);

  final Color color;

  /// 2026-10-21: 4px 선·3px 간격 점선을 아래쪽에 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final y = size.height - 0.5;
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + 4).clamp(0, size.width), y),
        paint,
      );
    }
  }

  /// 2026-10-21: 색이 바뀌었을 때만 다시 그린다.
  @override
  bool shouldRepaint(covariant _DashedBottomLine oldDelegate) =>
      oldDelegate.color != color;
}
