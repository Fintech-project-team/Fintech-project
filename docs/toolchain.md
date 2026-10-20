# 팀 개발 도구

모바일 목표는 Flutter/Dart다. 아래의 기존 Node 기록과 2026-10-19 초기화한 Flutter 기준을 구분한다. 스킬 설치는 SDK나 앱 초기화가 아니다.

| 영역            | 기준                                       | 상태                                                                 |
| --------------- | ------------------------------------------ | -------------------------------------------------------------------- |
| Node / npm      | package.json의 24.21.0 / 11.19.0           | 기존 저장소 기록 유지. 제공 환경과 공식 배포 호환성은 사용 전 확인   |
| 모바일          | Flutter 3.47.7 stable / Dart 3.13.5        | apps/mobile/flutter-toolchain.json으로 검사. Mac 안내와 같은 버전    |
| TypeScript      | 6.0.3                                      | 기존 Node 공통 도구. Dart 검사를 대신하지 않음                       |
| API / 더미 서버 | Java 21 · Spring Boot 4.1.1 · Gradle 9.7.1 | 2026-10-20 API 초기화. 실행/범위는 apps/api/docs/spring-bootstrap.md |
| Python          | 3.10 이상                                  | 기존 더미 테스트용. API test/check에서 필요                          |
| DB              | PostgreSQL 18.6                            | 기존 초기화 전 제안. 연결·초기화 전                                  |
| Android / iOS   | 선택한 Flutter SDK의 공식 요구사항         | 에뮬레이터·실기기·서명은 별도 준비. iOS 빌드는 macOS/Xcode 필요      |

## 설치와 변경

- integration이 초기화 전에 공식 배포와 호환성을 확인하고 사용 가능한 버전으로 기준·실제 설정·잠금 파일을 함께 맞춘다. 문서의 숫자를 실제 설치 확인으로 간주하지 않는다.
- 팀원마다 임의의 latest로 초기화하지 않는다. Flutter/Dart와 상태 관리·라우터 패키지 선택은 작업 범위 안에서 결정한다.
- Node 의존성은 루트 package-lock.json으로, Flutter 앱 의존성은 앱 pubspec.lock으로 공유한다. 기존 Node 잠금 파일을 삭제하지 않는다.
- 루트 package-lock.json은 기존 공통 Node 도구와 workspace를 유지한다. Flutter 앱은 apps/mobile/pubspec.yaml·pubspec.lock으로 별도 관리하며 서버는 API 전용 Gradle Wrapper와 gradle.lockfile로 별도 관리한다.
- 기존 유효한 환경은 재사용한다. Node 의존성이 바뀌었거나 최초 준비 시 `npm ci`, Flutter 앱 최초 준비 또는 잠금 파일 변경 시 `flutter pub get --enforce-lockfile`을 사용한다. 초기 lockfile 생성·SDK 변경은 integration 초기화 작업에서 처리한다.
- 명령은 각 도구가 요구하는 루트에서 실행한다. 기존 하네스는 저장소 루트, Flutter는 pubspec이 있는 앱 루트다. Windows에서는 필요한 경우 npm.cmd를 사용한다.

## 검사와 스킬

기존 Prettier 3.9.9, ESLint 10.11.0, @eslint/js 10.0.1, typescript-eslint 8.70.1, globals 17.12.0은 Node/문서 공통 검사다. Dart는 dart format, Flutter 분석·테스트를 사용하며 [전환 기준](harness/FLUTTER_TRANSITION.md)의 현재 구현·미검증 범위를 확인한다. 로컬 검사는 `node scripts/harness/run-flutter.mjs check`로 SDK 버전·Dart 포맷·분석·위젯 테스트를 실행한다.

Claude Code/Codex는 각자 설치·로그인한다. 스킬 파일과 승인된 공유 설정은 Git으로 받으며 개인 계정·비밀값·PC 경로는 공유하지 않는다. [팀원용 빠른 시작](harness/TEAM_SKILLS_QUICKSTART.md)을 따른다.

설치 기준: [Flutter](https://docs.flutter.dev/install), [Dart pub get](https://dart.dev/tools/pub/cmd/pub-get), [Claude Code](https://code.claude.com/docs/en/setup), [Codex 스킬](https://learn.chatgpt.com/docs/build-skills).

## MVP와 LLM의 설치 시점

현행 MVP는 서버 준비 합성 금융 데이터·데모 세션·사용자 설정 저장과 Flutter 로컬 계산을 사용한다. 별도 mock-bank 프로세스는 필수가 아니다. v0.7 실제 LLM 연동은 P0이고 v0.8/v0.9 설명 보조는 P1이다. SDK·모델 접근·키는 v0.7 연동 전에 확인한다. CODEF는 참고 자료이며 해당 SDK나 실제 금융 수집 서버를 MVP 선행 도구로 설치하지 않는다. 여러 제공자·에이전트 프레임워크·벡터 DB·추가 MCP 도입은 확정하지 않았다.

이 문서의 기존 Node 도구 숫자는 저장소 설정과의 일치를 위해 보존했다. 2026-10-19 Flutter 초기화는 Flutter/Dart와 앱 의존성을 확인했으며, 기존 Node 기록의 숫자를 새로 검증하거나 변경한 작업은 아니다. E2E와 디자인 시스템 구축도 현재 보류다.

Flutter SDK 버전은 `apps/mobile/flutter-toolchain.json`, 앱 pubspec, CI와 함께 유지한다. 설치된 SDK 자동 업그레이드는 하지 않는다. 2026-10-19 모바일 초기화 당시 호스트 Node는 24.19.0이었다. 2026-10-20 API 검증 작업본에서는 팀 기준 Node 24.21.0/npm 11.19.0을 사용했다. 원격 CI 실행 결과는 로컬 검사와 별도로 확인한다.

## API Java 준비

API 개발자는 JDK 21을 준비한다. `node scripts/harness/run-api.mjs check`로 실제 Java 검사와 실행 JAR 생성을 확인한다. 기존 Node/npm은 공통 검사에 유지한다. Flutter만 개발하는 팀원에게 JDK 21 설치나 모바일 SDK 변경을 요구하지 않는다. Java 프레임워크 선택으로 PostgreSQL 운영 버전·LLM SDK·배포 환경을 확정하지 않는다.
