import 'dart:math';

import 'analysis_api.dart';
import 'analysis_identity.dart';

/// 2026-11-05: 가짜 서버 모드의 분석 작업 서버. 앱 프로세스 동안 작업을 메모리에 두고 계약 응답 순서
/// (queued → awaitingInput·submitInput → running → succeeded)를 상태 조회 횟수로 흉내 낸다. 시간은 앱의 조회 간격이
/// 정한다(대기열 약 3초, 실행 중 약 1초마다). 벽시계를 쓰지 않아 위젯 테스트의 가짜 시간에서도 같은 순서로 진행한다.
/// 모델은 부르지 않고 결과 본문도 만들지 않으며, 완료된 입력 지문만 결과 있음(available)으로 답한다. 실제 서버의 검증·
/// 비용·권한을 대신하지 않는다.
class FakeAnalysisServer {
  /// 2026-11-05: 대기열로 답하는 조회 횟수 [queuedPolls], 실행 중으로 답하는 조회 횟수 [runningPolls], 난수 [random]으로 만든다.
  FakeAnalysisServer({
    this.queuedPolls = 1,
    this.runningPolls = 20,
    Random? random,
  }) : _random = random ?? Random();

  final int queuedPolls;
  final int runningPolls;
  final Random _random;
  final Map<String, _FakeJob> _jobs = {};
  final Map<String, String> _byKey = {};
  final Set<String> _done = {};

  /// 2026-11-05: 세션 토큰 [accessToken]의 API를 반환한다. 가짜 서버는 토큰을 검사하지 않는다.
  AnalysisApi api(String accessToken) => _FakeAnalysisApi(this);

  /// 2026-11-05: 접수. 같은 멱등 키는 같은 작업을 돌려준다.
  AnalysisJobStatus _accept(Map<String, Object?> body) {
    final key = '${body['idempotencyKey']}';
    final known = _byKey[key];
    if (known != null && _jobs.containsKey(known)) return _status(known)!;
    final id = _uuid();
    _jobs[id] = _FakeJob(hint: '${body['inputHashHint']}');
    _byKey[key] = id;
    return _status(id)!;
  }

  /// 2026-11-05: 상태. 대기열 조회 횟수가 차면 제출 허가를, 실행 중 조회 횟수가 차면 완료를 알린다. 상태 조회([poll])일
  /// 때만 횟수를 센다(접수·제출·재시도 응답은 세지 않음).
  AnalysisJobStatus? _status(String id, {bool poll = false}) {
    final job = _jobs[id];
    if (job == null) return null;
    if (job.started) {
      if (poll) job.runningSeen++;
      if (job.runningSeen >= runningPolls) {
        _done.add(job.hint);
        return _reply(
          id,
          AnalysisJobState.succeeded,
          AnalysisJobAction.readResult,
        );
      }
      return _reply(id, AnalysisJobState.running, AnalysisJobAction.wait);
    }
    if (job.queuedSeen < queuedPolls) {
      if (poll) job.queuedSeen++;
      return _reply(id, AnalysisJobState.queued, AnalysisJobAction.wait);
    }
    job.permit ??=
        'sha256:${List.generate(64, (_) => _random.nextInt(16).toRadixString(16)).join()}';
    return _reply(
      id,
      AnalysisJobState.awaitingInput,
      AnalysisJobAction.submitInput,
      permit: job.permit,
    );
  }

  /// 2026-11-05: 입력 제출. 허가가 맞으면 실행을 시작한다. 허가가 틀리면 null이다.
  AnalysisJobStatus? _submit(String id, Map<String, Object?> body) {
    final job = _jobs[id];
    if (job == null) return null;
    if (!job.started) {
      if (body['permit'] != job.permit) return null;
      job.started = true;
    }
    return _status(id)!;
  }

