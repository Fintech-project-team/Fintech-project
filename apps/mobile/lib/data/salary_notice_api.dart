import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth/auth_repository.dart';
import 'http/api_config.dart';
import 'http/api_transport.dart';

/// 2026-11-01: 급여 회차 안내 상태(apps/api/docs/salary-notices.md). 입금 확인·계산과 무관한 큰 안내 닫기 기록이다.
class SalaryNoticeState {
  /// 2026-11-01: 소유자 [userId], 명목 회차 [payMonth](YYYY-MM), 닫힘 [dismissed], 최초 닫은 시각 [dismissedAt]으로 만든다.
  const SalaryNoticeState({
    required this.userId,
    required this.payMonth,
    required this.dismissed,
    required this.dismissedAt,
  });

  final String userId;
  final String payMonth;
  final bool dismissed;
  final DateTime? dismissedAt;
}

/// 2026-11-01: 안내 조회·닫기 결과.
sealed class SalaryNoticeResult {
  const SalaryNoticeResult();
}

/// 2026-11-01: 성공. [state]는 서버가 돌려준 현재 상태다.
final class SalaryNoticeOk extends SalaryNoticeResult {
  /// 2026-11-01: 상태 [state]로 만든다.
  const SalaryNoticeOk(this.state);

  final SalaryNoticeState state;
}

/// 2026-11-01: 401 SESSION_INVALID. 금융 조회와 같은 세션 무효 처리(신규 로그인)를 따른다.
final class SalaryNoticeSessionInvalid extends SalaryNoticeResult {
  /// 2026-11-01: 세션 무효를 만든다.
  const SalaryNoticeSessionInvalid();
}

/// 2026-11-01: 그 밖의 실패(통신·서비스 불가·형식 오류·응답 유실). 닫기 저장 성공으로 보지 않는다.
final class SalaryNoticeFailed extends SalaryNoticeResult {
  /// 2026-11-01: 원인 [error]로 만든다.
  const SalaryNoticeFailed(this.error);

  final Object error;
}

/// 2026-11-01: 한 세션의 급여 안내 API. payMonth는 앱이 계산 결과에서 확인한 명목 회차만 넘긴다(추정 금지).
abstract interface class SalaryNoticeApi {
  /// 2026-11-01: GET /salary-notices/{payMonth}.
  Future<SalaryNoticeResult> read(String payMonth);

  /// 2026-11-01: PUT /salary-notices/{payMonth}/dismissal. 반복해도 최초 기록을 유지한다.
  Future<SalaryNoticeResult> dismiss(String payMonth);
}

/// 2026-11-01: 서버가 없는 빌드의 구현. 모든 요청이 실패다.
class UnavailableSalaryNoticeApi implements SalaryNoticeApi {
  /// 2026-11-01: 상태 없는 인스턴스를 만든다.
  const UnavailableSalaryNoticeApi();

  /// 2026-11-01: 실패를 반환한다.
  @override
  Future<SalaryNoticeResult> read(String payMonth) async =>
      const SalaryNoticeFailed('unavailable');

  /// 2026-11-01: 실패를 반환한다.
  @override
  Future<SalaryNoticeResult> dismiss(String payMonth) async =>
      const SalaryNoticeFailed('unavailable');
}

/// 2026-11-01: 실제 서버의 급여 안내 API. 본문·쿼리·멱등 헤더 없이 Bearer만 보낸다.
class HttpSalaryNoticeApi implements SalaryNoticeApi {
  /// 2026-11-01: 서버 설정 [config], 통신 [transport], 세션 토큰 [accessToken]으로 만든다.
  const HttpSalaryNoticeApi({
    required this.config,
    required this.transport,
    required this.accessToken,
  });

  final ApiConfig config;
  final ApiTransport transport;
  final String accessToken;

  /// 2026-11-01: 현재 안내 상태를 읽는다.
  @override
  Future<SalaryNoticeResult> read(String payMonth) =>
      _send('GET', '/salary-notices/$payMonth', payMonth);

  /// 2026-11-01: 안내를 닫은 기록을 남긴다.
  @override
  Future<SalaryNoticeResult> dismiss(String payMonth) =>
      _send('PUT', '/salary-notices/$payMonth/dismissal', payMonth);

