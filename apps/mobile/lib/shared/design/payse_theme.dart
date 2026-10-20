import 'package:flutter/material.dart';

import 'payse_tokens.dart';

/// 2026-10-20: 금융 상태·구성 색을 테마로 전달하는 확장. 위젯은 Theme.of(context)로 읽는다.
@immutable
class PayseFinanceColors extends ThemeExtension<PayseFinanceColors> {
  /// 2026-10-20: 각 상태 색으로 확장 인스턴스를 만든다. 인자는 모두 필수 색이다.
  const PayseFinanceColors({
    required this.negative,
    required this.unknown,
    required this.error,
    required this.errorContainer,
    required this.errorBorder,
    required this.warning,
    required this.warningContainer,
    required this.info,
    required this.infoContainer,
    required this.reserve,
    required this.scheduled,
    required this.available,
  });

  /// 2026-10-20: 확정 라이트 토큰으로 채운 기본 인스턴스.
  static const PayseFinanceColors light = PayseFinanceColors(
    negative: PayseColors.error,
    unknown: PayseColors.textSecondary,
    error: PayseColors.error,
    errorContainer: PayseColors.errorContainer,
    errorBorder: PayseColors.errorBorder,
    warning: PayseColors.warning,
    warningContainer: PayseColors.warningContainer,
    info: PayseColors.info,
    infoContainer: PayseColors.infoContainer,
    reserve: PayseColors.reserve,
    scheduled: PayseColors.scheduled,
    available: PayseColors.available,
  );

  final Color negative;
  final Color unknown;
  final Color error;
  final Color errorContainer;
  final Color errorBorder;
  final Color warning;
  final Color warningContainer;
  final Color info;
  final Color infoContainer;
  final Color reserve;
  final Color scheduled;
  final Color available;

  /// 2026-10-20: 지정한 색만 바꾼 새 인스턴스를 반환한다. null 인자는 기존 값을 유지한다.
  @override
  PayseFinanceColors copyWith({
    Color? negative,
    Color? unknown,
    Color? error,
    Color? errorContainer,
    Color? errorBorder,
    Color? warning,
    Color? warningContainer,
    Color? info,
    Color? infoContainer,
    Color? reserve,
    Color? scheduled,
    Color? available,
  }) {
    return PayseFinanceColors(
      negative: negative ?? this.negative,
      unknown: unknown ?? this.unknown,
      error: error ?? this.error,
      errorContainer: errorContainer ?? this.errorContainer,
      errorBorder: errorBorder ?? this.errorBorder,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      info: info ?? this.info,
      infoContainer: infoContainer ?? this.infoContainer,
      reserve: reserve ?? this.reserve,
      scheduled: scheduled ?? this.scheduled,
      available: available ?? this.available,
    );
  }

  /// 2026-10-20: 테마 전환 애니메이션용 보간. other가 같은 타입이 아니면 현재 값을 반환한다.
  @override
  PayseFinanceColors lerp(PayseFinanceColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return PayseFinanceColors(
      negative: mix(negative, other.negative),
      unknown: mix(unknown, other.unknown),
      error: mix(error, other.error),
      errorContainer: mix(errorContainer, other.errorContainer),
      errorBorder: mix(errorBorder, other.errorBorder),
      warning: mix(warning, other.warning),
      warningContainer: mix(warningContainer, other.warningContainer),
      info: mix(info, other.info),
      infoContainer: mix(infoContainer, other.infoContainer),
      reserve: mix(reserve, other.reserve),
      scheduled: mix(scheduled, other.scheduled),
      available: mix(available, other.available),
    );
  }
}

/// 2026-10-20: PAYSE 라이트 테마를 만든다. 인자 없음. 다크 테마는 지원하지 않는다.
ThemeData buildPayseTheme() {
  const scheme = ColorScheme.light(
    primary: PayseColors.charcoal,
    onPrimary: PayseColors.onCharcoal,
    secondary: PayseColors.moonYellow,
    onSecondary: PayseColors.charcoal,
    surface: PayseColors.background,
    onSurface: PayseColors.textPrimary,
    onSurfaceVariant: PayseColors.textSecondary,
    surfaceContainerHighest: PayseColors.surfaceMuted,
    error: PayseColors.error,
    onError: PayseColors.onCharcoal,
    outline: PayseColors.borderStrong,
    outlineVariant: PayseColors.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: PayseTypography.fontFamily,
  );
  return base.copyWith(
    scaffoldBackgroundColor: PayseColors.background,
    textTheme: base.textTheme.apply(
      bodyColor: PayseColors.textPrimary,
      displayColor: PayseColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: PayseColors.background,
      foregroundColor: PayseColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: PayseColors.dividerRow,
      thickness: 1,
      space: 1,
    ),
    extensions: const [PayseFinanceColors.light],
  );
}
