# Flutter 팀 스킬 설치본 결정

- 날짜: 2026-10-08.
- 근거: 사용자가 추천 스킬 판단·각 설치법·설치본·짧은 팀원 안내·기존 Markdown 호환 검증을 요청했다.
- 범위: 스킬과 관련 문서·공유 설정·gitignore. 제품 코드, 하네스 정책/실행기, 의존성 잠금 파일, GitHub 계정·브랜치·권한은 변경하지 않는다.
- 팀: 개발 관리자 포함 3명, Codex 1명·Claude Code 2명. 네 역할은 사람 수가 아니며 고정 기능 담당 배정은 미확정이다.
- 결정: `flowcast-task`, `flowcast-verify`, `flowcast-dart-test`, `flowcast-widget-test`, `flowcast-integration-test`, `flowcast-flutter-ui` 6개를 프로젝트 파일로 공유한다.

## 도입 판단

공통 스킬 두 개는 기존 규칙을 연결하고 전문 스킬은 필요한 작업에서만 읽는다. 외부 원본과 이름을 구분해 Flowcast 조정본임을 표시한다. 자동 선택은 유지하며, 별도 전역 설치나 MCP는 필수로 하지 않는다. Windows에서도 Git으로 같은 내용을 받을 수 있도록 Claude와 Codex 경로에 같은 실제 파일을 배포한다. 장점은 재현성과 작은 문맥이며, 대가는 양쪽 배포본과 참고 원본 업데이트를 함께 관리해야 한다는 점이다.

Flutter 원본은 `flutter/agent-plugins@0ef3972f93e2baa4156ba1cbb1e515cd53079c68`을 검토했다. 같은 커밋의 Dart·위젯·통합 테스트 안내를 조정하고 BSD 라이선스를 보존한다. Flutter 공식 테마·접근성 문서를 참고한 UI 스킬은 Flowcast 작성본이다. 보류 후보·비교·각각의 설치법은 [FLUTTER_SKILLS.md](../harness/FLUTTER_SKILLS.md)에 있다.

## 발견한 충돌과 해결

실제 저장소에는 아직 4인 공통 지침과 Expo 초기화 안내가 남아 있고, 앞선 3인 결정 기록만 일부 존재했다. 기존 3인 정정본을 함께 반영해 부분 적용 상태를 해소한다. 과거 결정 기록의 파일 수·당시 전제·발생 사건은 당시 이력으로 남기며 현재 구성의 원본은 이 결정과 연결 문서다.

Flutter 목표와 Node 골격을 한 상태처럼 쓰면 TypeScript 직접 import, 잘못된 역할 경로, Dart 검사 누락이 발생한다. [FLUTTER_TRANSITION.md](../harness/FLUTTER_TRANSITION.md)를 기준으로 실제 미초기화 상태와 필수 선행 작업을 구분한다. 이 설치 요청을 Flutter 제품 구현·금융 정책 변경·디자인 시스템 완성으로 확대하지 않는다.

Android/iOS 폴더 전체 제외는 Flutter 플랫폼 소스를 누락시킬 수 있어 생성 출력·개인 설정 제외로 바꾼다. 기존 npm lockfile과 Flutter 앱 pubspec.lock은 서로 다른 의존성 영역이다. JSDoc 규칙도 JS/TS와 Dart를 구분하고 Dart 자동 주석 검사가 없는 점을 밝힌다.

## 파일별 이유

