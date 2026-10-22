import 'dart:math';

import 'auth_repository.dart';
import 'random_id.dart';

/// 2026-10-21: 가짜 저장소가 아는 데모 계정. 이름·전화번호는 server-seeds.json의 합성 값,
/// [code]는 서버 코드가 확정되기 전 호출자가 주는 임시 검증 값이다.
class FakeDemoAccount {
  /// 2026-10-21: 계정 [userId], 정규화한 [name]·[phone], 임시 [code]로 만든다.
  const FakeDemoAccount({
    required this.userId,
    required this.name,
    required this.phone,
    required this.code,
  });

  final String userId;
  final String name;
  final String phone;
  final String code;
}

/// 2026-10-21: [AuthRepository]의 메모리 구현. api-contract §2의 서버 동작을 흉내 낸다.
/// - 이름·전화번호·코드가 모두 맞고 활성 세션이 없을 때만 발급. 불일치·사용 중은 같은 거절.
/// - 이름+전화번호 조합 기준 최근 5분 실패 5회면 5번째 실패부터 429·5분 차단. 차단 중 시도는 종료 시각을 늘리지 않는다.
/// - 형식 오류는 422이며 실패로 세지 않는다. 무효 토큰은 401 SESSION_INVALID.
/// 실제 서버 연동이 아니며 앱을 다시 시작하면 상태가 사라진다.
class FakeAuthRepository implements AuthRepository {
  /// 2026-10-21: 계정 목록 [accounts], 시각 [now], 토큰·ID 난수 [random]으로 만든다.
  FakeAuthRepository({
    required List<FakeDemoAccount> accounts,
    DateTime Function()? now,
    Random? random,
  }) : _accounts = List.unmodifiable(accounts),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static const int maxFailures = 5;
  static const Duration failureWindow = Duration(minutes: 5);
  static const Duration blockDuration = Duration(minutes: 5);

  final List<FakeDemoAccount> _accounts;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, _ActiveSession> _sessionsByUser = {};
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _phone = RegExp(r'^010[0-9]{8}$');
  static final RegExp _code = RegExp(r'^[0-9]{6}$');

  /// 2026-10-21: 세션 발급을 흉내 낸다. 형식 오류는 실패로 세지 않고 422, 그다음 시도 제한·자격 대조 순이다.
  @override
  Future<AuthOutcome<DemoSession>> createSession(
    DemoCredentials credentials, {
    required String installationId,
  }) async {
    if (!_wellFormed(credentials) || !_uuid.hasMatch(installationId)) {
      return const AuthInvalidInput();
    }
    final limited = _rateLimit<DemoSession>(credentials);
    if (limited != null) return limited;
    final account = _match(credentials);
    if (account == null) return _fail(credentials);
    if (_sessionsByUser.containsKey(account.userId)) {
      return const AuthRejected();
    }
    final session = _ActiveSession(
      sessionId: randomUuidV4(_random),
      accessToken: _token(),
    );
    _sessionsByUser[account.userId] = session;
    return AuthOk(
      DemoSession(
        userId: account.userId,
        sessionId: session.sessionId,
        accessToken: session.accessToken,
        issuedAt: _now(),
      ),
    );
  }

