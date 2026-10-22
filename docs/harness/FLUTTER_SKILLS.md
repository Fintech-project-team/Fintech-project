# PAYSE 저장소 스킬 사용

이 저장소의 `flowcast-*` 스킬 6개 중 요청에 필요한 것만 선택한다. 저장소에 맞춘 지침이므로 Flutter 공식 스킬을 그대로 설치한 것으로 표시하지 않는다. 현재 제품 범위는 [PAYSE 제품 기준](../product-baseline.md)을 따른다.

## 스킬 목록

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
- 공통 2개: 두 도구에서 같은 프로젝트 지침을 읽는다. 기록은 작업 단위로 한 번만 남긴다.

## 팀원이 사용할 때

팀원은 통합된 파일을 자기 브랜치에 동기화하고 프로젝트를 열면 된다. 별도의 npx·플러그인 설치는 이 배포 방식에 필요 없다. Claude Code/Codex 설치와 로그인, 실제 Flutter 개발에 필요한 SDK는 각자 준비한다. [짧은 팀원 가이드](TEAM_SKILLS_QUICKSTART.md)를 전달한다.

Claude 입력창 예시: `/flowcast-widget-test <실제 작업 명세 경로> 쓸 수 있는 돈 카드의 오류 상태를 검사해.` Codex에서는 같은 스킬을 선택하거나 이름을 지정한다. 자동 선택도 지원하지만 처음에는 명시 호출로 출처와 적용 규칙을 확인한다.

파일 발견과 실제 호출, 앱 초기화, 제품 테스트, E2E·디자인 시스템 완성은 각각 다르다. 현재 제품 준비 상태는 [FLUTTER_TRANSITION.md](FLUTTER_TRANSITION.md)가 기준이다.

스킬이 있다는 이유만으로 E2E 체계 구축을 요구하지 않는다. 과거 ZIP으로 현재 문서를 덮어쓰지 않으며, 팀원은 저장소의 최신 파일을 기존 Git 절차로 받아 사용한다. 최초 설치 절차와 당시 보류 목록은 [이력](../../apps/api/docs/history/2026-10-22-harness-doc-history.md)에 보존한다.
