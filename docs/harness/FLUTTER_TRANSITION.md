# Flutter 공통 앱과 남은 구현

앱 루트는 `apps/mobile`, 진입점은 `lib/main.dart`, SDK는 Flutter **3.47.7 stable**와 포함 Dart **3.13.5**다. Mac 설치 안내와 같은 버전이다. 제품 범위는 [PAYSE 기준](../product-baseline.md), 실제 구현과 남은 작업은 아래 표와 앱별 상세를 따른다.

| 항목       | 현재 초기화본                                                                                                                                                                                                    | 남은 작업                                                           |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 앱         | 공통 초기화 이후 FakeRepository·인증 화면·탭 골격이 추가됨. [모바일 상세](../../apps/mobile/docs/fake-repository.md) 참조                                                                                        | 실제 서버 연결·기기 저장과 금융 기능 통합을 각각 검증               |
| 역할 정책  | `lib/features/`와 대응 `test/features/`의 역할 경로 연결                                                                                                                                                         | 각 실제 작업의 allowedPaths를 필요한 파일로 제한                    |
| 검사       | SDK 일치·Dart 포맷·Flutter 분석·위젯 테스트 실행기, CI workflow 파일                                                                                                                                             | GitHub 실제 CI 실행·Mac 실행·실기기 빌드 확인                       |
| API/DB     | Java + Spring Boot 초기화·SQL/더미 준비. [서버 범위](../../apps/api/docs/spring-bootstrap.md) 참조                                                                                                               | 실제 세션·조회·설정 저장·정정 구현과 통합                           |
| 계산       | `packages/payse_calculation/` 순수 Dart 패키지(앱 path 의존, `run-flutter` 검사 포함). 기존 finance-core Node 골격은 계산 구현으로 사용하지 않음. [패키지 상세](../../packages/payse_calculation/docs/README.md) | FinancialSnapshot 어댑터·화면 연결과 상세 문서의 보류 항목          |
| LLM        | 초기화에 포함하지 않음                                                                                                                                                                                           | v0.7 실제 연동 P0, v0.8/v0.9 설명 보조 P1                           |
| 디자인·E2E | [디자인 기준](../design.md)에 토큰·컴포넌트와 개별 미정 항목이 있음                                                                                                                                              | 디자인 미정 항목과 실제 E2E·기기 검증을 구분하여 해당 작업에서 진행 |

앱 골격은 제품 기능 완료가 아니다. 계산은 Flutter에서 수행하고 서버로 옮기거나 Dart/TS에 중복 구현하지 않는다. 개인 SDK 경로·서명·키·캐시를 Git에 추가하지 않는다. 개발용 플랫폼 식별자는 `com.example.payse`이며 정식 배포 전에 실제 식별자를 확정한다.

## 팀원이 받았을 때

공통 초기화가 통합된 브랜치를 받은 뒤 저장소 루트에서 실행한다.

```sh
cd apps/mobile
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

pub get은 최초 준비 또는 lockfile 변경 시 수행한다. 팀원은 저장소에 공유된 같은 lockfile을 사용한다. IDE는 저장소 루트를 열고 `PAYSE Flutter` 실행 구성을 사용한다. 시뮬레이터/실기기 연결은 별도 준비다.

## 실제 경로와 검사

- `lib/app/`: 공통 진입점·구성. 현재 `lib/data/`의 인증·금융 Repository와 adapter를 사용하고 새 구현은 같은 경계를 따른다.
- `lib/features/{auth,connection,overview,planning,recurring,simulation,adjustment}/`: 제품 기능. 비어 있는 폴더를 미리 만들거나 기능 완료로 표시하지 않는다.
- 역할은 [ownership](../ownership.md)과 policy.json을 따른다. 기존 app/src는 이전 Node 골격으로 보존하며 신규 Expo 코드를 추가하지 않는다.
- 모바일 상세는 `apps/mobile/docs/`, 기능 상세는 담당 `<feature>/docs/`에 둔다.

저장소 루트의 `node scripts/harness/run-flutter.mjs check`는 버전 검사 후 읽기 전용 Dart 포맷, `flutter analyze --no-pub`, `flutter test --no-pub`를 실행한다. SDK 불일치는 중단하며 검사 중 의존성을 갱신하지 않는다. 포맷 수정은 작업에 허용된 변경 파일에만 한다.

기존 Node 하네스는 실제 Dart 소스도 제품 존재 판정에 포함한다. Flutter 소스 변경은 mobile 검사로 연결하고 공통 검사기 변경은 실제 구현이 있는 소비자를 검사한다. 직접 변경된 서버/패키지는 구현이 없어도 해당 검사 요구를 유지하여 누락된 명령을 숨기지 않는다. 기존 Node 구조·lint·하네스 검사는 유지한다.

`code-spec` 자동 검사는 JS/TS 대상이며 Dart 문서 주석은 작성자 검토 대상이다. Node PASS, 위젯 테스트 PASS, Android/iOS 빌드 PASS, 사용자 검증 PASS를 서로 대체하지 않는다. CI 파일을 추가한 사실은 원격 CI 실행 성공이 아니다.

공식 근거: [Flutter 앱 생성](https://docs.flutter.dev/reference/create-new-app), [Dart 잠금 파일](https://dart.dev/tools/pub/cmd/pub-get#enforce-lockfile), [Flutter 테스트](https://docs.flutter.dev/testing/overview).
