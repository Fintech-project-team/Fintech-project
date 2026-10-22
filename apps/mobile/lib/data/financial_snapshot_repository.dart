import 'dart:convert';

import 'financial_snapshot.dart';
import 'fixture_scenario.dart';
import 'snapshot_source.dart';

/// 2026-10-20: 스냅샷 조회 결과. 성공·읽기 실패·형식 오류를 서로 다른 타입으로 구분한다.
sealed class SnapshotLoadResult {
  /// 2026-10-20: 하위 결과 타입만 만든다.
  const SnapshotLoadResult();
}

/// 2026-10-20: 조회 성공. [snapshot]은 불변 원천 값이다.
final class SnapshotLoaded extends SnapshotLoadResult {
  /// 2026-10-20: 읽은 [snapshot]으로 만든다.
  const SnapshotLoaded(this.snapshot);

  final FinancialSnapshot snapshot;
}

/// 2026-10-20: 원문을 읽지 못함(에셋 없음·연결 오류 등). 빈 자료나 0원으로 대체하지 않는다.
final class SnapshotLoadFailed extends SnapshotLoadResult {
  /// 2026-10-20: 원인 [error]로 만든다.
  const SnapshotLoadFailed(this.error);

  final Object error;
}

/// 2026-10-20: 원문은 읽었으나 JSON·계약 형식이 맞지 않음. [path]는 문제 위치다.
final class SnapshotFormatInvalid extends SnapshotLoadResult {
  /// 2026-10-20: 문제 위치 [path]와 이유 [reason]으로 만든다.
  const SnapshotFormatInvalid(this.path, this.reason);

  final String path;
  final String reason;
}

/// 2026-10-20: 화면이 쓰는 금융 스냅샷 조회 계약. Fake와 실제 API 구현이 같은 의미를 지켜야 한다.
abstract interface class FinancialSnapshotRepository {
  /// 2026-10-20: 현재 사용자 스냅샷을 조회해 결과 타입으로 반환한다. 예외를 화면으로 던지지 않는다.
  Future<SnapshotLoadResult> loadSnapshot();
}

/// 2026-10-20: 합성 더미 스냅샷을 읽는 임시 구현. 파싱만 하며 금액 계산을 하지 않는다.
class FakeFinancialSnapshotRepository implements FinancialSnapshotRepository {
  /// 2026-10-20: 원문 출처 [source]와 읽을 [scenario]로 만든다. 스냅샷을 바꾸려면 새 인스턴스를 만든다.
  const FakeFinancialSnapshotRepository({
    required this.source,
    this.scenario = FixtureScenario.defaultScenario,
  });

  final SnapshotSource source;
  final FixtureScenario scenario;

  /// 2026-10-20: 원문을 읽고 파싱한 결과를 반환한다. 읽기 실패와 형식 오류를 구분한다.
  @override
  Future<SnapshotLoadResult> loadSnapshot() async {
    final String raw;
    try {
      raw = await source.load(scenario);
    } catch (error) {
      return SnapshotLoadFailed(error);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      return SnapshotFormatInvalid(r'$', 'JSON 해석 실패: ${error.message}');
    }
    try {
      return SnapshotLoaded(FinancialSnapshot.fromJson(decoded));
    } on SnapshotFormatException catch (error) {
      return SnapshotFormatInvalid(error.path, error.reason);
    }
  }
}
