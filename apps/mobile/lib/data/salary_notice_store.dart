import 'package:shared_preferences/shared_preferences.dart';

/// 2026-10-29: 홈 월급 입금 확인 안내를 '나중에 확인'으로 접은 기록을 기기에 남기는 계약(FirstCalcRecordStore와 같은 경계).
/// 사용자별로 접은 안내의 키 하나만 둔다. 키가 지금 안내와 같을 때만 접힌 상태로 보이며 계산 입력·결과에는 쓰지 않는다.
abstract interface class SalaryNoticeStore {
  /// 2026-10-29: 사용자 [userId]가 접은 안내 키를 반환한다. 없으면 null이다.
  Future<String?> read(String userId);

  /// 2026-10-29: 사용자 [userId]가 접은 안내 키를 [noticeKey]로 바꾼다. null이면 지운다(다시 펼침).
  Future<void> save(String userId, String? noticeKey);
}

/// 2026-10-29: 메모리 기록 저장소. 앱을 다시 시작하면 사라진다(테스트·개발용).
class MemorySalaryNoticeStore implements SalaryNoticeStore {
  final Map<String, String> _keys = {};

  /// 2026-10-29: 메모리의 기록을 반환한다.
  @override
  Future<String?> read(String userId) async => _keys[userId];

  /// 2026-10-29: 메모리에 기록을 두거나 지운다.
  @override
  Future<void> save(String userId, String? noticeKey) async {
    if (noticeKey == null) {
      _keys.remove(userId);
    } else {
      _keys[userId] = noticeKey;
    }
  }
}

/// 2026-10-29: 기기 저장소(shared_preferences). 앱을 다시 시작해도 남고, 재설치·다른 기기에서는 없다.
/// 저장소를 읽거나 쓰지 못하면 기록 없음으로 보고 안내를 다시 보인다.
class DeviceSalaryNoticeStore implements SalaryNoticeStore {
  /// 2026-10-29: 기기 저장소 [preferences]로 만든다. 없으면 기본 저장소를 쓴다.
  DeviceSalaryNoticeStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  /// 2026-10-29: 사용자 [userId]의 기록 이름을 반환한다.
  static String _name(String userId) => 'salary-notice-folded.$userId';

  /// 2026-10-29: 기기의 기록을 반환한다.
  @override
  Future<String?> read(String userId) async {
    try {
      return await _preferences.getString(_name(userId));
    } on Exception {
      return null;
    }
  }

  /// 2026-10-29: 기기에 기록을 두거나 지운다.
  @override
  Future<void> save(String userId, String? noticeKey) async {
    try {
      if (noticeKey == null) {
        await _preferences.remove(_name(userId));
      } else {
        await _preferences.setString(_name(userId), noticeKey);
      }
    } on Exception {
      return;
    }
  }
}
