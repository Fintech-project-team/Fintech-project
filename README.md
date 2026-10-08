# Fintech-Project

합성 금융 데이터를 활용해 예정 지출을 분석하고, 다음 월급일까지의 현금흐름과 구매 영향을 확인하는 팀 프로젝트입니다.

## 해결하려는 문제

“지금 이 돈을 써도 다음 월급일까지 괜찮을까?”

현재 잔액만으로는 카드대금, 공과금, 보험료, 대출 상환액 등 앞으로 필요한 돈을 파악하기 어렵습니다. 이 프로젝트는 예정 지출과 생활비를 반영해 추가 소비 가능 예상액을 보여주는 것을 목표로 합니다.

## 개발 범위

- 금융 마이데이터·오픈뱅킹 규격을 참고한 모의 API
- 계좌·카드·대출·보험·통신 데이터 수집 및 정리
- 구독료·공과금 등 반복 지출 탐지
- 날짜별 예상 잔액과 부족 구간 분석
- 구매 전후 현금흐름 비교
- 계산 근거와 예측·미확인 항목 표시

## 데이터와 서비스 범위

- 실제 개인 금융정보 대신 합성 데이터를 사용합니다.
- 실제 금융기관 연결과 자동이체는 구현 범위에 포함하지 않습니다.
- 예측 결과는 입력 데이터와 설정한 가정에 따른 시뮬레이션입니다.

## 팀 구성

개발 관리자 1명을 포함해 총 3명의 기여자(contributors)가 개발합니다.
개발 관리자는 공통 코드·개발 환경·리뷰·통합을 맡는 기여자이며 프로젝트 소유자를 뜻하지 않습니다.
관리자는 integration을 조정합니다. integration·data·cashflow·allocation은 사람 수가 아닌 작업 역할이며 3명이 나누어 맡거나 겸임합니다. 활성 개인 브랜치와 작업별 담당 배정 기준은 [역할 문서](docs/ownership.md)를 따릅니다.

## 협업 방식

변경은 `기능 브랜치 → 본인 전용 브랜치 → develop → main` 순서로 Pull Request를 통해 반영합니다.

1. 본인 전용 브랜치(`이름-dev`)에 develop 변경을 먼저 반영하고, 그 위에서 기능 브랜치를 만들어 개발합니다.
2. 기능 브랜치 → 본인 전용 브랜치 PR은 Squash and merge로 합칩니다.
3. 본인 전용 브랜치 → develop PR은 리뷰와 검증을 거쳐 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 Create a merge commit으로 합칩니다.
4. develop → main 릴리스도 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 Create a merge commit으로 합칩니다.

- 커밋 첫 줄과 PR 제목은 `type(scope): 한국어 설명` 형식을 따르며 PR에서 자동 검사합니다.
- 데이터 형식과 금융 계산 규칙은 공통 문서로 관리합니다.

규칙 문서:

- [커밋·PR·merge 규칙과 빠른 안내](docs/harness/COMMIT_PR_POLICY.md)
- [개발 시작과 통합 절차](docs/development-workflow.md)
- [역할별 담당 범위](docs/ownership.md)
- [작업 명세 작성법](docs/tasks/README.md)
- [Claude Code·Codex 공유 설정과 스킬](docs/harness/CLAUDE_SETUP.md)
- [3인 운영·문서 정합성 수정 이유](docs/decisions/2026-10-08-agent-team-and-skills.md)
- [PR 템플릿](.github/PULL_REQUEST_TEMPLATE.md)

## 프로젝트 상태

기획 및 개발 환경 구성 단계입니다.

기술 스택, 실행 방법, API 명세와 팀원별 역할은 개발 진행에 맞춰 추가합니다.

## Flutter와 팀 스킬

모바일 목표 기술은 Flutter/Dart입니다. 현재 저장소는 초기화 전 골격이며 기존 Node 서버·하네스와 함께 전환 준비 중입니다. 앱·검사·디자인 시스템 구축 완료 상태는 [전환 기준](docs/harness/FLUTTER_TRANSITION.md)을 확인합니다.

- [스킬 선정과 설치](docs/harness/FLUTTER_SKILLS.md)
- [팀원용 빠른 시작](docs/harness/TEAM_SKILLS_QUICKSTART.md)
