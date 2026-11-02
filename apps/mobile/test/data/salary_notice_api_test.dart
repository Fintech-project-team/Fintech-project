import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/http/api_transport.dart';
import 'package:payse/data/salary_notice_api.dart';

import 'http/fake_api_transport.dart';

/// 2026-11-01: 응답 시점을 테스트가 정하는 급여 안내 API.
class _HeldApi implements SalaryNoticeApi {
  final List<(String, String, Completer<SalaryNoticeResult>)> calls = [];

  @override
  Future<SalaryNoticeResult> read(String payMonth) => _hold('GET', payMonth);

  @override
  Future<SalaryNoticeResult> dismiss(String payMonth) => _hold('PUT', payMonth);

  Future<SalaryNoticeResult> _hold(String method, String payMonth) {
    final c = Completer<SalaryNoticeResult>();
    calls.add((method, payMonth, c));
    return c.future;
  }
}

SalaryNoticeResult _state(String user, String month, bool dismissed) =>
    SalaryNoticeOk(
      SalaryNoticeState(
        userId: user,
        payMonth: month,
        dismissed: dismissed,
        dismissedAt: dismissed ? DateTime.utc(2026, 11) : null,
      ),
    );

void main() {
  late _HeldApi api;
  late SalaryNoticeController notices;
  var invalid = 0;

  setUp(() {
    api = _HeldApi();
    invalid = 0;
    notices = SalaryNoticeController(
      api: api,
      userId: 'u1',
      onSessionInvalid: () => invalid++,
    );
  });

  test(
    'a known month asks the server once and stays open until it answers',
    () async {
      expect(notices.isFolded('2026-11', 'k'), isFalse);
      expect(notices.isFolded('2026-11', 'k'), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(api.calls.map((c) => c.$1), ['GET']);
      api.calls.single.$3.complete(_state('u1', '2026-11', true));
      await Future<void>.delayed(Duration.zero);
      expect(
        notices.isFolded('2026-11', 'other-key'),
        isTrue,
        reason: '설정이 바뀌어도 같은 회차는 접힌 채',
      );
    },
  );

  test('a failed or lost PUT folds this session only and is retried, never confirmed', () async {
    notices.fold('2026-11', 'k');
    expect(notices.isFolded('2026-11', 'k'), isTrue);
    expect(notices.isConfirmed('2026-11'), isFalse);
    api.calls.single.$3.complete(const SalaryNoticeFailed('lost'));
    await Future<void>.delayed(Duration.zero);
    expect(notices.isConfirmed('2026-11'), isFalse);

    notices.refresh();
    expect(api.calls.last.$1, 'PUT', reason: '같은 PUT 재전송');
    api.calls.last.$3.complete(_state('u1', '2026-11', true));
    await Future<void>.delayed(Duration.zero);
    expect(notices.isConfirmed('2026-11'), isTrue);
  });

  test(
    'a late GET saying not dismissed does not undo a confirmed PUT',
    () async {
      notices.isFolded('2026-11', 'k');
      await Future<void>.delayed(Duration.zero);
      final get = api.calls.single.$3;
      notices.fold('2026-11', 'k');
      api.calls.last.$3.complete(_state('u1', '2026-11', true));
      await Future<void>.delayed(Duration.zero);
      get.complete(_state('u1', '2026-11', false));
      await Future<void>.delayed(Duration.zero);
      expect(notices.isFolded('2026-11', 'k'), isTrue);
    },
  );

  test(
    'answers for another user or month and answers after dispose are ignored',
    () async {
      notices.fold('2026-11', 'k');
      api.calls.single.$3.complete(_state('u2', '2026-11', true));
      await Future<void>.delayed(Duration.zero);
      expect(notices.isConfirmed('2026-11'), isFalse);

      final next = SalaryNoticeController(
        api: api,
        userId: 'u1',
        onSessionInvalid: () {},
      );
      next.fold('2026-12', 'k');
      next.dispose();
      api.calls.last.$3.complete(_state('u1', '2026-12', true));
      await Future<void>.delayed(Duration.zero);
      expect(
        next.isConfirmed('2026-12'),
        isFalse,
        reason: '이전 세션(같은 사용자 재로그인 전) 응답',
      );
    },
  );

  test(
    'an unknown month is never sent and folds only for the same notice key',
    () {
      notices.fold(null, 'awaiting|2026-10-25|25');
      expect(notices.isFolded(null, 'awaiting|2026-10-25|25'), isTrue);
      expect(notices.isFolded(null, 'awaiting|2026-10-25|26'), isFalse);
      expect(api.calls, isEmpty);
    },
  );

  test('SESSION_INVALID goes to the common session handling', () async {
    notices.fold('2026-11', 'k');
    api.calls.single.$3.complete(const SalaryNoticeSessionInvalid());
    await Future<void>.delayed(Duration.zero);
    expect(invalid, 1);
  });

  test('http: GET and PUT have no body; the response is checked', () async {
    final transport = FakeApiTransport(
      (r) => jsonResponse(200, {
        'contractVersion': 'PAYSE-SALARY-NOTICE-1',
        'userId': 'u1',
        'payMonth': '2026-11',
        'dismissed': r.method == 'PUT',
        'dismissedAt': r.method == 'PUT' ? '2026-11-01T03:00:00Z' : null,
      }),
    );
    final http = HttpSalaryNoticeApi(
      config: testApiConfig,
      transport: transport,
      accessToken: 't',
    );
    expect(await http.read('2026-11'), isA<SalaryNoticeOk>());
    expect(await http.dismiss('2026-11'), isA<SalaryNoticeOk>());
    expect(transport.requests.map((r) => (r.method, r.uri.path, r.body)), [
      ('GET', '/api/salary-notices/2026-11', null),
      ('PUT', '/api/salary-notices/2026-11/dismissal', null),
    ]);
    expect(
      await http.read('2026-12'),
      isA<SalaryNoticeFailed>(),
      reason: '다른 회차 응답',
    );

    transport.handler = (_) => errorResponse(401, 'SESSION_INVALID');
    expect(await http.dismiss('2026-11'), isA<SalaryNoticeSessionInvalid>());
    transport.handler = (_) =>
        throw const ApiTransportException(ApiFailureKind.unknown, 'lost');
    expect(await http.dismiss('2026-11'), isA<SalaryNoticeFailed>());
  });
}
