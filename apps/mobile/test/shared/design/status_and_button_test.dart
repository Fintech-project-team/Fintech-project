import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/moon_glyph.dart';
import 'package:payse/shared/design/payse_tokens.dart';
import 'package:payse/shared/design/primary_button.dart';
import 'package:payse/shared/design/status_notice.dart';

import 'design_test_utils.dart';

void main() {
  testWidgets('save failure and version conflict look and act differently', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      themed(
        Column(
          children: [
            StatusNotice(
              kind: StatusNoticeKind.saveFailed,
              title: '저장하지 못했어요',
              message: '미리보기 금액은 아직 반영되지 않았어요.',
              actionLabel: '다시 시도',
              onAction: () => actions.add('retry'),
            ),
            StatusNotice(
              kind: StatusNoticeKind.versionConflict,
              title: '저장 전에 정보가 변경됐어요',
              actionLabel: '변경 내용 확인하기',
              onAction: () => actions.add('review'),
            ),
          ],
        ),
      ),
    );

    final failed = find.byKey(const ValueKey('status-saveFailed'));
    final conflict = find.byKey(const ValueKey('status-versionConflict'));
    expect(
      find.descendant(of: failed, matching: find.byIcon(Icons.error_outline)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: conflict, matching: find.byIcon(Icons.sync_problem)),
      findsOneWidget,
    );
    final failedBox =
        tester.widget<Container>(failed).decoration! as BoxDecoration;
    final conflictBox =
        tester.widget<Container>(conflict).decoration! as BoxDecoration;
    expect(failedBox.color, PayseColors.errorContainer);
    expect(conflictBox.color, PayseColors.warningContainer);

    await tester.tap(find.text('다시 시도'));
    await tester.tap(find.text('변경 내용 확인하기'));
    expect(actions, ['retry', 'review']);
  });

  testWidgets(
    'insufficient info notice is neutral and hides action without callback',
    (tester) async {
      await tester.pumpWidget(
        themed(
          const StatusNotice(
            kind: StatusNoticeKind.insufficientInfo,
            title: '삼성카드 결제일',
            message: '결제 예정일을 입력해주세요.',
            actionLabel: '결제일 입력하기',
          ),
        ),
      );

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    },
  );

  testWidgets(
    'primary band button taps when enabled and is disabled without callback',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        themed(PrimaryButton(label: '계산 내역 보기', onPressed: () => taps++)),
      );
      expect(
        tester.getSize(find.byType(PrimaryButton)).height,
        PayseSize.primaryBandHeight,
      );
      await tester.tap(find.byType(PrimaryButton));
      expect(taps, 1);

      await tester.pumpWidget(
        themed(const PrimaryButton(label: '계산 내역 보기', onPressed: null)),
      );
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(PrimaryButton),
          matching: find.byType(Material),
        ),
      );
      expect(material.color, PayseColors.surfaceMuted);
    },
  );

  testWidgets('moon glyph renders as fixed decoration hidden from semantics', (
    tester,
  ) async {
    await tester.pumpWidget(themed(const Center(child: MoonGlyph())));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(MoonGlyph)), const Size(26, 26));
    expect(
      find.descendant(
        of: find.byType(MoonGlyph),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
  });

  testWidgets('band padding is the button content padding, not screen margin', (
    tester,
  ) async {
    await tester.pumpWidget(
      themed(
        PrimaryButton(
          label: '계산 내역 보기',
          onPressed: () {},
          contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      ),
    );

    final band = tester.getRect(find.byType(PrimaryButton));
    final label = tester.getRect(find.text('계산 내역 보기'));
    expect(label.left - band.left, 18);
  });
}