  /// 2026-11-01: 요청을 한 번 보내 200이면 응답 형식·회차를 검사해 읽는다. 사용자 대조는 [SalaryNoticeController]가 한다.
  Future<SalaryNoticeResult> _send(
    String method,
    String path,
    String payMonth,
  ) async {
    final ApiResponse response;
    try {
      response = await transport.send(
        ApiRequest(
          method: method,
          uri: config.resolve(path),
          headers: {'authorization': 'Bearer $accessToken'},
        ),
      );
    } on ApiTransportException catch (error) {
      return SalaryNoticeFailed(error);
    }
    if (response.status == 401 && response.errorCode == 'SESSION_INVALID') {
      return const SalaryNoticeSessionInvalid();
    }
    final json = response.jsonObject;
    if (response.status != 200 || json == null) {
      return SalaryNoticeFailed(ApiNonContractResponse(response.status));
    }
    final state = parseSalaryNoticeState(json);
    return state == null || state.payMonth != payMonth
        ? const SalaryNoticeFailed('format')
        : SalaryNoticeOk(state);
  }
}

/// 2026-11-01: 성공 응답 다섯 키를 읽는다. 계약 버전이 다르거나 닫힘과 시각이 맞지 않으면 null이다.
SalaryNoticeState? parseSalaryNoticeState(Map<String, Object?> json) {
  final userId = json['userId'];
  final payMonth = json['payMonth'];
  final dismissed = json['dismissed'];
  final at = json['dismissedAt'];
  final dismissedAt = at is String ? DateTime.tryParse(at) : null;
  if (json['contractVersion'] != 'PAYSE-SALARY-NOTICE-1' ||
      userId is! String ||
      payMonth is! String ||
      dismissed is! bool ||
      (dismissed ? dismissedAt == null : at != null)) {
    return null;
  }
  return SalaryNoticeState(
    userId: userId,
    payMonth: payMonth,
    dismissed: dismissed,
    dismissedAt: dismissedAt,
  );
}

/// 2026-11-01: 개발 빌드의 가짜 급여 안내 서버. 사용자+회차별 최초 닫은 시각을 앱 실행 동안 메모리에 둔다.
class FakeSalaryNoticeServer {
  /// 2026-11-01: 세션 판정 [sessions]와 시각 [now]로 만든다.
  FakeSalaryNoticeServer({required this.sessions, required this.now});

  final SessionResolver sessions;
  final DateTime Function() now;
  final Map<(String, String), DateTime> _dismissed = {};

  /// 2026-11-01: 토큰 [accessToken]의 회차 [payMonth] 상태를 읽고, [dismiss]면 처음 한 번만 기록한다.
  SalaryNoticeResult handle(String accessToken, String payMonth, bool dismiss) {
    final userId = sessions.userIdForToken(accessToken);
    if (userId == null) return const SalaryNoticeSessionInvalid();
    if (dismiss) _dismissed.putIfAbsent((userId, payMonth), now);
    final at = _dismissed[(userId, payMonth)];
    return SalaryNoticeOk(
      SalaryNoticeState(
        userId: userId,
        payMonth: payMonth,
        dismissed: at != null,
        dismissedAt: at,
      ),
    );
  }
}

/// 2026-11-01: [FakeSalaryNoticeServer]에 세션 토큰으로 요청하는 구현.
class FakeSalaryNoticeApi implements SalaryNoticeApi {
  /// 2026-11-01: 서버 [server]와 토큰 [accessToken]으로 만든다.
  const FakeSalaryNoticeApi({required this.server, required this.accessToken});

  final FakeSalaryNoticeServer server;
  final String accessToken;

  /// 2026-11-01: 상태를 읽는다.
  @override
  Future<SalaryNoticeResult> read(String payMonth) async =>
      server.handle(accessToken, payMonth, false);

  /// 2026-11-01: 닫기를 기록한다.
  @override
  Future<SalaryNoticeResult> dismiss(String payMonth) async =>
      server.handle(accessToken, payMonth, true);
}