  /// 2026-10-21: 토큰 소유자와 자격이 같은지만 확인한다. 새 세션을 만들지 않는다.
  /// 토큰이 이미 무효면 자격과 상관없이 [AuthSessionInvalid]를 돌려준다.
  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  ) async {
    final owner = _ownerOf(accessToken);
    if (owner == null) return const AuthSessionInvalid();
    if (!_wellFormed(credentials)) return const AuthInvalidInput();
    final limited = _rateLimit<ReverifiedSession>(credentials);
    if (limited != null) return limited;
    final account = _match(credentials);
    if (account == null || account.userId != owner) return _fail(credentials);
    return AuthOk(
      ReverifiedSession(
        userId: owner,
        sessionId: _sessionsByUser[owner]!.sessionId,
      ),
    );
  }

  /// 2026-10-21: [accessToken] 세션을 지운다. 이미 없는 토큰이면 [AuthSessionInvalid]를 돌려주고 아무것도 바꾸지 않는다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) async {
    final owner = _ownerOf(accessToken);
    if (owner == null) return const AuthSessionInvalid();
    _sessionsByUser.remove(owner);
    return const AuthOk(null);
  }

  /// 2026-10-21: 테스트·운영 흉내용으로 [userId]의 활성 세션을 서버 쪽에서 끝낸다(운영 종료, 09-13).
  void terminateSessionOf(String userId) => _sessionsByUser.remove(userId);

  /// 2026-10-21: 요청 형식(이름 앞뒤 공백 없음·2~20자, 010 11자리, ASCII 숫자 6자리)이 맞으면 true를 반환한다.
  bool _wellFormed(DemoCredentials c) {
    final nameLength = c.name.runes.length;
    return c.name == c.name.trim() &&
        nameLength >= 2 &&
        nameLength <= 20 &&
        _phone.hasMatch(c.phone) &&
        _code.hasMatch(c.code);
  }

  /// 2026-10-21: 자격 대조 실패를 기록한다. 이번 실패로 차단되면 429, 아니면 401을 반환한다(5번째 실패부터 429).
  AuthOutcome<T> _fail<T>(DemoCredentials c) {
    final blockedUntil = _recordFailure(c);
    if (blockedUntil != null) {
      return AuthRateLimited(blockedUntil.difference(_now()));
    }
    return const AuthRejected();
  }

  /// 2026-10-21: 이름·전화번호·코드가 모두 같은 계정을 반환한다. 없거나 둘 이상이면 null이다.
  FakeDemoAccount? _match(DemoCredentials c) {
    final found = _accounts
        .where(
          (a) => a.name == c.name && a.phone == c.phone && a.code == c.code,
        )
        .toList();
    return found.length == 1 ? found.single : null;
  }

  /// 2026-10-21: [accessToken]을 가진 사용자 ID를 반환한다. 없으면 null이다.
  String? _ownerOf(String accessToken) {
    for (final entry in _sessionsByUser.entries) {
      if (entry.value.accessToken == accessToken) return entry.key;
    }
    return null;
  }

  /// 2026-10-21: 시도 제한 키(정규화한 이름+전화번호)를 반환한다. 코드는 키에 넣지 않는다.
  String _key(DemoCredentials c) => '${c.name}\u0000${c.phone}';

  /// 2026-10-21: 차단 중이면 남은 시간을 담은 429 결과를, 아니면 null을 반환한다.
  AuthOutcome<T>? _rateLimit<T>(DemoCredentials c) {
    final key = _key(c);
    final until = _blockedUntil[key];
    if (until == null) return null;
    final now = _now();
    if (now.isBefore(until)) {
      final seconds = (until.difference(now).inMilliseconds / 1000).ceil();
      return AuthRateLimited(Duration(seconds: seconds));
    }
    _blockedUntil.remove(key);
    _failures.remove(key);
    return null;
  }

  /// 2026-10-21: 자격 대조 실패를 기록하고, 최근 5분 안에 5회가 되면 그때부터 5분 차단한다.
  /// 차단을 시작했으면 해제 시각을, 아니면 null을 반환한다.
  DateTime? _recordFailure(DemoCredentials c) {
    final key = _key(c);
    final now = _now();
    final recent = (_failures[key] ?? [])
      ..removeWhere((t) => now.difference(t) >= failureWindow)
      ..add(now);
    _failures[key] = recent;
    if (recent.length < maxFailures) return null;
    final until = now.add(blockDuration);
    _blockedUntil[key] = until;
    return until;
  }

  /// 2026-10-21: 32바이트 난수를 16진 문자열로 만든 불투명 토큰을 반환한다.
  String _token() => List.generate(
    32,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// 2026-10-21: 사용자별 활성 세션 하나.
class _ActiveSession {
  /// 2026-10-21: [sessionId]와 [accessToken]으로 만든다.
  const _ActiveSession({required this.sessionId, required this.accessToken});

  final String sessionId;
  final String accessToken;
}
