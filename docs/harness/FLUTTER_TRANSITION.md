# Flutter 전환 상태와 검사 기준

2026-10-08 사용자 요청에 따라 모바일의 목표 기술은 Flutter/Dart다. 스킬 설치와 앱 전환은 별개다. 이 문서는 현재 구조와 준비 조건을 구분하는 기준이며 앱 초기화 완료를 선언하지 않는다.

## 현재와 다음 단계

| 항목        | 현재                                                                     | 다음 초기화 작업에서 필요한 것                                  |
| ----------- | ------------------------------------------------------------------------ | --------------------------------------------------------------- |
| 앱          | apps/mobile의 package.json과 app/src 안내만 있음. pubspec·Dart 구현 없음 | 기존 변경을 보존한 Flutter 초기화, 팀 SDK 버전 기록             |
| 서버·하네스 | Node/npm workspace와 JS/TS 검사 유지                                     | Flutter와 함께 쓸 실행·검사 명령 연결                           |
| 역할 경로   | policy.json은 기존 app/src 경로만 분담                                   | lib·test·integration_test 경로와 작업별 소유 범위 동시 반영     |
| 데이터 계약 | packages/contracts와 docs/contracts.md의 초안                            | 언어 독립적인 JSON 계약과 Dart/서버 직렬화·검증 사례            |
| 계산        | finance-core는 Node workspace 골격                                       | 기존 앱 측 순수 계산 원칙을 만족하는 Dart 구현·패키지 연결 결정 |
| 디자인      | 토큰·컴포넌트·승인된 시각 기준 미구축                                    | 대표 화면 기준 최소 토큰·컴포넌트·상태 확정                     |
| E2E         | 시나리오·환경·CI 실행기 미구축                                           | 합성 데이터 초기화, 기기·서버 연결, 실패 증거와 CI              |

기존 TypeScript 패키지를 Flutter에서 직접 import할 수 있다고 설명하지 않는다. 계산을 서버로 이동하거나 Dart/TS 양쪽에 중복 구현하는 결정도 이 설치본에서 하지 않는다. 미확정 금융 정책은 그대로 미확정이다. Flutter 선택은 프레임워크 변경이며 기존 Android 시연 목표나 iOS 범위를 자동 변경하지 않는다.

## 권장 경로와 적용 조건

초기화 시 앱 내부 후보는 `apps/mobile/lib/app/`, `lib/features/{connection,recurring,spending,allocation}/`, `lib/shared/`, `test/`, `integration_test/`다. 이는 초기화 작업의 제안이며 현재 하네스가 허용한 경로라는 뜻이 아니다.

기존 app/src 폴더는 이전 골격이다. 기능 담당자는 거기에 새 Expo 코드를 추가하지 않는다. Flutter 기능 작업에 앞서 integration 초기화 작업이 실제 경로·역할 정책·제품 검사·Node workspace와 Dart package 공존·IDE 설정을 함께 맞춰야 한다. 역할이나 allowedPaths를 바꿔 실패를 우회하지 않는다. 아직 충족되지 않은 전제는 BLOCKED로 보고하고, 정책·금융 사례 확인 등 가능한 읽기 작업은 진행할 수 있다.

## 검사 선택

Node 하네스는 JS/TS 제품을 대상으로 한다. Dart 파일을 위한 분석·테스트·코드 명세 검사는 자동 연결되어 있지 않다. 현재 하네스의 PASS 또는 product NOT_APPLICABLE을 Flutter 구현 완료 근거로 사용하지 않는다. Flutter 기능 완료에는 아래에서 해당되는 검사와 기기 근거가 추가로 필요하다.

아래 명령은 실제 pubspec이 있는 패키지 루트에서 실행하며 꺾쇠 부분은 실제 경로·기기 ID로 바꾼다.

| 변경                            | 추가 근거                                                                                            |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Dart 코드·테스트                | `dart format --output=none --set-exit-if-changed <변경한 Dart 파일 목록>`                            |
| Flutter 패키지                  | `flutter analyze`와 영향받은 `flutter test <테스트 파일>`                                            |
| 순수 Dart 패키지                | `dart analyze`와 영향받은 `dart test <테스트 파일>`                                                  |
| 의존성·공통 계약·공통 테마      | 의존하는 대상까지 분석·관련 테스트 범위 확대                                                         |
| 저장·서버 연결·사용자 핵심 흐름 | 지원 기기의 `flutter test integration_test/<파일> -d <기기 ID>` 및 연결 범위·합성 데이터 초기화 기록 |
| 문서·스킬만 변경                | 기존 공통 하네스와 문서·스킬 정합성. Flutter 앱 검사는 해당 없음                                     |

분석은 대상 패키지 단위의 읽기 검사다. 자동 수정은 최초 허용 파일에만 적용한다. `dart fix --apply`나 `dart format .`를 작업 범위 전체에 무조건 실행하지 않는다. Dart와 Node 제품 검사를 함께 요구하는 변경이면 두 결과를 모두 확인한다. 형식 검사를 위해 새 테스트를 만들지 않는다.

재실행 조건은 [AGENT_REVIEW.md](AGENT_REVIEW.md)와 같다. 관련 입력·설정·의존성·환경이 같은 PASS를 재사용한다. pubspec·SDK·역할 정책·명령·필수 기기가 없으면 필요한 검사가 BLOCKED인 것이며 생략해서 PASS로 만들 수 없다. 전체 종합 보고서를 꾸며 쓰지 말고 공통 하네스 결과와 Flutter 추가 검사 결과를 따로 기록한다.

## 도구와 잠금 파일

Node/npm 기준은 [toolchain.md](../toolchain.md)를 따른다. Flutter SDK는 초기화 담당자가 공식 배포와 호환성을 확인한 버전으로 팀에 고정하고 Dart는 그 SDK에 포함된 버전을 사용한다. Flutter 앱의 pubspec.lock은 공유한다. pubspec.yaml이 생긴 뒤 잠금 의존성을 받으며, 모든 작업마다 의존성을 다시 설치하지 않는다.

Android/iOS 플랫폼 프로젝트는 앱 소스다. 루트 .gitignore에서 두 폴더 전체를 제외하지 않는다. 생성 캐시·빌드 출력·개인 서명 파일은 제외한다. 실제 플랫폼별 세부 설정은 초기화 때 확인한다.

현재 여섯 스킬은 MCP 없이 사용할 수 있는 지침이다. Dart/Flutter MCP는 실제 앱을 다루는 도구가 필요할 때 추가하는 선택 구성이다. 스킬 설치만으로 SDK·MCP·에뮬레이터·앱·디자인 시스템·E2E가 설치되거나 완성되지 않는다.

공식 기준: [Flutter 설치](https://docs.flutter.dev/install), [테스트 계층](https://docs.flutter.dev/testing/overview), [통합 테스트](https://docs.flutter.dev/testing/integration-tests), [Dart format](https://dart.dev/tools/dart-format).
