# PAYSE

PAYSE MVP 1.0의 목표는 **파악 → 판단 → 조정**이다. 현재 제품 기준은 [문서 색인](docs/PAYSE-README.md)과 [제품 기준](docs/product-baseline.md)이다. 개발자는 2명이며 공동 PM이다.

- 서버: PAYSE 공통 계약을 만족하는 준비된 합성 금융 데이터(CODEF는 참고 자료), 사용자 설정 영속화, 세션·소유권 검증, LLM 연동.
- Flutter: 계좌 합산·사용 가능 금액·소비 집계·반복 후보 수치·시뮬레이션·조정 계산.
- 실제 본인인증·실제 금융기관 연동은 범위 밖이다. 합성 이름·전화번호는 식별 입력이며 단독 로그인 수단이 아니다.
- v0.6 모델·더미·DB·API·인증 설계를 우선한다. 최신 업무표에서 서버 구현은 P1이며 구현 전에는 저장 유지가 완료된 것으로 표시하지 않는다.

## 개발 문서

1. [2인 담당·문서 경로](docs/team-plan.md), [기존 경로 역할과 협업](docs/ownership.md)
2. [앱 구조](docs/app-architecture.md), [계산](docs/calculation-rules.md), [데이터/API](docs/data-contracts.md), [DB 구조안](docs/database-schema.md)
3. [v0.6 화면](docs/v0.6-screen-rules.md), [남은 개발 설계](docs/open-decisions.md)
4. [개발 순서](docs/first-tasks.md), [Flutter 초기화 상태](docs/harness/FLUTTER_TRANSITION.md)
5. [개발 절차](docs/development-workflow.md), [검사 기준](docs/harness/GATE_MATRIX.md), [도구](docs/toolchain.md), [Git 규칙](docs/harness/COMMIT_PR_POLICY.md)

문서 적용은 앱·서버·DB 구현 또는 마이그레이션이 아니다. 기존 Node 골격과 Flutter 실행 준비를 구별한다. 저장소 스킬의 `flowcast-` 식별자는 호출 호환을 위해 유지한다. 이전 작업 기록·원문은 이력이며 현행 제품 요구를 대체하지 않는다. 노션은 읽기 전용이다.
