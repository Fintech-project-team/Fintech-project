import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-11-02: 기기 저장소 대신 쓰는 메모리 대역. [failing]이면 읽기·쓰기에서 예외를 던진다.
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('기록이 없으면 null, 저장한 사용자만 값을 돌려준다', () async {
    final store = MemoryFirstCalcRecordStore();
    expect(await store.read('a'), isNull);
    await store.save('a', FirstCalcRecord.deferred);
    expect(await store.read('a'), FirstCalcRecord.deferred);
    expect(await store.read('b'), isNull);
  });

  test('같은 사용자는 마지막 기록 하나만 남는다', () async {
    final store = MemoryFirstCalcRecordStore();
    await store.save('a', FirstCalcRecord.deferred);
    await store.save('a', FirstCalcRecord.explained);
    expect(await store.read('a'), FirstCalcRecord.explained);
  });

  test('기기 기록은 새 저장소 객체(앱 재실행)에서도 남는다', () async {
    final prefs = _FakePreferences();
    await DeviceFirstCalcRecordStore(preferences: prefs)
        .save('a', FirstCalcRecord.skipped);
    expect(prefs.values, {'first-calc-record.a': 'skipped'});
    final restarted = DeviceFirstCalcRecordStore(preferences: prefs);
    expect(await restarted.read('a'), FirstCalcRecord.skipped);
    expect(await restarted.read('b'), isNull);
  });

  test('읽지 못하거나 모르는 값이면 기록 없음으로 본다', () async {
    final broken = DeviceFirstCalcRecordStore(
      preferences: _FakePreferences(failing: true),
    );
    expect(await broken.read('a'), isNull);
    await broken.save('a', FirstCalcRecord.explained);
    final prefs = _FakePreferences()..values['first-calc-record.a'] = 'unknown';
    expect(
      await DeviceFirstCalcRecordStore(preferences: prefs).read('a'),
      isNull,
    );
  });
}
