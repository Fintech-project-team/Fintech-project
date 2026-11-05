import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 2026-11-05: 접수한 분석 작업 하나의 기기 기록. 작업 번호·멱등 키·입력 지문만 두고 분석 본문·거래 원문·
/// 제출 허가·토큰은 두지 않는다.
final class AnalysisJobEntry {
  /// 2026-11-05: 접수 지문 [inputHashHint], 대표 작업 [jobId], 접수 멱등 키 [acceptKey]로 만든다.
  const AnalysisJobEntry({
    required this.inputHashHint,
    required this.jobId,
    required this.acceptKey,
  });

  final String inputHashHint;
  final String jobId;
  final String acceptKey;

  /// 2026-11-05: 저장용 JSON을 반환한다.
  Map<String, Object?> toJson() => {
    'inputHashHint': inputHashHint,
    'jobId': jobId,
    'acceptKey': acceptKey,
  };

  /// 2026-11-05: 저장한 JSON [json]을 읽는다. 형식이 틀리면 null이다.
  static AnalysisJobEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final hint = json['inputHashHint'];
    final jobId = json['jobId'];
    final key = json['acceptKey'];
    if (hint is! String || jobId is! String || key is! String) return null;
    return AnalysisJobEntry(inputHashHint: hint, jobId: jobId, acceptKey: key);
  }
}

/// 2026-11-05: 첫 분석 한 번의 기기 기록. 앱을 다시 켜면 같은 사용자·자료 버전·화면 세션일 때만 이어 본다.
final class AnalysisJobRecord {
  /// 2026-11-05: 사용자 [userId], 기준 자료 버전 [dataVersion], 화면 세션 [localSessionEpoch], 작업 [jobs]로 만든다.
  AnalysisJobRecord({
    required this.userId,
    required this.dataVersion,
    required this.localSessionEpoch,
    required Iterable<AnalysisJobEntry> jobs,
  }) : jobs = List.unmodifiable(jobs);

  final String userId;
  final String dataVersion;
  final int localSessionEpoch;
  final List<AnalysisJobEntry> jobs;

  /// 2026-11-05: 저장용 JSON을 반환한다.
  Map<String, Object?> toJson() => {
    'userId': userId,
    'dataVersion': dataVersion,
    'localSessionEpoch': localSessionEpoch,
    'jobs': [for (final job in jobs) job.toJson()],
  };

  /// 2026-11-05: 저장한 JSON [json]을 읽는다. 형식이 틀리면 null이다.
  static AnalysisJobRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final userId = json['userId'];
    final dataVersion = json['dataVersion'];
    final epoch = json['localSessionEpoch'];
    final rows = json['jobs'];
    if (userId is! String ||
        dataVersion is! String ||
        epoch is! int ||
        rows is! List) {
      return null;
    }
    final jobs = <AnalysisJobEntry>[];
    for (final row in rows) {
      final job = AnalysisJobEntry.fromJson(row);
      if (job == null) return null;
      jobs.add(job);
    }
    return AnalysisJobRecord(
      userId: userId,
      dataVersion: dataVersion,
      localSessionEpoch: epoch,
      jobs: jobs,
    );
  }
}

/// 2026-11-05: 첫 분석 기록 저장소. 읽기·쓰기 실패는 기록 없음으로 보고 화면은 처음부터 다시 조회한다.
abstract interface class AnalysisJobStore {
  /// 2026-11-05: 사용자 [userId]의 기록을 반환한다. 없거나 읽지 못하면 null이다.
  Future<AnalysisJobRecord?> read(String userId);

  /// 2026-11-05: 기록 [record]를 그 사용자 이름으로 둔다.
  Future<void> save(AnalysisJobRecord record);

  /// 2026-11-05: 사용자 [userId]의 기록을 지운다('다음'을 눌렀을 때).
  Future<void> clear(String userId);

  /// 2026-11-05: 모든 사용자의 기록을 지운다(로그아웃·세션 무효).
  Future<void> clearAll();
}

/// 2026-11-05: 메모리 저장소. 앱을 다시 시작하면 사라진다(테스트·기기 저장소를 쓰지 않는 실행용).
class MemoryAnalysisJobStore implements AnalysisJobStore {
  final Map<String, AnalysisJobRecord> _records = {};

  /// 2026-11-05: 메모리 기록을 반환한다.
  @override
  Future<AnalysisJobRecord?> read(String userId) async => _records[userId];

  /// 2026-11-05: 메모리에 둔다.
  @override
  Future<void> save(AnalysisJobRecord record) async =>
      _records[record.userId] = record;

  /// 2026-11-05: 메모리에서 지운다.
  @override
  Future<void> clear(String userId) async => _records.remove(userId);

  /// 2026-11-05: 메모리를 비운다.
  @override
  Future<void> clearAll() async => _records.clear();
}

/// 2026-11-05: 기기 저장소(shared_preferences). 앱을 강제 종료해도 남아 다시 켜면 결과 조회부터 이어 본다.
/// 금융 본문·토큰이 없어 보안 저장소를 쓰지 않는다. 기기 저장소는 처음 쓸 때 열며, 열 수 없는 환경(플러그인 없음)에서는
/// 기록 없음으로 동작한다.
class DeviceAnalysisJobStore implements AnalysisJobStore {
  /// 2026-11-05: 기기 저장소 [preferences]로 만든다. 없으면 처음 쓸 때 기본 저장소를 연다.
  DeviceAnalysisJobStore({SharedPreferencesAsync? preferences})
    : _opened = preferences;

  SharedPreferencesAsync? _opened;
  static const String _prefix = 'analysis-job.';

  /// 2026-11-05: 기기 저장소를 반환한다. 플랫폼 구현이 없으면 null이다.
  SharedPreferencesAsync? get _preferences {
    try {
      return _opened ??= SharedPreferencesAsync();
    } on StateError {
      return null;
    }
  }

  /// 2026-11-05: 기기 기록을 반환한다. 없거나 형식이 틀리거나 읽지 못하면 null이다.
  @override
  Future<AnalysisJobRecord?> read(String userId) async {
    try {
      final raw = await _preferences?.getString('$_prefix$userId');
      if (raw == null) return null;
      final record = AnalysisJobRecord.fromJson(jsonDecode(raw));
      return record?.userId == userId ? record : null;
    } on Exception {
      return null;
    }
  }

  /// 2026-11-05: 기기에 둔다. 쓰지 못해도 이번 실행의 추적은 계속한다.
  @override
  Future<void> save(AnalysisJobRecord record) async {
    try {
      await _preferences?.setString(
        '$_prefix${record.userId}',
        jsonEncode(record.toJson()),
      );
    } on Exception {
      return;
    }
  }

  /// 2026-11-05: 기기에서 지운다.
  @override
  Future<void> clear(String userId) async {
    try {
      await _preferences?.remove('$_prefix$userId');
    } on Exception {
      return;
    }
  }

  /// 2026-11-05: 이 저장소가 쓴 이름만 모두 지운다.
  @override
  Future<void> clearAll() async {
    try {
      final preferences = _preferences;
      if (preferences == null) return;
      final keys = await preferences.getKeys();
      for (final key in keys.where((k) => k.startsWith(_prefix))) {
        await preferences.remove(key);
      }
    } on Exception {
      return;
    }
  }
}
