import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/session_cleanup.dart';

/// 2026-10-21: 종료 결과를 차례로 돌려주는 테스트용 저장소. 다른 메서드는 쓰지 않는다.
class _EndOnlyRepository extends UnavailableAuthRepository {
  _EndOnlyRepository(this.results);

  final List<AuthOutcome<void>> results;
  final List<String> calls = [];

  /// 2026-10-21: 호출을 기록하고 준비한 결과를 차례로 반환한다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) async {
    calls.add(accessToken);
    return results.removeAt(0);
  }
}

void main() {
  test(
    'success or already-invalid counts as ended; other results are kept',
    () async {
      final repo = _EndOnlyRepository([
        const AuthOk(null),
        const AuthSessionInvalid(),
        const AuthUnavailable(),
        AuthNetworkFailure(Exception('offline')),
      ]);
      final cleanup = PendingSessionCleanup(repo);

      expect(await cleanup.end('a'), isTrue);
      expect(await cleanup.end('b'), isTrue);
      expect(await cleanup.end('c'), isFalse);
      expect(await cleanup.end('d'), isFalse);
      expect(cleanup.pendingCount, 2);
    },
  );

  test('retry keeps only the tokens that still fail', () async {
    final repo = _EndOnlyRepository([
      const AuthUnavailable(),
      const AuthUnavailable(),
      const AuthOk(null),
      const AuthUnavailable(),
      const AuthOk(null),
    ]);
    final cleanup = PendingSessionCleanup(repo);
    await cleanup.end('a');
    await cleanup.end('b');

    expect(await cleanup.retryPending(), isFalse);
    expect(cleanup.pendingCount, 1);
    expect(await cleanup.retryPending(), isTrue);
    expect(cleanup.pendingCount, 0);
    expect(repo.calls, ['a', 'b', 'a', 'b', 'b']);
  });
}
