import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/salary_notice_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-10-29: 기기 저장소 대신 쓰는 메모리 대역. [failing]이면 읽기·쓰기에서 예외를 던진다.
class _FakePreferences implements SharedPreferencesAsync {
  _FakePreferences({this.failing = false});

  final bool failing;
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async {
    if (failing) throw Exception('저장소 없음');
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    if (failing) throw Exception('저장소 없음');
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (failing) throw Exception('저장소 없음');
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final (name, make) in [
    ('memory', () => MemorySalaryNoticeStore() as SalaryNoticeStore),
    (
      'device',
      () =>
          DeviceSalaryNoticeStore(preferences: _FakePreferences())
              as SalaryNoticeStore,
    ),
  ]) {
    test('$name: ⑧ 사용자별로 따로 남고 null이면 지운다', () async {
      final store = make();
      expect(await store.read('alpha'), isNull);
      await store.save('alpha', 'awaiting|2026-10-25|25|3000000|a');
      expect(await store.read('alpha'), 'awaiting|2026-10-25|25|3000000|a');
      expect(await store.read('beta'), isNull, reason: '다른 사용자에게 이어지지 않는다');
      await store.save('alpha', null);
      expect(await store.read('alpha'), isNull);
    });
  }

  test('device: 사용자 ID를 이름에 넣어 저장한다', () async {
    final prefs = _FakePreferences();
    final store = DeviceSalaryNoticeStore(preferences: prefs);
    await store.save('alpha', 'k');
    expect(prefs.values, {'salary-notice-folded.alpha': 'k'});
  });

  test('device: 저장소를 쓸 수 없으면 기록 없음으로 보고 안내를 다시 보인다', () async {
    final store = DeviceSalaryNoticeStore(
      preferences: _FakePreferences(failing: true),
    );
    await store.save('alpha', 'k');
    expect(await store.read('alpha'), isNull);
  });
}
