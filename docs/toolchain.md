# 팀 개발 도구

모바일 목표는 Flutter/Dart다. 아래의 기록된 Node 기준과 아직 정하지 않은 Flutter 기준을 구분한다. 스킬 설치는 SDK나 앱 초기화가 아니다.

| 영역            | 기준                                           | 상태                                                               |
| --------------- | ---------------------------------------------- | ------------------------------------------------------------------ |
| Node / npm      | package.json의 24.21.0 / 11.19.0               | 기존 저장소 기록 유지. 제공 환경과 공식 배포 호환성은 사용 전 확인 |
| 모바일          | Flutter stable의 팀 지정 버전, 포함된 Dart SDK | 초기화 때 정확한 버전 확정·기록. 아직 설치·고정하지 않음           |
| TypeScript      | 6.0.3                                          | 기존 Node 공통 도구. Dart 검사를 대신하지 않음                     |
| API / 더미 서버 | Fastify 5.12.5                                 | 기존 초기화 전 제안. 실제 배포·호환성 확인 후 선택                 |
| DB              | PostgreSQL 18.6                                | 기존 초기화 전 제안. 연결·초기화 전                                |
| Android / iOS   | 선택한 Flutter SDK의 공식 요구사항             | 에뮬레이터·실기기·서명은 별도 준비. iOS 빌드는 macOS/Xcode 필요    |

## 설치와 변경

- integration이 초기화 전에 공식 배포와 호환성을 확인하고 사용 가능한 버전으로 기준·실제 설정·잠금 파일을 함께 맞춘다. 문서의 숫자를 실제 설치 확인으로 간주하지 않는다.
- 팀원마다 임의의 latest로 초기화하지 않는다. Flutter/Dart와 상태 관리·라우터 패키지 선택은 작업 범위 안에서 결정한다.
- Node 의존성은 루트 package-lock.json으로, Flutter 앱 의존성은 앱 pubspec.lock으로 공유한다. 기존 Node 잠금 파일을 삭제하지 않는다.
- 현재 lockfile에는 공통 Node 도구와 workspace만 있다. 앱·서버 프레임워크 초기화나 Dart 검사는 포함되지 않는다.
- 기존 유효한 환경은 재사용한다. Node 의존성이 바뀌었거나 최초 준비 시 `npm ci`, Flutter pubspec이 생긴 뒤 최초 준비 또는 잠금 파일 변경 시 `flutter pub get --enforce-lockfile`을 사용한다. 초기 lockfile 생성·SDK 변경은 integration 초기화 작업에서 처리한다.
- 명령은 각 도구가 요구하는 루트에서 실행한다. 기존 하네스는 저장소 루트, Flutter는 pubspec이 있는 앱 루트다. Windows에서는 필요한 경우 npm.cmd를 사용한다.

## 검사와 스킬

기존 Prettier 3.9.9, ESLint 10.11.0, @eslint/js 10.0.1, typescript-eslint 8.70.1, globals 17.12.0은 Node/문서 공통 검사다. Dart는 dart format, Flutter 분석·테스트를 사용하며 [전환 기준](harness/FLUTTER_TRANSITION.md)의 미구축 부분을 먼저 확인한다.

Claude Code/Codex는 각자 설치·로그인한다. 스킬 파일과 승인된 공유 설정은 Git으로 받으며 개인 계정·비밀값·PC 경로는 공유하지 않는다. [팀원용 빠른 시작](harness/TEAM_SKILLS_QUICKSTART.md)을 따른다.

설치 기준: [Flutter](https://docs.flutter.dev/install), [Dart pub get](https://dart.dev/tools/pub/cmd/pub-get), [Claude Code](https://code.claude.com/docs/en/setup), [Codex 스킬](https://learn.chatgpt.com/docs/build-skills).
