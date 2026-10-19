# PAYSE Flutter 공통 앱

앱 루트는 `apps/mobile`, Dart 진입점은 `lib/main.dart`다. Flutter **3.47.7 stable**, 포함 Dart **3.13.5**를 사용한다. 기존 `app/`, `src/`, `package.json`은 이전 Node 골격과 검사 연결을 보존한 것이며 신규 모바일 기능은 `lib/`, `test/`에서 개발한다.

## 처음 받았을 때

```sh
cd apps/mobile
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

저장소 루트에서는 `node scripts/harness/run-flutter.mjs check`로 SDK 일치·Dart 포맷·분석·위젯 테스트를 함께 검사한다. 최초 준비/잠금 파일 변경 외에는 의존성을 다시 받지 않는다. Flutter의 Dart SDK를 사용하고 개인 SDK 경로를 커밋하지 않는다.

## 준비된 것과 후속 작업

- 준비: PAYSE 시작 화면, Android/iOS 플랫폼 소스, pubspec·lockfile, VS Code 실행 설정, 로컬/CI 검사 명령.
- 후속: 데모 로그인·PIN·서버 API·금융 Repository·순수 계산·제품 화면·실기기/시뮬레이터 빌드. 시작 화면은 v0.6 완료나 최종 디자인을 의미하지 않는다.
- `com.example.payse`는 초기 개발용 식별자다. 정식 배포 전 두 담당자가 실제 Android applicationId와 iOS bundleId를 정하고 관련 플랫폼 설정을 함께 바꾼다.
- 공통 객체는 앱 시작점에서 생성하고 필요한 생성자로 전달한다. 전역 가변 Singleton·Service Locator를 도입하지 않는다. 초기화에는 공유 금융 상태 자체가 없다.
- Node 루트 `package-lock.json`과 Flutter `pubspec.lock`을 모두 유지한다. `package.json`의 검사 스크립트는 실제 Flutter 명령으로 연결된다.

[모바일 상세 안내](docs/bootstrap.md), [앱 구조](../../docs/app-architecture.md), [Mac 설치·개발](../../docs/harness/MAC_FLUTTER_VSCODE_GUIDE.md).
