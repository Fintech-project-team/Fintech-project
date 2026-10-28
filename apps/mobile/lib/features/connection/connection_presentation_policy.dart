import 'dart:math';

/// 2026-10-22: 금융사 불러오기 표시 연출 정책(v0.6 화면 규칙 '금융사 표시 연출', app-architecture §7).
/// 금융 데이터와 분리된 화면 연출이며 난수·지연을 주입해 테스트에서 재현한다. 연출 성공을 API 성공으로 쓰지 않는다.
class ConnectionPresentationPolicy {
  /// 2026-10-22: 실패 연출 사용 여부 [failuresEnabled], 난수 [random], 지연 대기 [wait]로 만든다.
  /// [wait]를 생략하면 실제 시간만큼 기다린다.
  /// 2026-10-23: [failuresEnabled]는 추첨할 때마다 읽는 현재 값(개발 설정 토글)이다.
  ConnectionPresentationPolicy({
    required this.failuresEnabled,
    Random? random,
    Future<void> Function(Duration)? wait,
  }) : _random = random ?? Random(),
       _wait = wait ?? Future<void>.delayed;

  final bool Function() failuresEnabled;
  final Random _random;
  final Future<void> Function(Duration) _wait;

  static const double failureChance = 0.1;
  static const int maxFailures = 2;

  /// 2026-10-22: 기관 순서 [codes]에서 실패 연출할 기관을 추첨해 반환한다. 기관마다 10%, 최대 2곳이다.
  /// 흐름마다 첫 불러오기에서 한 번만 부르고 같은 흐름의 다시 시도에서는 다시 추첨하지 않는다.
  /// 2026-10-23: 실패 연출 사용 여부는 이 추첨 직전 값을 읽으며, 결과는 부른 흐름이 보관해 고정한다.
  Set<String> drawFailures(List<String> codes) {
    if (!failuresEnabled()) return const {};
    final failed = <String>{};
    for (final code in codes) {
      if (failed.length >= maxFailures) break;
      if (_random.nextDouble() < failureChance) failed.add(code);
    }
    return failed;
  }

  /// 2026-10-23: 12-1 진입 로딩 한 단계(은행·카드사 각각 1~1.5초, 합쳐 2~3초)를 기다린다.
  Future<void> entryStepDelay() => _wait(_between(1000, 1500));

  /// 2026-10-22: 기관 한 곳의 순차 처리 지연(1~1.5초)을 기다린다.
  Future<void> stepDelay() => _wait(_between(1000, 1500));

  /// 2026-10-22: 실패 행 다시 시도 뒤 표시상 완료까지(2~3초)를 기다린다.
  Future<void> retryDelay() => _wait(_between(2000, 3000));

  /// 2026-10-28: 홈 새로고침 로딩을 보이는 최소 시간(3초)을 기다린다.
  Future<void> refreshMinimum() => _wait(const Duration(seconds: 3));

  /// 2026-10-22: [minMs] 이상 [maxMs] 이하의 지연을 반환한다.
  Duration _between(int minMs, int maxMs) =>
      Duration(milliseconds: minMs + _random.nextInt(maxMs - minMs + 1));
}
