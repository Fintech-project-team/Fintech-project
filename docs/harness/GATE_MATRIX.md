# 작업별 필수 문서와 검사

작업 시작 전에 이 표를 확인한다. 아래 표에서 해당 작업에 지정한 문서와 작업 명세의 readBefore가 필수이며 docs/ 전체를 매번 읽는 것은 아니다.

| 작업 영역        | 읽을 문서                                           | 추가 검사                                                |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------- |
| 모든 작업        | mvp-scope.md, ownership.md, 이 문서, 작업 명세      | 범위·구조·Prettier·ESLint·하네스 테스트·코드 명세        |
| UI               | architecture.md, contracts.md                       | mobile check: SDK·Dart 포맷·Flutter 분석·테스트          |
| API·더미·AI·DB   | architecture.md, contracts.md                       | 해당 서버 typecheck/test                                 |
| 공통 데이터 형식 | contracts.md, architecture.md, calculation-rules.md | contracts와 이를 사용하는 모든 앱·서버 typecheck/test    |
| 금융 계산        | calculation-rules.md, contracts.md                  | finance-core·mobile typecheck/test                       |
| 하네스·설정      | development-workflow.md, toolchain.md               | 검사기 테스트; 제품 코드가 있으면 전체 제품 검사         |
| 일반 문서        | 설명하는 기능의 문서                                | 공통 검사; 제품 코드가 없으면 제품 검사는 NOT_APPLICABLE |

검사기는 변경 파일과 allowedPaths로 읽을 문서와 검사를 선택한다. 새 기능을 추가하면 실제 typecheck/test 명령을 연결한다.
CODE_SPEC.md와 EXTENSION_POINTS.md도 공통 필수 문서다. Git 작업은 COMMIT_PR_POLICY.md를 읽는다.
이미 문맥에서 확인한 문서는 바뀐 부분이나 새로 필요한 부분만 읽는다. 단순 작업에서 같은 문서를 반복해서 읽거나 무관한 상세 문서를 추가로 읽지 않는다.

## 실행 순서

저장소 루트에서 실제 작업 명세 경로로 실행한다.

1. 유효한 계획이 없으면 `node scripts/harness/verify-change.mjs --task docs/tasks/FC-001.json --plan`으로 계획을 확인한다. 실제 명세 경로를 사용하며, 계획은 검사 통과 결과가 아니다.
2. 필요한 경우 같은 명령의 --plan을 --format으로 바꿔 허용된 변경 파일만 포맷한다.
3. 최종 변경을 대상으로 --plan/--format 없이 전체 검사를 한 번 실행한다. 이미 같은 최종 변경과 환경에 대한 유효한 전체 통과 결과가 있으면 재실행하지 않는다.
4. 실패 후에는 최초 범위 안에서 수정하고 실패했거나 수정의 영향을 받는 검사만 다시 실행한다. 완료 전 필수 목록과 최신 유효 결과를 대조한다.

| 상태    | 뜻                                        | 종료 코드 |
| ------- | ----------------------------------------- | --------- |
| PASS    | 필요한 검사를 모두 실행해 통과            | 0         |
| FAIL    | 범위 위반 또는 검사 실패                  | 1         |
| BLOCKED | 명세·도구·명령·기준 커밋이 없어 검사 불가 | 2         |
| PLANNED | 계획만 확인                               | 2         |

보고서는 .harness/reports/에 저장한다. Android 기기 검증은 별도로 기록한다.
최초 범위 고정·자기검증·기록은 [AGENT_REVIEW.md](AGENT_REVIEW.md)를 따른다. 네 지표는 작성자와 리뷰어가 확인하며 현재 검사기가 자동 수집하거나 판정하지 않는다.
마지막 PASS 보고서만으로 작업 중 범위 위반·재작업·누락이 0건이었다고 판단하지 않는다. 완료 조건과 지침·참조 문서의 내용 일치는 AGENT_REVIEW.md에 따라 별도로 확인한다. 현재 하네스는 인원수·역할 배정 같은 문서의 의미를 자동 판정하지 않는다.

현재 검사기는 이전 PASS를 자동 재사용하지 않는다. 실패 후 개별 검사를 보완하면 종합 보고서의 원래 상태와 보완 결과를 함께 보고한다. 필수 검사별로 현재 변경에 유효한 근거가 있어야 하며, 과거 FAIL·BLOCKED를 PASS로 바꾸거나 필수 검사를 임의로 생략하지 않는다.

## 적용 범위

