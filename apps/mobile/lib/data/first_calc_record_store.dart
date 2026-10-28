/// 2026-10-27: 01-3 첫 계산 안내 기록. 사용자별로 한 값만 둔다.
enum FirstCalcRecord {
  /// 2026-10-27: 01-3 4/4까지 보고 '홈으로'를 눌렀다.
  explained,

  /// 2026-10-27: 01-3 중간에 '홈으로 가기'를 눌렀다.
  skipped,

  /// 2026-10-27: 01-2에서 계산하지 못해 '나중에 확인하고 홈으로 가기'를 눌렀다. 설명 완료로 보지 않는다.
  deferred,
}

/// 2026-10-27: 첫 계산 기록을 기기에 남기는 계약(ConsentStore와 같은 경계). 계산 입력·결과에는 쓰지 않는다.
abstract interface class FirstCalcRecordStore {
  /// 2026-10-27: 사용자 [userId]의 기록을 반환한다. 없으면 null이다.
  Future<FirstCalcRecord?> read(String userId);

  /// 2026-10-27: 사용자 [userId]의 기록을 [record]로 바꾼다.
  Future<void> save(String userId, FirstCalcRecord record);
}

/// 2026-10-27: 메모리 기록 저장소. 같은 앱 실행 안에서는 로그아웃·재로그인 뒤에도 남고, 앱을 다시 시작하면 사라진다
/// (재실행 뒤 복원은 범위 밖).
class MemoryFirstCalcRecordStore implements FirstCalcRecordStore {
  final Map<String, FirstCalcRecord> _records = {};

  /// 2026-10-27: 메모리의 기록을 반환한다.
  @override
  Future<FirstCalcRecord?> read(String userId) async => _records[userId];

  /// 2026-10-27: 메모리에 기록을 둔다.
  @override
  Future<void> save(String userId, FirstCalcRecord record) async =>
      _records[userId] = record;
}
