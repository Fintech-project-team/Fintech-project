import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 2026-10-20: 번들한 Pretendard OFL 원문 경로. pubspec assets에 등록되어 있다.
const String pretendardLicenseAsset = 'assets/fonts/OFL.txt';

bool _pretendardLicenseRegistered = false;

/// 2026-10-20: Pretendard 라이선스를 Flutter 라이선스 목록(LicensePage)에 한 번만 등록한다.
/// 인자 없음. 반환값 없음 - 전역 LicenseRegistry에 수집기를 추가하며 여러 번 호출해도 중복 등록하지 않는다.
/// 원문은 목록을 열 때 assets/fonts/OFL.txt에서 읽는다.
void registerPayseFontLicenses() {
  if (_pretendardLicenseRegistered) return;
  _pretendardLicenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString(pretendardLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['Pretendard'], text);
  });
}
