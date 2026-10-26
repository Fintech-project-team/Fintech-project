import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/code_timer_field.dart';
import 'package:payse/shared/design/payse_text_field.dart';
import 'package:payse/shared/design/payse_tokens.dart';
import 'package:payse/shared/design/pin_pad.dart';
import 'package:payse/shared/design/primary_button.dart';
import 'package:payse/shared/design/selection_controls.dart';

import 'design_test_utils.dart';

/// 2026-10-21: design.md §5에 적은 입력·선택·PIN·타이머 값이 실제 위젯 값과 같은지 대조한다.

/// 2026-10-21: [finder] 컨테이너의 BoxDecoration을 반환한다.
BoxDecoration decorationOf(WidgetTester tester, Finder finder) =>
    tester.widget<Container>(finder).decoration! as BoxDecoration;

void main() {
  group('PayseTextField', () {
    testWidgets(
      'underline 52dp: 1px borderStrong → 2px charcoal on focus → 2px error',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          themed(PayseTextField(label: '이름', controller: controller)),
        );

        final box = find.byKey(const ValueKey('payse-text-field-box'));
        expect(tester.getSize(box).height, 52);
        var line = (decorationOf(tester, box).border! as Border).bottom;
        expect((line.color, line.width), (PayseColors.borderStrong, 1));

        await tester.tap(find.byType(TextField));
        await tester.pump();
        line = (decorationOf(tester, box).border! as Border).bottom;
        expect((line.color, line.width), (PayseColors.charcoal, 2));

        await tester.pumpWidget(
          themed(
            PayseTextField(
              label: '이름',
              controller: controller,
              errorText: '이름을 확인해주세요.',
            ),
          ),
        );
        line = (decorationOf(tester, box).border! as Border).bottom;
        expect((line.color, line.width), (PayseColors.error, 2));
        expect(
          find.byIcon(Icons.error_outline),
          findsOneWidget,
          reason: '오류는 색 + 아이콘 + 문구',
        );
        final label = tester.widget<Text>(find.text('이름'));
        expect(
          (label.style!.fontSize, label.style!.fontWeight),
          (13, FontWeight.w600),
        );
      },
    );

    testWidgets('clear button only with a value; disabled shows dashed line', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        themed(PayseTextField(label: '이름', controller: controller)),
      );
      expect(
        find.byKey(const ValueKey('payse-text-field-clear')),
        findsNothing,
      );

      await tester.enterText(find.byType(TextField), '홍길동');
      await tester.pump();
      final clear = find.byKey(const ValueKey('payse-text-field-clear'));
      expect(clear, findsOneWidget);
      expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
      final circle = find.byKey(
        const ValueKey('payse-text-field-clear-circle'),
      );
      expect(
        tester.getSize(circle),
        const Size(20, 20),
        reason: '시안: 지름 20 원 + 흰 ✕',
      );
      expect(decorationOf(tester, circle).shape, BoxShape.circle);
      expect(decorationOf(tester, circle).color, PayseColors.dividerSection);
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: circle, matching: find.byType(Icon)),
            )
            .color,
        PayseColors.onCharcoal,
      );
      await tester.tap(clear);
      await tester.pump();
      expect(controller.text, isEmpty);

      controller.text = '신한은행 입출금 ····1234';
      await tester.pumpWidget(
        themed(
          PayseTextField(
            label: '출금 계좌',
            controller: controller,
            enabled: false,
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(
        find.byKey(const ValueKey('payse-text-field-dashed')),
        findsOneWidget,
      );
      final value = tester.widget<Text>(find.text('신한은행 입출금 ····1234'));
      expect(value.style!.color, PayseColors.textSecondary);
    });
  });

  group('selection', () {
    testWidgets(
      'check mark: 24dp, selected charcoal + yellow check, unselected 1.5 borderStrong',
      (tester) async {
        await tester.pumpWidget(
          themed(
            const Row(
              children: [
                SelectionCheckMark(selected: true),
                SelectionCheckMark(selected: false),
              ],
            ),
          ),
        );
        final marks = find.byKey(const ValueKey('selection-check-mark'));
        expect(tester.getSize(marks.first), const Size(24, 24));

        final on = decorationOf(tester, marks.first);
        expect(on.color, PayseColors.charcoal);
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: marks.first, matching: find.byType(Icon)),
              )
              .color,
          PayseColors.moonYellow,
        );

        final off = decorationOf(tester, marks.last);
        expect(off.color, PayseColors.background);
        final side = (off.border! as Border).top;
        expect((side.color, side.width), (PayseColors.borderStrong, 1.5));
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: marks.last, matching: find.byType(Icon)),
              )
              .color,
          PayseColors.dividerSection,
        );
      },
    );

    testWidgets('check row is 48dp, reports checked state, link is separate', (
      tester,
    ) async {
      var selected = false;
      var linked = 0;
      await tester.pumpWidget(
        themed(
          StatefulBuilder(
            builder: (context, setState) => SelectionCheckRow(
              label: '서비스 이용 약관',
              prefix: '필수',
              selected: selected,
              onChanged: (v) => setState(() => selected = v),
              linkLabel: '보기',
              onLink: () => linked++,
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SelectionCheckRow)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('필수 서비스 이용 약관')),
        matchesSemantics(
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.text('서비스 이용 약관'));
      await tester.pump();
      expect(selected, isTrue);
      await tester.tap(find.text('보기'));
      expect(linked, 1);
      expect(selected, isTrue, reason: '보기는 선택을 바꾸지 않음');
    });

    testWidgets('list row is at least 64dp with the check on the right', (
      tester,
    ) async {
      await tester.pumpWidget(
        themed(
          SelectionListRow(
            title: '신한은행',
            subtitle: '입출금 ····1234',
            selected: true,
            onChanged: (_) {},
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SelectionListRow)).height,
        greaterThanOrEqualTo(64),
      );
      final mark = tester.getCenter(
        find.byKey(const ValueKey('selection-check-mark')),
      );
      expect(mark.dx, greaterThan(tester.getCenter(find.text('신한은행')).dx));
    });

    testWidgets(
      'chip: 36dp visible, 48dp touch, selected charcoal + yellow check',
      (tester) async {
        await tester.pumpWidget(
          themed(
            Row(
              children: [
                PayseChip(label: '매달', selected: true, onSelected: (_) {}),
                PayseChip(label: '매주', selected: false, onSelected: (_) {}),
              ],
            ),
          ),
        );
        final bodies = find.byKey(const ValueKey('payse-chip-body'));
        expect(tester.getSize(bodies.first).height, 36);
        expect(tester.getSize(find.byType(PayseChip).first).height, 48);
        final on = decorationOf(tester, bodies.first);
        expect(on.color, PayseColors.charcoal);
        expect(on.borderRadius, BorderRadius.circular(20));
        expect(find.byIcon(Icons.check), findsOneWidget, reason: '선택만 체크 모양');
        final off = decorationOf(tester, bodies.last);
        expect((off.border! as Border).top.color, PayseColors.borderStrong);
      },
    );

    testWidgets(
      'toggle: 52x32, no icons, knob side and colors change, toggled semantics',
      (tester) async {
        var value = false;
        await tester.pumpWidget(
          themed(
            StatefulBuilder(
              builder: (context, setState) => PayseToggle(
                value: value,
                semanticLabel: '알림',
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        );
        final track = find.byKey(const ValueKey('payse-toggle-track'));
        final knob = find.byKey(const ValueKey('payse-toggle-knob'));
        expect(tester.getSize(track), const Size(52, 32));
        expect(tester.getSize(knob), const Size(21, 21));
        expect(
          find.descendant(
            of: find.byType(PayseToggle),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
        final offKnobX = tester.getCenter(knob).dx;
        expect(decorationOf(tester, knob).color, PayseColors.borderStrong);
        expect(
          tester.getSemantics(find.byType(PayseToggle)),
          matchesSemantics(
            hasToggledState: true,
            hasTapAction: true,
            isToggled: false,
            hasEnabledState: true,
            isEnabled: true,
            label: '알림',
          ),
        );

        await tester.tap(find.byType(PayseToggle));
        await tester.pumpAndSettle();
        expect(tester.getCenter(knob).dx, greaterThan(offKnobX));
        expect(decorationOf(tester, knob).color, PayseColors.moonYellow);
        expect(
          tester.widget<AnimatedContainer>(track).decoration,
          isA<BoxDecoration>().having(
            (d) => d.color,
            'color',
            PayseColors.charcoal,
          ),
        );
      },
    );
  });

  group('PinPad', () {
    /// 2026-10-21: 높이가 정해진 화면에 [pad]를 넣어 띄운다.
    Future<void> pumpPad(WidgetTester tester, PinPad pad) =>
        tester.pumpWidget(themed(SizedBox(height: 500, child: pad)));

    /// 2026-10-23: 오류 문구 [error]가 있는 PinPad를 띄운다. [reduceMotion]이면 기기의 움직임 줄이기를 켠다.
    Future<void> pumpErrorPad(
      WidgetTester tester,
      String? error, {
      bool reduceMotion = false,
    }) => tester.pumpWidget(
      themed(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: SizedBox(
            height: 500,
            child: PinPad(
              title: '앱 비밀번호 6자리를\n만들어주세요',
              filled: 0,
              message: error,
              isError: error != null,
              onDigit: (_) {},
              onBackspace: () {},
            ),
          ),
        ),
      ),
    );

    /// 2026-10-23: 첫 번째 점의 가로 위치를 반환한다.
    double dotX(WidgetTester tester) =>
        tester.getTopLeft(find.byKey(const ValueKey('pin-dot-0'))).dx;

    testWidgets(
      'a new error shakes the dots and vibrates; the same error does not repeat',
      (tester) async {
        final haptics = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'HapticFeedback.vibrate') haptics.add('$call');
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pumpErrorPad(tester, null);
        final rest = dotX(tester);

        await pumpErrorPad(tester, '같은 숫자나 연속된 숫자는 쓸 수 없어요');
        await tester.pump(const Duration(milliseconds: 30));
        expect(dotX(tester), isNot(rest), reason: '흔들리는 중');
        await tester.pumpAndSettle();
        expect(dotX(tester), rest, reason: '0.4초 뒤 제자리');
        expect(haptics, hasLength(1));

        await pumpErrorPad(tester, '같은 숫자나 연속된 숫자는 쓸 수 없어요');
        await tester.pump(const Duration(milliseconds: 30));
        expect(dotX(tester), rest, reason: '같은 오류 유지는 다시 흔들지 않음');
        expect(haptics, hasLength(1));
      },
    );

    testWidgets('reduced motion keeps the dots still but still vibrates', (
      tester,
    ) async {
      var vibrations = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') vibrations++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpErrorPad(tester, null, reduceMotion: true);
      final rest = dotX(tester);
      await pumpErrorPad(
        tester,
        '비밀번호가 일치하지 않아요. 다시 입력해주세요',
        reduceMotion: true,
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(dotX(tester), rest);
      expect(vibrations, 1);
    });

    testWidgets(
      'dots 14dp/16dp gap, message under the dots, keys 64dp in fixed order',
      (tester) async {
        final pressed = <int>[];
        await pumpPad(
          tester,
          PinPad(
            title: '비밀번호를 입력해주세요',
            filled: 2,
            message: '안내',
            onDigit: pressed.add,
            onBackspace: () {},
          ),
        );
        final d0 = find.byKey(const ValueKey('pin-dot-0'));
        final d1 = find.byKey(const ValueKey('pin-dot-1'));
        expect(tester.getSize(d0), const Size(14, 14));
        expect(tester.getTopLeft(d1).dx - tester.getTopRight(d0).dx, 16);
        expect(decorationOf(tester, d0).color, PayseColors.charcoal);
        expect(
          decorationOf(tester, find.byKey(const ValueKey('pin-dot-2'))).color,
          isNull,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('pin-message'))).dy -
              tester.getBottomLeft(d0).dy,
          16,
          reason: '문구는 점 아래 16dp',
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('pin-key-1'))).height,
          64,
        );
        final one = tester.getCenter(find.byKey(const ValueKey('pin-key-1')));
        final three = tester.getCenter(find.byKey(const ValueKey('pin-key-3')));
        final zero = tester.getCenter(find.byKey(const ValueKey('pin-key-0')));
        expect(three.dx, greaterThan(one.dx));
        expect(zero.dy, greaterThan(one.dy));
        await tester.tap(find.byKey(const ValueKey('pin-key-7')));
        expect(pressed, [7]);
      },
    );

    testWidgets('error paints dots and message in error color with an icon', (
      tester,
    ) async {
      await pumpPad(
        tester,
        PinPad(
          title: 't',
          filled: 0,
          message: '틀렸어요',
          isError: true,
          onDigit: (_) {},
          onBackspace: () {},
        ),
      );
      final ring =
          (decorationOf(tester, find.byKey(const ValueKey('pin-dot-0'))).border!
                  as Border)
              .top;
      expect(ring.color, PayseColors.error);
      expect(
        tester.widget<Text>(find.text('틀렸어요')).style!.color,
        PayseColors.error,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('showKeypad false hides every key (09-12)', (tester) async {
      await pumpPad(
        tester,
        PinPad(
          title: 't',
          filled: 0,
          message: '비밀번호를 5번 틀렸어요',
          isError: true,
          secondaryMessage: '본인 확인 후 비밀번호를 다시 만들 수 있어요',
          showKeypad: false,
          onDigit: (_) {},
          onBackspace: () {},
        ),
      );
      expect(find.byKey(const ValueKey('pin-keypad')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pin-secondary-message')))
            .style!
            .color,
        PayseColors.textSecondary,
      );
    });
  });

  group('CodeTimerField', () {
    testWidgets('m:ss timer, never negative, resend active only at 0:00', (
      tester,
    ) async {
      expect(CodeTimerField.format(const Duration(seconds: 180)), '3:00');
      expect(CodeTimerField.format(const Duration(seconds: 59)), '0:59');
      expect(CodeTimerField.format(const Duration(seconds: -5)), '0:00');

      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var resent = 0;
      Widget field(Duration left) => themed(
        CodeTimerField(
          label: '인증번호',
          controller: controller,
          remaining: left,
          onResend: () => resent++,
          resendLabel: '다시 받기',
        ),
      );

      await tester.pumpWidget(field(const Duration(seconds: 167)));
      final timer = tester.widget<Text>(
        find.byKey(const ValueKey('code-timer-text')),
      );
      expect(timer.data, '2:47');
      expect(
        (timer.style!.fontSize, timer.style!.color),
        (15, PayseColors.textSecondary),
      );
      await tester.tap(find.byKey(const ValueKey('code-resend')));
      expect(resent, 0);
      expect(
        tester.getSize(find.byKey(const ValueKey('code-resend'))).height,
        greaterThanOrEqualTo(48),
      );

      await tester.pumpWidget(field(Duration.zero));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('code-timer-text')))
            .style!
            .color,
        PayseColors.textPrimary,
      );
      final resend = tester.widget<Text>(find.text('다시 받기'));
      expect(resend.style!.decoration, TextDecoration.underline);
      await tester.tap(find.byKey(const ValueKey('code-resend')));
      expect(resent, 1);
    });
  });

  group('screen reader tap actions', () {
    testWidgets(
      'PIN keys, resend, terms link, chip, toggle and primary button run by semantics tap',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final handle = tester.ensureSemantics();
        final events = <String>[];
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          themed(
            SizedBox(
              height: 1200,
              child: ListView(
                children: [
                  SizedBox(
                    height: 420,
                    child: PinPad(
                      title: 't',
                      filled: 0,
                      onDigit: (d) => events.add('digit$d'),
                      onBackspace: () => events.add('back'),
                    ),
                  ),
                  CodeTimerField(
                    label: '인증번호',
                    controller: controller,
                    remaining: Duration.zero,
                    onResend: () => events.add('resend'),
                    resendLabel: '다시 받기',
                  ),
                  SelectionCheckRow(
                    label: '약관',
                    selected: false,
                    onChanged: (_) {},
                    linkLabel: '보기',
                    onLink: () => events.add('link'),
                  ),
                  PayseChip(
                    label: '매달',
                    selected: false,
                    onSelected: (_) => events.add('chip'),
                  ),
                  PayseToggle(
                    value: false,
                    semanticLabel: '알림',
                    onChanged: (_) => events.add('toggle'),
                  ),
                  PrimaryButton(
                    label: '확인',
                    onPressed: () => events.add('primary'),
                  ),
                ],
              ),
            ),
          ),
        );

        tester.semantics.tap(find.semantics.byLabel('7'));
        tester.semantics.tap(find.semantics.byLabel('지우기'));
        tester.semantics.tap(find.semantics.byLabel('다시 받기'));
        tester.semantics.tap(find.semantics.byLabel('약관 보기'));
        tester.semantics.tap(find.semantics.byLabel('매달'));
        tester.semantics.tap(find.semantics.byLabel('알림'));
        tester.semantics.tap(find.semantics.byLabel('확인'));
        expect(events, [
          'digit7',
          'back',
          'resend',
          'link',
          'chip',
          'toggle',
          'primary',
        ]);
        handle.dispose();
      },
    );

    testWidgets(
      'disabled resend and disabled primary button expose no tap action',
      (tester) async {
        final handle = tester.ensureSemantics();
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          themed(
            Column(
              children: [
                CodeTimerField(
                  label: '인증번호',
                  controller: controller,
                  remaining: const Duration(seconds: 30),
                  onResend: () {},
                  resendLabel: '다시 받기',
                ),
                const PrimaryButton(label: '확인', onPressed: null),
              ],
            ),
          ),
        );
        expect(
          tester.getSemantics(find.byKey(const ValueKey('code-resend'))),
          isNot(
            matchesSemantics(
              hasTapAction: true,
              isButton: true,
              hasEnabledState: true,
              label: '다시 받기',
            ),
          ),
        );
        expect(
          find.semantics
              .byAction(SemanticsAction.tap)
              .evaluate()
              .where((n) => n.label == '확인'),
          isEmpty,
        );
        handle.dispose();
      },
    );
  });
}