/// 2026-11-01: 한 세션의 홈 급여 안내 접힘 상태. 세션이 바뀌면 새로 만들고 이전 것은 [dispose]해 늦은 응답을 버린다.
/// 회차를 아는 안내는 서버 기록을 따른다. 서버 닫기 기록은 지우는 API가 없으므로 한 번 닫힘을 확인한 회차는 늦게 온 GET이
/// 되돌리지 않는다. 접기 저장(PUT)이 확인되기 전에는 이 세션 화면에서만 접어 두고 저장 성공으로 보지 않으며, [refresh] 때
/// 같은 PUT을 다시 보낸다. 회차를 모르는 안내는 서버에 묻지 않고 이 세션 동안만 접으며, 안내 키(종류·예정일·월급 설정)가 바뀌면
/// 다시 펼친다. 조회 실패·지연은 안내를 펼친 채 두고 홈 표시를 막지 않는다.
class SalaryNoticeController extends ChangeNotifier {
  /// 2026-11-01: 세션 API [api], 이 세션의 사용자 [userId], 세션 무효 콜백 [onSessionInvalid]로 만든다.
  SalaryNoticeController({
    required this.api,
    required this.userId,
    required this.onSessionInvalid,
  });

  final SalaryNoticeApi api;
  final String userId;
  final VoidCallback onSessionInvalid;
  final Set<String> _dismissed = {};
  final Set<String> _unconfirmed = {};
  final Set<String> _requested = {};
  String? _sessionFold;
  bool _disposed = false;

  /// 2026-11-01: 회차 [payMonth]의 닫기가 서버에서 확인됐으면 true를 반환한다.
  bool isConfirmed(String payMonth) => _dismissed.contains(payMonth);

  /// 2026-11-01: 회차 [payMonth](없으면 null)와 안내 키 [noticeKey]의 안내가 접혀 보여야 하면 true를 반환한다.
  /// 회차를 알고 아직 조회하지 않았으면 조회를 시작하고, 결과가 오기 전까지는 펼친 채로 둔다.
  bool isFolded(String? payMonth, String noticeKey) {
    if (payMonth == null) return _sessionFold == noticeKey;
    if (_dismissed.contains(payMonth) || _unconfirmed.contains(payMonth)) {
      return true;
    }
    if (_requested.add(payMonth)) scheduleMicrotask(() => _read(payMonth));
    return false;
  }

  /// 2026-11-01: 안내를 접는다. 회차를 알면 서버에 닫기를 저장하고, 모르면 이 세션 동안만 접는다.
  void fold(String? payMonth, String noticeKey) {
    if (payMonth == null) {
      _sessionFold = noticeKey;
    } else if (!_dismissed.contains(payMonth)) {
      _unconfirmed.add(payMonth);
      _dismiss(payMonth);
    }
    notifyListeners();
  }

  /// 2026-11-01: 새 Snapshot을 받았다. 실패했던 조회를 다시 할 수 있게 하고, 확인되지 않은 닫기를 같은 요청으로 다시 보낸다.
  void refresh() {
    _requested.removeWhere((m) => !_dismissed.contains(m));
    for (final payMonth in List.of(_unconfirmed)) {
      _dismiss(payMonth);
    }
  }

  /// 2026-11-01: 이후 도착하는 응답을 버린다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 2026-11-01: 회차 [payMonth] 상태를 조회한다. 닫힘이면 기록하고, 닫히지 않음은 이미 확인한 닫힘을 되돌리지 않는다.
  Future<void> _read(String payMonth) async {
    final result = await api.read(payMonth);
    if (_disposed) return;
    if (_apply(result, payMonth)) notifyListeners();
  }

  /// 2026-11-01: 회차 [payMonth] 닫기를 저장한다. 성공 응답에서 닫힘을 확인할 때만 저장 성공으로 본다.
  Future<void> _dismiss(String payMonth) async {
    final result = await api.dismiss(payMonth);
    if (_disposed) return;
    if (_apply(result, payMonth)) notifyListeners();
  }

  /// 2026-11-01: 응답 [result]를 반영하고 화면이 바뀌면 true를 반환한다. 다른 사용자·회차의 응답은 버린다.
  bool _apply(SalaryNoticeResult result, String payMonth) {
    switch (result) {
      case SalaryNoticeOk(:final state)
          when state.userId == userId &&
              state.payMonth == payMonth &&
              state.dismissed:
        _unconfirmed.remove(payMonth);
        return _dismissed.add(payMonth);
      case SalaryNoticeOk():
      case SalaryNoticeFailed():
        return false;
      case SalaryNoticeSessionInvalid():
        onSessionInvalid();
        return false;
    }
  }
}
