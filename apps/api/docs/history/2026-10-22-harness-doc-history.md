# 2026-10-22 하네스 문서의 일회성 설명 분리

이 문서는 기존 문구와 도입 시점의 설치·검토 기록을 보존한다. 현재 작업의 범위나 필수 검사 지침으로 사용하지 않는다. 현행 기준은 각 출처 문서에 남겼다.

- 출처 기준 커밋: `7eae1cf8da527ec45d439de6cc5b309e95139ec5`. 문서 정리 작업본에서 복사해 대조했다.
- 출처: `docs/harness/CODE_SPEC.md`, `AGENT_REVIEW.md`, `FLUTTER_SKILLS.md`, `GATE_MATRIX.md`, `TEAM_SKILLS_QUICKSTART.md`, `MAC_FLUTTER_VSCODE_GUIDE.md`.
- 처리: 작업을 지칭하는 표현은 일반 규칙으로 중립화하고, 최초 설치법·도입 날짜·당시 보류 판단은 여기로 옮겼다. 검사 명령·대상·시간 제한·실패 판정·주석 의무는 유지한다.

## 1. CODE_SPEC — 기존 문구

출처: [`docs/harness/CODE_SPEC.md`](../../../../docs/harness/CODE_SPEC.md)

```text
이번 변경 대상의 필요한 주석만 검토하며
```

## 2. CODE_SPEC — 기존 문구

출처: [`docs/harness/CODE_SPEC.md`](../../../../docs/harness/CODE_SPEC.md)

```text
2026-10-20 사용자 요청에 따라 API 개발은
```

## 3. AGENT_REVIEW — 기존 문구

출처: [`docs/harness/AGENT_REVIEW.md`](../../../../docs/harness/AGENT_REVIEW.md)

```text
이번 수정 반복의 기준으로
```

## 4. AGENT_REVIEW — 기존 문구

출처: [`docs/harness/AGENT_REVIEW.md`](../../../../docs/harness/AGENT_REVIEW.md)

```text
이번 작업이 만든 부분만 원복하고
```

## 5. GATE_MATRIX — 기존 문구

출처: [`docs/harness/GATE_MATRIX.md`](../../../../docs/harness/GATE_MATRIX.md)

```text
2026-10-19 초기화 이후 mobile 검사는
```

## 6. GATE_MATRIX — 기존 문구

출처: [`docs/harness/GATE_MATRIX.md`](../../../../docs/harness/GATE_MATRIX.md)

```text
## API Java 초기화 이후
```

## 7. GATE_MATRIX — 기존 문구

출처: [`docs/harness/GATE_MATRIX.md`](../../../../docs/harness/GATE_MATRIX.md)

```text
2026-10-20부터 API typecheck는
```

## 8. TEAM_SKILLS_QUICKSTART — 기존 문구

출처: [`docs/harness/TEAM_SKILLS_QUICKSTART.md`](../../../../docs/harness/TEAM_SKILLS_QUICKSTART.md)

```text
담당자가 설치본을 저장소에 반영한 뒤, 팀원은 **Git으로 받은 스킬을 바로 사용**하면 됩니다. 아래는 6개 전체 설치 기준입니다.
```

## 9. TEAM_SKILLS_QUICKSTART — 기존 문구

출처: [`docs/harness/TEAM_SKILLS_QUICKSTART.md`](../../../../docs/harness/TEAM_SKILLS_QUICKSTART.md)

```text
초기화 담당자가 정한 SDK 버전을
```

## 10. TEAM_SKILLS_QUICKSTART — 기존 문구

출처: [`docs/harness/TEAM_SKILLS_QUICKSTART.md`](../../../../docs/harness/TEAM_SKILLS_QUICKSTART.md)

```text
초기화가 통합된 브랜치를 받은 뒤
```

## 11. TEAM_SKILLS_QUICKSTART — 기존 문구

출처: [`docs/harness/TEAM_SKILLS_QUICKSTART.md`](../../../../docs/harness/TEAM_SKILLS_QUICKSTART.md)

