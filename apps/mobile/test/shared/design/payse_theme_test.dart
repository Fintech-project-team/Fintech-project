import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/amount_format.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_tokens.dart';

void main() {
  group('buildPayseTheme', () {
    test('maps confirmed tokens to ColorScheme and scaffold', () {
      final theme = buildPayseTheme();

      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.primary, PayseColors.charcoal);
      expect(theme.colorScheme.secondary, PayseColors.moonYellow);
      expect(theme.colorScheme.error, PayseColors.error);
      expect(theme.scaffoldBackgroundColor, PayseColors.background);
    });

    test('provides finance colors extension in confirmed order colors', () {
      final finance = buildPayseTheme().extension<PayseFinanceColors>();

      expect(finance, isNotNull);
      expect(finance!.reserve, const Color(0xFF555A61));
      expect(finance.scheduled, const Color(0xFF9EA3AA));
      expect(finance.available, const Color(0xFFF4CF65));
      expect(finance.negative, PayseColors.error);
    });
  });

  group('Pretendard font', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('theme uses Pretendard and four bundled weights load', () async {
      expect(
        buildPayseTheme().textTheme.bodyMedium?.fontFamily,
        PayseTypography.fontFamily,
      );
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        final data = await rootBundle.load(
          'assets/fonts/Pretendard-$weight.otf',
        );
        expect(data.lengthInBytes, greaterThan(1000000));
      }
      final license = await rootBundle.loadString('assets/fonts/OFL.txt');
      expect(license, contains('SIL Open Font License'));
    });
  });

  group('amount format', () {
    test('formats integer won with commas only', () {
      expect(formatKrw(0), '0원');
      expect(formatKrw(1100000), '1,100,000원');
      expect(formatKrw(1234567890), '1,234,567,890원');
    });

    test('uses U+2212 minus and spoken label for negatives', () {
      expect(formatKrw(-120000), '−120,000원');
      expect(spokenKrw(-120000), '마이너스 120,000원');
    });
  });
}
