import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/payse_app.dart';
import 'data/auth/secure_credential_stores.dart';
import 'data/first_calc_record_store.dart';
import 'data/http/api_config.dart';
import 'data/http/device_tls_transport.dart';
import 'features/my_info/my_info_screen.dart' show AppVersion;

/// 2026-10-19: PAYSE 앱을 시작한다. 인자는 없고 반환값 없이 루트 위젯을 등록한다.
/// 2026-11-01: 빌드 설정에 서버 주소가 있으면 빌드 모드와 무관하게 실제 서버와 기기 보안 저장소(세션·PIN·동의)를 쓴다.
/// 2026-11-02: 서버는 등록 기기 인증서를 요구하므로 모든 요청을 Keystore 키 [deviceTlsAlias]의 mTLS 통신으로 보낸다. 서버
/// 인증서는 기기 기본 신뢰 저장소와 주소(IP) 일치로 검증한다.
/// 2026-11-02: 01-3 첫 계산 기록은 모드와 무관하게 기기에 남겨 재실행 뒤 01-3을 다시 띄우지 않는다.
/// 2026-11-03: 내 정보 탭의 앱 버전은 모드와 무관하게 설치된 앱 정보([_installedVersion])에서 읽는다.
/// 주소 형식이 틀리면 [ApiConfigException]으로 시작에 실패한다. 주소가 없으면 기존처럼 메모리 저장소와 가짜(개발)·서비스 불가(릴리스)다.
void main() {
  final config = ApiConfig.fromEnvironment();
  final firstCalcRecords = DeviceFirstCalcRecordStore();
  if (config == null) {
    runApp(
      PayseApp(
        firstCalcRecords: firstCalcRecords,
        appVersion: _installedVersion,
      ),
    );
    return;
  }
  const values = FlutterSecureValues();
  runApp(
    PayseApp(
      server: (
        config: config,
        transport: DeviceTlsTransport(
          alias: deviceTlsAlias,
          timeout: config.timeout,
        ),
      ),
      sessionStore: SecureSessionStore(values),
      pinStore: SecurePinStore(values),
      consentStore: SecureConsentStore(values),
      firstCalcRecords: firstCalcRecords,
      appVersion: _installedVersion,
    ),
  );
}

/// 2026-11-03: 설치된 앱의 버전과 빌드 번호를 플랫폼에서 읽는다. 실패는 내 정보 화면이 버전 줄을 숨겨 처리한다.
Future<AppVersion?> _installedVersion() async {
  final info = await PackageInfo.fromPlatform();
  return (version: info.version, buildNumber: info.buildNumber);
}
