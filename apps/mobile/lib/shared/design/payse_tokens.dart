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
  static const Color warningBorder = Color(0xFFFEDF89);
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

  static const TextStyle sectionTitle = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
    color: PayseColors.textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 13,
    height: 19 / 13,
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

/// 2026-10-22: 금융사 표시(InstitutionMark) 색. 실제 로고 대신 금융사 키 컬러의 채도를 낮춘 기본·어두운·밝은 면과 이름표 색이다.
/// 등록되지 않은 기관은 [fallback]을 쓴다. 이름 글자와 함께 표시하며 색만으로 기관을 구분하지 않는다.
abstract final class InstitutionTones {
  static const Color bookLeaf = Color(0xFFB8BCC3);
  static const Color cardStripe = Color(0xFF4A4D57);
  static const Color cardStripeOnDark = Color(0xFF9EA3AA);
  static const Color cardChip = Color(0xFFEBCB78);
  static const Color bookLabel = Color(0xFFEBB45E);

  static const InstitutionTone fallback = InstitutionTone(
    base: Color(0xFF9EA3AA),
    dark: Color(0xFF62676F),
    light: Color(0xFFC9CCD1),
  );

  static const Map<String, InstitutionTone> byCode = {
    'bank.kb': InstitutionTone(
      base: Color(0xFFE0B04F),
      dark: Color(0xFF6E675E),
      light: Color(0xFFEBCC8D),
      label: Color(0xFF6E675E),
    ),
    'bank.shinhan': InstitutionTone(
      base: Color(0xFF5774D6),
      dark: Color(0xFF3A54A8),
      light: Color(0xFF92A5E4),
    ),
    'bank.hana': InstitutionTone(
      base: Color(0xFF3E9E97),
      dark: Color(0xFF26736D),
      light: Color(0xFF82C0BB),
    ),
    'bank.ibk': InstitutionTone(
      base: Color(0xFF4D8FBF),
      dark: Color(0xFF356A90),
      light: Color(0xFF8BB6D5),
    ),
    'bank.kakao': InstitutionTone(
      base: Color(0xFFF5DA3F),
      dark: Color(0xFF4A3A36),
      light: Color(0xFFF9E88A),
      label: Color(0xFF4A3A36),
    ),
    'card.hyundai': InstitutionTone(
      base: Color(0xFF5E5F63),
      dark: Color(0xFF3E3F42),
      light: Color(0xFF5E5F63),
      stripe: cardStripeOnDark,
    ),
    'card.samsung': InstitutionTone(
      base: Color(0xFF4A58A8),
      dark: Color(0xFF333D78),
      light: Color(0xFF4A58A8),
    ),
    'card.woori': InstitutionTone(
      base: Color(0xFF5BA3CC),
      dark: Color(0xFF3F7A9C),
      light: Color(0xFF5BA3CC),
    ),
    'card.kb': InstitutionTone(
      base: Color(0xFFE0B04F),
      dark: Color(0xFF6E675E),
      light: Color(0xFFE0B04F),
    ),
  };

  /// 2026-10-22: 기관 코드 [code]의 색 묶음을 반환한다. 없으면 [fallback]이다.
  static InstitutionTone of(String code) => byCode[code] ?? fallback;
}

/// 2026-10-22: 한 금융사의 표시 색 묶음. 기본 면 [base], 그늘 [dark], 밝은 면 [light], 통장 이름표 [label], 카드 자기띠 [stripe].
class InstitutionTone {
  /// 2026-10-22: 면 색과 선택 색으로 만든다. 이름표·자기띠를 생략하면 공통 색을 쓴다.
  const InstitutionTone({
    required this.base,
    required this.dark,
    required this.light,
    this.label = InstitutionTones.bookLabel,
    this.stripe = InstitutionTones.cardStripe,
  });

  final Color base;
  final Color dark;
  final Color light;
  final Color label;
  final Color stripe;
}
