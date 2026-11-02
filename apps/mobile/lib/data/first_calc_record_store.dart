import 'package:shared_preferences/shared_preferences.dart';

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
/// (테스트·기기 저장소를 쓰지 않는 실행용).
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

/// 2026-11-02: 기기 저장소(shared_preferences). 앱을 다시 시작해도 남아 01-3을 다시 띄우지 않는다. 재설치·다른 기기에서는 없다.
/// 계산과 무관한 안내 기록이므로 보안 저장소를 쓰지 않는다. 읽지 못하면 기록 없음으로 보고 01-3을 다시 보이며(계산 결과는 그대로),
/// 쓰지 못해도 이번 실행 화면은 진행한다.
class DeviceFirstCalcRecordStore implements FirstCalcRecordStore {
  /// 2026-11-02: 기기 저장소 [preferences]로 만든다. 없으면 기본 저장소를 쓴다.
  DeviceFirstCalcRecordStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  /// 2026-11-02: 사용자 [userId]의 기록 이름을 반환한다.
  static String _name(String userId) => 'first-calc-record.$userId';

  /// 2026-11-02: 기기의 기록을 반환한다. 없거나 알 수 없는 값이거나 읽지 못하면 null이다.
  @override
  Future<FirstCalcRecord?> read(String userId) async {
    try {
      final value = await _preferences.getString(_name(userId));
      for (final record in FirstCalcRecord.values) {
        if (record.name == value) return record;
      }
      return null;
    } on Exception {
      return null;
    }
  }

  /// 2026-11-02: 기기에 기록을 둔다.
  @override
  Future<void> save(String userId, FirstCalcRecord record) async {
    try {
      await _preferences.setString(_name(userId), record.name);
    } on Exception {
      return;
    }
  }
}
