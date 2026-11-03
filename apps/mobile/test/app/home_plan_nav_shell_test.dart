import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/app_shell.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/calculation_input_adapter_test.dart' show alphaWithReceipt;

/// 2026-11-03: 코치마크 없이 앱 셸을 띄운다. 높이를 줄여 계획 목록이 스크롤되게 한다.
Future<void> _shell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: AppShell(
        snapshot: FinancialSnapshot.fromJson(alphaWithReceipt()),
        onReload: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-11-03: 하단 탭 [label]을 누른다.
Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// 2026-11-03: 하단 탭에서 고른 위치(0 홈, 2 계획).
int _selected(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

/// 2026-11-03: 예정 지출 목록 스크롤 위치.
double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('plan-list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

/// 2026-11-03: 기간 머리 제목.
String? _title(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('plan-period')),
        matching: find.byType(Text),
      ),
    )
    .data;

void main() {
  testWidgets('홈 남겨둘 돈 행 → 하단 탭이 계획으로 바뀌고 남겨둘 돈 탭이 열린다', (tester) async {
    await _shell(tester);
    expect(_selected(tester), 0);
    await tester.tap(find.byKey(const ValueKey('home-row-reserve')));
    await tester.pumpAndSettle();
    expect(_selected(tester), 2);
    expect(find.text('남겨둘 금액'), findsOneWidget);
    expect(find.text('340,000원'), findsWidgets);
  });

  testWidgets('스크롤: 하단 탭 직접 진입은 유지, 홈 예정 지출 행 진입은 맨 위', (tester) async {
    await _shell(tester);
    await _tab(tester, '계획');
    await tester.drag(
      find.byKey(const ValueKey('plan-list')),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    final scrolled = _offset(tester);
    expect(scrolled, greaterThan(0));
    await _tab(tester, '홈');
    await _tab(tester, '계획');
    expect(_offset(tester), scrolled, reason: '하단 탭 직접 진입은 스크롤 유지');
    await _tab(tester, '홈');
    await tester.tap(find.byKey(const ValueKey('home-row-scheduled')));
    await tester.pumpAndSettle();
    expect(_selected(tester), 2);
    expect(_offset(tester), 0, reason: '홈 행 진입은 맨 위');
  });

  testWidgets('하단 탭 직접 진입은 보던 기간을 유지한다', (tester) async {
    await _shell(tester);
    await _tab(tester, '계획');
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pumpAndSettle();
    await _tab(tester, '홈');
    await _tab(tester, '계획');
    expect(_title(tester), '10/25 ~ 11/24');
    await _tab(tester, '홈');
    await tester.tap(find.byKey(const ValueKey('home-row-scheduled')));
    await tester.pumpAndSettle();
    expect(_title(tester), '다음 월급일까지');
  });
}