  /// 2026-11-05: 사용자 재시도. 대기열부터 다시 시작한다. 없는 작업이면 null이다.
  AnalysisJobStatus? _retry(String id) {
    final job = _jobs[id];
    if (job == null) return null;
    job
      ..queuedSeen = 0
      ..runningSeen = 0
      ..started = false
      ..permit = null;
    return _status(id)!;
  }

  /// 2026-11-05: 상태 응답을 만든다.
  AnalysisJobStatus _reply(
    String id,
    AnalysisJobState state,
    AnalysisJobAction action, {
    String? permit,
  }) => AnalysisJobStatus(
    jobId: id,
    state: state,
    action: action,
    availability: AnalysisAvailability.unchecked,
    permit: permit,
  );

  /// 2026-11-05: 무작위 UUID 형식 문자열.
  String _uuid() {
    String hex(int n) =>
        List.generate(n, (_) => _random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
  }
}

/// 2026-11-05: 가짜 분석 작업 하나. 조회 횟수와 실행 시작 여부만 둔다.
final class _FakeJob {
  /// 2026-11-05: 입력 지문 [hint]로 만든다.
  _FakeJob({required this.hint});

  final String hint;
  int queuedSeen = 0;
  int runningSeen = 0;
  bool started = false;
  String? permit;
}

/// 2026-11-05: [FakeAnalysisServer]에 연결한 세션 API.
final class _FakeAnalysisApi implements AnalysisApi {
  /// 2026-11-05: 가짜 서버 [server]로 만든다.
  _FakeAnalysisApi(this.server);

  final FakeAnalysisServer server;
  bool _closed = false;

  /// 2026-11-05: 세션을 닫는다.
  @override
  void close() => _closed = true;

  /// 2026-11-05: 접수.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> accept(
    Map<String, Object?> body,
  ) async => _closed
      ? const AnalysisSessionInvalid()
      : AnalysisOk(server._accept(body));

  /// 2026-11-05: 상태. [wait]는 흉내 내지 않고 바로 답한다.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> status(
    String jobId, {
    bool wait = false,
  }) async => _closed
      ? const AnalysisSessionInvalid()
      : _known(server._status(jobId, poll: true));

  /// 2026-11-05: 입력 제출. 허가가 틀리면 409다.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> submitInput(
    String jobId,
    Map<String, Object?> body,
  ) async {
    if (_closed) return const AnalysisSessionInvalid();
    if (!server._jobs.containsKey(jobId)) return _known(null);
    final status = server._submit(jobId, body);
    return status == null
        ? const AnalysisRejected(status: 409, code: 'STALE_DATA')
        : AnalysisOk(status);
  }

  /// 2026-11-05: 사용자 재시도.
  @override
  Future<AnalysisCall<AnalysisJobStatus>> retry(
    String jobId,
    Map<String, Object?> body,
  ) async =>
      _closed ? const AnalysisSessionInvalid() : _known(server._retry(jobId));

  /// 2026-11-05: 작업 응답 [status]를 돌려준다. 없는 작업(앱을 다시 켜 가짜 서버 메모리가 사라진 경우 포함)은 실제 서버처럼 403이다.
  AnalysisCall<AnalysisJobStatus> _known(AnalysisJobStatus? status) =>
      status == null
      ? const AnalysisRejected(status: 403, code: 'RESOURCE_FORBIDDEN')
      : AnalysisOk(status);

  /// 2026-11-05: 결과 조회. 완료된 지문만 available이다.
  @override
  Future<AnalysisCall<AnalysisQueryResult>> query(
    Map<String, Object?> body,
  ) async {
    if (_closed) return const AnalysisSessionInvalid();
    final input = body['input'];
    if (input is! Map<String, Object?>) {
      return const AnalysisRejected(status: 400, code: 'INVALID_REQUEST');
    }
    final done = server._done.contains(
      identifyAnalysisInput(input).inputHashHint,
    );
    return AnalysisOk(
      AnalysisQueryResult(
        done ? AnalysisAvailability.available : AnalysisAvailability.missing,
      ),
    );
  }
}
