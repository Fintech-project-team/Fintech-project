# Flowcast

월급생활자가 **다음 월급일까지 쓸 수 있는 돈**을 파악하도록 돕는 Flutter 프로젝트입니다. 현재 구현 기준은 [MVP 기능 정의서 v0.3을 반영한 범위](docs/mvp-scope.md)입니다.

## 이번 MVP

- 급여 통장 1개의 월급일·잔액을 직접 입력합니다.
- 모아둘 돈과 예정 지출을 추가·수정·삭제합니다.
- `급여 통장 잔액 − 모아둘 돈 − 아직 안 나간 예정 지출`을 홈과 계산 내역에 표시합니다.
- '이미 나갔어요' 처리와 '잔액 다시 입력'을 구분해 중복 차감을 막습니다.
- 가입 후 첫 월급일 전까지만 다룹니다. 소비 사용액·이번 주 금액·자동 마감·이월을 현재 완료 조건에 넣지 않습니다.

개발·테스트·시연에는 합성 데이터를 사용합니다. 계좌 자동 반영 F07과 전체 자산 F12는 Should이며 현재 Must의 선행 조건이 아닙니다. 실제 금융기관 연결·자동이체는 현재 범위 밖입니다.

## 바로 다음과 이후

MVP 다음에는 **예정 지출 입력·분류 LLM 보조**를 붙입니다. 사용자가 후보를 확인한 뒤 기존 저장·재계산 흐름으로 연결합니다. 모델이 잔액을 바꾸거나 쓸 수 있는 돈을 결정하지 않습니다.

mock-bank·자동 거래 매칭, 다계좌·별도 배분·What-if·일/주 예산·이월은 [후속 확장 기준](docs/EXTENSION_POINTS.md)에 따라 선택합니다. E2E 체계와 디자인 시스템 구축은 지금 보류합니다.

## 개발 상태와 기준 문서

현재 저장소는 공통 개발 도구와 문서·스킬을 준비한 초기 골격입니다. Flutter pubspec·실제 앱·API·계산 구현은 아직 없습니다. 문서 정정이 제품 구현이나 검증 완료를 뜻하지 않습니다.

- [첫 작업 순서](docs/first-tasks.md)
- [구조](docs/architecture.md) · [데이터 계약](docs/contracts.md) · [계산·상태 변경](docs/calculation-rules.md)
- [Flutter 준비 상태](docs/harness/FLUTTER_TRANSITION.md) · [작업별 검사](docs/harness/GATE_MATRIX.md)
- [최신 MVP 반영 이유](docs/decisions/2026-10-08-mvp-v03-alignment.md)

## 팀과 협업

개발 관리자 포함 3명의 기여자가 참여합니다. integration·data·cashflow·allocation은 네 작업 역할이며 사람 수나 네 개의 필수 제품을 뜻하지 않습니다. 관리자는 개발·통합을 맡는 기여자입니다. [담당 배정](docs/ownership.md)을 따릅니다.

변경은 기능 브랜치→개인 브랜치→develop→main 순서로 공유합니다. 기능→개인은 squash, 개인→develop과 develop→main은 개발 관리자 enpl이 merge commit으로 통합합니다. 사용자가 승인한 Git 작업만 실행합니다.

- [커밋·PR 규칙](docs/harness/COMMIT_PR_POLICY.md) · [개발 절차](docs/development-workflow.md)
- [작업 명세](docs/tasks/README.md) · [PR 양식](.github/PULL_REQUEST_TEMPLATE.md)
- [공유 설정](docs/harness/CLAUDE_SETUP.md) · [스킬 구성](docs/harness/FLUTTER_SKILLS.md) · [팀원 시작](docs/harness/TEAM_SKILLS_QUICKSTART.md)
