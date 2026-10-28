/// 2026-10-20: FakeRepository가 읽을 수 있는 합성 더미 스냅샷. 화면은 이 이름으로만 고르고 파일 경로를 모른다.
/// 2026-10-27: #100 일상 지출 시연(demo-ready)을 기본으로 둔다. alpha-ready는 부분 정산·보호 배정 검증 사례로 남긴다.
enum FixtureScenario {
  demoReady('demo-ready', '일상 지출 시연(기본)'),
  alphaReady('alpha-ready', '부분 정산·보호 배정'),
  alphaShock('alpha-shock', '잔액 하락 사건'),
  salaryWait('salary-wait', '월급일 입금 전'),
  alphaUnconnected('alpha-unconnected', '금융사 연결 전'),
  betaReady('beta-ready', 'beta 계정 원본'),
  gammaMonthEnd('gamma-month-end', 'gamma 계정 원본(말일)');

  /// 2026-10-20: [fileStem]은 catalog.json의 사례 id, [devLabel]은 개발용 화면의 짧은 설명이다.
  const FixtureScenario(this.fileStem, this.devLabel);

  final String fileStem;
  final String devLabel;

  /// 2026-10-20: 기본 스냅샷.
  static const FixtureScenario defaultScenario = FixtureScenario.demoReady;
}
