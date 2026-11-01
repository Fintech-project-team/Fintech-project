import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/font_licenses.dart';
import 'package:payse/shared/design/payse_symbols.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('거래 아이콘은 번들한 Material Symbols 부분 글꼴을 쓴다', () async {
    final font = await rootBundle.load(
      'assets/fonts/MaterialSymbolsRounded-subset.ttf',
    );
    expect(font.lengthInBytes, greaterThan(0));
    for (final icon in [
      PayseSymbols.compareArrows,
      PayseSymbols.northEast,
      PayseSymbols.southWest,
      PayseSymbols.undo,
      PayseSymbols.creditCard,
      PayseSymbols.payments,
    ]) {
      expect(icon.fontFamily, 'PayseSymbols');
    }
  });

  test('Material Symbols 라이선스(Apache 2.0)를 앱 라이선스 목록에 등록한다', () async {
    registerPayseFontLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final symbols = entries.where(
      (e) => e.packages.contains('Material Symbols'),
    );
    expect(symbols, isNotEmpty);
    final text = symbols.first.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Apache License'));
  });
}
