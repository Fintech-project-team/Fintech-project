import 'package:flutter/services.dart';

import 'fixture_scenario.dart';

/// 2026-10-20: 스냅샷 JSON 원문을 가져오는 경계. 실제 API 도입 시 Repository 구현과 함께 교체한다.
abstract interface class SnapshotSource {
  /// 2026-10-20: [scenario]의 JSON 원문을 반환한다. 읽지 못하면 예외를 던진다.
  Future<String> load(FixtureScenario scenario);
}

/// 2026-10-20: 앱 에셋(assets/fixtures/)에서 원본과 같은 바이트의 더미를 읽는다. 에셋 경로를 아는 유일한 곳이다.
class AssetSnapshotSource implements SnapshotSource {
  /// 2026-10-20: 읽을 [bundle]을 받는다. 앱에서는 rootBundle, 테스트에서는 가짜 묶음을 넣는다.
  const AssetSnapshotSource(this.bundle);

  final AssetBundle bundle;

  /// 2026-10-20: [scenario]의 에셋 경로를 반환한다.
  static String assetPath(FixtureScenario scenario) =>
      'assets/fixtures/${scenario.fileStem}.json';

  /// 2026-10-20: 캐시 없이 에셋을 읽어 반환한다. 에셋이 없으면 묶음의 예외가 그대로 전달된다.
  @override
  Future<String> load(FixtureScenario scenario) =>
      bundle.loadString(assetPath(scenario), cache: false);
}
