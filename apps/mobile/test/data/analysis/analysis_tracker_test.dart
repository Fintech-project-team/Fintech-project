import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/analysis/analysis_api.dart';
import 'package:payse/data/analysis/analysis_job_store.dart';
import 'package:payse/data/analysis/analysis_tracker.dart';
import 'package:payse/data/analysis/analysis_wait_session.dart';
import 'package:payse/data/financial_snapshot.dart';

/// 2026-11-05: 반복 후보가 있는 v4 더미(demo-life, 후보 11개·묶음 1개).
FinancialSnapshot _life() => FinancialSnapshot.fromJson(
  jsonDecode(
    File('../api/fixtures/generated-v4/snapshots/demo-life.json')
        .readAsStringSync(),
  ),
);

/// 2026-11-05: 작업 응답을 만든다.
AnalysisJobStatus _job(
  AnalysisJobState state, {
  String id = 'job-1',
  String? permit,
}) => AnalysisJobStatus(
  jobId: id,
  state: state,
  action: switch (state) {
    AnalysisJobState.awaitingInput => AnalysisJobAction.submitInput,
    AnalysisJobState.succeeded => AnalysisJobAction.readResult,
    AnalysisJobState.failed ||
    AnalysisJobState.cancelled ||
    AnalysisJobState.outcomeUnknown => AnalysisJobAction.retry,
    AnalysisJobState.expired => AnalysisJobAction.refreshInput,
    _ => AnalysisJobAction.wait,
  },
  availability: AnalysisAvailability.unchecked,
  permit:
      permit ??
      (state == AnalysisJobState.awaitingInput ? 'sha256:${'a' * 64}' : null),
);

/// 2026-11-05: 호출마다 미리 넣어 둔 응답을 차례로 돌려주는 분석 API. 응답이 떨어지면 그 호출을 [parked]에 두고
/// 테스트가 답할 때까지 기다리게 한다(응답이 오지 않는 요청).
class _ScriptedApi implements AnalysisApi {
  final Queue<AnalysisCall<AnalysisQueryResult>> queries = Queue();
  final Queue<AnalysisCall<AnalysisJobStatus>> accepts = Queue();
  final Queue<AnalysisCall<AnalysisJobStatus>> statuses = Queue();
  final Queue<AnalysisCall<AnalysisJobStatus>> submits = Queue();
  final Queue<AnalysisCall<AnalysisJobStatus>> retries = Queue();
  final List<String> calls = [];
  final List<Map<String, Object?>> bodies = [];
  final List<bool> waits = [];
  final List<Completer<Object?>> parked = [];

  /// 2026-11-05: [queue]에서 다음 응답을 꺼낸다. 비었으면 테스트가 [parked]로 답할 때까지 기다린다.
  Future<AnalysisCall<T>> _next<T>(Queue<AnalysisCall<T>> queue) async {
    if (queue.isNotEmpty) return queue.removeFirst();
    final waiting = Completer<Object?>();
    parked.add(waiting);
    return await waiting.future as AnalysisCall<T>;
  }

  /// 2026-11-05: 접수.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> accept(Map<String, Object?> body) {
    calls.add('accept');
    bodies.add(body);
    return _next(accepts);
  }

  /// 2026-11-05: 상태.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> status(
    String jobId, {
    bool wait = false,
  }) {
    calls.add('status $jobId');
    waits.add(wait);
    return _next(statuses);
  }

  /// 2026-11-05: 입력 제출.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> submitInput(
    String jobId,
    Map<String, Object?> body,
  ) {
    calls.add('submit $jobId');
    bodies.add(body);
    return _next(submits);
  }

  /// 2026-11-05: 재시도.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> retry(
    String jobId,
    Map<String, Object?> body,
  ) {
    calls.add('retry $jobId');
    bodies.add(body);
    return _next(retries);
  }

  /// 2026-11-05: 결과 조회.
  @override
  Future<AnalysisCall<AnalysisQueryResult>> query(Map<String, Object?> body) {
    calls.add('query');
    return _next(queries);
  }

  /// 2026-11-05: 닫기.
  @override
  void close() {}
}

