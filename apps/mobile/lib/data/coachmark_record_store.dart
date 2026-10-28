/// 2026-10-28: 02-1a 홈 코치마크 기록. 사용자별로 한 값만 둔다.
enum CoachmarkRecord {
  /// 2026-10-28: 3/3까지 보고 '시작하기'를 눌렀다.
  completed,

  /// 2026-10-28: 중간에 '건너뛰기'나 뒤로 가기로 닫았다.
  skipped,
}

/// 2026-10-28: 코치마크 기록을 기기에 남기는 계약(FirstCalcRecordStore와 같은 경계). 계산 입력·결과에는 쓰지 않는다.
abstract interface class CoachmarkRecordStore {
  /// 2026-10-28: 사용자 [userId]의 기록을 반환한다. 없으면 null이다.
  Future<CoachmarkRecord?> read(String userId);

  /// 2026-10-28: 사용자 [userId]의 기록을 [record]로 바꾼다.
  Future<void> save(String userId, CoachmarkRecord record);
}

/// 2026-10-28: 메모리 기록 저장소. 같은 앱 실행 안에서는 로그아웃·재로그인 뒤에도 남고, 앱을 다시 시작하면 사라진다
/// (재실행 뒤 복원은 범위 밖).
class MemoryCoachmarkRecordStore implements CoachmarkRecordStore {
  final Map<String, CoachmarkRecord> _records = {};

  /// 2026-10-28: 메모리의 기록을 반환한다.
  @override
  Future<CoachmarkRecord?> read(String userId) async => _records[userId];

  /// 2026-10-28: 메모리에 기록을 둔다.
  @override
  Future<void> save(String userId, CoachmarkRecord record) async =>
      _records[userId] = record;
}
