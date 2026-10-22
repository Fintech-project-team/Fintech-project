import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/connection/user_snapshot_repository.dart';
import 'package:payse/data/financial_snapshot_repository.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/shared/design/payse_theme.dart';

import 'app_test_utils.dart';

/// 2026-10-22: 정해 둔 조회 결과를 돌려주는 테스트용 저장소.
class _FixedRepository implements FinancialSnapshotRepository {
  /// 2026-10-22: 반환할 [result]로 만든다.
  const _FixedRepository(this.result);

  final SnapshotLoadResult result;

  /// 2026-10-22: 정해 둔 결과를 반환한다.
  @override
  Future<SnapshotLoadResult> loadSnapshot() async => result;
}

/// 2026-10-22: [repository]로 MainEntry를 띄운다. 세션 무효 콜백 호출 수를 [onSessionInvalid]로 센다.
Future<void> pumpEntry(
  WidgetTester tester,
  FinancialSnapshotRepository repository, {
  VoidCallback? onSessionInvalid,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        repository: repository,
        reloadKey: 0,
        devEntryBuilder: (_) => null,
        onSessionInvalid: onSessionInvalid ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-22: 미리 읽은 에셋에서 [scenario] 원본을 그대로 읽는 저장소를 만든다.
FinancialSnapshotRepository fixture(FixtureScenario scenario) =>
    FakeFinancialSnapshotRepository(
      source: PreloadedAssetSource(),
      scenario: scenario,
    );

/// 2026-10-22: 조회 Future를 예외로 끝내는 저장소.
class _ThrowingRepository implements FinancialSnapshotRepository {
  /// 2026-10-22: 상태 없는 인스턴스를 만든다.
  const _ThrowingRepository();

  /// 2026-10-22: 항상 예외를 던진다.
  @override
  Future<SnapshotLoadResult> loadSnapshot() async => throw StateError('boom');
}

void main() {
  testWidgets('a load that throws shows retry instead of loading forever', (
    tester,
  ) async {
    await pumpEntry(tester, const _ThrowingRepository());

    expect(tester.takeException(), isA<StateError>());
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('금융 정보를 불러오지 못했어요.'), findsOneWidget);
  });

  testWidgets('unconnected snapshot opens the connection placeholder', (
    tester,
  ) async {
    await pumpEntry(tester, fixture(FixtureScenario.alphaUnconnected));

    expect(find.text('금융사 연결 화면이 들어갈 자리예요.'), findsOneWidget);
    await tester.tap(find.text('홈으로 가기'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('connected snapshot opens the home shell directly', (
    tester,
  ) async {
    await pumpEntry(tester, fixture(FixtureScenario.alphaReady));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('금융사 연결 화면이 들어갈 자리예요.'), findsNothing);
  });

  testWidgets('session invalid on load hands over to a new login', (
    tester,
  ) async {
    var handedOver = 0;
    await pumpEntry(
      tester,
      const _FixedRepository(
        SnapshotLoadFailed(FinancialLoadError(FinancialSessionInvalid())),
      ),
      onSessionInvalid: () => handedOver++,
    );

    expect(handedOver, 1);
    expect(find.text('금융 정보를 불러오지 못했어요.'), findsNothing);
  });

  testWidgets('other load failures show retry, never empty data', (
    tester,
  ) async {
    await pumpEntry(
      tester,
      const _FixedRepository(
        SnapshotLoadFailed(FinancialLoadError(FinancialUnavailable())),
      ),
    );

    expect(find.text('금융 정보를 불러오지 못했어요.'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