| 파일                                                    | 이유                                                                                                              |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `.agents/skills/flowcast-dart-test/SKILL.md`            | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.agents/skills/flowcast-flutter-ui/SKILL.md`           | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.agents/skills/flowcast-integration-test/SKILL.md`     | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.agents/skills/flowcast-task/SKILL.md`                 | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.agents/skills/flowcast-verify/SKILL.md`               | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.agents/skills/flowcast-widget-test/SKILL.md`          | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/rules/reporting.md`                            | 기존 결과 우선 보고 기준을 그대로 보존한다.                                                                       |
| `.claude/settings.json`                                 | 기존 명령 허용을 그대로 보존하며 권한을 확대하지 않는다.                                                          |
| `.claude/skills/flowcast-dart-test/SKILL.md`            | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/skills/flowcast-flutter-ui/SKILL.md`           | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/skills/flowcast-integration-test/SKILL.md`     | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/skills/flowcast-task/SKILL.md`                 | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/skills/flowcast-verify/SKILL.md`               | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.claude/skills/flowcast-widget-test/SKILL.md`          | 같은 작업 기준을 두 도구에 배포. 범위·계약·PASS 재사용을 지키고 도구 전용 인수 치환과 필수 MCP 의존성을 제거한다. |
| `.github/ISSUE_TEMPLATE/task.md`                        | 앞서 검증한 3인 정정: 담당자와 작업 역할을 구분한다.                                                              |
| `.github/PULL_REQUEST_TEMPLATE.md`                      | 기존 네 지표와 3인 정정을 유지하며 Flutter 추가 근거 누락을 안내한다.                                             |
| `.gitignore`                                            | Flutter 플랫폼 소스를 공유할 수 있게 하고 생성 캐시·개인 서명 파일만 제외한다.                                    |
| `AGENTS.md`                                             | 동일한 30줄 공통 규칙을 유지하면서 Flutter의 언어·검사·잠금 파일 기준을 연결한다.                                 |
| `CLAUDE.md`                                             | 동일한 30줄 공통 규칙을 유지하면서 Flutter의 언어·검사·잠금 파일 기준을 연결한다.                                 |
| `README.md`                                             | 3인 기준 정정을 포함하고 Flutter 상태·설치·팀원 안내로 연결한다.                                                  |
| `apps/mobile/README.md`                                 | Expo 초기화 지시를 Flutter 목표와 현재 미초기화 상태로 바꾼다.                                                    |
| `apps/mobile/app/README.md`                             | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `apps/mobile/src/features/allocation/README.md`         | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `apps/mobile/src/features/connection/README.md`         | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `apps/mobile/src/features/recurring/README.md`          | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `apps/mobile/src/features/spending/README.md`           | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `apps/mobile/src/shared/README.md`                      | 이전 앱 디렉터리의 기능 의미는 보존하고 Flutter 목표 경로와 역할 정책 전환을 연결한다.                            |
| `docs/EXTENSION_POINTS.md`                              | Expo·SecureStore·기존 앱 경로를 신규 Flutter 구현 지시로 오해하지 않게 바꾼다.                                    |
| `docs/architecture.md`                                  | Node 패키지 직접 공유 전제를 언어 독립 계약과 미완료 Dart 연결로 정정한다.                                        |
| `docs/calculation-rules.md`                             | 금액 정책 변경 없이 Dart/Node 간 정수 계약 검증을 명시한다.                                                       |
| `docs/contracts.md`                                     | 금융 필드·API는 보존하고 Flutter의 TypeScript 직접 import 오해를 제거한다.                                        |
| `docs/decisions/2026-10-08-agent-team-and-skills.md`    | 앞선 3인 정정의 이유와 재작업 1건·검사 누락 1종 이력을 그대로 보존한다.                                           |
| `docs/development-workflow.md`                          | 기존 결과 재사용 절차를 보존하며 Flutter 검사 준비를 연결한다.                                                    |
| `docs/first-tasks.md`                                   | 기능 구현 전에 Flutter 초기화·역할·검사 전제를 해결하도록 순서를 맞춘다.                                          |
| `docs/harness/AGENT_REVIEW.md`                          | 앞서 검증한 자기검증 정정: 운영 지침·완료 조건 대조와 발생 이력 보존.                                             |
| `docs/harness/CLAUDE_SETUP.md`                          | 이전 Claude 전용 2개/6파일 설명을 현재 혼합 도구·6스킬 배포 구조로 갱신한다.                                      |
| `docs/harness/CODE_SPEC.md`                             | Dart에 JSDoc 강제를 적용하지 않고 기존 설명 목적을 유지한다.                                                      |
| `docs/harness/COMMIT_PR_POLICY.md`                      | 앞서 검증한 3인 정정: 활성 개인 브랜치 3개와 기존 merge 흐름을 유지한다.                                          |
| `docs/harness/FLUTTER_SKILLS.md`                        | 추천·비교·각각의 설치 명령·선택 설치의 공통 의존성·현행 한계를 한 안내에 모은다.                                  |
| `docs/harness/FLUTTER_TRANSITION.md`                    | Expo 구조와 Flutter 목표를 구분하고 Node 검사의 Dart 누락, 역할 경로와 도구 전제를 명시한다.                      |
| `docs/harness/GATE_MATRIX.md`                           | 기존 검사 명령을 허위로 바꾸지 않고 Dart 미지원과 필수 추가 검사의 판정 기준을 명시한다.                          |
| `docs/harness/TEAM_SKILLS_QUICKSTART.md`                | 다른 두 Claude 팀원과 Codex 사용자가 할 일을 최소 단계로 구분한다.                                                |
| `docs/harness/engineering-rules.md`                     | React/Expo 전용 표현과 단일 lockfile 규칙을 Flutter와 Node 공존 기준으로 정정한다.                                |
| `docs/harness/skill-licenses/flutter-agent-plugins.txt` | 참고·조정한 Flutter 원본의 BSD 저작권과 라이선스를 보존한다.                                                      |
| `docs/mvp-scope.md`                                     | 3인·Flutter 방향을 반영하되 Android 완료 조건과 금융 범위는 보존한다.                                             |
| `docs/ownership.md`                                     | 3인과 네 역할을 유지하면서 이전 경로 표가 Flutter 권한을 이미 부여한 것으로 오해되지 않게 한다.                   |
| `docs/tasks/README.md`                                  | 앞서 검증한 정정: role과 작업 담당자를 구분한다.                                                                  |
| `docs/toolchain.md`                                     | 기존 Expo 버전 제안과 Android 전용 JDK 고정을 제거하고 Node와 Flutter의 실제 준비 상태·검사·lockfile을 구분한다.  |
| `packages/contracts/README.md`                          | 계약의 언어 독립 원본과 언어별 구현을 구분한다.                                                                   |
| `packages/finance-core/README.md`                       | 순수 계산 경계를 유지하며 Flutter 연결이 아직 구현되지 않았음을 명시한다.                                         |
| 이 결정 기록                                            | 선택·변경 근거와 검증의 한계를 유지한다.                                                                          |

## 검증 범위와 사건 기록

기존 Markdown 48개를 읽고 현재 문서와 이력·언어 독립 문서를 구분한다. 바뀐 문서의 상대 참조, 같은 30줄 루트 규칙, 양쪽 스킬 내용·구조, 개인 파일 제외, installer의 충돌 보호·재적용·선택 설치, 기존 공통 하네스, ZIP 내용을 확인한다. 실행 결과는 설치본의 검증 보고서에 남긴다.

현재 컴퓨터에는 Flutter/Dart SDK와 실제 앱이 없으므로 제품 테스트·기기 E2E·실제 두 클라이언트 세션을 통과했다고 쓰지 않는다. 설치본의 정합성 PASS와 실제 팀 적용 완료를 구분한다. 형식 검사만으로 스킬 행동이나 계약 위반 0건을 보장하지 않는다.

앞선 3인 정정 과정의 운영 계약 재작업 1건·필수 내용 검사 누락 1종은 이전 결정 기록대로 보존한다. 이번 설치본의 작성·검증 사건은 별도 작업 기록에서 구분하고, 테스트가 의도적으로 만드는 충돌·변조는 실제 팀 위반 발생으로 집계하지 않는다.
