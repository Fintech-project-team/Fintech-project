import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/secure_credential_stores.dart';

/// 2026-11-01: 기기 저장소 흉내. 값은 앱 재시작(새 저장소 객체)에도 남고, [failing]이면 모든 작업이 실패한다.
class _Device implements SecureValues {
  final Map<String, String> values = {};
  bool failing = false;

  @override
  Future<String?> read(String key) async {
    if (failing) throw Exception('keystore');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failing) throw Exception('keystore');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failing) throw Exception('keystore');
    values.remove(key);
  }
}

const _session = StoredSession(
  userId: 'u1',
  name: '테스트',
  sessionId: 's1',
  accessToken: 'token-1',
);

void main() {
  test(
    'session, PIN and failure count come back together after a restart',
    () async {
      final device = _Device();
      await SecureSessionStore(device).save(_session);
      final pins = SecurePinStore(device);
      await pins.setPin('135790');
      await pins.verify('000000');
      await pins.verify('000001');

      final restored = await SecureSessionStore(device).read();
      expect(restored?.accessToken, 'token-1');
      final restartedPins = SecurePinStore(device);
      expect(await restartedPins.hasPin(), isTrue);
      expect(
        await restartedPins.failureCount(),
        2,
        reason: '재시작해도 5회 제한이 풀리지 않음',
      );
      expect((await restartedPins.verify('135790')).matched, isTrue);
    },
  );

  test('5 failures survive a restart and still require recovery', () async {
    final device = _Device();
    await SecurePinStore(device).setPin('135790');
    for (var i = 0; i < 5; i++) {
      await SecurePinStore(device).verify('000000');
    }
    final locked = await SecurePinStore(device).verify('135790');
    expect((locked.matched, locked.recoveryRequired), (false, true));
  });

  test(
    'a storage failure is an error, never an empty session or a saved one',
    () async {
      final device = _Device()..failing = true;
      await expectLater(
        SecureSessionStore(device).read(),
        throwsA(isA<CredentialStoreException>()),
      );
      await expectLater(
        SecureSessionStore(device).save(_session),
        throwsA(isA<CredentialStoreException>()),
      );
      await expectLater(
        SecurePinStore(device).hasPin(),
        throwsA(isA<CredentialStoreException>()),
      );
    },
  );

  test('a broken stored value is an error, not a missing session', () async {
    final device = _Device()..values['payse.session'] = '{"userId":1}';
    await expectLater(
      SecureSessionStore(device).read(),
      throwsA(isA<CredentialStoreException>()),
    );
  });

  test('clearing removes the session, PIN and consent', () async {
    final device = _Device();
    await SecureSessionStore(device).save(_session);
    await SecurePinStore(device).setPin('135790');
    await SecureConsentStore(device).saveAgreed();
    await SecureSessionStore(device).clear();
    await SecurePinStore(device).clear();
    await SecureConsentStore(device).clear();
    expect(device.values, isEmpty);
  });
}
