import 'package:flutter/painting.dart';

/// 2026-10-20: 확정 홈 시안 기준 색 토큰. 화면에서 HEX를 직접 쓰지 않고 이 값을 참조한다.
abstract final class PayseColors {
  static const Color charcoal = Color(0xFF242629);
  static const Color moonYellow = Color(0xFFF4CF65);

  /// 2026-10-20: 현재 확정 화면에서 쓰지 않는 예비 토큰(보조 강조 바탕). 쓰기 전에 design.md에 용도를 확정한다.
  static const Color moonYellowSoft = Color(0xFFFFF3D1);

  static const Color background = Color(0xFFFFFFFF);
  static const Color surfaceMuted = Color(0xFFF1F2F4);

  static const Color textPrimary = Color(0xFF242629);
  static const Color textSecondary = Color(0xFF62676F);
  static const Color onCharcoal = Color(0xFFFFFFFF);

  static const Color dividerSection = Color(0xFFD5D8DC);
  static const Color dividerRow = Color(0xFFECEEF1);
  static const Color border = Color(0xFFE8EAED);
  static const Color borderStrong = Color(0xFF80858C);

  static const Color reserve = Color(0xFF555A61);
  static const Color scheduled = Color(0xFF9EA3AA);
  static const Color available = Color(0xFFF4CF65);

  static const Color error = Color(0xFFB42318);
  static const Color errorContainer = Color(0xFFFEF3F2);
  static const Color errorBorder = Color(0xFFFECDCA);
  static const Color warning = Color(0xFFB54708);
  static const Color warningContainer = Color(0xFFFFFAEB);
  static const Color info = Color(0xFF175CD3);
  static const Color infoContainer = Color(0xFFEFF8FF);
}

/// 2026-10-20: 간격 토큰(dp). 화면 좌우 여백은 상위 화면 레이아웃이 적용하며 확정 홈 기준 24dp다.
abstract final class PayseSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double section = 28;
  static const double x8 = 32;
  static const double screenHorizontal = 24;
  static const double buttonContentHorizontal = 24;
}

/// 2026-10-20: 모서리 반경 토큰(dp).
abstract final class PayseRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
}

/// 2026-10-20: 터치·컴포넌트 크기 토큰(dp).
abstract final class PayseSize {
  static const double touchMin = 48;
  static const double primaryBandHeight = 60;
}

/// 2026-10-20: 글자 토큰. 글꼴은 앱에 번들한 Pretendard(assets/fonts)다.
abstract final class PayseTypography {
  static const String fontFamily = 'Pretendard';

  static const double amountMax = 50;
  static const double amountUnitRatio = 0.52;
  static const double amountUnitSize = amountMax * amountUnitRatio;

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static const TextStyle amountDisplay = TextStyle(
    fontSize: amountMax,
    height: 1.12,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.045 * amountMax,
    color: PayseColors.textPrimary,
    fontFeatures: tabular,
  );

  static const TextStyle amountUnit = TextStyle(
    fontSize: amountUnitSize,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02 * amountUnitSize,
  );

  static const TextStyle amountLabel = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w600,
    color: PayseColors.textPrimary,
  );

  static const TextStyle ledgerName = TextStyle(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w500,
    color: PayseColors.textPrimary,
  );

  static const TextStyle ledgerAmount = TextStyle(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w600,
    color: PayseColors.textPrimary,
    fontFeatures: tabular,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: PayseColors.textSecondary,
  );

  static const TextStyle meta = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    color: PayseColors.textPrimary,
  );

  static const TextStyle button = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w600,
  );
}
