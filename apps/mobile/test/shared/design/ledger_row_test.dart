import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/shared/design/ledger_row.dart';
import 'package:payse/shared/design/payse_tokens.dart';

import 'design_test_utils.dart';

void main() {
  testWidgets('home deduction row: minus line, name, chip, chevron', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      themed(
        LedgerRow(
          name: '모아둘 돈',
          amountKrw: 400000,
          isDeduction: true,
          chipColor: PayseColors.reserve,
          subtitle: '1건',
          showChevron: true,
          onTap: () => tapped++,
        ),
      ),
    );

    final minus = tester.getSize(find.byKey(const ValueKey('ledger-minus')));
    expect(minus.width, LedgerRow.minusWidth);
    expect(minus.height, LedgerRow.minusThickness);

    final minusCenter = tester.getCenter(
      find.byKey(const ValueKey('ledger-minus')),
    );
    final nameCenter = tester.getCenter(find.text('모아둘 돈'));
    final subtitleCenter = tester.getCenter(find.text('1건'));
    expect((minusCenter.dy - nameCenter.dy).abs(), lessThan(1.5));
    expect(subtitleCenter.dy, greaterThan(minusCenter.dy + 10));

    final nameRight = tester.getTopRight(find.text('모아둘 돈')).dx;
    final chipLeft = tester
        .getTopLeft(find.byKey(const ValueKey('ledger-chip')))
        .dx;
    expect(chipLeft - nameRight, closeTo(6, 0.5));
    expect(find.byKey(const ValueKey('ledger-chevron')), findsOneWidget);

    expect(find.bySemanticsLabel('빼기 모아둘 돈 1건 400,000원'), findsOneWidget);
    expect(
      tester.getSize(find.byType(LedgerRow)).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.byType(LedgerRow));
    expect(tapped, 1);
  });

  testWidgets('optional parts can be turned off per screen', (tester) async {
    await tester.pumpWidget(
      themed(
        const LedgerRow(
          name: '계좌 잔액',
          amountKrw: 2000000,
          emphasizeName: true,
          verticalPadding: 10,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('ledger-minus')), findsNothing);
    expect(find.byKey(const ValueKey('ledger-chip')), findsNothing);
    expect(find.byKey(const ValueKey('ledger-chevron')), findsNothing);
    expect(find.text('2,000,000원'), findsOneWidget);
    expect(
      tester.getSize(find.byType(LedgerRow)).height,
      LedgerRow.firstLineHeight + 20,
    );
  });

  testWidgets(
    'long name wraps to 2 lines with ellipsis and never covers amount on 320dp',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const longName = '아주 긴 예정 지출 항목 이름이 화면 폭을 넘어서 여러 줄로 이어지는 경우의 표시 확인';
      await tester.pumpWidget(
        themed(
          LedgerRow(
            name: longName,
            amountKrw: 1234567890,
            isDeduction: true,
            chipColor: PayseColors.scheduled,
            subtitle: '월급일 전 2건',
            showChevron: true,
            onTap: () {},
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      final name = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('ledger-name')),
          matching: find.byType(RichText),
        ),
      );
      expect(name.didExceedMaxLines, isTrue);
      expect(
        tester.getSize(find.byKey(const ValueKey('ledger-name'))).height,
        lessThanOrEqualTo(LedgerRow.firstLineHeight * 2 + 0.5),
      );

      final amount = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('ledger-amount')),
          matching: find.byType(RichText),
        ),
      );
      expect(amount.didExceedMaxLines, isFalse);
      expect(find.text('1,234,567,890원'), findsOneWidget);

      final nameRect = tester.getRect(
        find.byKey(const ValueKey('ledger-name')),
      );
      final chipRect = tester.getRect(
        find.byKey(const ValueKey('ledger-chip')),
      );
      final amountRect = tester.getRect(
        find.byKey(const ValueKey('ledger-amount')),
      );
      final chevronRect = tester.getRect(
        find.byKey(const ValueKey('ledger-chevron')),
      );
      expect(nameRect.right, lessThanOrEqualTo(chipRect.left));
      expect(chipRect.right, lessThan(amountRect.left));
      expect(amountRect.right, lessThanOrEqualTo(chevronRect.left));
      expect((chipRect.center.dy - amountRect.center.dy).abs(), lessThan(1.5));
      final rowWidth = tester.getSize(find.byType(LedgerRow)).width;
      expect(
        amountRect.width,
        lessThanOrEqualTo(rowWidth * LedgerRow.amountMaxWidthFactor + 0.5),
      );
    },
  );
}
