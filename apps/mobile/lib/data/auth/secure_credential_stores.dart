import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_stores.dart';

/// 2026-11-01: 기기 보안 저장소의 읽기·쓰기 경계. 실제 구현은 [FlutterSecureValues]이며 테스트에서 실패를 주입한다.
abstract interface class SecureValues {
  /// 2026-11-01: [key]의 값을 반환한다. 없으면 null이다. 읽지 못하면 예외를 던진다.
  Future<String?> read(String key);

  /// 2026-11-01: [key]에 [value]를 쓴다. 쓰지 못하면 예외를 던진다.
  Future<void> write(String key, String value);

  /// 2026-11-01: [key]를 지운다. 지우지 못하면 예외를 던진다.
  Future<void> delete(String key);
}

/// 2026-11-02: flutter_secure_storage 구현(Android: Keystore로 감싼 키 + AES-GCM 암호문). 오류가 나도 값을 자동으로 지우지 않아
/// (resetOnError: false) 읽기 실패가 '저장된 세션 없음'으로 바뀌지 않는다. 지우기는 키 하나씩만 하며 mTLS 키·인증서와 무관하다.
class FlutterSecureValues implements SecureValues {
  /// 2026-11-02: 자동 초기화를 끈 Android 설정으로 만든다.
  const FlutterSecureValues()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(resetOnError: false),
      );

  final FlutterSecureStorage _storage;

  /// 2026-11-02: 값을 읽는다.
  @override
  Future<String?> read(String key) => _storage.read(key: key);

  /// 2026-11-02: 값을 쓴다.
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  /// 2026-11-02: 값을 지운다.
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 2026-11-01: 기기 보안 저장소를 읽거나 쓰지 못했다. 세션 없음·저장 성공으로 바꾸지 않고 호출부가 실패로 처리한다.
class CredentialStoreException implements Exception {
  /// 2026-11-01: 실패한 작업 [operation]과 원인 [cause]로 만든다. 저장 값은 담지 않는다.
  const CredentialStoreException(this.operation, this.cause);

  final String operation;
  final Object cause;

  /// 2026-11-01: 작업과 원인 형식을 반환한다.
  @override
  String toString() =>
      'CredentialStoreException($operation, ${cause.runtimeType})';
}

/// 2026-11-01: 저장소 작업 [operation]의 [run]을 실행하고 실패를 [CredentialStoreException]으로 바꾼다.
Future<T> _guard<T>(String operation, Future<T> Function() run) async {
  try {
    return await run();
  } on CredentialStoreException {
    rethrow;
  } on Exception catch (error) {
    throw CredentialStoreException(operation, error);
  }
}

/// 2026-11-01: 세션을 기기 보안 저장소에 둔다. 앱을 다시 시작해도 남고, 로그아웃 성공 뒤에만 지운다.
class SecureSessionStore implements SessionStore {
  /// 2026-11-01: 저장소 [values]로 만든다.
  const SecureSessionStore(this.values);

  final SecureValues values;
  static const String _key = 'payse.session';

  /// 2026-11-01: 저장된 세션을 반환한다. 형식이 깨졌으면 [CredentialStoreException]이다.
  @override
  Future<StoredSession?> read() => _guard('session.read', () async {
    final text = await values.read(_key);
    if (text == null) return null;
    final json = jsonDecode(text);
    if (json is! Map ||
        json['userId'] is! String ||
        json['name'] is! String ||
        json['sessionId'] is! String ||
        json['accessToken'] is! String) {
      throw const CredentialStoreException('session.read', 'format');
    }
    return StoredSession(
      userId: json['userId']! as String,
      name: json['name']! as String,
      sessionId: json['sessionId']! as String,
      accessToken: json['accessToken']! as String,
    );
  });

