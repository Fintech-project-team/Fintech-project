import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/auth/credential_stores.dart';

import 'app_test_utils.dart';

/// 2026-10-21: 세션·PIN이 있는 기기로 앱을 띄우고 11-1에서 PIN을 넣어 하단 탭 홈까지 연다.
Future<void> openSignedIn(WidgetTester tester, {bool devTools = false}) async {
  final (sessions, pins) = await signedInStores();
  await tester.pumpWidget(
    PayseApp(
      snapshotSource: PreloadedAssetSource(),
      enableDevTools: devTools,
      sessionStore: sessions,
      pinStore: pins,
    ),
  );
  await tester.pumpAndSettle();
  await enterPin(tester, testPin);
}

void main() {
  testWidgets('device without a session opens 00-1 start', (tester) async {
    await tester.pumpWidget(const PayseApp(enableDevTools: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('시작하기'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('session without PIN resumes at 10-4', (tester) async {
    final sessions = MemorySessionStore();
    await sessions.save(
      const StoredSession(
        userId: 'u',
        name: '데모알파',
        sessionId: 's',
        accessToken: 't',
      ),
    );
    await tester.pumpWidget(
      PayseApp(enableDevTools: false, sessionStore: sessions),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pin-setup-pad')), findsOneWidget);
    expect(find.text('앱 비밀번호 6자리를\n만들어주세요'), findsOneWidget);
  });

  testWidgets('relaunch asks 11-1 PIN, then opens the connected home shell', (
    tester,
  ) async {
    final (sessions, pins) = await signedInStores();
    await tester.pumpWidget(
      PayseApp(
        snapshotSource: PreloadedAssetSource(),
        enableDevTools: false,
        sessionStore: sessions,
        pinStore: pins,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pin-login-pad')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await enterPin(tester, testPin);

    for (final label in ['홈', '계좌', '계획', '내 정보']) {
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('계획').last);
    await tester.pumpAndSettle();
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.selectedIndex, 2);
  });

  testWidgets('shell stays readable on the PAYSE light theme', (tester) async {
    await openSignedIn(tester);

    final theme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(theme.colorScheme.onSurface, const Color(0xFF242629));
  });

  testWidgets('release-like build has no dev entry anywhere', (tester) async {
    await openSignedIn(tester);
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dev-entry')), findsNothing);
    expect(find.textContaining('개발용'), findsNothing);
  });

  testWidgets('dev build: debug screen shows alpha-ready counts and switches', (
    tester,
  ) async {
    await openSignedIn(tester, devTools: true);
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('개발용: 더미 스냅샷 확인'));
    await tester.pumpAndSettle();

    expect(find.text('계좌 6개'), findsOneWidget);
    expect(find.text('카드 4장'), findsOneWidget);
    expect(find.text('거래 193건'), findsOneWidget);
    expect(find.text('기준 시각 2026-10-19T12:00:00+09:00'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scenario-alpha-unconnected')));
    await tester.pumpAndSettle();
    expect(find.text('계좌 자료 없음(미노출)'), findsOneWidget);
    expect(find.text('계좌 0개'), findsNothing);
  });

  testWidgets('Pretendard license appears in the Flutter license list', (
    tester,
  ) async {
    await tester.pumpWidget(const PayseApp(enableDevTools: false));

    final entries = await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    final pretendard = entries!.where(
      (entry) => entry.packages.contains('Pretendard'),
    );
    expect(pretendard, hasLength(1));
    final text = pretendard.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('SIL Open Font License'));
  });
}