```text
현재 제품 작업은 [PAYSE 제품 기준](../product-baseline.md)에 따라 v0.6 설계·더미 준비와 로컬 계산부터 진행합니다. 실제 LLM은 v0.7 P0입니다. E2E 체계·디자인 시스템 구축은 보류하며, 최신 문서 정정을 받기 위해 기존 스킬 ZIP이나 새 플러그인을 다시 설치할 필요는 없습니다.
```

## 12. FLUTTER_SKILLS — 제목·도입 문단

출처: [`docs/harness/FLUTTER_SKILLS.md`](../../../../docs/harness/FLUTTER_SKILLS.md)

```text
# Flowcast 권장 스킬과 설치

권장 구성은 아래 6개다. 공통 작업 2개를 유지하고 테스트 3개와 UI 1개를 추가한다. 모두 이 저장소용 Flowcast 스킬이며, Flutter 공식 스킬을 그대로 설치한 것으로 표시하지 않는다. 여섯 스킬이 항상 함께 실행되는 것은 아니다. 요청에 필요한 것만 선택한다.
```

## 13. FLUTTER_SKILLS — 당시 보류 목록·비교·최초 ZIP 설치법

출처: [`docs/harness/FLUTTER_SKILLS.md`](../../../../docs/harness/FLUTTER_SKILLS.md)

````text
## 이번 기본 구성에서 보류한 것

| 후보                                      | 장점                               | 이번에 보류한 이유                                                                                        |
| ----------------------------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 공식 dart-flutter 플러그인 전체           | 스킬과 MCP를 묶어 시작하기 편함    | Flowcast에서 필요하지 않은 작업까지 추가되고, 일부 원본 절차와 팀 정책을 개별 조정해야 함                 |
| flutter-apply-architecture-best-practices | 레이어 분리와 구성 예시가 풍부     | ChangeNotifier·freezed/built_value·DI 도입 지시가 있어 미확정 팀 설계를 대신 결정할 수 있음               |
| dart-run-static-analysis                  | 분석과 자동 수정 안내              | 원본에 dart fix --apply·dart format . 절차가 있음. 분석은 필수 검사로 두고 전체 자동 수정은 채택하지 않음 |
| flutter-add-widget-preview                | 컴포넌트 상태를 빠르게 눈으로 확인 | SDK와 앱 테마가 준비된 뒤 추가. 미리보기는 위젯 테스트·기기 검증을 대체하지 않음                          |
| 커뮤니티 디자인 시스템 묶음               | 구체적인 토큰·컴포넌트·검사 제공   | 서로 다른 테마 정책과 경로·의존성을 강제할 수 있어 현재 초기화 전 구조에 그대로 적용하지 않음             |
| 네이티브 E2E 추가 도구                    | 권한창·외부 앱 같은 경계 검사      | 실제 시나리오가 정해지면 선택. 실제 E2E 작업 요청 때 검토하며 현재 시스템 구축은 보류                     |

