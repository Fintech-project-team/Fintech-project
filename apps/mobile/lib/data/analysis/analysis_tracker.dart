import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../financial_snapshot.dart';
import 'analysis_api.dart';
import 'analysis_job_store.dart';
import 'analysis_wait_session.dart';
import 'recurring_analysis_input.dart';
import 'recurring_source.dart';

/// 2026-11-05: 상태 조회 간격(docs/analysis-protocol.md §3). queued는 약 3초, Prefer: wait를 지원하지 않아 running이
/// 바로 돌아오면 약 1초 뒤 다시 묻는다. 서버 재요청 안내가 없을 때의 통신 실패 대기도 3초다.
const Duration _queuedGap = Duration(seconds: 3);
const Duration _runningGap = Duration(seconds: 1);
const Duration _failureGap = Duration(seconds: 3);

/// 2026-11-05: running 응답이 이보다 빨리 오면 서버가 완료 대기를 하지 않은 것으로 본다(Prefer: wait=5).
const Duration _waitHonored = Duration(seconds: 4);

/// 2026-11-05: 첫 계산 전 반복 의미 분석의 실제 작업 추적(분석 연동 3단계, apps/mobile/docs/analysis-tracking.md).
///
/// 01-2 스냅샷으로 2단계 묶음을 만들고, 묶음마다 현재 입력으로 결과를 먼저 조회한 뒤 재사용할 결과가 없을 때만
/// 접수한다. 제출 허가가 오면 입력을 한 번 제출하고, 서버 응답이 running 이후를 알려 준 뒤에만 입력 수신으로 본다.
/// 작업마다 요청은 한 번에 하나다. 공급자 자동 재호출은 없고 다시 시도는 [retry]에서만 한다.
/// 작업 번호·멱등 키·지문은 [store]에 남겨 앱을 다시 켜도 같은 작업을 이어 본다.
class AnalysisTracker implements AnalysisWaitSession {
  /// 2026-11-05: 01-2 스냅샷 `snapshot`, 분석 API `api`, 기기 기록 `store`, 멱등 키 만들기 `newKey`,
  /// 새 화면 세션 번호 `newEpoch`, 대기 `delay`, 시계 `now`, 세션 무효 알림 `onSessionInvalid`로 만들고 바로 시작한다.
  AnalysisTracker({
    required this._snapshot,
    required this._api,
    required this._store,
    required this._newKey,
    required this._newEpoch,
    this._delay = _defaultDelay,
    this._now = DateTime.now,
    this._onSessionInvalid,
  }) {
    unawaited(_start());
  }

  final FinancialSnapshot _snapshot;
  final AnalysisApi _api;
  final AnalysisJobStore _store;
  final String Function() _newKey;
  final int Function() _newEpoch;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final VoidCallback? _onSessionInvalid;

  final ValueNotifier<AnalysisWaitState> _state = ValueNotifier(
    const AnalysisRunning(),
  );
  final List<_Job> _jobs = [];
  int _generation = 0;
  int _epoch = 0;
  int _candidateCount = 0;
  bool _incomplete = false;
  bool _ready = false;
  bool _paused = false;
  bool _closed = false;

  /// 2026-11-05: 화면용 상태.
  @override
  ValueListenable<AnalysisWaitState> get state => _state;

  int get _transactionCount => _snapshot.transactions?.length ?? 0;

