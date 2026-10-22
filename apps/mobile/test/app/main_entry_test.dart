import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/financial_snapshot_repository.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/shared/design/payse_theme.dart';

import 'app_test_utils.dart';

/// 2026-10-21: [scenario]와 첫 가입 여부 [fresh]로 MainEntry를 띄운다.
Future<void> pumpEntry(
  WidgetTester tester,
  FixtureScenario scenario, {
  bool fresh = false,
}) async {
  final source = PreloadedAssetSource();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        scenario: scenario,
        repositoryFor: (s) =>
            FakeFinancialSnapshotRepository(source: source, scenario: s),
        showConnectionFirst: fresh,
        devEntryBuilder: (_) => null,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unconnected snapshot opens the connection placeholder', (
    tester,
  ) async {
    await pumpEntry(tester, FixtureScenario.alphaUnconnected);

    expect(find.text('금융사 연결 화면이 들어갈 자리예요.'), findsOneWidget);
    await tester.tap(find.text('홈으로 가기'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('connected snapshot opens the home shell directly', (
    tester,
  ) async {
    await pumpEntry(tester, FixtureScenario.alphaReady);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('금융사 연결 화면이 들어갈 자리예요.'), findsNothing);
  });

  testWidgets('first signup shows connection first even when connected', (
    tester,
  ) async {
    await pumpEntry(tester, FixtureScenario.alphaReady, fresh: true);

    expect(find.text('금융사 연결 화면이 들어갈 자리예요.'), findsOneWidget);
    await tester.tap(find.text('홈으로 가기'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