대표 비교: [gabuldev의 디자인 시스템](https://github.com/gabuldev/flutter-skills/blob/99570628666c20503889fa8fd5608e14f31ff971/skills/flutter-design-system/SKILL.md)은 별도 패키지·정적 토큰·fromSeed 예시를 제공한다. [zakariaf의 디자인 시스템](https://github.com/zakariaf/Flutter-Skills/blob/e073e5ea10c963d2c52ab1e423bd314c28a56154/skills/design-system-structure/SKILL.md)은 정적 토큰/fromSeed를 금지하고 ThemeExtension·추가 셸 검사를 요구한다. 두 묶음을 함께 설치하는 대신 기존 토큰 재사용이라는 공통 원칙을 Flowcast에 맞춰 적용한다.

## 담당자가 설치하는 방법

아래는 **최초 Flutter skills kit의 설치법**이다. 이미 적용한 팀은 최신 저장소 파일만 받는다. 현재 제품 문서는 [PAYSE 색인](../PAYSE-README.md)을 따른다. 현행 MD 적용 배치파일은 스킬 선택 설치 명령을 제공하지 않는다. 예전 ZIP으로 현재 문서를 덮어쓰지 않는다.

배포 ZIP을 저장소 밖에 압축 해제한다. 설치 폴더의 터미널에서 아래 명령을 사용한다. Node가 필요하며 실제 팀 저장소 경로로 바꾼다. 기본 권장은 전체 설치다.

```powershell
node install.mjs --repo "C:\workspace\Fintech-project" --apply
```

macOS/Linux에서도 같은 Node 설치기를 쓰고 --repo 값만 실제 경로로 바꾼다. --apply를 생략하면 변경할 파일을 보여주기만 한다. --list는 제공 스킬 목록이다. 다운로드·전역 설치·SDK 변경·Git commit/push를 실행하지 않는다.

각각 설치하려면 다음처럼 --skill을 지정한다. **선택 설치에도 공통 문서와 flowcast-task/flowcast-verify가 포함된다.** 기존에 설치된 다른 스킬은 지우지 않는다.

| 설치할 스킬               | 설치 폴더에서 실행할 명령                                                                          |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| flowcast-task             | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-task --apply`             |
| flowcast-verify           | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-verify --apply`           |
| flowcast-dart-test        | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-dart-test --apply`        |
| flowcast-widget-test      | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-widget-test --apply`      |
| flowcast-integration-test | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-integration-test --apply` |
| flowcast-flutter-ui       | `node install.mjs --repo "C:\workspace\Fintech-project" --skill flowcast-flutter-ui --apply`       |

기존 파일이 확인한 버전과 다르면 어떤 파일도 변경하기 전에 중단한다. 최신 변경을 검토·병합한 뒤 적용해야 하며 강제 덮어쓰기 옵션은 없다. 정상 적용 시 기존 파일과 receipt.json을 `.harness/skill-install-backups/`에 보관한다. 설치본을 다시 실행해도 같은 내용은 다시 쓰지 않는다.

설치 후 담당자가 diff를 검토해 기존 기능→개인→develop 절차로 공유한다. 2인 공동 PM 기준과 Flutter 관련 문서 정정이 포함돼 있으므로 스킬 폴더만 골라 복사해 오래된 지침과 섞지 않는다. installer 자체와 배포 ZIP은 저장소에 넣을 필요가 없다.
````

## 14. FLUTTER_SKILLS — PAYSE 현행 기준 반영 후의 변경 기록

출처: [`docs/harness/FLUTTER_SKILLS.md`](../../../../docs/harness/FLUTTER_SKILLS.md)

```text
## PAYSE 현행 기준 반영 후

설치된 스킬 6개를 유지하고 현재 [제품 기준](../product-baseline.md)과 로컬 계산·서버 더미·v0.7 LLM 기준에 맞춰 관련 문구만 정정했다. E2E 스킬의 존재가 E2E 체계 구축을 지금 요구하지 않는다. 화면 용어는 MVP 문서를 따른다.

위 설치 명령은 최초 Flutter skills kit의 사용법이다. MVP 문서 정정 이후 예전 ZIP으로 덮어쓰지 않는다. 현재 팀원은 저장소의 최신 파일을 기존 Git 절차로 받아 사용하며 새 스킬·MCP·플러그인을 추가 설치할 필요가 없다.
```

## 15. Mac 안내 — 당시 단계와 기기 연결 범위

출처: [`docs/harness/MAC_FLUTTER_VSCODE_GUIDE.md`](../../../../docs/harness/MAC_FLUTTER_VSCODE_GUIDE.md). 아래는 초기 안내 당시의 문구다. 현행 설치 절차를 유지하고, 삭제된 임시 화면을 현재 화면으로 설명하지 않도록 정정했다.

```text
공통 초기화 SDK 기준은 Flutter **3.47.7 stable**, 포함된 Dart **3.13.5**입니다. SDK 변경은 [toolchain.md](../toolchain.md)와 앱 잠금 파일을 함께 검토한 뒤 반영합니다. 이미 완료한 단계는 생략합니다. 기기 연결은 보류합니다.

현재 시작 화면은 초기화 확인용입니다.
```
