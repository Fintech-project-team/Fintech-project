# 공통 앱 초기화와 개발 경계

초기화 기준일: 2026-10-19. Windows의 Flutter 3.47.7 stable / Dart 3.13.5로 생성했다. Android와 iOS 플랫폼 소스를 포함하지만 이 문서 자체는 기기 빌드 성공 근거가 아니다. 최종 실행 결과는 작업 검증 보고로 확인한다.

| 경로                                    | 책임                                                                               |
| --------------------------------------- | ---------------------------------------------------------------------------------- |
| `lib/main.dart`, `lib/app/`             | 앱 시작, 공통 구성, 후속 라우팅·수명 연결                                          |
| `lib/data/`                             | 후속 Repository·API adapter; 초기화에서는 미생성                                   |
| `lib/features/`                         | auth·connection·overview·planning·recurring·simulation·adjustment 기능의 후속 구현 |
| `test/app/`, `test/features/`           | 공통 시작 검사와 담당 기능 검사                                                    |
| `android/`, `ios/`                      | Flutter가 생성한 플랫폼 소스; 개인 서명·생성 캐시는 제외                           |
| `docs/`, `lib/features/<feature>/docs/` | 모바일 공통 상세와 기능별 상세                                                     |

부품이 필요한 시점에 생성자 주입으로 연결한다. 상태 관리·라우터 패키지는 초기화에서 추가하지 않았다. ViewModel과 Repository 없는 단순 시작 화면에 빈 추상 계층을 만들지 않는다. 금융 기능 도입 시 [공통 구조](../../../docs/app-architecture.md)의 UI/데이터/순수 계산 경계를 따른다.

금융 계산은 후속 `packages/payse_calculation/` 순수 Dart 패키지에 구현한다. 기존 `packages/finance-core` Node 골격에 동일 계산을 중복 구현하지 않는다. 이번 작업은 계산 패키지·더미 금융 자료·API를 생성하지 않는다.

Flutter SDK 버전의 기계 판정 기준은 `../flutter-toolchain.json`이며 `../pubspec.yaml`과 CI도 같은 버전을 사용한다. 변경 시 세 곳과 팀 `docs/toolchain.md`, lockfile을 함께 검토한다. 앱의 `0.1.0+1`은 초기 빌드 표기이며 제품 v0.6/v1.0 완료 선언이 아니다.

`dart format --output=none --set-exit-if-changed lib test`는 읽기 검사다. 포맷 수정은 작업 명세에 허용된 변경 파일만 대상으로 한다. SDK와 의존성이 준비되지 않으면 제품 검사 완료로 보고하지 않는다.
