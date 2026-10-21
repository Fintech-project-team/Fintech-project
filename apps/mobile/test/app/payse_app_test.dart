import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/data/snapshot_source.dart';

/// 2026-10-20: 앱 에셋 복사본을 미리 읽어 두고 즉시 돌려주는 테스트용 출처(위젯 테스트의 가짜 시계와 호환).
class _PreloadedAssetSource implements SnapshotSource {
  /// 2026-10-20: 4개 스냅샷 원문을 디스크에서 동기로 읽어 둔다.
  _PreloadedAssetSource()
    : _raw = {
        for (final s in FixtureScenario.values)
          s: File('assets/fixtures/${s.fileStem}.json').readAsStringSync(),
      };

  final Map<FixtureScenario, String> _raw;

  /// 2026-10-20: 미리 읽은 [scenario] 원문을 반환한다.
  @override
  Future<String> load(FixtureScenario scenario) async => _raw[scenario]!;
}

void main() {
  testWidgets('app opens on the 4-tab shell and switches tabs', (tester) async {
    await tester.pumpWidget(const PayseApp(enableDevTools: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final label in ['홈', '계좌', '계획', '내 정보']) {
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('이 화면은 준비 중이에요.'), findsWidgets);

    await tester.tap(find.text('계획').last);
    await tester.pumpAndSettle();
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.selectedIndex, 2);
  });

  testWidgets('shell stays readable on the PAYSE light theme', (tester) async {
    await tester.pumpWidget(const PayseApp(enableDevTools: false));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(theme.colorScheme.onSurface, const Color(0xFF242629));
  });

  testWidgets('release-like build has no dev entry anywhere', (tester) async {
    await tester.pumpWidget(const PayseApp(enableDevTools: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dev-entry')), findsNothing);
    expect(find.textContaining('개발용'), findsNothing);
  });

  testWidgets('dev build: debug screen shows alpha-ready counts and switches', (
    tester,
  ) async {
    await tester.pumpWidget(
      PayseApp(snapshotSource: _PreloadedAssetSource(), enableDevTools: true),
    );
    await tester.pumpAndSettle();
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

  testWidgets('dev build: onboarding placeholder route opens', (tester) async {
    await tester.pumpWidget(
      PayseApp(snapshotSource: _PreloadedAssetSource(), enableDevTools: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('개발용: 온보딩 자리 보기'));
    await tester.pumpAndSettle();

    expect(find.text('온보딩 흐름이 들어갈 자리예요.'), findsOneWidget);
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
