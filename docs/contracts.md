# 공통 데이터와 API 초안

상태: 구현 전 논의용 v0. 공통 JSON 계약과 예시는 packages/contracts에서 관리하고 언어별 타입·입력 검증 연결은 [전환 기준](harness/FLUTTER_TRANSITION.md)에 따라 정한다. TypeScript 타입을 Flutter에서 직접 사용하지 않는다. 아래 API는 아직 구현되지 않았다.

## 공통 형식

- 합성 데모 사용자와 과거 3개월 거래를 사용한다. 실제 금융사 API 인증·호환을 보장하지 않는다.
- 금액은 KRW 정수, 시점은 ISO 8601, 출금 예정일은 YYYY-MM-DD로 쓰고 Asia/Seoul 기준임을 명시한다.
- 응답에 schemaVersion, snapshotId, version, asOf를 둔다. 오류는 code, message, requestId로 표현한다.
- accountId, transactionId, obligationId, planId, evidenceTransactionIds를 구분한다.
- 거래 kind는 수입·직접 지출·카드 이용·카드 청구 결제·내부 이체를 구분한다. 상태는 pending/posted/cancelled 등으로 명시한다.
- 후보 상태는 proposed/confirmed/excluded이며 앱과 서버가 같은 이름을 쓴다.
- 지출 분류 제안: card-bill, housing, utility, subscription, loan-repayment, insurance, other.
- 목적별 계획은 보호 금액·소비 가능 금액·연결 obligationId를 구분한다. 실제 계좌 잔액은 바꾸지 않는다.

## 앱 API 제안: 포트 3000

| 요청                                    | 목적                                      |
| --------------------------------------- | ----------------------------------------- |
| GET /health                             | 상태 확인                                 |
| POST /v1/demo/snapshots                 | scenarioId로 더미 원천을 모아 스냅샷 생성 |
| GET /v1/snapshots/:snapshotId           | 같은 시점의 계좌·거래 조회                |
| POST /v1/snapshots/:snapshotId/analysis | 분석 후보 생성·조회 작업 시작             |
| PATCH /v1/obligations/:obligationId     | 후보 확인·수정·제외, expectedVersion 필요 |
| GET /v1/allocation-plans/current        | 현재 계획 조회                            |
| PUT /v1/allocation-plans/current        | 계획 저장, expectedVersion 필요           |

앱 측 공통 순수 계산 원칙을 유지한다. finance-core의 Dart 연결·패키지 형태는 초기화 작업에서 정하고, 프레임워크 전환만으로 서버 계산 API나 중복 계산 구현을 추가하지 않는다.
데모 사용자도 접근 범위를 서버에서 검사한다. 요청에 담긴 사용자 ID만 믿고 다른 사용자의 데이터를 허용하지 않는다.

## 더미 API 제안: 포트 3001

- GET /health
- GET /v1/scenarios
- GET /v1/scenarios/:scenarioId/accounts
- GET /v1/scenarios/:scenarioId/transactions
- GET /v1/scenarios/:scenarioId/scheduled-payments

fixtureId와 기준일을 고정한다. 은행·카드·공과금·보험·대출·구독을 같은 스냅샷 생성 규칙으로 변환한다. 처음에는 로컬 서버끼리 통신한다.

## 충돌·오류·변경

- expectedVersion 불일치는 409를 반환한다. 앱은 다시 조회하고 사용자 변경을 재적용하도록 안내한다.
- 잘못된 입력은 400, 없는 데이터는 404다. 제공자 오류·시간 초과도 구분해 반환한다.
- 분석 중복 실행은 snapshotId와 분석 버전을 기준으로 처리 방법을 정한다.
- 변경 순서: Issue→integration이 스키마·예시·테스트 수정→develop 통합→각 담당자가 같은 형식으로 구현.
- 필드 이름을 각자 만들지 않는다. 필드 삭제·타입 변경은 사용하는 앱·서버의 수정과 함께 통합한다.
