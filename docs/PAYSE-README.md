# PAYSE MVP 1.0 — 현행 개발 기준

**사용자 최신 확정 사항을 우선 적용한 2인 공동 PM·개발 기준**이다. v8 이후의 직접 결정과 기존 업무표의 범위·우선순위를 함께 따른다. 앱·API·DB 구현 완료 보고가 아니다.

현재 기준은 CODEF 참고 전환, PAYSE 공통 계약, Java + Spring Boot 확정, Flutter 로컬 계산을 반영한다. 사용성 검증 축소·생략은 적용하지 않고 [미승인 변경](open-decisions.md)에 표시한다. 실제 공급자 호환·금융/인증 API·앱 통합 완료를 뜻하지 않는다.

## 읽는 순서

작업에 필요한 항목만 읽는다. 다음 문서가 각 주제의 단일 기준이며 공통 의미를 앱별 문서에 복제하지 않는다.

| 내용                            | 기준 문서                                                                                                       |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 제품·버전·인증 수명·비용        | [제품 기준](product-baseline.md)                                                                                |
| 2인 담당·경로·문서 작성/공유    | [팀 계획](team-plan.md), [수정 범위](ownership.md), [작성·공유](development-notes.md)                           |
| 의존성·계산 위치·상태 수명      | [앱 구조](app-architecture.md)                                                                                  |
| 현재 금액·기간·반복·보호·정정   | [계산 기준](calculation-rules.md)                                                                               |
| 외부 공급자·LLM 경계·공통 인수  | [데이터 계약 색인](data-contracts.md)                                                                           |
| 필드·타입·필수 여부·수정 권한   | [공통 데이터 모델](data-model.md)                                                                               |
| v0.6 HTTP·인증 입력·쓰기·오류   | [HTTP 계약](api-contract.md)                                                                                    |
| 연결 전/부분 연결·공개·페이지   | [응답 모델](api-response-models.md)                                                                             |
| 실제 SQL·DB 사전·이행/검증 상태 | [DB 구조](database-schema.md)                                                                                   |
| 화면 동작·디자인 값             | [화면 규칙](v0.6-screen-rules.md), [디자인](design.md)                                                          |
| 코드 작성·필수 검사·Git         | [CODE_SPEC](harness/CODE_SPEC.md), [검사 기준](harness/GATE_MATRIX.md), [Git 정책](harness/COMMIT_PR_POLICY.md) |
| 구현 대기·미승인 범위 변경      | [남은 작업](open-decisions.md)                                                                                  |
| 과거 기준과 정리 근거           | [검토 이력](reconciliation-report.md)                                                                           |

`apps/api/docs/`는 내부 인증 설계·실행 안내·검증 사례를 유지한다. 기존 데이터 모델·DB·HTTP·응답 문서 경로는 위 기준으로 안내하며 독립 규칙을 병행하지 않는다. 실제 DTO·SQL·Flutter 구현과 검사는 해당 코드/상세 문서의 상태로 확인한다.

## 적용 우선순위

1. 사용자 후속 직접 결정: Java + Spring Boot, 2인 공동 PM, M1~M6·비용·인증 입력 수명 등. 같은 항목에서는 최신 결정이 우선한다.
2. 후속 결정으로 대체되지 않은 [업무표·확정 사항](references/work-brief.source.md).
3. [로드맵 v8 원문](references/roadmap-v8.source.md), [상세 계획 v7 원문](references/detailed-plan-v7.source.md)의 대체되지 않은 규칙.
4. [v0.6 와이어프레임](https://claude.ai/artifact/PSWLqmLaBTTapdU6E41pGj)의 대체되지 않은 화면 규칙.

원문은 이력 증거다. 원문에 남은 네 항목 인증·서버 금액 재계산·전담 PM 표기를 현행 요구로 읽지 않는다. 충돌은 검토 보고서에서 설명하고 구현 기준에는 최신 내용을 적용한다. 권장 구현과 사용자 확정 정책을 구별한다.

## 산출물 상태

데이터·DB 작업은 [공통 데이터 모델](data-model.md)과 [DB 사전](database-schema.md), Java 초기화의 구현·미구현 범위는 [서버 초기화 안내](../apps/api/docs/spring-bootstrap.md)를 따른다. 초기화를 금융·인증 API 완료로 표시하지 않는다.

현행 제품·개발 기준은 이 색인에서 연결한 현재 기준 문서다. [5차 핵심 기억](../PAYSE-핵심기억-05.md)과 [27개 결정 요약](../PAYSE-결정사항-27개-요약.md)은 과거 기록이며 후속 직접 결정과 현행 문서를 대체하지 않는다. 작성·조회·검토의 시점별 근거는 [공통 문서 이력](../apps/api/docs/history/2026-10-22-common-doc-history.md)에 보존한다. 기존 저장소의 검사·Git 보호 절차는 보존한다. 노션은 계속 읽기 전용이다.
전체 이력의 위치와 읽기 기준은 [이력 색인](../apps/api/docs/history/README.md)을 따른다.
