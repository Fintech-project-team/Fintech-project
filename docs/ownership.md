# 2인 공동 PM·개발 역할

총 2명이 공동 PM 겸 개발자다. A는 데이터·더미·DB·API·LLM, B는 Flutter·UI·로컬 계산을 맡는다. A/B는 업무 표기이며 실명 또는 Git 계정 배정이 아니다. 산출물·우선순위·확인은 [팀 계획](team-plan.md)을 따른다.

공통 기준은 `docs/`, 세부 문서는 담당 앱·기능의 `docs/`에 둔다. 다른 담당자에게 영향이 있는 변경은 해당 담당자끼리 확인한다. 별도 PM 승인자를 두지 않는다.

2026-10-18 GitHub 작업에서는 A 영역을 enpl, B 영역을 hyeyeonso가 맡고 통합/QA는 공동 배정되어 있다. 현행 작업 링크와 인계 기준은 [팀 계획](team-plan.md)에 둔다. 이 조회 기록으로 기존 경로 권한·Git 보호 정책을 변경하지 않는다.

## 기존 검사기의 경로 역할

integration·data·cashflow·allocation은 사람 수가 아니라 기존 하네스의 경로 역할이다. 두 사람이 작업별로 나누어 맡는다. 한 사람이 여러 역할을 수행하면 작업별 명세와 허용 경로를 구분한다. 검사 통과를 위해 역할만 integration으로 바꾸지 않는다.

| 역할        | 담당 경로                                                                 | 확인할 다른 영역                                           |
| ----------- | ------------------------------------------------------------------------- | ---------------------------------------------------------- |
| integration | packages/, scripts/, 공통 설정, apps/mobile/app/, apps/mobile/src/shared/ | 각 기능 영역의 코드와 통합 결과                            |
| data        | apps/api/, apps/mock-bank/                                                | contracts, finance-core 입력, 앱의 API 사용 방식           |
| cashflow    | apps/mobile/src/features/connection/, recurring/, spending/               | contracts, finance-core 출력, shared, allocation 공개 함수 |
| allocation  | apps/mobile/src/features/allocation/, docs/demo/                          | contracts, finance-core, spending 결과, 계획 저장 API      |

cashflow 표의 recurring/와 spending/은 apps/mobile/src/features/ 아래 경로다. 사람 수가 줄었다는 이유로 이 기능 영역이나 검사기의 역할을 삭제하지 않는다.

## 수정 범위

- scripts/harness/policy.json은 역할별 수정 범위를 정한다. 작업 명세의 allowedPaths로 범위를 더 좁힌다.
- integration도 작업 명세에 허용된 파일만 수정한다. 관리 역할이 다른 사람의 변경을 덮을 권한을 주지는 않는다.
- 다른 담당자의 코드를 읽어 연결 방식을 확인할 수 있다. 수정·포맷·이름 변경은 허용 범위 안에서만 한다.
- package.json, lockfile, 공통 설정, 하네스, 공통 데이터 형식 변경은 integration이 조정한다.
- 최초 범위 밖 문제는 필요한 경로와 원인을 보고한다. 범위 변경이 별도로 승인되면 이유와 새 명세를 남긴다. 이미 승인된 작업을 다시 승인받지 않는다.

## 협업과 Git

작업마다 담당자·역할·허용 경로·완료 조건을 기록한다. 한 작업 폴더에는 쓰기 에이전트 하나만 두고 동시 작업은 checkout/worktree를 분리한다. 공통 계약은 영향을 받는 두 담당자가 확인한다.

기능→개인→develop→main 흐름과 기존 merge 담당은 [Git 규칙](harness/COMMIT_PR_POLICY.md)을 유지한다. 인원 변경만으로 계정 권한·브랜치·보호 규칙을 수정하거나 누가 제외됐는지 추정하지 않는다. 기존 브랜치 이름은 실제 권한 확인 자료이며 3명 운영 요구가 아니다.

## Flutter 전환

역할표는 현재 `scripts/harness/policy.json`의 이전 골격 경로다. 신규 Flutter 경로는 [전환 기준](harness/FLUTTER_TRANSITION.md)에 따라 실제 lib/test 경로·정책·검사를 초기화 작업에서 함께 맞춘다. 본 문서 적용만으로 코드 수정 허용 경로가 확장되지는 않는다.
