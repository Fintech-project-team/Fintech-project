import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/local_lock_controller.dart';
import 'package:payse/app/payse_app.dart';

import 'app_test_utils.dart';

void main() {
  group('LocalLockController', () {
    testWidgets('locks exactly after 10 minutes without input', (tester) async {
      final clock = FakeClock();
      final lock = LocalLockController(now: clock.now)..enable();
      addTearDown(lock.dispose);

      clock.advance(const Duration(minutes: 9, seconds: 59));
      await tester.pump(const Duration(minutes: 9, seconds: 59));
      expect(lock.locked, isFalse);

      clock.advance(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(lock.locked, isTrue);
    });

    testWidgets('input resets the 10 minute count', (tester) async {
      final clock = FakeClock();
      final lock = LocalLockController(now: clock.now)..enable();
      addTearDown(lock.dispose);

      clock.advance(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      lock.recordActivity();
      clock.advance(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      expect(lock.locked, isFalse);

      clock.advance(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      expect(lock.locked, isTrue);
    });

    testWidgets('background time counts when the app comes back', (
      tester,
    ) async {
      final clock = FakeClock();
      final lock = LocalLockController(now: clock.now)..enable();
      addTearDown(lock.dispose);

      clock.advance(const Duration(minutes: 2));
      lock.onBackground();
      clock.advance(const Duration(minutes: 7));
      lock.onForeground();
      expect(lock.locked, isFalse, reason: '9분 경과');

      clock.advance(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(lock.locked, isTrue, reason: '남은 1분 뒤 잠금');
    });

    testWidgets('long background locks immediately on return', (tester) async {
      final clock = FakeClock();
      final lock = LocalLockController(now: clock.now)..enable();
      addTearDown(lock.dispose);

      lock.onBackground();
      clock.advance(const Duration(minutes: 11));
      lock.onForeground();
      expect(lock.locked, isTrue);
    });

    testWidgets('disabled controller never locks', (tester) async {
      final clock = FakeClock();
      final lock = LocalLockController(now: clock.now);
      addTearDown(lock.dispose);

      lock.recordActivity();
      clock.advance(const Duration(minutes: 30));
      lock.onForeground();
      await tester.pump(const Duration(minutes: 30));
      expect(lock.locked, isFalse);
    });
  });

  group('app lock overlay', () {
    /// 2026-10-21: 가짜 시계로 로그인된 앱을 띄워 하단 탭의 계획 탭까지 연다.
    Future<FakeClock> openOnPlanTab(WidgetTester tester) async {
      final clock = FakeClock();
      final (sessions, pins, auth) = await signedInStores();
      await tester.pumpWidget(
        PayseApp(
          snapshotSource: PreloadedAssetSource(),
          enableDevTools: false,
          authRepository: auth,
          sessionStore: sessions,
          pinStore: pins,
          now: clock.now,
          presentationPolicy: instantPresentation(),
        ),
      );
      await tester.pumpAndSettle();
      await enterPin(tester, testPin);
      await connectAndChooseAccounts(tester);
      await tester.tap(find.text('계획').last);
      await tester.pumpAndSettle();
      return clock;
    }

    testWidgets('10 minutes idle covers the screen and keeps its state', (
      tester,
    ) async {
      final clock = await openOnPlanTab(tester);

      clock.advance(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lock-overlay')), findsOneWidget);
      expect(
        find.byType(NavigationBar),
        findsNothing,
        reason: '잠금 아래 화면은 그리지 않음',
      );
      expect(find.byType(NavigationBar, skipOffstage: false), findsOneWidget);

      await enterPin(tester, testPin);

      expect(find.byKey(const ValueKey('lock-overlay')), findsNothing);
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 2, reason: '잠금 전 선택한 탭이 그대로');
    });

    testWidgets('returning from background after 10 minutes locks', (
      tester,
    ) async {
      final clock = await openOnPlanTab(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock.advance(const Duration(minutes: 12));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lock-overlay')), findsOneWidget);
    });

    testWidgets('short background does not lock', (tester) async {
      final clock = await openOnPlanTab(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock.advance(const Duration(minutes: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lock-overlay')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });
}