  /// 2026-11-05: 기기 기록을 읽어 같은 사용자·자료 버전이면 그 작업을 이어 보고, 아니면 새로 준비한다.
  Future<void> _start() async {
    final record = await _store.read(_snapshot.userId);
    if (_closed) return;
    final resumed =
        record != null && record.dataVersion == _snapshot.dataVersion;
    if (record != null && !resumed) await _store.clear(_snapshot.userId);
    _epoch = resumed ? record.localSessionEpoch : _newEpoch();
    final RecurringAnalysisPlan plan;
    try {
      final transactions =
          _snapshot.transactions ?? const <SourceTransaction>[];
      final detection = calc.detectRecurring(
        recurringInputFromSnapshot(
          snapshot: _snapshot,
          transactions: transactions,
          coverage: _snapshot.coverage,
        ),
      );
      plan = planRecurringAnalysis(
        snapshot: _snapshot,
        detection: detection,
        transactions: transactions,
        localSessionEpoch: _epoch,
        triggerKind: record != null && !resumed ? 'B' : 'A',
      );
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
      );
      _incomplete = true;
      _ready = true;
      _emit();
      return;
    }
    _candidateCount = plan.detection.candidates.length;
    _incomplete = plan.notAnalyzed.isNotEmpty;
    final known = {
      if (resumed)
        for (final job in record.jobs) job.inputHashHint: job,
    };
    for (final batch in plan.batches) {
      final saved = known[batch.identity.inputHashHint];
      _jobs.add(
        _Job(
          batch,
          jobId: saved?.jobId,
          acceptKey: saved?.acceptKey ?? _newKey(),
        ),
      );
    }
    _ready = true;
    _emit();
    if (!_paused) _driveAll();
  }

  /// 2026-11-05: 끝나지 않은 작업을 모두 이어서 진행한다.
  void _driveAll() {
    final generation = ++_generation;
    for (final job in _jobs) {
      if (job.outcome == null) unawaited(_drive(job, generation));
    }
  }

  /// 2026-11-05: [generation]이 아직 현재 진행이면 true다(멈춤·다시 시도·폐기 뒤의 늦은 응답은 버림).
  bool _alive(int generation) => !_closed && generation == _generation;

  /// 2026-11-05: 작업 [job] 하나를 끝날 때까지 진행한다. 작업 번호가 없으면 결과 조회 → 접수부터, 있으면 상태 조회부터다.
  Future<void> _drive(_Job job, int generation) async {
    try {
      if (job.jobId == null) {
        if (await _reuse(job, generation)) return;
        if (!_alive(generation)) return;
        final accepted = await _acceptUntilAnswered(job, {
          ...job.batch.accept,
          'idempotencyKey': job.acceptKey,
        }, generation);
        if (accepted == null || !_alive(generation)) return;
        await _follow(job, accepted, generation);
      } else {
        final status = await _statusUntilAnswered(job, generation, wait: false);
        if (status == null || !_alive(generation)) return;
        await _follow(job, status, generation);
      }
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
      );
      if (_alive(generation)) _finish(job, AnalysisOutcome.failed);
    }
  }

  /// 2026-11-05: 현재 입력으로 저장 결과를 조회해 쓸 수 있으면 작업을 끝내고 true를 반환한다(EX-R, 모델 호출 0회).
  Future<bool> _reuse(_Job job, int generation) async {
    final result = await job.serial(() => _api.query(_queryBody(job)));
    if (!_alive(generation)) return true;
    switch (result) {
      case AnalysisOk(value: AnalysisQueryResult(:final availability))
          when availability == AnalysisAvailability.available:
        _finish(job, AnalysisOutcome.interpreted);
        return true;
      case AnalysisSessionInvalid():
        _sessionEnded();
        return true;
      default:
        return false;
    }
  }

  /// 2026-11-05: 접수 [body]를 보낸다. 응답을 받지 못하면 같은 멱등 키로 다시 보내 같은 요청을 재확인한다.
  /// 용량 제한(429)·일시 장애(503)는 서버 안내만큼 기다린다. 그 밖의 거절은 실패로 끝내고 null을 반환한다.
  Future<AnalysisJobStatus?> _acceptUntilAnswered(
    _Job job,
    Map<String, Object?> body,
    int generation,
  ) async {
    while (_alive(generation)) {
      final result = await job.serial(() => _api.accept(body));
      if (!_alive(generation)) return null;
      switch (result) {
        case AnalysisOk(:final value):
          job.jobId = value.jobId;
          await _remember();
          return value;
        case AnalysisSessionInvalid():
          _sessionEnded();
          return null;
        case AnalysisRejected(status: 429 || 503, :final retryAfter):
          await _delay(retryAfter ?? _failureGap);
        case AnalysisRejected():
          _finish(job, AnalysisOutcome.failed);
          return null;
        case AnalysisNetworkFailure():
          await _delay(_failureGap);
      }
    }
    return null;
  }

  /// 2026-11-05: 상태를 조회한다. 응답을 받지 못하거나 일시 장애면 기다렸다가 다시 묻는다(조회는 서버 상태를 바꾸지 않음).
  Future<AnalysisJobStatus?> _statusUntilAnswered(
    _Job job,
    int generation, {
    required bool wait,
  }) async {
    while (_alive(generation)) {
      final jobId = job.jobId!;
      final result = await job.serial(() => _api.status(jobId, wait: wait));
      if (!_alive(generation)) return null;
      switch (result) {
        case AnalysisOk(:final value):
          return value;
        case AnalysisSessionInvalid():
          _sessionEnded();
          return null;
        case AnalysisRejected(status: 429 || 503, :final retryAfter):
          await _delay(retryAfter ?? _failureGap);
        case AnalysisRejected():
          _finish(job, AnalysisOutcome.failed);
          return null;
        case AnalysisNetworkFailure():
          await _delay(_failureGap);
      }
    }
    return null;
  }

  /// 2026-11-05: 상태 [status]부터 작업이 끝날 때까지 따라간다. 서버가 대표 작업 번호를 바꾸면 그 번호로 관찰한다.
  Future<void> _follow(
    _Job job,
    AnalysisJobStatus status,
    int generation,
  ) async {
    var current = status;
    while (_alive(generation)) {
      if (current.jobId != job.jobId) {
        job.jobId = current.jobId;
        await _remember();
      }
      final asked = _now();
      switch (current.state) {
        case AnalysisJobState.queued:
          await _delay(_queuedGap);
        case AnalysisJobState.awaitingInput
            when current.action == AnalysisJobAction.submitInput:
          final submitted = await _submit(job, current.permit!, generation);
          if (!_alive(generation)) return;
          if (submitted != null) {
            current = submitted;
            continue;
          }
        case AnalysisJobState.awaitingInput:
          await _delay(_queuedGap);
        case AnalysisJobState.running:
          job.received = true;
          _emit();
        case AnalysisJobState.succeeded:
          job.received = true;
          await _settleFromResult(job, AnalysisOutcome.failed, generation);
          return;
        case AnalysisJobState.failed || AnalysisJobState.cancelled:
          _finish(job, AnalysisOutcome.failed);
          return;
        case AnalysisJobState.outcomeUnknown:
          _finish(job, AnalysisOutcome.outcomeUnknown);
          return;
        case AnalysisJobState.expired:
          await _settleFromResult(job, AnalysisOutcome.expired, generation);
          return;
      }
      if (!_alive(generation)) return;
      final running = current.state == AnalysisJobState.running;
      final next = await _statusUntilAnswered(job, generation, wait: running);
      if (next == null || !_alive(generation)) return;
      if (running &&
          next.state == AnalysisJobState.running &&
          _now().difference(asked) < _waitHonored) {
        await _delay(_runningGap);
      }
      current = next;
    }
  }

  /// 2026-11-05: 받은 허가 [permit]으로 입력을 제출한다. 허가가 바뀌면 새 멱등 키, 응답을 받지 못한 같은 허가의
  /// 재확인은 같은 키다. 응답이 없거나 허가가 이미 만료(409)면 null을 반환해 상태 조회로 확인하게 한다.
  Future<AnalysisJobStatus?> _submit(
    _Job job,
    String permit,
    int generation,
  ) async {
    if (job.permit != permit) {
      job.permit = permit;
      job.submitKey = _newKey();
    }
    final jobId = job.jobId!;
    final result = await job.serial(
      () => _api.submitInput(jobId, {
        'context': job.batch.input['context'],
        'input': job.batch.input,
        'idempotencyKey': job.submitKey,
        'permit': permit,
      }),
    );
    if (!_alive(generation)) return null;
    switch (result) {
      case AnalysisOk(:final value):
        return value;
      case AnalysisSessionInvalid():
        _sessionEnded();
        return null;
      case AnalysisRejected(status: 429 || 503, :final retryAfter):
        await _delay(retryAfter ?? _failureGap);
        return null;
      case AnalysisRejected(status: 409):
        return null;
      case AnalysisRejected():
        _finish(job, AnalysisOutcome.failed);
        return null;
      case AnalysisNetworkFailure():
        await _delay(_failureGap);
        return null;
    }
  }

  /// 2026-11-05: 상태만으로 본문을 쓰지 않고 현재 입력으로 결과 자격을 확인한다. available이면 분석 완료, 아니면
  /// [otherwise]로 끝낸다(succeeded인데 partial·stale 등이면 실패, expired면 만료).
  Future<void> _settleFromResult(
    _Job job,
    AnalysisOutcome otherwise,
    int generation,
  ) async {
    while (_alive(generation)) {
      final result = await job.serial(() => _api.query(_queryBody(job)));
      if (!_alive(generation)) return;
      switch (result) {
        case AnalysisOk(:final value):
          _finish(
            job,
            value.availability == AnalysisAvailability.available
                ? AnalysisOutcome.interpreted
                : otherwise,
          );
          return;
        case AnalysisSessionInvalid():
          _sessionEnded();
          return;
        case AnalysisRejected(status: 429 || 503, :final retryAfter):
          await _delay(retryAfter ?? _failureGap);
        case AnalysisRejected():
          _finish(job, otherwise);
          return;
        case AnalysisNetworkFailure():
          await _delay(_failureGap);
      }
    }
  }

  /// 2026-11-05: 결과 조회 본문(queryRequest).
  Map<String, Object?> _queryBody(_Job job) => {
    'context': job.batch.input['context'],
    'semanticTaskKind': job.batch.input['semanticTaskKind'],
    'input': job.batch.input,
  };

  /// 2026-11-05: 사용자 '다시 시도'. 실패·취소는 새 키로 /retry, 결과 불명은 동의 표시와 함께 /retry, 만료는 결과를 먼저
  /// 조회한 뒤 recovery 접수다. 접수 전에 끝난 작업, 서버가 더는 모르는 작업(403)은 새 접수 키로 처음부터 한다.
  @override
  void retry() {
    if (_closed || !_ready) return;
    final generation = ++_generation;
    final targets = [
      for (final job in _jobs)
        if (job.outcome != null && job.outcome != AnalysisOutcome.interpreted)
          job,
    ];
    for (final job in targets) {
      final previous = job.outcome!;
      job
        ..outcome = null
        ..received = false
        ..permit = null;
      unawaited(_retry(job, previous, generation));
    }
    _emit();
  }

  /// 2026-11-05: [previous]로 끝난 작업 [job]을 사용자 요청으로 다시 진행한다.
  Future<void> _retry(
    _Job job,
    AnalysisOutcome previous,
    int generation,
  ) async {
    try {
      final jobId = job.jobId;
      if (jobId == null) {
        job.acceptKey = _newKey();
        await _drive(job, generation);
        return;
      }
      if (previous == AnalysisOutcome.expired) {
        if (await _reuse(job, generation) || !_alive(generation)) return;
        job.acceptKey = _newKey();
        final accepted = await _acceptUntilAnswered(job, {
          ...job.batch.accept,
          'triggerKind': 'recovery',
          'previousJobId': jobId,
          'input': job.batch.input,
          'idempotencyKey': job.acceptKey,
        }, generation);
        if (accepted == null || !_alive(generation)) return;
        await _follow(job, accepted, generation);
        return;
      }
      final body = {
        'context': job.batch.input['context'],
        'input': job.batch.input,
        'idempotencyKey': _newKey(),
        if (previous == AnalysisOutcome.outcomeUnknown)
          'acknowledgeDuplicateRisk': true,
      };
      while (_alive(generation)) {
        final result = await job.serial(() => _api.retry(jobId, body));
        if (!_alive(generation)) return;
        switch (result) {
          case AnalysisOk(:final value):
            await _follow(job, value, generation);
            return;
          case AnalysisSessionInvalid():
            _sessionEnded();
            return;
          case AnalysisRejected(status: 429 || 503, :final retryAfter):
            await _delay(retryAfter ?? _failureGap);
          case AnalysisRejected(status: 403):
            job
              ..jobId = null
              ..acceptKey = _newKey();
            await _drive(job, generation);
            return;
          case AnalysisRejected():
            _finish(job, previous);
            return;
          case AnalysisNetworkFailure():
            await _delay(_failureGap);
        }
      }
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
      );
      if (_alive(generation)) _finish(job, AnalysisOutcome.failed);
    }
  }

  /// 2026-11-05: 백그라운드. 반복 조회를 멈춘다(서버 작업 취소 아님). 진행 중 응답은 버린다.
  @override
  void pause() {
    if (_closed || _paused) return;
    _paused = true;
    _generation++;
  }

  /// 2026-11-05: 앱 복귀. 끝나지 않은 작업을 결과·상태 조회부터 다시 확인한다.
  @override
  void resume() {
    if (_closed || !_paused) return;
    _paused = false;
    if (_ready) _driveAll();
  }

  /// 2026-11-05: '다음'. 이 사용자의 기기 기록을 지운다.
  @override
  Future<void> forget() => _store.clear(_snapshot.userId);

  /// 2026-11-05: 화면을 떠났다. 반복 조회를 멈추며 서버 작업은 취소하지 않는다.
  @override
  void dispose() {
    _closed = true;
    _generation++;
  }

  /// 2026-11-05: 작업 [job]을 [outcome]으로 끝내고 알린다.
  void _finish(_Job job, AnalysisOutcome outcome) {
    job.outcome = outcome;
    _emit();
  }

  /// 2026-11-05: 세션이 끝났다. 진행을 멈추고 앱에 알린다.
  void _sessionEnded() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _onSessionInvalid?.call();
  }

  /// 2026-11-05: 접수한 작업 번호·키·지문을 기기에 남긴다.
  Future<void> _remember() => _store.save(
    AnalysisJobRecord(
      userId: _snapshot.userId,
      dataVersion: _snapshot.dataVersion,
      localSessionEpoch: _epoch,
      jobs: [
        for (final job in _jobs)
          if (job.jobId != null)
            AnalysisJobEntry(
              inputHashHint: job.batch.identity.inputHashHint,
              jobId: job.jobId!,
              acceptKey: job.acceptKey,
            ),
      ],
    ),
  );

  /// 2026-11-05: 작업들을 화면 상태로 바꿔 알린다. 하나라도 진행 중이면 기다리는 중이고, 모든 작업이 서버 입력 수신을
  /// 확인했거나 끝났을 때만 입력 수신으로 본다. 모두 끝나면 결과 불명 → 만료 → 실패 → 완료 순으로 대표 결과를 고른다.
  /// 보내지 못한 후보가 있으면 완료로 보지 않는다.
  void _emit() {
    if (_closed || !_ready) return;
    if (_jobs.any((job) => job.outcome == null)) {
      _state.value = AnalysisRunning(
        inputReceived: _jobs.every(
          (job) => job.received || job.outcome != null,
        ),
      );
      return;
    }
    final outcomes = {for (final job in _jobs) job.outcome!};
    final outcome = outcomes.contains(AnalysisOutcome.outcomeUnknown)
        ? AnalysisOutcome.outcomeUnknown
        : outcomes.contains(AnalysisOutcome.expired)
        ? AnalysisOutcome.expired
        : outcomes.contains(AnalysisOutcome.failed) || _incomplete
        ? AnalysisOutcome.failed
        : AnalysisOutcome.interpreted;
    _state.value = AnalysisFinished(
      transactionCount: _transactionCount,
      candidateCount: _candidateCount,
      outcome: outcome,
    );
  }
}

/// 2026-11-05: 기본 대기.
Future<void> _defaultDelay(Duration duration) => Future.delayed(duration);

/// 2026-11-05: 묶음 하나의 서버 작업 진행. 요청은 [serial]로 한 번에 하나만 보낸다.
final class _Job {
  /// 2026-11-05: 묶음 [batch], 기기에 남은 작업 번호 [jobId], 접수 멱등 키 [acceptKey]로 만든다.
  _Job(this.batch, {this.jobId, required this.acceptKey});

  final RecurringAnalysisBatch batch;
  String? jobId;
  String acceptKey;
  String? permit;
  String? submitKey;
  bool received = false;
  AnalysisOutcome? outcome;
  Future<void> _last = Future.value();

  /// 2026-11-05: 이 작업의 앞선 요청이 끝난 뒤 [send]를 보낸다(멈췄다 돌아와도 같은 작업 요청이 겹치지 않게).
  Future<T> serial<T>(Future<T> Function() send) {
    final next = _last.then((_) => send());
    _last = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}