  /// 2026-11-01: 세션을 덮어쓴다.
  @override
  Future<void> save(StoredSession session) => _guard(
    'session.save',
    () => values.write(
      _key,
      jsonEncode({
        'userId': session.userId,
        'name': session.name,
        'sessionId': session.sessionId,
        'accessToken': session.accessToken,
      }),
    ),
  );

  /// 2026-11-01: 세션을 지운다.
  @override
  Future<void> clear() => _guard('session.clear', () => values.delete(_key));
}

/// 2026-11-01: PIN과 연속 실패 횟수를 한 값으로 기기 보안 저장소에 둔다. 앱을 다시 시작해도 5회 제한이 풀리지 않는다.
/// PIN은 서버로 보내지 않으며 이 클래스 밖으로 읽어 내지 않는다(비교만 함).
class SecurePinStore implements LocalPinStore {
  /// 2026-11-01: 저장소 [values]로 만든다.
  const SecurePinStore(this.values);

  final SecureValues values;
  static const String _key = 'payse.pin';

  /// 2026-11-01: PIN 설정 여부를 반환한다.
  @override
  Future<bool> hasPin() async => (await _read()) != null;

  /// 2026-11-01: 새 PIN을 두고 실패 횟수를 0으로 한다.
  @override
  Future<void> setPin(String pin) => _write(pin, 0);

  /// 2026-11-01: 비교 결과와 누적 실패 횟수를 반환한다. 실패 횟수를 저장하지 못하면 [CredentialStoreException]이다.
  @override
  Future<PinCheckResult> verify(String pin) async {
    final stored = await _read();
    if (stored == null) {
      return const PinCheckResult(matched: false, failures: 0);
    }
    final (saved, failures) = stored;
    if (failures >= maxPinFailures) {
      return PinCheckResult(matched: false, failures: failures);
    }
    if (saved == pin) {
      if (failures != 0) await _write(saved, 0);
      return const PinCheckResult(matched: true, failures: 0);
    }
    await _write(saved, failures + 1);
    return PinCheckResult(matched: false, failures: failures + 1);
  }

  /// 2026-11-01: 누적 실패 횟수를 반환한다.
  @override
  Future<int> failureCount() async => (await _read())?.$2 ?? 0;

  /// 2026-11-01: PIN과 실패 횟수를 지운다.
  @override
  Future<void> clear() => _guard('pin.clear', () => values.delete(_key));

  /// 2026-11-01: 저장된 (PIN, 실패 횟수)를 반환한다. 없으면 null이다.
  Future<(String, int)?> _read() => _guard('pin.read', () async {
    final text = await values.read(_key);
    if (text == null) return null;
    final json = jsonDecode(text);
    if (json is! Map || json['pin'] is! String || json['failures'] is! int) {
      throw const CredentialStoreException('pin.read', 'format');
    }
    return (json['pin']! as String, json['failures']! as int);
  });

  /// 2026-11-01: PIN [pin]과 실패 횟수 [failures]를 함께 쓴다.
  Future<void> _write(String pin, int failures) => _guard(
    'pin.write',
    () => values.write(_key, jsonEncode({'pin': pin, 'failures': failures})),
  );
}

/// 2026-11-01: 필수 약관 동의 기록을 기기 보안 저장소에 둔다.
class SecureConsentStore implements ConsentStore {
  /// 2026-11-01: 저장소 [values]로 만든다.
  const SecureConsentStore(this.values);

  final SecureValues values;
  static const String _key = 'payse.consent';

  /// 2026-11-01: 동의 기록이 있으면 true를 반환한다.
  @override
  Future<bool> hasAgreed() =>
      _guard('consent.read', () async => await values.read(_key) == 'agreed');

  /// 2026-11-01: 동의를 기록한다.
  @override
  Future<void> saveAgreed() =>
      _guard('consent.save', () => values.write(_key, 'agreed'));

  /// 2026-11-01: 동의 기록을 지운다.
  @override
  Future<void> clear() => _guard('consent.clear', () => values.delete(_key));
}
