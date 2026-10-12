# Flowcast 권장 스킬과 설치

권장 구성은 아래 6개다. 공통 작업 2개를 유지하고 테스트 3개와 UI 1개를 추가한다. 모두 이 저장소용 Flowcast 스킬이며, Flutter 공식 스킬을 그대로 설치한 것으로 표시하지 않는다. 여섯 스킬이 항상 함께 실행되는 것은 아니다. 요청에 필요한 것만 선택한다.

## 선정 결과

| 스킬                      | 역할·필요한 이유                            | 기대 효과                                       | 없을 때 생길 수 있는 차이                              |
| ------------------------- | ------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------ |
| flowcast-task             | 목적·최초 범위·계약·검사·기록 연결          | 작업마다 같은 경계를 유지하고 중복 절차 감소    | 같은 규칙을 사람이 요청마다 설명해야 함                |
| flowcast-verify           | 필수 검사·기존 PASS·완료 조건 대조          | 누락과 과장된 완료 판단 감소                    | 형식 PASS를 제품 완료로 오해하기 쉬움                  |
| flowcast-dart-test        | Dart 로직·계약·금융 경계 검증               | 중복 차감·날짜·원본 변경 회귀를 구체적으로 발견 | UI에서 잘 보이지 않는 계산 오류를 놓치기 쉬움          |
| flowcast-widget-test      | 위젯 표시·입력·상태·접근성 검증             | 변경 화면의 오류를 빠른 테스트로 확인           | 기기 수동 확인에 더 많이 의존                          |
| flowcast-integration-test | 실제 앱 흐름과 서버 경계 확인               | 각 부품이 함께 동작하는지 증거 확보             | 단위/위젯 PASS 이후 통신·저장 연결 오류가 남을 수 있음 |
| flowcast-flutter-ui       | 승인된 토큰·공통 요소·금융 상태 표현 재사용 | 화면 일관성과 재사용 개선                       | 에이전트마다 스타일·상태 표현을 새로 만들 수 있음      |

효과는 도입 기대값이다. 결함 감소율·계약 위반 0건·팀 행동의 동일성을 측정했다고 주장하지 않는다. 스킬은 지침이며 범위·계약·검사의 실제 판정은 명세·검사기·리뷰가 맡는다.

## 출처와 조정

Flutter 공식 [agent-plugins](https://github.com/flutter/agent-plugins/tree/0ef3972f93e2baa4156ba1cbb1e515cd53079c68)는 2026-10-08 확인한 커밋 `0ef3972f93e2baa4156ba1cbb1e515cd53079c68`에 고정해 검토했다. Dart 단위 테스트 스킬도 이 저장소에 포함돼 있어 별도 Dart 묶음을 중복 설치하지 않는다. 참고·조정한 원본의 [BSD 라이선스](skill-licenses/flutter-agent-plugins.txt)를 포함한다.

- Dart·위젯 테스트: 공식 패턴과 실행기를 사용하되 원본의 실패 수정 반복에 최초 범위·계약 보존·중단 조건·PASS 재사용을 연결했다. 테스트를 위해 의존성이나 제품 구현을 무단 변경하지 않는다.
- 통합 테스트: [공식 integration_test 실행](https://docs.flutter.dev/testing/integration-tests)을 기본으로 한다. 원본 스킬의 필수 MCP 탐색·Driver 확장 주입 절차는 제외했다. 가짜 API 테스트와 실제 서버 E2E를 구분한다.
- UI: [Flutter 테마](https://docs.flutter.dev/cookbook/design/themes)·[ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html)·[접근성](https://docs.flutter.dev/ui/accessibility)을 바탕으로 새로 작성했다. 특정 색상·폰트·상태 관리 라이브러리는 지정하지 않는다.
- 공통 2개: 기존 Flowcast 지침을 두 도구에서 동일하게 읽도록 조정했다. 기록은 기존 작업 단위로 한 번만 남긴다.

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

아래는 **최초 Flutter skills kit의 설치법**이다. 이미 적용한 팀은 최신 저장소 파일만 받는다. MVP v0.3 정정은 별도 MVP 문서 kit의 README를 따르며, 그 설치기는 `--skill`·`--list`를 제공하지 않는다. 예전 ZIP으로 현재 문서를 덮어쓰지 않는다.

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

설치 후 담당자가 diff를 검토해 기존 기능→개인→develop 절차로 공유한다. 3인 정정본과 Flutter 관련 문서 정정이 포함돼 있으므로 스킬 폴더만 골라 복사해 오래된 지침과 섞지 않는다. installer 자체와 배포 ZIP은 저장소에 넣을 필요가 없다.

## 팀원이 사용할 때

팀원은 통합된 파일을 자기 브랜치에 동기화하고 프로젝트를 열면 된다. 별도의 npx·플러그인 설치는 이 배포 방식에 필요 없다. Claude Code/Codex 설치와 로그인, 실제 Flutter 개발에 필요한 SDK는 각자 준비한다. [짧은 팀원 가이드](TEAM_SKILLS_QUICKSTART.md)를 전달한다.

Claude 입력창 예시: `/flowcast-widget-test <실제 작업 명세 경로> 쓸 수 있는 돈 카드의 오류 상태를 검사해.` Codex에서는 같은 스킬을 선택하거나 이름을 지정한다. 자동 선택도 지원하지만 처음에는 명시 호출로 출처와 적용 규칙을 확인한다.

파일 발견과 실제 호출, 앱 초기화, 제품 테스트, E2E·디자인 시스템 완성은 각각 다르다. 현재 제품 준비 상태는 [FLUTTER_TRANSITION.md](FLUTTER_TRANSITION.md)가 기준이다.

## MVP v0.3 반영 후

설치된 스킬 6개를 유지하고 현재 [수동 MVP](../mvp-scope.md)와 두 잔액 동작·직후 LLM 기준에 맞춰 관련 문구만 정정했다. E2E 스킬의 존재가 E2E 체계 구축을 지금 요구하지 않는다. 화면 용어는 MVP 문서를 따른다.

위 설치 명령은 최초 Flutter skills kit의 사용법이다. MVP 문서 정정 이후 예전 ZIP으로 덮어쓰지 않는다. 현재 팀원은 저장소의 최신 파일을 기존 Git 절차로 받아 사용하며 새 스킬·MCP·플러그인을 추가 설치할 필요가 없다.
