import '../financial_snapshot.dart';
import '../financial_snapshot_repository.dart';
import 'financial_api.dart';

/// 2026-10-22: 세션 금융 조회 실패를 화면이 구분하도록 담는 원인. 401이면 신규 로그인으로 보낸다.
class FinancialLoadError {
  /// 2026-10-22: 조회 결과 [outcome]으로 만든다.
  const FinancialLoadError(this.outcome);

  final FinancialOutcome<Object?> outcome;

  /// 2026-10-22: 세션이 무효(401)면 true를 반환한다.
  bool get sessionInvalid => outcome is FinancialSessionInvalid;
}

/// 2026-10-22: [UserFinancialRepository]의 Snapshot JSON을 화면용 [FinancialSnapshot]으로 읽는 어댑터.
/// 금액을 계산하지 않으며 읽기 실패와 형식 오류를 구분한다.
class UserSnapshotRepository implements FinancialSnapshotRepository {
  /// 2026-10-22: 세션 금융 저장소 [repository]로 만든다.
  const UserSnapshotRepository(this.repository);

  final UserFinancialRepository repository;

  /// 2026-10-22: 현재 Snapshot을 조회해 결과 타입으로 반환한다. 계약된 실패는 결과 타입으로 돌려주고
  /// 프로그래밍 오류(TypeError 등)는 잡지 않는다.
  @override
  Future<SnapshotLoadResult> loadSnapshot() async {
    final result = await repository.loadSnapshot();
    if (result case FinancialOk(:final value)) {
      try {
        return SnapshotLoaded(FinancialSnapshot.fromJson(value));
      } on SnapshotFormatException catch (error) {
        return SnapshotFormatInvalid(error.path, error.reason);
      }
    }
    return SnapshotLoadFailed(FinancialLoadError(result));
  }
}
