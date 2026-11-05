import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/analysis/analysis_api.dart';
import 'package:payse/data/http/api_config.dart';
import 'package:payse/data/http/api_transport.dart';

/// 2026-11-05: A가 공개한 HTTP 예제 14개. 형식이 바뀌면 이 파서도 함께 확인해야 한다.
final Map<String, dynamic> _examples = jsonDecode(
  File('../api/testing/protocol/fixtures/http-examples.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

/// 2026-11-05: 예제 [name]의 값을 반환한다.
Map<String, Object?> _example(String name) =>
    ((_examples['examples'] as List).firstWhere(
          (e) => (e as Map)['name'] == name,
        ) as Map)['value']
        as Map<String, Object?>;

/// 2026-11-05: 보낸 요청을 남기고 정해 둔 응답을 돌려주는 통신.
class _Transport implements ApiTransport {
  /// 2026-11-05: 돌려줄 응답 [reply]로 만든다.
  _Transport(this.reply);

  final ApiResponse Function(ApiRequest request) reply;
  final List<ApiRequest> sent = [];

  /// 2026-11-05: 요청을 남기고 응답을 돌려준다.
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    sent.add(request);
    return reply(request);
  }
}

/// 2026-11-05: JSON 응답을 만든다.
ApiResponse _json(int status, Object body, {Map<String, String>? headers}) =>
    ApiResponse(
      status: status,
      headers: {'content-type': 'application/json', ...?headers},
      body: jsonEncode(body),
    );

void main() {
  final config = ApiConfig.parse(
    baseUrl: 'https://api.example.test/v1',
    timeoutSeconds: '20',
  )!;

  /// 2026-11-05: [reply]를 쓰는 API와 통신을 만든다.
  (HttpAnalysisApi, _Transport) api(
    ApiResponse Function(ApiRequest request) reply,
  ) {
    final transport = _Transport(reply);
    return (
      HttpAnalysisApi(
        config: config,
        transport: transport,
        accessToken: 'token-1',
      ),
      transport,
    );
  }

  test('every public job and query example parses', () {
    for (final name in [
      'queued',
      'awaitingInput',
      'running',
      'succeeded',
      'failed',
      'outcomeUnknown',
    ]) {
      expect(
        AnalysisJobStatus.fromJson(_example(name)),
        isNotNull,
        reason: name,
      );
    }
    final waiting = AnalysisJobStatus.fromJson(_example('awaitingInput'))!;
    expect(waiting.action, AnalysisJobAction.submitInput);
    expect(waiting.permit, isNotNull);
    final unknown = AnalysisJobStatus.fromJson(_example('outcomeUnknown'))!;
    expect(unknown.retryNeedsAcknowledgement, isTrue);
    for (final (name, availability) in [
      ('available_candidate', AnalysisAvailability.available),
      ('available_unknown', AnalysisAvailability.available),
      ('missing', AnalysisAvailability.missing),
    ]) {
      expect(
        AnalysisQueryResult.fromJson(_example(name))?.availability,
        availability,
      );
    }
  });

  test('unknown states, missing permits and other contracts are rejected', () {
    final running = {..._example('running')};
    expect(AnalysisJobStatus.fromJson({...running, 'state': 'paused'}), isNull);
    expect(
      AnalysisJobStatus.fromJson({...running, 'contractVersion': 'X'}),
      isNull,
    );
    final waiting = {..._example('awaitingInput')}..remove('permit');
    expect(AnalysisJobStatus.fromJson(waiting), isNull);
    expect(
      AnalysisQueryResult.fromJson({
        ..._example('missing'),
        'resultAvailability': 'gone',
      }),
      isNull,
    );
  });

  test(
    'requests carry the bearer token, paths and the wait preference',
    () async {
      final (http, transport) = api((_) => _json(200, _example('running')));
      await http.status('job/1', wait: true);
      await http.status('job-2');
      await http.submitInput('job-3', {'a': 1});
      await http.retry('job-4', {'b': 2});
      await http.accept({'c': 3});
      await http.query({'d': 4});
      expect(
        [for (final r in transport.sent) '${r.method} ${r.uri.path}'],
        [
          'GET /v1/analysis-jobs/job%2F1',
          'GET /v1/analysis-jobs/job-2',
          'POST /v1/analysis-jobs/job-3/input',
          'POST /v1/analysis-jobs/job-4/retry',
          'POST /v1/analysis-jobs',
          'POST /v1/analysis-results/query',
        ],
      );
      expect(transport.sent.first.headers['prefer'], 'wait=5');
      expect(transport.sent[1].headers.containsKey('prefer'), isFalse);
      expect(
        transport.sent.every(
          (r) => r.headers['authorization'] == 'Bearer token-1',
        ),
        isTrue,
      );
      expect(transport.sent[2].body, {'a': 1});
    },
  );

  test('202 is a success like 200', () async {
    final (http, _) = api((_) => _json(202, _example('queued')));
    final result = await http.accept({});
    expect(result, isA<AnalysisOk<AnalysisJobStatus>>());
  });

  test('errors keep status, code and retry-after', () async {
    final (http, _) = api(
      (_) => _json(
        429,
        {
          'error': {'code': 'RATE_LIMITED'},
        },
        headers: {'retry-after': '7'},
      ),
    );
    final result = await http.status('j');
    expect(result, isA<AnalysisRejected<AnalysisJobStatus>>());
    final rejected = result as AnalysisRejected<AnalysisJobStatus>;
    expect(rejected.status, 429);
    expect(rejected.code, 'RATE_LIMITED');
    expect(rejected.retryAfter, const Duration(seconds: 7));
  });

  test('401 ends the session and closing drops late answers', () async {
    final (expired, _) = api(
      (_) => _json(401, {
        'error': {'code': 'X'},
      }),
    );
    expect(
      await expired.status('j'),
      isA<AnalysisSessionInvalid<AnalysisJobStatus>>(),
    );
    final (http, transport) = api((_) => _json(200, _example('running')));
    http.close();
    expect(
      await http.status('j'),
      isA<AnalysisSessionInvalid<AnalysisJobStatus>>(),
    );
    expect(transport.sent, isEmpty);
  });

  test(
    'non-contract answers and lost responses are network failures',
    () async {
      final (proxy, _) = api(
        (_) => const ApiResponse(status: 502, headers: {}, body: 'bad gateway'),
      );
      final failed = await proxy.status('j');
      expect(failed, isA<AnalysisNetworkFailure<AnalysisJobStatus>>());
      final (broken, _) = api((_) => _json(200, {'contractVersion': 'nope'}));
      expect(
        await broken.status('j'),
        isA<AnalysisNetworkFailure<AnalysisJobStatus>>(),
      );
      final (lost, _) = api(
        (_) => throw const ApiTransportException(
          ApiFailureKind.unknown,
          'timeout',
        ),
      );
      final unknown = await lost.submitInput('j', {});
      expect((unknown as AnalysisNetworkFailure).sent, isTrue);
      final (refused, _) = api(
        (_) => throw const ApiTransportException(
          ApiFailureKind.notSent,
          'refused',
        ),
      );
      expect(
        ((await refused.accept({})) as AnalysisNetworkFailure).sent,
        isFalse,
      );
    },
  );
}
