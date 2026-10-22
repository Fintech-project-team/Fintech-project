import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/credential_stores.dart';

void main() {
  test('wrong PINs add up and a right PIN resets the count', () async {
    final store = MemoryLocalPinStore();
    await store.setPin('135790');

    expect((await store.verify('000000')).failures, 1);
    expect((await store.verify('000001')).failures, 2);
    expect(await store.failureCount(), 2);

    final ok = await store.verify('135790');
    expect((ok.matched, ok.failures), (true, 0));
    expect(await store.failureCount(), 0);
  });

  test(
    '5 failures require recovery; even the right PIN is refused until reset',
    () async {
      final store = MemoryLocalPinStore();
      await store.setPin('135790');
      for (var i = 0; i < 4; i++) {
        expect((await store.verify('000000')).recoveryRequired, isFalse);
      }
      final fifth = await store.verify('000000');
      expect((fifth.failures, fifth.recoveryRequired), (5, true));

      final locked = await store.verify('135790');
      expect(
        (locked.matched, locked.failures),
        (false, 5),
        reason: '비교하지 않고 실패',
      );

      await store.setPin('246813');
      expect(await store.failureCount(), 0, reason: '복구 후 새 PIN 설정은 횟수 초기화');
      expect((await store.verify('246813')).matched, isTrue);
    },
  );

  test('clear removes the PIN and the count; no PIN never matches', () async {
    final store = MemoryLocalPinStore();
    expect((await store.verify('135790')).matched, isFalse);
    await store.setPin('135790');
    await store.verify('000000');
    await store.clear();
    expect(await store.hasPin(), isFalse);
    expect(await store.failureCount(), 0);
  });
}
