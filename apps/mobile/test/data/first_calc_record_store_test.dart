import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/first_calc_record_store.dart';

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
}
