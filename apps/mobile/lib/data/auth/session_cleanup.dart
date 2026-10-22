import 'auth_repository.dart';

/// 2026-10-21: 화면이 사라진 뒤 받은 세션처럼, 기기에 저장하지 않을 세션을 서버에서 끝내는 앱 수명 정리 담당.
/// 종료가 확인(성공 또는 이미 무효)되기 전에는 토큰을 버리지 않고 보관해 다음 인증 요청 전에 다시 시도한다.
/// 보관은 메모리이며 앱 프로세스가 끝나면 사라진다(실제 보안 저장소 작업에서 다시 정한다).
class PendingSessionCleanup {
  /// 2026-10-21: 종료 요청을 보낼 [repository]로 만든다.
  PendingSessionCleanup(this.repository);

  final AuthRepository repository;
  final List<String> _pending = [];

  /// 2026-10-21: 아직 종료를 확인하지 못한 토큰 수를 반환한다.
  int get pendingCount => _pending.length;

  /// 2026-10-21: [accessToken] 세션 종료를 요청한다. 확인되면 true, 실패하면 보관 후 false를 반환한다.
  Future<bool> end(String accessToken) async {
    if (await _tryEnd(accessToken)) return true;
    if (!_pending.contains(accessToken)) _pending.add(accessToken);
    return false;
  }

  /// 2026-10-21: 보관한 토큰의 종료를 다시 시도한다. 모두 확인되면 true를 반환한다. 실패한 토큰은 남긴다.
  Future<bool> retryPending() async {
    for (final token in List<String>.of(_pending)) {
      if (await _tryEnd(token)) _pending.remove(token);
    }
    return _pending.isEmpty;
  }

  /// 2026-10-21: 종료 요청 결과가 성공이거나 토큰이 이미 무효면 true를 반환한다.
  Future<bool> _tryEnd(String accessToken) async {
    final result = await repository.endSession(accessToken);
    return result is AuthOk || result is AuthSessionInvalid;
  }
}
