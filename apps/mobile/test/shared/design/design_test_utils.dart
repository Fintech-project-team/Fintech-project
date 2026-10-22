import 'package:flutter/material.dart';
import 'package:payse/shared/design/payse_theme.dart';

/// 2026-10-20: [child]를 PAYSE 테마 화면에 넣어 반환한다. 위젯 테스트 공통 준비용.
Widget themed(Widget child) {
  return MaterialApp(
    theme: buildPayseTheme(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [child],
        ),
      ),
    ),
  );
}