- 범위 검사는 잘못된 수정을 찾아낸다. 다른 파일의 수정을 물리적으로 차단하지는 않는다.
- 작업 명세·역할·검사기를 바꿔 통과시키지 않는다. 공통 규칙 변경은 PR에서 검토한다.
- 기본 CI는 공통 검사다. 작업별 범위 검사는 작업 명세를 지정해 실행하고 보고서를 확인한다.
- GitHub 권한과 required checks는 개발 관리자가 설정한다. CODEOWNERS는 리뷰 담당 표시다.
- 자기 PR은 스스로 승인할 수 없다. 팀의 리뷰·merge 절차로 처리하고 승인 완료를 꾸미지 않는다.
- 하네스 통과를 제품 구현 완료나 실기기 시연 완료로 보고하지 않는다.

## Flutter 작업의 추가 판정

2026-10-19 초기화 이후 mobile 검사는 `apps/mobile/package.json`의 `check`를 통해 실제 SDK 버전·Dart 포맷·Flutter 분석·위젯 테스트로 연결된다. 명령은 `scripts/harness/run-flutter.mjs`에 있다. 이전 Node의 mobile typecheck/test라는 표기는 해당 wrapper의 분석/테스트 명령으로 호환한다.

하네스는 Dart 소스도 실제 제품 소스로 인식한다. 공유 검사기 변경은 실제 소스가 존재하는 소비자까지 검사하며, 직접 변경된 서버/패키지의 검사는 빈 골격이라는 이유로 생략하지 않는다. 제품 코드를 바꾸지 않은 일반 MD 작업에는 모바일 검사를 강제하지 않는다.

최초 준비에는 앱 루트에서 `flutter pub get --enforce-lockfile`이 필요하다. SDK·명령 누락 또는 버전 불일치는 BLOCKED다. 테스트 실패는 FAIL이며, 원격 CI·Android/iOS 빌드·기기 검증은 별도 근거가 필요하다. Dart 문서 주석의 의미는 [CODE_SPEC](CODE_SPEC.md)에 따라 검토한다.

## 현재 MVP에 맞는 검사 선택

범위는 [제품 기준](../product-baseline.md)과 [계산 규칙](../calculation-rules.md)이다. 변경된 버전에 맞춰 U=B−E−(R−O), 원천 불변, 선택 계좌, 지급 연결·수동 정정, 기간·시뮬레이션, 저장 실패·버전 충돌을 실제 담당 계층에서 검사한다.

숫자는 Flutter 순수 Dart, 서버는 사용자 격리·저장 제약·멱등·LLM 계약을 검사한다. v0.7 실제 LLM과 후속 설명 보조의 우선순위를 구분한다. 준비된 더미 제공 계약은 필요하지만 별도 mock-bank 프로세스 도입을 강제하지 않는다. 문서만 적용한 작업에 앱·기기 완료를 요구하거나 완료로 보고하지 않는다. 기존 필수 검사 규칙을 완화하지 않는다.

## API Java 초기화 이후

2026-10-20부터 API typecheck는 Java 컴파일+주석 검사, API test는 JUnit+기존 Python 더미 검사에 연결한다. 주석 자동 검사 대상은 apps/api의 src/main/java·src/test/java·tools 아래 직접 작성한 Java 코드다. `node scripts/harness/run-api.mjs check`는 실행 JAR 생성까지 포함한다. JDK 21 또는 테스트용 Python 3.10+ 부재는 BLOCKED, 컴파일/테스트 실패는 FAIL이다. 기존 Node lint는 Java 검증을 대신하지 않는다.

Java 소스도 공통 변경의 실제 소비자로 인식한다. Flutter 전용 변경은 기존 mobile 선택을 유지하므로 API JDK를 요구하지 않는다. 공통 검사기 변경은 mobile과 api를 함께 검사한다. 종합 검사에서 API typecheck와 test는 각각 최대 17분이다(전체 합계 17분이 아님). 내부 Gradle은 명령당 14분, Python 더미 검사는 2분, Java/Python 버전 확인은 각각 10초로 제한하고 나머지는 프로세스 기동·종료 여유다. 단독 API check도 같은 내부 제한을 사용한다. 다른 제품 검사 제한 시간은 유지한다.

API 전용 CI는 API/계약/공통 검사기 변경에서 실행하고 기존 Flutter CI는 수정하지 않는다. 프로세스 생존·초기 차단 테스트와 실제 DB 연결/SQL 동시성/금융 API·Flutter 통합을 구분한다.
