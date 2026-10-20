# PAYSE MVP 1.0 — 현행 개발 기준

개정일: 2026-10-20. **사용자 최신 확정 사항을 우선 적용한 2인 공동 PM·개발 기준**이다. v8 이후의 직접 결정과 기존 업무표의 범위·우선순위를 함께 따른다. 앱·API·DB 구현 완료 보고가 아니다.

현재 기준은 CODEF 참고 전환, PAYSE 공통 계약, Java + Spring Boot 확정, Flutter 로컬 계산을 반영한다. 사용성 검증 축소·생략은 적용하지 않고 [미승인 변경](open-decisions.md)에 표시한다. 실제 공급자 호환·금융/인증 API·앱 통합 완료를 뜻하지 않는다.

## 읽는 순서

1. [제품·버전 기준](product-baseline.md): 확정 범위·인증·분석·비용.
2. [2인 역할·개발 순서](team-plan.md): 담당 업무, 산출물, 문서 경로·변경 조건.
3. [앱 구조](app-architecture.md): 로컬 계산·서버 저장·상태 수명.
4. [계산 기준](calculation-rules.md): 현재 금액·반복·시뮬레이션·보호·정정.
5. [데이터·API 기초 계약](data-contracts.md): 사용자 식별 권장안·데이터 경계·조회/저장.
6. [DB 최소 구조안](database-schema.md): 저장 단위·핵심 컬럼·제약과 근거.
7. [v0.6 화면 규칙](v0.6-screen-rules.md): 기존 43개 화면/상태 대응 및 변경점.
8. [남은 설계 작업](open-decisions.md): 확정 정책을 다시 묻지 않는 개발 확인 목록.
9. [충돌·정리·검증 보고](reconciliation-report.md): 이전 기준과 달라진 점·검증 범위.

## 적용 우선순위

1. 사용자 후속 직접 결정: Java + Spring Boot, 2인 공동 PM, M1~M6·비용·인증 입력 수명 등. 같은 항목에서는 최신 결정이 우선한다.
2. 후속 결정으로 대체되지 않은 [업무표·확정 사항](references/work-brief.source.md).
3. [로드맵 v8 원문](references/roadmap-v8.source.md), [상세 계획 v7 원문](references/detailed-plan-v7.source.md)의 대체되지 않은 규칙.
4. [v0.6 와이어프레임](https://claude.ai/artifact/PSWLqmLaBTTapdU6E41pGj)의 대체되지 않은 화면 규칙.

원문은 이력 증거다. 원문에 남은 네 항목 인증·서버 금액 재계산·전담 PM 표기를 현행 요구로 읽지 않는다. 충돌은 검토 보고서에서 설명하고 구현 기준에는 최신 내용을 적용한다. 권장 구현과 사용자 확정 정책을 구별한다.

## 산출물 상태

2026-10-18 문서 개정 당시 산출물은 개발 기초 MD와 검증 기록이었다. 이후 데이터·DB 작업은 [데이터 명세](../apps/api/docs/data-model-draft.md)와 [DB 설계](../apps/api/docs/database-design.md), Java 초기화의 구현·미구현 범위는 [서버 초기화 안내](../apps/api/docs/spring-bootstrap.md)를 따른다. 초기화를 금융·인증 API 완료로 표시하지 않는다.

현행 제품·개발 기준은 이 색인에서 연결한 현재 기준 문서다. [5차 핵심 기억](../PAYSE-핵심기억-05.md)과 [27개 결정 요약](../PAYSE-결정사항-27개-요약.md)은 2026-10-15~18의 기록으로 보존하며 후속 직접 결정과 현행 문서를 대체하지 않는다. 기존 저장소의 검사·Git 보호 절차는 보존한다. 노션은 계속 읽기 전용이다.