/// 2026-11-05: 결과 조회 응답.
AnalysisOk<AnalysisQueryResult> _result(AnalysisAvailability a) =>
    AnalysisOk(AnalysisQueryResult(a));

void main() {
  late _ScriptedApi api;
  late MemoryAnalysisJobStore store;
  late List<AnalysisWaitState> seen;
  late int keys;
  late int sessionEnded;
  late List<AnalysisTracker> trackers;
  final life = _life();

  setUp(() {
    api = _ScriptedApi();
    store = MemoryAnalysisJobStore();
    seen = [];
    keys = 0;
    sessionEnded = 0;
    trackers = [];
  });

  tearDown(() {
    for (final t in trackers) {
      t.dispose();
    }
  });

  /// 2026-11-05: 즉시 대기하는 추적을 [snapshot]으로 시작하고 상태 변화를 [seen]에 모은다.
  AnalysisTracker start([FinancialSnapshot? snapshot]) {
    final tracker = AnalysisTracker(
      snapshot: snapshot ?? life,
      api: api,
      store: store,
      newKey: () => 'key-${++keys}',
      newEpoch: () => 7,
      delay: (_) async {},
      onSessionInvalid: () => sessionEnded++,
    );
    tracker.state.addListener(() => seen.add(tracker.state.value));
    trackers.add(tracker);
    return tracker;
  }

  /// 2026-11-05: 대기 중인 비동기 처리를 모두 돌린다.
  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 2026-11-05: 마지막 상태를 끝난 결과로 반환한다.
  AnalysisFinished finished(AnalysisTracker t) =>
      t.state.value as AnalysisFinished;

  test('accept → permit → submit → running → succeeded → result', () async {
    api.queries.addAll([
      _result(AnalysisAvailability.missing),
      _result(AnalysisAvailability.available),
    ]);
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.queued)));
    api.statuses.addAll([
      AnalysisOk(_job(AnalysisJobState.awaitingInput)),
      AnalysisOk(_job(AnalysisJobState.succeeded)),
    ]);
    api.submits.add(AnalysisOk(_job(AnalysisJobState.running)));
    final t = start();
    await settle();

    expect(api.calls, [
      'query',
      'accept',
      'status job-1',
      'submit job-1',
      'status job-1',
      'query',
    ]);
    final accept = api.bodies.first;
    expect(accept['triggerKind'], 'A');
    expect(accept['idempotencyKey'], 'key-1');
    expect(accept['inputHashHint'], startsWith('sha256:'));
    final submit = api.bodies[1];
    expect(submit['permit'], 'sha256:${'a' * 64}');
    expect(submit['idempotencyKey'], 'key-2');
    expect((submit['input']! as Map)['semanticTaskKind'], 'recurringMeaning');
    expect(api.waits.last, isTrue, reason: 'running 뒤에는 Prefer: wait');

    final running = seen.whereType<AnalysisRunning>().toList();
    expect(running.first.inputReceived, isFalse);
    expect(running.last.inputReceived, isTrue);
    final done = finished(t);
    expect(done.outcome, AnalysisOutcome.interpreted);
    expect(done.candidateCount, 11);
    expect(done.transactionCount, life.transactions!.length);

    final record = (await store.read(life.userId))!;
    expect(record.jobs.single.jobId, 'job-1');
    expect(record.jobs.single.acceptKey, 'key-1');
    expect(record.localSessionEpoch, 7);
    await t.forget();
    expect(await store.read(life.userId), isNull);
  });

  test('a lost submit answer keeps the preparing copy until the server says running', () async {
    api.queries.add(_result(AnalysisAvailability.missing));
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.awaitingInput)));
    api.submits.add(AnalysisNetworkFailure(StateError('timeout'), sent: true));
    api.statuses.add(AnalysisOk(_job(AnalysisJobState.awaitingInput)));
    final t = start();
    await settle();
    expect(api.calls, [
      'query',
      'accept',
      'submit job-1',
      'status job-1',
      'submit job-1',
    ]);
    expect(
      api.bodies[2]['idempotencyKey'],
      api.bodies[1]['idempotencyKey'],
      reason: '같은 허가의 재확인은 같은 키',
    );
    expect(
      seen.whereType<AnalysisRunning>().every((s) => !s.inputReceived),
      isTrue,
    );
    expect((t.state.value as AnalysisRunning).inputReceived, isFalse);
  });

  test('a valid stored result is reused without accepting', () async {
    api.queries.add(_result(AnalysisAvailability.available));
    final t = start();
    await settle();
    expect(api.calls, ['query']);
    expect(finished(t).outcome, AnalysisOutcome.interpreted);
  });

  test(
    'a renewed permit gets a new key; a stale permit asks for status',
    () async {
      api.queries.add(_result(AnalysisAvailability.missing));
      api.accepts.add(
        AnalysisOk(
          _job(AnalysisJobState.awaitingInput, permit: 'sha256:${'1' * 64}'),
        ),
      );
      api.submits.add(const AnalysisRejected(status: 409, code: 'STALE_DATA'));
      api.statuses.add(
        AnalysisOk(
          _job(AnalysisJobState.awaitingInput, permit: 'sha256:${'2' * 64}'),
        ),
      );
      api.submits.add(AnalysisOk(_job(AnalysisJobState.running)));
      start();
      await settle();
      final submits = [
        for (final b in api.bodies)
          if (b.containsKey('permit')) b,
      ];
      expect(submits.map((b) => b['permit']), [
        'sha256:${'1' * 64}',
        'sha256:${'2' * 64}',
      ]);
      expect(submits[0]['idempotencyKey'], isNot(submits[1]['idempotencyKey']));
    },
  );

  test('a missed 180-second window fails; retry uses a new key without acknowledgement', () async {
    api.queries.add(_result(AnalysisAvailability.missing));
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.queued)));
    api.statuses.add(AnalysisOk(_job(AnalysisJobState.failed)));
    final t = start();
    await settle();
    expect(finished(t).outcome, AnalysisOutcome.failed);

    api.retries.add(AnalysisOk(_job(AnalysisJobState.queued)));
    t.retry();
    await settle();
    expect(t.state.value, isA<AnalysisRunning>());
    final retry = api.bodies.last;
    expect(api.calls, contains('retry job-1'));
    expect(retry['idempotencyKey'], isNot('key-1'));
    expect(retry.containsKey('acknowledgeDuplicateRisk'), isFalse);
    expect(retry['input'], isA<Map<String, Object?>>());
  });

  test('an unknown outcome retries only with acknowledgement', () async {
    api.queries.add(_result(AnalysisAvailability.missing));
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.running)));
    api.statuses.add(AnalysisOk(_job(AnalysisJobState.outcomeUnknown)));
    final t = start();
    await settle();
    expect(finished(t).outcome, AnalysisOutcome.outcomeUnknown);
    expect(
      api.calls.where((c) => c.startsWith('retry')),
      isEmpty,
      reason: '자동 재호출 없음',
    );
    t.retry();
    await settle();
    expect(api.bodies.last['acknowledgeDuplicateRisk'], isTrue);
  });

  test(
    'expired checks results first, then recovery with the previous job',
    () async {
      api.queries.addAll([
        _result(AnalysisAvailability.missing),
        _result(AnalysisAvailability.missing),
        _result(AnalysisAvailability.missing),
      ]);
      api.accepts.addAll([
        AnalysisOk(_job(AnalysisJobState.expired)),
        AnalysisOk(_job(AnalysisJobState.queued, id: 'job-2')),
      ]);
      final t = start();
      await settle();
      expect(finished(t).outcome, AnalysisOutcome.expired);
      t.retry();
      await settle();
      final recovery = api.bodies.last;
      expect(recovery['triggerKind'], 'recovery');
      expect(recovery['previousJobId'], 'job-1');
      expect(recovery['input'], isA<Map<String, Object?>>());
      expect(api.calls.sublist(api.calls.length - 3), [
        'query',
        'accept',
        'status job-2',
      ]);
    },
  );

  test('a representative job id replaces the observed one', () async {
    api.queries.add(_result(AnalysisAvailability.missing));
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.queued, id: 'temp')));
    api.statuses.add(AnalysisOk(_job(AnalysisJobState.running, id: 'main')));
    start();
    await settle();
    expect(api.calls.sublist(0, 4), [
      'query',
      'accept',
      'status temp',
      'status main',
    ]);
    expect((await store.read(life.userId))!.jobs.single.jobId, 'main');
  });

  test(
    'pause stops polling without cancelling; resume checks status again',
    () async {
      api.queries.add(_result(AnalysisAvailability.missing));
      api.accepts.add(AnalysisOk(_job(AnalysisJobState.running)));
      final t = start();
      await settle();
      expect(api.calls.last, 'status job-1');
      t.pause();
      api.parked.single.complete(AnalysisOk(_job(AnalysisJobState.running)));
      await settle();
      final paused = api.calls.length;
      expect(
        api.calls,
        isNot(contains('retry job-1')),
        reason: '서버 작업 취소·재시도 없음',
      );
      expect(paused, 3, reason: '멈춘 뒤 늦게 온 응답으로 다음 조회를 이어 보내지 않음');
      t.resume();
      await settle();
      expect(api.calls.length, 4);
      expect(api.calls.last, 'status job-1', reason: '돌아오면 상태부터 다시 확인');
    },
  );

  test(
    'a stored job for the same data version is resumed, not accepted again',
    () async {
      await store.save(
        AnalysisJobRecord(
          userId: life.userId,
          dataVersion: life.dataVersion,
          localSessionEpoch: 3,
          jobs: [],
        ),
      );
      api.queries.add(_result(AnalysisAvailability.missing));
      api.accepts.add(AnalysisOk(_job(AnalysisJobState.queued)));
      start();
      await settle();
      final hint = api.bodies.first['inputHashHint']! as String;
      expect((api.bodies.first['context']! as Map)['localSessionEpoch'], 3);

      api = _ScriptedApi();
      seen = [];
      await store.save(
        AnalysisJobRecord(
          userId: life.userId,
          dataVersion: life.dataVersion,
          localSessionEpoch: 3,
          jobs: [
            AnalysisJobEntry(
              inputHashHint: hint,
              jobId: 'job-9',
              acceptKey: 'k',
            ),
          ],
        ),
      );
      api.statuses.add(AnalysisOk(_job(AnalysisJobState.running, id: 'job-9')));
      start();
      await settle();
      expect(api.calls.first, 'status job-9');
      expect(api.calls, isNot(contains('accept')));
    },
  );

  test('a record from another data version is dropped and analysed as a source change', () async {
    await store.save(
      AnalysisJobRecord(
        userId: life.userId,
        dataVersion: '999',
        localSessionEpoch: 3,
        jobs: const [
          AnalysisJobEntry(inputHashHint: 'h', jobId: 'old', acceptKey: 'k'),
        ],
      ),
    );
    api.queries.add(_result(AnalysisAvailability.missing));
    api.accepts.add(AnalysisOk(_job(AnalysisJobState.queued)));
    start();
    await settle();
    expect(api.calls.take(2), ['query', 'accept']);
    expect(api.bodies.first['triggerKind'], 'B');
    expect((api.bodies.first['context']! as Map)['localSessionEpoch'], 7);
  });

  test('a 401 ends the session and stops', () async {
    api.queries.add(const AnalysisSessionInvalid());
    start();
    await settle();
    expect(sessionEnded, 1);
    expect(api.calls, ['query']);
  });

  test('zero candidates finish at once without any call', () async {
    final raw = jsonDecode(
      File('../api/fixtures/generated-v4/snapshots/demo-life.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    raw['transactions'] = <Object?>[];
    raw['transactionRelations'] = <Object?>[];
    final t = start(FinancialSnapshot.fromJson(raw));
    await settle();
    expect(api.calls, isEmpty);
    expect(finished(t).candidateCount, 0);
    expect(finished(t).outcome, AnalysisOutcome.interpreted);
  });
}
