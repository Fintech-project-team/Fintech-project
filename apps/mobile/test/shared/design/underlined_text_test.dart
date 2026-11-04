import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_tokens.dart';
import 'package:payse/shared/design/underlined_text.dart';

/// 2026-11-04: [child]를 가운데 두고 띄운다.
Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildPayseTheme(),
    home: Scaffold(body: Center(child: child)),
  ),
);

/// 2026-11-04: [text]를 감싼 밑줄 그리기 도구. 없으면 null이다.
UnderlinePainter? _painter(WidgetTester tester, String text) {
  final paints = find.ancestor(
    of: find.text(text),
    matching: find.byType(CustomPaint),
  );
  for (final e in paints.evaluate()) {
    final p = (e.widget as CustomPaint).foregroundPainter;
    if (p is UnderlinePainter) return p;
  }
  return null;
}

void main() {
  testWidgets('글꼴 밑줄 없이 글자 상자 맨 아래에 1px 선, 크기는 그냥 글자와 같다', (tester) async {
    await _pump(
      tester,
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          UnderlinedText(
            '사용 계획 해제',
            key: ValueKey('u'),
            style: TextStyle(fontSize: 15, color: PayseColors.textPrimary),
          ),
          Text(
            '사용 계획 해제',
            key: ValueKey('t'),
            style: TextStyle(fontSize: 15, color: PayseColors.textPrimary),
          ),
        ],
      ),
    );
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('u')),
        matching: find.byType(Text),
      ),
    );
    expect(text.style?.decoration, isNot(TextDecoration.underline));
    expect(
      tester.getSize(find.byKey(const ValueKey('u'))),
      tester.getSize(find.byKey(const ValueKey('t'))),
    );
    final painter = find
        .descendant(
          of: find.byKey(const ValueKey('u')),
          matching: find.byType(CustomPaint),
        )
        .evaluate()
        .map((e) => (e.widget as CustomPaint).foregroundPainter)
        .whereType<UnderlinePainter>()
        .single;
    expect(painter.color, PayseColors.textPrimary);
    expect(UnderlinedText.thickness, 1);
  });

  testWidgets('선 색은 lineColor, 없으면 버튼 글자색을 따른다', (tester) async {
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const UnderlinedText('관리', lineColor: PayseColors.borderStrong),
          TextButton(
            onPressed: () {},
            style: TextButton.styleFrom(
              foregroundColor: PayseColors.textSecondary,
            ),
            child: const UnderlinedText('나중에 확인'),
          ),
        ],
      ),
    );
    expect(_painter(tester, '관리')?.color, PayseColors.borderStrong);
    expect(_painter(tester, '나중에 확인')?.color, PayseColors.textSecondary);
  });

  testWidgets('underline이 false면 선을 그리지 않는다', (tester) async {
    await _pump(tester, const UnderlinedText('다시 받기', underline: false));
    expect(_painter(tester, '다시 받기'), isNull);
  });

  test('앱 코드에서 글꼴 밑줄(TextDecoration.underline)을 쓰지 않는다', () {
    final users = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            !f.path.contains('zz_dev') &&
            f.readAsStringSync().contains('TextDecoration.underline'))
          f.path,
    ];
    expect(users, isEmpty);
  });
}
