# 공통 데이터/API 계약 초안

상태: 타입·런타임 스키마 구현 전 논의용 v0. 최종 계약의 기준 소스는 packages/contracts가 된다. 여기의 필드/경로는 실제 구현된 API가 아니다.

## 공통 원칙

- 합성 demo 사용자와 3개월 거래를 사용한다. 실제 금융사 스펙 인증·호환을 주장하지 않는다.
- 금액: KRW 정수. 시점: ISO 8601 타임스탬프, 출금 예정일: YYYY-MM-DD + 명시적 Asia/Seoul 해석.
- 응답에 schemaVersion, snapshotId, version, asOf를 둔다. 오류에는 code, message, requestId를 둔다.
- 계좌/accountId, 거래/transactionId, 지출/obligationId, 계획/planId, 근거/evidenceTransactionIds를 구분한다.
- 거래 kind는 수입·직접 지출·카드 이용·카드 청구 결제·내부 이체를 구분한다. 상태는 pending/posted/cancelled 등을 명시한다.
- 후보 상태는 proposed/confirmed/excluded로 분리한다. UI와 서버가 같은 이름을 사용한다.
- 지출 카테고리에는 card-bill, housing, utility, subscription, loan-repayment, insurance, other를 포함하는 것을 제안한다.
- 목적별 계획은 보호 금액/소비 가능 금액과 연결 obligationId를 구분한다. 실제 계좌 잔액은 바꾸지 않는다.

## 앱용 API 제안 (개발 포트 3000)

| 메서드·경로                             | 목적                                        |
| --------------------------------------- | ------------------------------------------- |
| GET /health                             | 서비스 상태                                 |
| POST /v1/demo/snapshots                 | scenarioId로 더미 원천 수집, 새 스냅샷 생성 |
| GET /v1/snapshots/:snapshotId           | 동일 시점의 계좌·거래 조회                  |
| POST /v1/snapshots/:snapshotId/analysis | 분석 후보 생성/조회용 작업 시작             |
| PATCH /v1/obligations/:obligationId     | 후보 확인/수정/제외, expectedVersion 필요   |
| GET /v1/allocation-plans/current        | 현재 계획 조회                              |
| PUT /v1/allocation-plans/current        | 계획 저장, expectedVersion 필요             |

계산은 앱의 finance-core를 호출한다. 첫 버전에 매 입력마다 서버 계산 endpoint를 추가하지 않는다. 데모 사용자 범위도 서버에서 검사하고 사용자 ID만 믿고 다른 데이터 접근을 허용하지 않는다.

## 더미 금융 API 제안 (개발 포트 3001)

GET /health, GET /v1/scenarios, GET /v1/scenarios/:scenarioId/accounts, GET /v1/scenarios/:scenarioId/transactions, GET /v1/scenarios/:scenarioId/scheduled-payments.
fixtureId/기준일을 고정한다. 은행·카드·공과금·보험·대출·구독 데이터를 동일 snapshot 생성 규칙으로 정규화한다. 로컬 서버 간 통신만으로 시작한다.

## 저장 충돌과 오류

변경 요청은 expectedVersion을 검사하고 불일치 시 409를 반환한다. UI는 재조회·사용자 수정 재적용을 안내한다. 잘못된 입력 400, 없는 자원 404, 공급자 timeout/오류는 명시적으로 반환한다. 분석 재요청은 snapshotId+분석 버전 기준 중복 실행 정책을 정한다.

## 계약을 바꾸는 순서

요청 Issue → 공통 담당자가 스키마·예시·테스트를 함께 변경 → develop에 선행 통합 → 각 영역이 같은 계약 버전으로 구현. 임시로 다른 필드 이름을 각자 만들지 않는다. 삭제/타입 변경은 양쪽 소비자 변경을 같은 통합 단위에 담는다.
