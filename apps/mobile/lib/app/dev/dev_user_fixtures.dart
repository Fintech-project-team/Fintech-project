import '../../data/fixture_scenario.dart';

/// 2026-10-22: 개발 빌드 데모 계정의 불변 원본(docs/api-response-models.md §1.1). userId는 dev_demo_accounts.dart와 같다.
/// 연결 전 상태는 이 원본에서 공통 변환으로 만들며 alpha-unconnected를 쓰지 않는다. 릴리스 빌드에서는 참조하지 않는다.
/// 2026-10-27: 알파는 서버 준비 시드의 initialCase와 같은 demo-ready를 쓴다(#100).
const Map<String, FixtureScenario> devUserFixtures = {
  'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c': FixtureScenario.demoReady,
  '87f7bbf9-2355-5210-9325-f25d83a8ff35': FixtureScenario.betaReady,
  'd04073fd-f7ab-518d-8938-f2920d593db2': FixtureScenario.gammaMonthEnd,
};
