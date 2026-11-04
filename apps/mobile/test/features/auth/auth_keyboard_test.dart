import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/auth/auth_screens.dart';
import 'package:payse/shared/design/payse_theme.dart';

/// 2026-11-04: [key] 입력칸의 TextField.
Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

/// 2026-11-04: 인증 화면 본문 아래쪽 빈 곳을 누른다.
Future<void> _tapEmpty(WidgetTester tester) async {
  final body = tester.getRect(find.byKey(const ValueKey('auth-body')));
  await tester.tapAt(Offset(body.center.dx, body.bottom - 8));
  await tester.pump();
}

/// 2026-11-04: [key] 입력칸에 포커스가 있으면 true다.
bool _focused(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  testWidgets('10-2: 입력칸 밖 빈 곳을 누르면 포커스가 풀리고, 입력칸을 누르면 다시 입력된다', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: IdentityScreen(onSubmitted: (_) {}, onBack: () {}),
      ),
    );
    await tester.tap(_field('identity-name'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await _tapEmpty(tester);
    expect(_focused(tester, 'identity-name'), isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(_field('identity-phone'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(_focused(tester, 'identity-phone'), isTrue);
    await _tapEmpty(tester);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(_focused(tester, 'identity-phone'), isFalse);
  });

  testWidgets('공통 틀: 본문 안 버튼은 빈 곳 누르기보다 먼저 동작한다', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: AuthPage(
          body: ListView(
            children: [
              const TextField(key: ValueKey('f')),
              TextButton(onPressed: () => pressed++, child: const Text('보기')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('f')));
    await tester.pump();
    await tester.tap(find.text('보기'));
    await tester.pump();
    expect(pressed, 1);
  });
}
