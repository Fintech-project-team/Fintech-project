# PAYSE Mac 설치와 사용

공통 초기화 SDK 기준은 Flutter **3.47.7 stable**, 포함된 Dart **3.13.5**입니다. SDK 변경은 [toolchain.md](../toolchain.md)와 앱 잠금 파일을 함께 검토한 뒤 반영합니다. 이미 완료한 단계는 생략합니다. 기기 연결은 보류합니다.

## 1 Git과 VS Code 준비

터미널에서 `git --version`과 `xcode-select -p`를 확인합니다. 명령행 도구가 없으면 `xcode-select --install`로 설치합니다.
[VS Code](https://code.visualstudio.com/download)를 설치하고 응용 프로그램 폴더에 둡니다.

## 2 Flutter SDK 설치

기존 SDK가 있다면 4단계의 경로·버전을 먼저 확인합니다. 모두 일치하는 경우에만 2~3단계를 생략합니다. 기존 flutter 폴더에는 덮어쓰지 않습니다.

[공식 다운로드](https://docs.flutter.dev/install/archive)에서 **macOS 3.47.7 stable**을 받습니다. Apple Silicon은 **arm64**, Intel은 **x64**를 선택합니다.

터미널에서 폴더를 만듭니다.

```bash
mkdir -p "$HOME/develop"
```

ZIP을 압축 해제하고 생성된 `flutter` 폴더를 `~/develop`로 옮깁니다. 최종 위치는 **~/develop/flutter**입니다. [공식 설치 안내](https://docs.flutter.dev/install/manual)

## 3 PATH 등록

```bash
nano "$HOME/.zprofile"
```

파일 끝에 아래 한 줄을 추가합니다. 같은 줄이 있으면 생략합니다.

```bash
export PATH="$HOME/develop/flutter/bin:$PATH"
```

**Control+O → Enter**로 저장하고 **Control+X**로 종료합니다. 터미널과 VS Code를 완전히 닫고 다시 엽니다. [PATH 안내](https://docs.flutter.dev/install/add-to-path)

## 4 설치 확인

```bash
command -v flutter
flutter --version
dart --version
```

본인의 `~/develop/flutter/bin/flutter` 경로와 **Flutter 3.47.7·Dart 3.13.5**가 표시되는지 확인합니다.

## 5 VS Code 확장 설치

**Command+Shift+X → Flutter 검색 → 게시자 Dart Code → 설치**합니다. Dart 확장도 함께 설치됩니다.
VS Code를 다시 엽니다. SDK 위치를 묻는다면 **~/develop/flutter**를 선택합니다. `bin` 폴더를 선택하지 않습니다. [공식 안내](https://docs.flutter.dev/tools/vs-code)

## 6 공통 Flutter 앱 받기

[팀 Git 절차](../development-workflow.md)에 따라 초기화가 통합된 develop 변경을 본인 개인 브랜치에 반영합니다. VS Code에서 PAYSE 저장소 루트를 엽니다. 별도 Flutter 프로젝트를 생성하지 않습니다.

저장소 루트에서 아래 파일이 보이는지 확인합니다.

```bash
ls apps/mobile/pubspec.yaml apps/mobile/pubspec.lock apps/mobile/lib/main.dart
```

모두 있으면 7단계로 진행합니다. 없다면 현재 checkout에 공통 초기화가 반영되지 않은 상태입니다. SDK 재설치 대신 가져온 브랜치·커밋을 확인합니다. 로컬 적용본만 만든 상태와 팀 develop에 병합된 상태를 구분합니다.

## 7 코드 작성과 검사

앱 루트는 `apps/mobile`입니다. 저장소 루트에서 다음을 실행합니다.

```bash
cd apps/mobile
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

의존성 설치는 최초 준비 또는 lockfile이 바뀐 때 실행합니다. 버전·잠금 파일 오류를 해결하려고 개인적으로 Flutter를 업그레이드하거나 lockfile을 삭제하지 않습니다. 담당자와 팀 버전을 확인합니다.

실제 작업 명세와 와이어프레임을 `flowcast-task`에 지정하고 [앱 구조](../app-architecture.md), [데이터 계약](../data-contracts.md), [역할 경로](../ownership.md)에 따라 `lib/`와 `test/`를 수정합니다. 저장소 루트의 `node scripts/harness/run-flutter.mjs check`는 SDK·Dart 포맷·분석·위젯 검사를 함께 실행합니다. 포맷 수정은 작업 명세에 허용된 변경 파일로 제한합니다.

VS Code의 `PAYSE Flutter` 실행 구성은 `apps/mobile/lib/main.dart`를 가리킵니다. 현재 시작 화면은 초기화 확인용입니다. 기기 연결·Xcode 서명·Android/iOS 빌드는 별도 준비이며 위젯 테스트 성공을 기기 빌드 성공으로 보고하지 않습니다. [Flutter iOS 준비](https://docs.flutter.dev/platform-integration/ios/setup)
