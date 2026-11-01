import 'package:flutter/widgets.dart';

/// 2026-11-01: 거래 종류 선 아이콘(#163). Google Fonts Material Symbols Rounded(굵기 400, 채움 0)에서 쓰는 아이콘만 담은
/// 부분 글꼴 assets/fonts/MaterialSymbolsRounded-subset.ttf(Apache 2.0)의 문자 코드다. 아이콘을 더하려면 글꼴을 같은 설정으로
/// 다시 받아 바꾼다. Flutter 내장 Material Icons와 달리 화살표가 모두 선 모양이다.
abstract final class PayseSymbols {
  static const String _family = 'PayseSymbols';

  static const IconData compareArrows = IconData(0xe915, fontFamily: _family);
  static const IconData northEast = IconData(0xf1e1, fontFamily: _family);
  static const IconData southWest = IconData(0xf1e5, fontFamily: _family);
  static const IconData undo = IconData(0xe166, fontFamily: _family);
  static const IconData creditCard = IconData(0xe870, fontFamily: _family);
  static const IconData payments = IconData(0xef63, fontFamily: _family);
}
