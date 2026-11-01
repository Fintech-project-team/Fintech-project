# PAYSE v0.6 API 명세 — #20

[#20 API 명세](https://github.com/Fintech-project-team/Fintech-project/issues/20)의 연결 전후 조회·페이지·CRUD·로그인/복구·오류·동시성·멱등 규격이다. B가 Flutter fake repository를 작성하는 데 사용할 외부 계약이며 서버 기능의 구현 완료를 뜻하지 않는다.

## 문서와 적용 범위

| 문서                                                 | 내용                                              |
| ---------------------------------------------------- | ------------------------------------------------- |
| [API 계약](../../../../docs/api-contract.md)         | 18개 메서드·경로, 요청·성공·오류·버전·멱등 규칙   |
| [응답 모델](../../../../docs/api-response-models.md) | 원천 필드 참조, 연결 전후 표현, 페이지, 수정 권한 |
| [인계·검증](review-checklist.md)                     | #20 요구사항 대조, 프론트 인계, 실제 검증 범위    |

금융 필드 사전은 [데이터 모델](../../../../docs/data-model.md), 물리 저장은 [DB 사전](../../../../docs/database-schema.md), 입력·이름 규칙은 [공통 API 계약](../../../../docs/api-contract.md)이 기준이다.

인증 내부 설계는 [#21](https://github.com/Fintech-project-team/Fintech-project/issues/21), 세션·조회 구현은 [#22](https://github.com/Fintech-project-team/Fintech-project/issues/22), 설정 저장 구현은 [#23](https://github.com/Fintech-project-team/Fintech-project/issues/23)에 대응한다. 실제 Java 로그인·재확인·로그아웃 HTTP는 [인증 DB·HTTP](../auth-database.md)의 명시적 실행 조건에서 구현했다. 금융 조회·설정·탈퇴 HTTP, 기존 DB migration·파쇄 운영 적용은 완료하지 않았다. Flutter Fake 구현을 실제 HTTP 연동 완료로 해석하지 않는다.

## 기준 문서와 책임

공통 제품 범위는 [제품 기준](../../../../docs/product-baseline.md), 논리 필드·관계는 [데이터 모델](../../../../docs/data-model.md), HTTP 입력·성공/오류·인증·쓰기/멱등·탈퇴는 [API 계약](../../../../docs/api-contract.md), 부분 연결·페이지는 [응답 계약](../../../../docs/api-response-models.md), 물리 저장은 [DB 사전](../../../../docs/database-schema.md)이 각각 단일 기준이다. 이 폴더에는 [인증 내부 설계](auth-design.md)와 [인증 검증](auth-verification.md)·[인계 체크리스트](review-checklist.md)를 둔다.

상위 계약의 제안은 확정 결정 없이 구현값으로 간주하지 않는다. 인증 본문 4096바이트는 사용자 확정에 따라 [서비스 경계](../service-boundaries.md)에 반영했으며, 공통 계약의 제안 표기 정정은 담당자 인계 대상으로 남겼다. 문서 규격 존재가 실제 API 구현·기기 통합·기존 DB 이행 완료를 뜻하지 않는다. 프론트의 A 확인 표시는 담당자 간 연결 검토이며 이미 확정된 제품 정책을 다시 선택하는 절차가 아니다.

## 버전 경계와 프론트 영향

v0.6은 데모 세션·재확인·종료·탈퇴, 최초 기관 연결, 계좌 선택·별칭, 연간 원천 페이지, 급여·카드 계획, 예정 지출·모아둘 돈·명시 배정의 계약을 포함한다. 기존 월간 계획·정산 근거 읽기도 유지한다.

반복 후보 승인·분류 정정·거래에서 계획 등록은 v0.7, 미래 시뮬레이션은 v0.8, 정산 정정·돌발 사건·보호 조정은 v0.9의 후속 쓰기다. 기관 추가/해제 화면의 P1 우선순위도 유지한다. #20 명세 완료로 서버 구현·재접속 유지 완료를 선언하지 않는다.

API에 화면 번호·문구·탭 순서를 저장하지 않는다. Flutter는 Repository/mapper에서 API 표현을 화면·계산 모델로 변환한다. Java 금융 API·부분 연결·페이지·설정 저장의 구현과 검증은 [금융 API 인계](../history/2026-10-29-financial-api-handoff.md)를 따른다. Flutter의 실제 HTTP 연결과 탈퇴는 별도이며 [인계 표](review-checklist.md)의 계약 기준을 유지한다.

## 이름·연결 표현과 프론트 경계

이름 사용 범위, 세 계정의 최초 연결 전 변환, FakeRepository/API의 부분 연결 표현은 같은 공통 계약을 사용한다. 현재 화면 호칭 위치·새 연결 시나리오 파일 수를 임의 확정하지 않는다. [응답 모델](../../../../docs/api-response-models.md)에 조건/필드/예시를, [인계·검증](review-checklist.md)에 사례와 미구현 경계를 둔다. 로드맵의 v0.6 단계·서버 구현 P1, Flutter 로컬 계산, 기관 추가/해제 P1은 유지한다. 원문 references는 과거 자료로 보존한다.

작성·변경·검증 이력은 [API 문서 이력](../history/2026-10-22-api-doc-history.md)에 보존한다.
