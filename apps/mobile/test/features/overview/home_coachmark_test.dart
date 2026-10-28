import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/app_shell.dart';
import 'package:payse/data/coachmark_record_store.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/features/overview/calculation_detail_screen.dart';
import 'package:payse/features/overview/composition_bar.dart';
import 'package:payse/features/overview/home_coachmark.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/shared/design/amount_hero.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../connection/connection_test_support.dart';

/// 2026-10-28: U가 계산되는 스냅샷.
FinancialSnapshot _computed() => FinancialSnapshot.fromJson(alphaWithReceipt());

/// 2026-10-28: 지난 회차 월급 입금 근거가 없어 U가 없는 스냅샷.
FinancialSnapshot _receiptAbsent() {
  final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
  return FinancialSnapshot.fromJson(betaJson({...betaBanks}, selected: {kb}));
}

void main() {
  late List<CoachmarkRecord> saved;

  /// 2026-10-28: 01-3을 이미 본 사용자의 홈 셸을 폭 [width]·높이 [height]·글자 배율 [scale]로 띄운다.
  Future<void> show(
    WidgetTester tester,
    FinancialSnapshot snapshot, {
    CoachmarkRecord? record,
    HomeRefresh refresh = HomeRefresh.idle,
    FirstCalcRecord? firstCalc = FirstCalcRecord.explained,
    double width = 390,
    double height = 844,
    double scale = 1,
  }) async {
    saved = [];
    tester.view.physicalSize = Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AppShell(
          key: UniqueKey(),
          snapshot: snapshot,
          onReload: () {},
          refresh: refresh,
          firstCalcRecord: firstCalc,
          onFirstCalcRecord: (_) {},
          coachmarkRecord: record,
          onCoachmarkRecord: saved.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  final coach = find.byKey(const ValueKey('home-coachmark'));
  final next = find.byKey(const ValueKey('coachmark-next'));
  final skip = find.byKey(const ValueKey('coachmark-skip'));

  /// 2026-10-28: 덮개 그림을 반환한다.
  CoachmarkPainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byKey(const ValueKey('coachmark-scrim')),
              )
              .painter!
          as CoachmarkPainter;

  /// 2026-10-28: 안내 면의 위치를 반환한다.
  Rect panel(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byKey(const ValueKey('coachmark-panel')),
      matching: find.byType(Container),
    ),
  );

  /// 2026-10-28: '다음'을 누르고 화면을 안정시킨다.
  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('step 1 frames the amount area and links it to the panel', (
    tester,
  ) async {
    await show(tester, _computed());
    expect(coach, findsOneWidget);
    expect(find.text('지금 쓸 수 있는 돈이에요'), findsOneWidget);
    expect(find.text('계좌 잔액에서 모아둘 돈과 예정 지출을 빼고 계산해요.'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(skip, findsOneWidget);
    expect(
      DefaultTextStyle.of(tester.element(find.text('지금 쓸 수 있는 돈이에요')))
          .style
          .decoration,
      isNot(TextDecoration.underline),
      reason: 'Material 밖 기본 글자 모양(노란 밑줄)이 아님',
    );
    expect(find.text('다음'), findsOneWidget);

    final p = painter(tester);
    final hole = p.hole!;
    final hero = tester.getRect(find.byType(AmountHero));
    final bar = tester.getRect(find.byType(CompositionBar));
    expect(hole.left, 16, reason: '화면 여백 24에서 8dp 넓힘');
    expect(hole.right, 390 - 16);
    expect(hole.top, hero.top - 8);
    expect(hole.bottom, bar.bottom + 8);
    expect(p.radius, 12);

    final detail = tester.getRect(
      find.byKey(const ValueKey('home-detail-button')),
    );
    final box = panel(tester);
    expect(box.bottom, detail.top - 8, reason: '계산 내역 보기 위 8dp');
    expect(box.left, 16);
    expect(box.right, 390 - 16);
    expect(box.height, greaterThanOrEqualTo(180));
    expect(p.connectTo, box.top, reason: '연결선은 안내 면 위까지');
  });

  testWidgets('step 2 frames the detail band and step 3 the plan tab', (
    tester,
  ) async {
    await show(tester, _computed());
    final first = panel(tester);
    await tapNext(tester);
    expect(find.text('어떻게 계산했는지 확인해 보세요'), findsOneWidget);
    expect(find.text('계좌별 잔액과 계산에 반영한 지출을 확인할 수 있어요.'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    final detail = tester.getRect(
      find.byKey(const ValueKey('home-detail-button')),
    );
    expect(painter(tester).hole, detail);
    expect(painter(tester).radius, 0);
    expect(painter(tester).connectTo, isNull, reason: '연결선은 1단계만');
    expect(panel(tester).bottom, first.bottom, reason: '같은 기준선');

    await tapNext(tester);
    expect(find.text('계획은 여기서 관리해요'), findsOneWidget);
    expect(find.text('예정 지출과 모아둘 돈을 확인하고 수정할 수 있어요.'), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(skip, findsNothing, reason: '마지막 단계에는 건너뛰기 없음');
    expect(find.text('시작하기'), findsOneWidget);
    final hole = painter(tester).hole!;
    expect(hole.size, const Size(64, 58));
    final nav = tester.getRect(find.byType(NavigationBar));
    final label = tester.getRect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('계획'),
      ),
    );
    expect(hole.contains(label.center), isTrue, reason: '계획 탭 글자를 감쌈');
    expect(hole.top, greaterThanOrEqualTo(nav.top), reason: '탭바 밖으로 안 나감');
    expect(panel(tester).bottom, first.bottom);

    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(saved, [CoachmarkRecord.completed]);
    expect(coach, findsNothing);
  });

  testWidgets('skip and back close it as skipped', (tester) async {
    await show(tester, _computed());
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(saved, [CoachmarkRecord.skipped]);
    expect(coach, findsNothing);

    await show(tester, _computed());
    await tapNext(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(saved, [CoachmarkRecord.skipped]);
    expect(coach, findsNothing);
  });

  testWidgets('the scrim blocks the home underneath', (tester) async {
    await show(tester, _computed());
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('home-reload'))),
    );
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('home-detail-button'))) +
          const Offset(4, 4),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CalculationDetailScreen), findsNothing);
    expect(coach, findsOneWidget);
    expect(saved, isEmpty);
  });

  testWidgets('a missing salary deposit uses the insufficient copy', (
    tester,
  ) async {
    await show(tester, _receiptAbsent(), firstCalc: FirstCalcRecord.deferred);
    expect(find.text('월급 입금을 확인하면 계산해요'), findsOneWidget);
    expect(
      find.text('입금이 확인되면 계좌 잔액에서 모아둘 돈과 예정 지출을 빼고 계산해요.'),
      findsOneWidget,
    );
    final hole = painter(tester).hole!;
    final check = tester.getRect(
      find.byKey(const ValueKey('home-salary-check-button')),
    );
    expect(hole.bottom, check.bottom + 8, reason: '월급 입금 확인하기까지');
    expect(hole.top, tester.getRect(find.byType(AmountHero)).top - 8);
  });

  testWidgets('not shown with a record, while refreshing or before 01-3', (
    tester,
  ) async {
    await show(tester, _computed(), record: CoachmarkRecord.skipped);
    expect(coach, findsNothing);
    await show(tester, _computed(), refresh: HomeRefresh.loading);
    expect(coach, findsNothing);
    await show(tester, _computed(), firstCalc: null);
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
    expect(coach, findsNothing, reason: '01-3이 먼저');
  });

  testWidgets('screen readers get only the panel as a dialog', (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester, _computed());
    expect(
      tester.getSemantics(find.byKey(const ValueKey('coachmark-panel'))),
      isSemantics(label: '사용법 1 / 3', scopesRoute: true, namesRoute: true),
    );
    expect(find.bySemanticsLabel('계산 내역 보기'), findsNothing);
    handle.dispose();
  });

  for (final (width, scale) in [(320.0, 1.0), (320.0, 1.3), (390.0, 1.3)]) {
    testWidgets('no overflow at ${width}dp with text x$scale', (tester) async {
      await show(tester, _computed(), width: width, height: 911, scale: scale);
      for (var step = 0; step < 3; step++) {
        expect(tester.takeException(), isNull);
        final box = panel(tester);
        expect(box.height, greaterThanOrEqualTo(180 * scale - 0.5));
        expect(box.right, lessThanOrEqualTo(width - 16));
        if (step < 2) await tapNext(tester);
      }
    });
  }
}
