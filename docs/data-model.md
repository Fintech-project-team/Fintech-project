# PAYSE 공통 데이터 모델

v1.0 논리 필드·타입·관계·수정 권한의 단일 기준이다. [#17 데이터 명세서](https://github.com/Fintech-project-team/Fintech-project/issues/17)에 대응한다. 이 문서의 모델을 API와 Flutter가 함께 사용한다. 실제 HTTP 생략/페이지 규칙은 [응답 계약](api-response-models.md), 요청·오류·인증은 [API 계약](api-contract.md), 물리 저장은 [DB 사전](database-schema.md)을 따른다.

PAYSE-DRAFT-2 원본 fixture와 초기 SQL은 존재하지만 HTTP 응답·인증 기능·이름 통합 이행이 구현됐다는 뜻은 아니다. JSON Schema/OpenAPI 완성본을 대신하지 않는다. 공동 변경은 [문서 공유 기준](development-notes.md)에 따라 영향받는 담당자가 확인한다.

## 1. 읽는 방법과 공통 규칙

- `필수`는 키와 값 모두 필요, `null`은 키는 필요하지만 미상/해당 없음에 null 허용, `조건`은 적힌 조건에서 필수다. PATCH의 키 생략은 변경 없음이며 null 초기화는 허용된 필드에만 쓴다.
- `원천`은 버전 있는 합성 자료로 일반 사용자 수정 불가, `사용자`는 인증된 설정 저장, `서버`는 식별·버전·검증 메타데이터, `로컬`은 Dart 계산/현재 흐름 메모리다. 서버의 저장 제약 검증은 금융 금액 계산의 서버 이전을 뜻하지 않는다.

| 공통 타입             | 정의                                                                                                                         |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| ID                    | UUID 문자열. HTTP 출력은 소문자. 물리 DB 타입은 uuid                                                                         |
| Version               | 1~9223372036854775807의 10진 정수 문자열, 선행 0 없음. dataVersion/expectedDataVersion에 사용하며 DB bigint와 구분           |
| 문자열                | JSON string. DB text 등의 물리 타입과 구분                                                                                   |
| Money / PositiveMoney | JSON 원화 정수 0~9,000,000,000,000 / 1~9,000,000,000,000. DB bigint. 숫자 문자열·소수·boolean은 금액이 아님                  |
| 부호 있는 금액        | 잔액·로컬 파생값(순소비·차이·예상 잔액)은 ±9,000,000,000,000 범위. 중간 합계에도 같은 상한 적용                              |
| Date / Time           | 유효 YYYY-MM-DD / 오프셋 포함 확인 시각. 업무 날짜는 Asia/Seoul. 날짜만 확인했으면 시각은 null이며 임의 자정을 생성하지 않음 |

원천 거래 크기·사용자 설정은 Money, 배정·정산액은 PositiveMoney다. 각 필드의 null·생략 조건은 아래 표와 HTTP 응답 계약을 따른다.

- 정상 객체는 아래 필드를 충족해야 한다. 조회 실패를 잔액 0인 정상 계좌로 만들지 않는다. 실패·누락은 §2의 조회 범위에 기록한다.
- 모든 사용자 소유 객체에는 `userId: ID`가 필수다. API는 묶음에서 한 번 제공할 수 있다. 서버는 요청 userId가 아니라 인증 세션으로 소유자를 정한다.
- 원천 객체는 `sourceRef: 문자열`, `sourceVersion: 문자열`이 필수다. 원천 키는 공급자·기관·객체 종류·원천 식별 기준을 포함한 이름 공간에서 유일하게 만들고 같은 객체는 버전이 바뀌어도 내부 ID를 유지한다. 같은 사건의 승인/매입 등 조회 경로별 별칭은 매핑으로 묶는다. 조회 경로만 달라졌다는 이유로 새 소비 ID를 만들지 않으며, 금액·날짜만으로 ID를 생성하지 않는다.
- 저장 대응은 논리 값과 물리 저장의 관계를 설명한다. 실제 컬럼·null·FK·인덱스는 [DB 사전](database-schema.md)이 단일 기준이다. 원천 JSON+manifest의 준비 자료와 사용자 설정 참조를 검증하며, 이 표의 각 JSON 필드를 독립 DB 컬럼으로 복제하지 않는다.

## 2. 조회 묶음·기관 연결

| 객체/필드                                                                               | 타입                                | 필수 여부   | 수정 권한·의미                                                      | 저장 대응                             |
| --------------------------------------------------------------------------------------- | ----------------------------------- | ----------- | ------------------------------------------------------------------- | ------------------------------------- |
| Snapshot.userId                                                                         | ID                                  | 필수        | 서버: 인증 사용자                                                   | demo_users.id                         |
| schemaVersion / currency                                                                | 문자열 / KRW                        | 필수        | PAYSE 전달 형식 버전/통화. dataVersion·ruleVersion과 별개           | 계약 배포·manifest                    |
| dataVersion                                                                             | 10진 정수 문자열                    | 필수        | 서버: 원천·연결·확정 설정 변경 버전. 전달 시 정수 정밀도 손실 방지  | demo_users.data_version bigint        |
| sourceVersion / ruleVersion                                                             | 문자열 각각                         | 필수        | 준비 자료/로컬 계산 규칙 버전. 서로 대체 불가                       | manifest / 배포 규칙                  |
| asOf                                                                                    | 시각                                | 필수        | 합성 자료의 계산 기준. 수집 시각으로 대체 금지                      | manifest                              |
| coverage                                                                                | Coverage[]                          | 필수        | 조회 대상별 실제 확보 상태. 빈 결과와 누락 구분                     | manifest·조회 구성                    |
| accounts/cards/transactions/statements                                                  | 각 객체 배열                        | 조건        | 허용된 연결 자료만. 분할 거래는 페이지 참조와 coverage 필요         | 원천 저장·조회                        |
| settings/obligations/reserves/allocations/settlements/recurringPlans/recurringDecisions | 해당 객체 또는 배열                 | 조건        | 연결 범위와 화면 권한에 맞는 확정 설정. 인증 비밀 제외              | 각 설정 저장                          |
| Coverage.targetKind / targetId                                                          | account/card / ID                   | 필수        | 서버: 조회 대상. 다른 사용자 자료 참조 금지                         | manifest·조회 구성                    |
| requestedStart / requestedEnd                                                           | 날짜 각각                           | 필수        | 요청 업무일 범위. 양 끝 포함으로 표현하고 분석 경계는 §8 적용       | 조회 조건                             |
| status                                                                                  | complete/partial/failed/unconnected | 필수        | 서버: 완전·부분·실패·미연결                                         | manifest·조회 결과                    |
| coveredRanges / missingRanges                                                           | 날짜 구간 배열 각각                 | 필수        | 각 구간 start/end 포함. complete는 전체 확보·누락 없음              | manifest·조회 결과                    |
| page.nextCursor                                                                         | 문자열                              | null        | 서버: 후속 페이지. null만으로 전체 자료 완전성 판정 금지            | 응답 전용                             |
| page.dataVersion / sourceVersion                                                        | 위 버전 타입 각각                   | 필수        | 같은 버전 페이지끼리만 합침. 버전 변경 시 다시 조회                 | 응답 전용                             |
| Institution.code / kind / name                                                          | 문자열 / bank·card / 문자열         | 필수        | 서버: PAYSE 내부 기관 목록. 외부 API 공식 코드라고 표시하지 않음    | 설정 목록                             |
| Institution.accountCount / cardCount                                                    | 비음수 정수 각각                    | 조건        | 연결 전 허용된 개수 메타데이터. 확인된 값만 제공                    | manifest                              |
| InstitutionLink.linkId / institutionCode                                                | ID / 문자열                         | 필수        | 서버: 사용자와 기관의 현재 연결은 최대 1개                          | institution_links.id/institution_code |
| InstitutionLink.consentedAt / disconnectedAt                                            | 시각 / 시각                         | 필수 / null | 사용자 확정 연결·해제의 서버 기록. 미연결은 연결 행 없음으로도 표현 | consented_at/disconnected_at          |

같은 Snapshot의 잔액 asOf/sourceVersion이 맞지 않으면 전체 합계를 완전한 결과로 표시하지 않는다. 거래 페이지는 `(userId, dataVersion, sourceVersion, 조회 조건)`에 묶고 중복 transactionId를 재집계하지 않는다.

기관 목록은 은행 국민·신한·하나·기업·카카오뱅크, 카드 현대·삼성·우리·국민이다. 현재 더미의 내부 코드 문자열은 [더미 구성](../apps/api/fixtures/docs/dummy-data.md)과 generated/catalog.json을 따른다. 공급자 공식 코드로 해석하지 않는다. 연결 전에는 기관 목록·종류·확인된 개수·연결 상태·버전만 노출한다. 연결과 홈 계산 계좌 선택은 별개다.

## 3. 계좌·카드·거래·청구

Snapshot의 `institutions: Institution[]`, `institutionLinks: InstitutionLink[]`는 필수다. 미연결이면 links는 []이며 기관별 연결 상태는 이 관계에서 구성한다. 정상 금융 묶음의 settings는 `salary: Salary`와 `cardPlans: CardPlan[]`을, 나머지 배열은 각 절의 동명 객체를 담는다. 연결 전에는 금융 묶음 키를 생략하고 coverage는 []로 전달한다. 계좌 ID가 포함된 미연결 Coverage로 연결 전 금융 목록을 노출하지 않는다. 연결 후에도 실패/미조회와 정상 빈 배열을 구분한다.

| 객체/필드                                      | 타입                                                      | 필수 여부   | 수정 권한·의미                                                                                                                                             | 저장 대응                                   |
| ---------------------------------------------- | --------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Account.accountId / institutionCode            | ID / 문자열                                               | 필수        | 원천: 계좌와 기관                                                                                                                                          | financial_accounts.id/institution_code      |
| productType                                    | demand/savings/time_deposit/other                         | 필수        | 원천: 입출금/적금/예금/기타. 급여 수령 여부는 별도 사용자 설정                                                                                             | product_type                                |
| productName / maskedNumber                     | 문자열 각각                                               | 필수        | 원천: 상품 표시명/가린 번호. 전체 번호를 화면 요구로 추가하지 않음                                                                                         | 원천 JSON / masked_number                   |
| balanceKRW / asOf                              | 금액 / 시각                                               | 필수        | 원천: 이미 반영된 입출금을 포함한 잔액                                                                                                                     | balance_krw/as_of                           |
| included / nickname                            | boolean / 문자열                                          | 필수 / null | 사용자: 홈 합산 선택/별칭. nickname null은 별칭 해제                                                                                                       | included/nickname                           |
| Card.cardId / institutionCode                  | ID / 문자열                                               | 필수        | 원천: 카드와 카드사                                                                                                                                        | financial_cards.id/institution_code         |
| productName / maskedNumber                     | 문자열 각각                                               | null        | 원천: 확보된 표시 정보만                                                                                                                                   | 원천 JSON 또는 조회 컬럼                    |
| cardType                                       | credit/debit/unknown                                      | 필수        | 원천: 미확인 카드 유형을 신용으로 가정하지 않음                                                                                                            | 원천 JSON                                   |
| withdrawalAccountId                            | ID → Account                                              | null        | 원천: 실제 출금 계좌, 화면에서 사용자 수정 불가                                                                                                            | withdrawal_account_id                       |
| scheduleEvidence                               | CardSchedule[]                                            | 필수        | 원천: 확인된 일정만. []는 일정 미확보                                                                                                                      | schedule_evidence                           |
| CardSchedule.periodStart / periodEnd / dueDate | 날짜 각각                                                 | null        | 이용기간은 양 끝 함께 제공하고 포함 범위로 해석. 결제일만 확인되면 기간은 null. 모두 null인 빈 일정은 제외                                                 | schedule_evidence 내부                      |
| CardSchedule.evidenceRef                       | 문자열                                                    | 필수        | 일정 근거 식별. 더미는 준비한 일정 규칙/자료 참조                                                                                                          | schedule_evidence 내부                      |
| Transaction.transactionId                      | ID                                                        | 필수        | 원천 거래의 안정된 내부 ID                                                                                                                                 | financial_transactions.id                   |
| accountId / cardId                             | ID → Account / Card                                       | null 각각   | 적어도 하나 필수. 같은 사용자만 참조                                                                                                                       | account_id/card_id                          |
| recordKind                                     | account_entry/card_purchase/card_refund/card_cancellation | 필수        | 원천: 계좌 내역/카드 구매/환불/취소. 취소를 새 현금 출금으로 해석 금지                                                                                     | 원천 JSON 또는 정규화 컬럼                  |
| amountKRW / direction                          | 금액 / in·out                                             | 필수        | 원천: 비음수 크기. 계좌 내역은 현금 유입/유출, 카드 내역은 환급/사용 방향이며 계좌 출금 명령 아님                                                          | amount_krw/direction                        |
| status                                         | approved/posted/cancelled/unknown                         | 필수        | 원천: 확인 단계. posted 카드 기록도 은행 출금 완료 증거가 아님                                                                                             | status                                      |
| merchantName / description                     | 문자열 각각                                               | null        | 원천 표시값, 사용자 수정 불가                                                                                                                              | 원천 JSON 또는 조회 컬럼                    |
| purchaseDate / withdrawalDate / refundDate     | 날짜 각각                                                 | null        | 원천: 이용일/실제 출금일/환불 반영일. 서로 복제해 채우지 않음                                                                                              | 대응 date 컬럼                              |
| occurredAt                                     | 시각                                                      | null        | 이 기록 자체의 확인 시각. 다른 종류 날짜의 시각으로 재사용 금지                                                                                            | occurred_at                                 |
| bookingDate                                    | 날짜                                                      | null        | 원천 계좌 입출금의 기장 업무일. 입금에도 사용하며 withdrawalDate를 입금일로 전용하지 않음                                                                  | 원천 JSON 또는 booking_date                 |
| occurredAtBasis                                | purchase/booking/withdrawal/refund/cancellation           | 조건        | occurredAt이 있으면 필수, 없으면 null. 어느 사실의 시각인지 보존                                                                                           | 원천 JSON 또는 정규화 컬럼                  |
| balanceReflected                               | boolean                                                   | null        | accountId의 같은 sourceVersion·잔액 asOf에 반영됐는지. false도 미반영 근거가 필요                                                                          | reflection_reason에서 응답 시 파생          |
| reflectionReason                               | reflected/not_reflected/not_applicable/unknown            | 필수        | true↔reflected, false↔not_reflected, null↔나머지. 이 두 값은 한 원천 반영 상태에서 함께 파생하여 독립 수정 금지. 카드 승인만으로 계좌 반영을 주장하지 않음 | 원천 JSON 또는 정규화 컬럼                  |
| originalTransactionId                          | ID → Transaction                                          | null        | 근거가 있는 취소·환불의 원거래. 같은 사용자, 자기 자신·순환 참조 금지                                                                                      | original_transaction_id                     |
| payseTransactionType                           | expense/income/internal_transfer/card_payment             | null        | 사용자 정정 가능. 미분류는 null이며 원천 recordKind/status는 불변                                                                                          | payse_transaction_type                      |
| installmentCurrent / installmentTotal          | 양수 정수 각각                                            | null        | 확인된 원문 할부 회차/전체 회차. 둘 다 있을 때 current≤total                                                                                               | 원천 JSON                                   |
| Statement.statementId / cardId                 | ID / ID → Card                                            | 필수        | 원천: 카드별 청구. 검증되지 않은 다중 카드 통합 청구 지원 선언 금지                                                                                        | card_statements.id/card_id                  |
| amountKRW / dueDate                            | 금액 / 날짜                                               | 필수 / null | 원천 청구 금액/확인된 결제 예정일. 사용자 계획과 분리                                                                                                      | amount_krw/due_date                         |
| includedTransactionRefs                        | ID → Transaction 배열                                     | 필수        | 확보한 같은 사용자·카드의 포함 사용 내역. 참조 객체가 다른 페이지에 있어도 ID는 안정 유지                                                                  | statement_items.transaction_id(청구별 관계) |
| detailCompleteness                             | complete/partial/unavailable                              | 필수        | 청구 상세 확보 정도. []와 별개                                                                                                                             | 원천 JSON·manifest 또는 컬럼                |
| Statement.periodStart / periodEnd              | 날짜 각각                                                 | null        | 확인된 해당 청구 이용기간. 제공 시 양 끝 함께 포함 범위로 보존                                                                                             | 원천 JSON 또는 기간 컬럼                    |

계좌·카드·거래·청구는 공통 userId/sourceRef/sourceVersion을 상속한다. 계좌 반영 판단에는 해당 Account.asOf도 함께 사용한다. 반영 여부를 다른 기준시각에 재사용하지 않는다. 계좌 입금의 업무일은 bookingDate이며, 소비 귀속일 선택은 기존 구매일 우선·출금일 대체 규칙을 유지한다. occurredAtBasis가 지칭하는 날짜와 시각이 충돌하면 정상 확정 자료로 처리하지 않는다. 방향과 상태는 **PAYSE 제안 코드**이며 외부 공급자 값으로 주장하지 않는다. 취소 건은 취소 사실만, 환불 건은 실제 확인된 환불 금액만 표현한다. 부분 환불을 원구매 전액 취소로 바꾸지 않는다. 계좌 내역과 카드 기록이 같은 경제적 사건인지 확정할 때는 원천/청구/정산 근거를 사용하고 동일 금액·날짜로 합치지 않는다.

## 4. 확정 설정·예정 의무·지급 연결

아래 객체는 userId 필수, 원천 sourceRef는 상속하지 않는다. 사용자 변경은 버전 조건과 허용 필드를 검증한 저장 API로만 한다.

| 객체/필드                                          | 타입                                    | 필수 여부   | 수정 권한·의미                                                                                                        | 저장 대응                                        |
| -------------------------------------------------- | --------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Salary.salaryDay / salaryAmountKRW                 | 정수 1~31 / 금액                        | null 각각   | 사용자: 월급 예정일/금액. 미입력을 0으로 바꾸지 않음                                                                  | user_settings.salary_day/salary_amount_krw       |
| salaryAccountId                                    | ID → Account                            | null        | 사용자: 선택한 급여 계좌. 미완료 상태에서 임의 계좌 지정 금지                                                         | salary_account_id                                |
| receiptEvidence                                    | SalaryReceipt[]                         | 필수        | 확인된 월별 입금 근거; []면 근거 없음                                                                                 | source_contexts.salary_evidence                  |
| SalaryReceipt.expectedPayDate / transactionIds     | 날짜 / ID → Transaction 배열            | 필수        | 원천 또는 확인된 명시 연결. 임의 금액 일치로 급여 확정 금지                                                           | source_contexts.salary_evidence 내부             |
| SalaryReceipt.confirmation                         | unknown/partial/confirmed               | 필수        | 입금 확인 상태. v1.0 임시: 더미의 명시 confirmed 사건에서만 입금 완료. 부분 합계로 임의 전환 금지                     | source_contexts.salary_evidence 내부             |
| CardPlan.cardId / plannedPaymentDay                | ID → Card / 정수 1~31                   | 필수 / null | 사용자: 카드별 계획 결제일. null이면 override 없음                                                                    | user_settings.card_plan_overrides                |
| Obligation.obligationId / label                    | ID / 문자열                             | 필수        | 서버 ID / 사용자 예정 지출명                                                                                          | obligations.id / 신규 표시 항목                  |
| withdrawalAccountId                                | ID → Account                            | 필수        | 사용자 확정 출금 계좌. 청구 연결 의무는 확인된 실제 출금 계좌와 일치                                                  | withdrawal_account_id                            |
| amountKRW / dueDate                                | 금액 / 날짜                             | 필수        | 사용자 확인 미지급 계획. 청구 의무 금액은 원천 총액에 종속, 자유 수정 금지                                            | amount_krw/due_date                              |
| status                                             | active/cancelled                        | 필수        | 사용자 계획 상태. paid를 사용자가 직접 지정하는 값으로 두지 않음                                                      | status                                           |
| statementId                                        | ID → Statement                          | null        | 서버 검증: 같은 청구를 대표하는 유효 의무 최대 1개                                                                    | statement_id                                     |
| recurringPlanId / recurrenceKey                    | ID → RecurringPlan / 문자열             | 조건        | 직접 현금 반복 회차면 필수, 수동 1회/청구 대표 의무면 null                                                            | obligations.plan_id / occurrence_month로 키 조립 |
| Settlement.linkId / obligationId / transactionId   | ID / ID → Obligation / ID → Transaction | 필수        | 확인된 실제 출금과 의무 연결. 원천 거래 편집 아님                                                                     | settlement_links의 대응 컬럼                     |
| allocatedKRW / method                              | 양수 금액 / automatic·manual            | 필수        | 자동 연결 또는 사용자 수동 정정. 실제 지급 근거·한도 검사                                                             | allocated_krw/method                             |
| evidenceRefs / invalidatedAt                       | 근거 참조 배열 / 시각                   | 필수 / null | 유효 근거/정정 무효 시점. 자동은 명시 원천 연결, 수동은 사용자 확정 작업 추적                                         | evidence/invalidated_at                          |
| Reserve.reserveId / accountId / label              | ID / ID → Account / 문자열              | 필수        | 서버 ID / 사용자 보호 계좌·명칭                                                                                       | reserves.id/account_id/label                     |
| amountKRW / cancelledAt                            | 금액 / 시각                             | 필수 / null | 현재 보호 설정액 R / 사용자 취소. 실제 적립 거래나 매월 적립액 아님                                                   | amount_krw/cancelled_at                          |
| Allocation.allocationId / reserveId / obligationId | ID / ID → Reserve / ID → Obligation     | 필수        | 사용자 명시 배정. 같은 사용자 대상만 참조하며 배정 자체가 계좌 이체를 만들지는 않음                                   | reserve_allocations 대응 컬럼                    |
| amountKRW / releasedKRW                            | 양수 금액 / 비음수 금액                 | 필수        | 현재 유효 배정 총액(해제 누계 포함)/근거 있는 해제 누계. 최초 배정·변경 이력은 WriteReceipt에 보존. 0≤released≤amount | amount_krw/released_krw                          |
| releaseEvidence                                    | 해제 근거 배열                          | 필수        | settlement linkId·해제 금액·정정 작업 참조. 미해제는 []                                                               | release_evidence                                 |

청구 일자나 실제 출금 계좌가 미상이면 정상 Obligation을 임의로 완성하지 않는다. 청구 원천은 조회하고 해당 예정 계산의 정보 부족을 표시한다. 카드 결제일 사용자 계획과 실제 청구 예정일을 한 컬럼에 덮어쓰지 않는다. 할부 원문 조회는 가상 신규 할부·이자 계산을 추가한 것이 아니다.

## 5. 월간 반복 계획

**승인 1회는 이후 회차에도 적용되는 월간 계획 저장이다. 예정일 29·30·31일이 없으면 말일이며, 확인된 개별 일정이 우선한다. 계획·회차는 실제 거래나 지급 완료가 아니다.**

| 객체/필드                                                    | 타입                                      | 필수 여부   | 수정 권한·의미                                                              | 저장 대응                                              |
| ------------------------------------------------------------ | ----------------------------------------- | ----------- | --------------------------------------------------------------------------- | ------------------------------------------------------ |
| RecurringDecision.decisionId / candidateKey                  | ID / 문자열                               | 필수        | 서버 ID / 같은 근거 집합·규칙의 후보 식별                                   | recurring_decisions.id/candidate_key                   |
| ruleVersion / sourceVersion / evidenceTransactionIds         | 문자열 각각 / ID → Transaction 배열       | 필수        | 로컬 산출 근거를 서버가 존재·소유권·버전 검증                               | rule_version / 추가 버전 / evidence_refs               |
| normalizedName / decision                                    | 문자열 / approved·excluded                | 필수        | LLM/로컬 해석을 확인한 이름, 사용자 승인·제외                               | normalized_name/decision                               |
| planId                                                       | ID → RecurringPlan                        | 조건        | approved면 필수, excluded면 null. 승인과 계획 저장은 원자적                 | recurring_decisions.plan_id                            |
| RecurringPlan.planId                                         | ID                                        | 필수        | 서버: 안정된 계획 식별자                                                    | recurring_plans.id                                     |
| RecurringPlan.firstOccurrenceMonth                           | YYYY-MM 문자열                            | 필수        | 사용자 확인 첫 회차월. 과거 전체를 소급 생성하지 않음                       | recurring_plans.first_occurrence_month                 |
| RecurringPlanRevision.label / amountKRW / monthlyDay         | 문자열 / 금액 / 정수 1~31                 | 필수        | 사용자 확인 명칭·금액·원래 월간 예정일. 말일 보정으로 원래 일자를 덮지 않음 | recurring_plan_revisions 대응 컬럼                     |
| paymentTiming / scheduleBasis                                | immediate·card_bill / withdrawal·purchase | 필수        | 일정이 현금 출금일인지 구매일인지 보존. 카드 구매일을 출금일로 바꾸지 않음  | recurring_plan_revisions.payment_timing/schedule_basis |
| withdrawalAccountId / cardId                                 | ID → Account / ID → Card                  | 필수 / 조건 | 확정 출금 계좌; card_bill이면 카드 필수. 카드 실제 출금 계좌와 일치         | 대응 관계 후보                                         |
| status                                                       | active/cancelled                          | 필수        | 사용자 계획 상태. 취소해도 기존 지급 근거 삭제 금지                         | status 후보                                            |
| scheduleOverrides                                            | ScheduleOverride[]                        | 필수        | 확인된 개별 일정. 없으면 []이며 휴일을 이유로 임의 생성 금지                | recurring_plan_revisions.schedule_overrides            |
| ScheduleOverride.occurrenceMonth / plannedDate / evidenceRef | YYYY-MM / 날짜 / 문자열                   | 필수        | 해당 명목 회차월·scheduleBasis 기준 확인 날짜·근거. 월별 중복 override 금지 | scheduleOverrides 내부                                 |
| Occurrence.recurrenceKey / planId                            | 문자열 / ID → RecurringPlan               | 필수        | 로컬 생성: planId+명목 회차월(YYYY-MM). 날짜 보정으로 회차 ID를 바꾸지 않음 | 필요 회차만 의무/연결에 저장                           |
| nominalDate / plannedWithdrawalDate                          | 날짜 / 날짜                               | 필수 / null | 로컬: 월말 보정/확인 일정 적용 날짜, 확인 가능한 출금 예정일                | 로컬 투영·확정 의무                                    |
| confirmedScheduleRef                                         | 문자열                                    | null        | 원천의 개별 일정이 있을 때 우선한 근거                                      | 원천 일정 참조                                         |
| obligationId / statementId                                   | ID → Obligation / Statement               | null 각각   | 이미 저장된 회차/청구의 연결. 연결된 비용을 다시 추가하지 않음              | 의무·청구 관계 또는 명시 매핑                          |

생성 규칙: immediate는 withdrawal 기준, card_bill은 purchase/withdrawal 중 근거 있는 기준을 보존한다. card_bill의 출금일은 확인된 카드 일정으로만 결정한다. 모르면 해당 미래 계산을 제한한다. 구매 기준과 출금 기준을 더미에서 명시하며 탐지된 날짜의 의미를 임의로 바꾸지 않는다.

필요 기간의 회차는 **Flutter에서 생성**한다. 저장된 동일 회차가 있으면 그 의무를 사용하고 가상 회차를 더하지 않는다. 카드 청구에 포함된 반복 구매는 청구 대표 의무에 포함하여 한 번만 계산하며 독립 현금 의무를 추가하지 않는다. 청구 전 반복 구매와 후속 청구를 연결할 근거도 더미에 명시한다. 관계를 확인하지 못하면 자동 합침·중복 차감 대신 확인 필요로 남긴다.

무한한 미래 회차를 DB에 미리 만들지 않는다. 직접 현금 회차를 지급 연결/보호 배정 대상으로 저장할 때는 사용자가 확정한 계획과 로컬 회차 입력을 서버가 검증하고 같은 recurrenceKey로 중복 등록하지 않는다. 계획 편집은 사용자 결정에 따라 두 작업으로 나눈다. ① 개별 미지급 회차 수정은 해당 회차만 바꾸고 월간 계획을 덮지 않는다. ② 향후 계획 수정은 사용자가 선택한 미래 월부터 적용한다. 기존 저장 회차·부분 정산 회차·실제 거래·정산 기록은 자동 변경하지 않는다. 선택 월 전 회차도 유지한다.

`RecurringPlan`은 `userId`, `planId`, `firstOccurrenceMonth` 세 필드만 가진다. 위 표의 `RecurringPlanRevision.label` 다음부터 `scheduleOverrides`까지는 버전 필드이며 계획에 복사하지 않는다. `RecurringPlanRevision`에는 `userId`, `revisionId`, `planId`, `effectiveFromMonth`, `isCurrent`와 label/amountKRW/monthlyDay/paymentTiming/scheduleBasis/withdrawalAccountId/cardId/status/scheduleOverrides가 필요하다. 최소 버전 시작 월은 firstOccurrenceMonth와 같으며, 그보다 이른 회차는 허용하지 않는다. 같은 계획·시작 월에 `isCurrent=true`인 버전만 최대 1개이며 과거 버전은 기존 회차 참조를 위해 보존한다. 새 회차는 isCurrent=true이고 effectiveFromMonth가 대상 회차월 이하인 버전 중 가장 늦은 시작 월을 선택한다. 기존 저장 회차·개별 편집은 고정된 planRevisionId를 유지한다. 회차월보다 나중에 시작하는 버전은 참조할 수 없다. 물리 저장은 recurring_plans와 recurring_plan_revisions로 분리하며 수정 기록은 WriteReceipt에 남긴다.

회차는 `planRevisionId: ID`로 생성 근거를 기록하되 recurrenceKey는 planId+명목 회차월을 유지한다. 개별 수정 값은 Obligation 또는 `OccurrenceOverride(recurrenceKey, planRevisionId, amountKRW, dueDate, withdrawalAccountId, status)`에 저장하여 재조회·재생성해도 유지한다. 동일 사용자·버전·지급 연결 제약을 검사한다. 부분 정산된 회차를 계획 수정에 따라 자동 재작성하지 않으며 잘못된 정산의 정정 API는 계속 허용한다. 카드 원천 청구 금액과 실제 거래는 개별 회차 편집 대상이 아니다.

Snapshot은 `recurringPlanRevisions: RecurringPlanRevision[]`, `occurrenceOverrides: OccurrenceOverride[]`를 제공한다. 사용자 확정 계획과 회차 수정은 DB에 저장하지만, 조회 기간을 위해 생성한 미확정 미래 투영은 로컬 메모리에 둔다. 미래 월이 되거나 예정일이 경과했다는 이유로 지급 완료·실제 거래를 생성하지 않는다.

## 6. 사용자·인증·변경 기록

승인 전 `RecurringCandidate`는 로컬 메모리 객체다. `candidateKey`, `ruleVersion`, `sourceVersion`(문자열), `evidenceTransactionIds`(거래 ID 배열), `normalizedName`(문자열), `suggestedAmountKRW`(마지막 확인 금액), `suggestedDay`(1~31 또는 null)를 가진다. 이름·근거와 수치는 로컬 규칙으로 재검증하고 승인할 때만 §5의 확정 금액·첫 회차·출금 계좌를 저장한다. 서버 LLM 요청은 필요한 이름·근거로 제한하고 응답은 후보 식별·이름·허용된 거래 분류·설명·근거 참조만 허용한다. 이 객체가 별도 영구 후보 테이블을 요구하지 않는다.

아래 민감 필드는 일반 Snapshot·금융 더미 공개 JSON·LLM 입력에 포함하지 않는다. 합성 계정 시드와 금융 자료는 별개다.

| 객체/필드                                                       | 타입                                       | 필수 여부          | 수정 권한·의미                                                                                           | 저장 대응                              |
| --------------------------------------------------------------- | ------------------------------------------ | ------------------ | -------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| DemoUser.userId                                                 | ID                                         | 필수               | 서버: 재로그인해도 동일 ID                                                                               | demo_users.id                          |
| name / syntheticPhone                                           | 문자열 각각                                | 필수               | 사전 합성 시드. name은 인증·호칭 공통 값, phone 단독 인증 금지. 이름/전화번호는 정규화 후 공백 없이 저장 | 목표 demo_users.name / synthetic_phone |
| codeVerifier / createdAt                                        | 검증 문자열 / 시각                         | 필수               | 서버 전용: 별도 데모 코드 검증값/시드 생성 시각                                                          | code_verifier/created_at               |
| Session.sessionId / userId                                      | ID 각각                                    | 필수               | 서버: 사용자별 활성 세션 1개; 기존 로그인 유지·새 로그인 거절                                            | demo_sessions.id/user_id               |
| tokenDigest / issuedAt / endedAt                                | 검증 문자열 / 시각 / 시각                  | 필수 / 필수 / null | 서버 전용: 무작위 토큰 검증/발급/명시 종료. 자동 만료 정책 추가 안 함                                    | 대응 세션 컬럼                         |
| WriteReceipt.receiptId / operationKey                           | ID / 문자열                                | 필수               | 서버: 사용자+작업키 유일. 같은 요청 재시도 한 번 처리                                                    | write_receipts.id/operation_key        |
| requestDigest / action / changedRefs                            | 문자열 / 작업 종류 문자열 / 대상 참조 배열 | 필수               | 서버: 허용된 저장 본문만 해시. 인증 원문·시뮬레이션 저장 금지                                            | 대응 기록 컬럼                         |
| beforeAfter / resultVersion / createdAt                         | 변경 필드 객체 / 버전 문자열 / 시각        | 필수               | 서버: 정정에 필요한 최소 설정·관계 기록. 금융 파생값 저장 아님                                           | before_after/result_version/created_at |
| WriteRequest.expectedDataVersion / ruleVersion / idempotencyKey | 버전 문자열 / 문자열 / 문자열              | 필수               | 사용자 요청, 서버 대조. 동일 키 다른 본문·오래된 버전은 저장 거절                                        | 요청·write_receipts                    |
| AuthInput.name / phone / code                                   | 문자열 각각                                | 필수               | 인증 요청 메모리만, 제출값 추가 저장·로그·LLM 전송 금지                                                  | 저장 안 함                             |
| LocalPIN                                                        | 6자리 입력                                 | 조건               | 기기 잠금/복구만. 서버로 원문·검증값 전송 금지                                                           | 기기 보안 저장 설계 대상               |

코드 검증 후 활성 세션이 없을 때만 발급한다. 활성 세션이 있으면 기존 로그인 유지·새 로그인 거절이다. PIN 복구는 기존 토큰+합성 입력·코드 재확인 후 로컬 재설정하며 새 세션을 만들지 않는다. 토큰 분실과 정상 PIN 복구를 동일 처리하지 않는다. 로그아웃/데모 탈퇴로 금융 설정을 초기화하지 않는다.

v1.0 급여 확인은 **임시 결정**이다. 합성 시나리오가 같은 자료 버전의 실제 입금 거래 ID와 partial/confirmed 상태를 명시한다. confirmed 사건 전까지 홈 급여 대기를 유지한다. 서버가 입금 합계를 계산하거나 LLM이 완료를 추정하지 않는다. 실제 잔액에 반영된 부분 입금을 숨기거나 다시 더하지 않는다. 프론트 개발상 필요가 확인될 때 이 기준을 재검토하며, 실제 금융 연동의 급여 자동 판정 규칙으로 확대하지 않는다.

## 7. 관계·저장 제약

| 관계/조건                                                                 | 검증                                                                             |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| User 1:N 계좌·카드·거래·설정, User 1:0..1 활성 Session                    | 동일 사용자 관계·활성 세션 유일성. user_settings는 사용자당 1개                  |
| Account/Card 1:N Transaction, Card 1:N Statement                          | transaction은 계좌/카드 적어도 하나. 카드 청구 참조는 같은 카드                  |
| Account 1:N Obligation/Reserve, Obligation N:M Transaction via Settlement | 실제 출금과 의무의 유효 배정 합계 한도, 출금 계좌 일치                           |
| Reserve N:M Obligation via Allocation                                     | 같은 사용자·미해제 배정 합계 한도. 명시 배정을 계좌 간 자동 이체로 해석하지 않음 |
| RecurringDecision approved → Plan, Plan 1:N 월별 Occurrence               | 승인 중복 방지·회차키 유일. 카드 청구와 직접 현금 의무의 중복 제거               |
| sourceId→내부 ID 매핑                                                     | 페이지·조회 순서로 ID 변경 금지. 소스 버전 변경 시 참조 유효성 검사              |
| 확정 설정 변경→write receipt+dataVersion                                  | 하나의 DB 트랜잭션으로 저장. 일부만 저장 후 성공 응답 금지                       |

단일 행 값 범위는 CHECK/NOT NULL, 같은 사용자 관계는 복합 FK 또는 동등한 원천 참조 검증, 유일성은 UNIQUE로 설계한다. 여러 행의 정산·보호 합계는 단일 CHECK로 보장한다고 쓰지 않고 동시 저장을 직렬화하여 검사한다. API·DB·Dart 모델의 필드 배치가 같을 필요는 없지만 의미와 권한은 같아야 한다.

## 8. 더미 생성·Flutter 인수 기준

1. 동일 fixture의 안정된 ID·자료 버전·기준시각을 서버와 Flutter FakeRepository가 사용한다. 5개 은행/4개 카드사 표시는 내부 합성 자료이며 외부 응답 규격 준수나 실연동 성공을 뜻하지 않는다.
2. 연결한 전체 계좌·카드의 최근 달력 1년 자료를 준비한다. 홈 포함 계좌와 연간 분석 대상은 다르다. 분석 범위는 기존 `(asOf−달력1년, asOf]` 기준안이며, 날짜만 있으면 시작 업무일 제외/종료일까지 확보분을 로컬에서 적용한다. coverage 요청 구간과 이 집계 필터를 혼동하지 않는다.
3. 반복 후보의 기간·횟수·날짜/금액 허용 범위·예정액은 [계산 규칙의 연간 소비와 반복 후보](calculation-rules.md#연간-소비와-반복-후보)를 같은 입력 벡터로 검증한다. 서버·LLM이 금액을 다시 산출하지 않는다.
4. 0원 정상 계좌, 조회 실패, 완전 조회의 거래 0건, 부분 조회의 누락을 별도 사례로 만든다. 기존 잔액과 시뮬레이션에 이미 반영된 거래를 재생하지 않는다.
5. 카드 구매 100,000원→동일 청구→실제 출금의 연결을 제공한다. 소비 300,000원 또는 잔액 재차감이 되지 않아야 한다. 취소·부분 환불·내부 이체·부분 정산·잘못 연결한 지급의 정정도 근거와 함께 준비한다.
6. 31일 월간 계획은 2027-02-28, 2027-03-31 회차가 된다. 2027-02-26의 확인된 개별 일정이 있으면 2월만 그 일정이 우선한다. 예정일 경과만으로 실제 거래·지급 완료·DB 상태 변경을 만들지 않는다.
7. 다른 사용자 ID 참조, 오래된 dataVersion, 같은 작업키 다른 입력, 같은 회차 중복 저장을 거절해야 한다. 정정 시 해당 연결·배정 해제·변경 기록만 원자적으로 복구한다.
8. U·연간 집계·시뮬레이션 입력/결과·조정 초안은 로컬 계산/메모리다. 실제로 확정한 계획·보호 설정만 저장한다. 금융 모델/Repository/순수 계산 모듈을 분리하고 전역 singleton에 계좌·세션·계산 상태를 한꺼번에 담지 않는다.

## 9. v1.0에서 필요한 보조 관계와 로컬 객체

다음은 새 금융 기능이 아니라 기존 원거래 연결·중복 방지·로컬 계산을 표현하기 위한 필드다. 고유 ID를 모든 거래에 무조건 추가하지 않으며 확인된 관계에만 사용한다.

| 객체/필드                                                                                       | 타입·필수 여부                                                   | 용도·저장 경계                                                                                                                |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Snapshot.relatedTransactions                                                                    | Transaction[]·필수, 없으면 []                                    | 조회 기간 밖 원구매·정산 근거를 같은 사용자·연결 권한·자료 버전으로 보충. 분석 대상 기간에 다시 포함시키지 않음               |
| ReferenceResolution.transactionId / status                                                      | ID / resolved·unavailable·필수                                   | 기간 밖 참조를 확보했는지 구분. unavailable은 원거래가 없다는 뜻이 아니며 영향 결과를 불완전으로 표시                         |
| ReferenceResolution.reason                                                                      | outside_retention·not_provided·not_connected·문자열 null         | unavailable이면 이유 필수. 다른 사용자의 ID를 사유와 함께 노출하지 않고 권한 거절                                             |
| Snapshot.referenceResolutions                                                                   | ReferenceResolution[]·필수                                       | relatedTransactions와 원본 페이지에 포함되지 않은 참조의 확보 상태                                                            |
| TransactionRelation.kind / fromId / toId / evidenceRef                                          | card_account_pair·internal_transfer / 거래 ID 각각 / 문자열·필수 | 확인된 카드·계좌의 동일 사건/내부 이체 양쪽 관계. 같은 사용자·자기 참조 금지. manifest 또는 관계 저장 후보                    |
| Snapshot.transactionRelations                                                                   | TransactionRelation[]·필수, 없으면 []                            | 연결 근거 없는 카드/계좌 동시 내역을 날짜·금액만으로 병합하지 않음                                                            |
| OccurrenceLink.recurrenceKey / purchaseTransactionId / statementId / obligationId / evidenceRef | 문자열 필수 / 각 ID null / 문자열 필수                           | 반복 회차가 실제 구매·청구·의무 중 어디에 반영됐는지 명시. 적어도 하나의 참조 필요. 원천 매핑 또는 사용자 확정 관계 저장 후보 |
| Snapshot.occurrenceLinks                                                                        | OccurrenceLink[]·필수                                            | 같은 회차·같은 참조 중복 금지. 청구 대표 의무와 포함 반복 구매를 중복 예약하지 않음                                           |
| SimulationInput.inputRevision / horizonStep / items                                             | 정수 / 1·2·3 / SimulationItem[]·필수                             | 세션·dataVersion·sourceVersion·ruleVersion·asOf에 묶인 로컬 메모리. 1~5건 계산, 0건 결과 해제, 6건 거절                       |
| SimulationItem.itemId / name / amountKRW / purchaseDate / paymentMethod                         | ID / 문자열 / 양수 금액 / 날짜 / immediate·card_lump_sum·필수    | 가상 구매 입력. 실제 거래 ID·DB 행을 만들지 않음                                                                              |
| SimulationItem.withdrawalAccountId / cardId / plannedWithdrawalDate / scheduleEvidenceRef       | 계좌 ID 조건 / 카드 ID 조건 / 날짜 null / 문자열 null            | 즉시출금은 계좌 필수, 카드 일시불은 카드 필수. 카드 출금일은 확인 일정으로 로컬 산출. 일정 미상은 계산 제한                   |
| SimulationResult.baseline / allItems / itemImpacts / limitations                                | 기간 결과 배열 각각 / 품목 영향 배열 / 제한 사유 배열·필수       | 각 기간 시작·종료 H, 종료 직전 A, 최소 H/A, 차이, 최초 확인 가능 부족·최대 부족액. 정보 부족 금액은 null                      |
| SimulationResult.versionContext / inputRevision / timePrecision                                 | 입력 버전 묶음 / 정수 / timestamp·day_end·mixed·필수             | 현재 세션·입력·버전과 다른 지연 결과는 폐기. 일 마감 결과를 일중 최초 시각·최대액으로 표현하지 않음                           |
| ConsumptionResult.dateBasis / evidenceTransactionIds / coverage                                 | purchase·withdrawalFallback·refund / ID[] / 조회 범위·필수       | 연간/월별 순소비의 날짜 근거·대체 근거·누락 추적. 음수 순소비 허용, DB 저장하지 않음                                          |
| AdjustmentDraft.reserveId / proposedAmountKRW / expectedDataVersion                             | ID / 비음수 금액 / 버전 문자열·필수                              | 로컬 전후 비교·취소. 확정 시 해당 보호 설정만 버전 검증하여 저장                                                              |
| DemoEvent.eventId / sourceVersionBefore / sourceVersionAfter                                    | 문자열 각각·필수                                                 | 준비된 사건 한 번 적용. 사용자+eventId의 적용 영수증으로 재시도 중복 방지, 잔액·거래·관련 근거를 한 버전으로 공개             |

관련 참조가 기간 밖에 있다는 이유로 원거래 ID를 null로 지우지 않는다. 원거래를 못 받아도 확인된 환불 사실은 보존하고, 원구매와의 중복/순소비 해석은 근거 확보 수준에 맞춰 표시한다. 카드 청구와 출금의 지급 연결은 SettlementLink를 사용한다. TransactionRelation은 카드 구매와 계좌 내역의 동일 사건 식별을 보완하며 정산액을 대신 저장하지 않는다.

로컬 결과의 상세 JSON 구조·Dart 클래스는 담당 기능 구현에서 정의하되 위 의미를 빠뜨리지 않는다. 기간 경계·상한·가상 소비의 기준·H/A 이월은 [계산 규칙](calculation-rules.md#시뮬레이션-구간)의 단일 정의를 따른다. 계좌별 부족 상세는 기존 P1 우선순위를 유지한다.

## 10. 확장 경계

- 서버의 공급자 adapter → PAYSE 계약 → Flutter Repository → 순수 계산 방향을 유지한다. 별도 CODEF 중간 계층·마이크로서비스·전역 싱글톤을 요구하지 않는다.
- `schemaVersion`은 전달 형식, `sourceVersion`은 금융 자료, `dataVersion`은 사용자 자료+설정, `ruleVersion`은 계산 규칙이다. 값 추가와 의미 변경을 구분하고 구형 앱이 모르는 금액·상태를 정상값으로 간주하지 않게 검증한다.
- v1.0 통화는 KRW다. 다른 통화는 원화로 추정·합산하지 않고 지원 불가로 표시한다. 환율·외화 계좌 지원은 후속 계약 변경이다.
- 공급자 변경 시 내부 userId/accountId/cardId를 새로 만들지 않도록 원천 별칭 매핑을 분리한다. 동일 소유·객체임을 검증하지 못하면 자동 통합하지 않는다. 실제 원천 삭제·정정은 버전 이력/참조 무효화로 다루고 사용자 설정을 연결 없이 연쇄 삭제하지 않는다.
- 원천 갱신과 설정 변경은 일관된 스냅샷을 공개한다. 상태 변경 후 이전 조회 응답·다른 계정의 늦은 LLM 응답으로 캐시를 덮지 않는다. 실제 동기화 주기·실시간성은 공급자 선정 후 정한다.
- 사용자 분류·별칭·계획은 원천 JSON과 독립적으로 보존한다. 새 sourceVersion을 받았다는 이유로 사용자 정정값을 초기화하지 않는다. 관계가 유효하지 않으면 확인 필요로 남긴다.
- 입력을 계약에 맞춰 검증하고 알 수 없는 쓰기 필드는 거절한다. 승인되지 않은 필드가 DB 엔티티에 자동 복사되는 구조를 피한다. 계좌 목록 페이지·부분 실패가 있어도 권한 검증은 모든 참조에 적용한다.

- 실제 본인확인·실사용자 동의/철회·보존/삭제·인증 수명은 실연동 전에 별도 계약으로 정한다. 합성 이름·고정 코드·자동 만료 없는 데모 세션을 실서비스 인증으로 그대로 확장하지 않는다.

## 11. 산출물과 미구현 경계

- [DB 사전](database-schema.md): 23개 테이블의 초기 DDL·FK·인덱스·저장 제약을 설명한다. 기존 DB 이름 이행과 인증/탈퇴 후속 DDL은 구분한다.
- [HTTP 계약](api-contract.md)·[응답 모델](api-response-models.md): v0.6 경로·오류·페이지·접근 제한의 문서 규격이다. 실제 API 구현·실행 테스트 완료를 뜻하지 않는다.
- [더미 사용 기준](../apps/api/fixtures/docs/dummy-data.md): 현재 합성 사용자 3명·시나리오·생성 및 검증 절차를 설명한다. 계정 수를 영구 제품 한도로 고정하지 않는다.
- 실행 가능한 전체 JSON Schema/OpenAPI, 실제 API mapper, 기존 DB 전환·인증/조회/저장 통합은 별도 구현 결과와 검증 근거가 필요하다.
- 실제 금융 공급자는 미정이다. CODEF 호출·응답 복제를 요구하지 않으며 공급자 확정 후 공식 자료로 변환 매핑을 별도 검증한다.

## 근거

최초 설계의 기준 커밋과 고정 커밋 문서 링크는 [API 문서 이력](../apps/api/docs/history/2026-10-22-api-doc-history.md)에 보존한다. 현재 규칙은 이 문서와 연결된 공통 계약을 따른다.

- [JSON Schema 객체](https://json-schema.org/understanding-json-schema/reference/object): 필수 키와 null을 구분하는 표현 근거.
- [PostgreSQL 제약](https://www.postgresql.org/docs/current/ddl-constraints.html): 관계·유일성·행 간 제약의 구현 범위. 제품 정책의 근거로 확대하지 않는다.

## DemoUser 이름 계약과 이행 상태

DemoUser의 이름 필드는 §6의 `name` 하나다. 인증 입력·저장 공백·세 UUID/name 매핑·반환 위치는 [API 이름 계약](api-contract.md#인증-입력과-단일-이름)이 단일 기준이다. 실제 SQL·server-seeds.json·생성/검증/export 도구는 아직 구 이름 구조이므로 [DB 이름 이행 목표](database-schema.md#단일-name-이행-목표--미구현)를 따른다. 이행 완료와 목표 계약을 혼동하지 않는다.

## 원본 모델과 API 투영의 구분

위 필드 표는 `PAYSE-DRAFT-2` 원본의 정상 객체를 설명한다. HTTP/FakeRepository의 `PAYSE-API-0.6-2`는 [응답 모델](api-response-models.md)에 따라 접근 제한 필드를 생략하고 accessRestrictions를 함께 제공한다. 정상 모델의 필수 FK를 임의 null로 채워 원본 검증기에 통과시키지 않는다. API 표현 검증은 별도로 필요하며 원본 검증기 성공이 API 계약 통과를 뜻하지 않는다.

최초 상태·재로그인·접근 제한·원천 미상/null/빈 배열/미수신 구분은 [응답 계약](api-response-models.md)의 단일 정의를 따른다. 이 문서의 정상 원본 모델을 부분 연결 HTTP 응답에 그대로 강제하지 않는다.

과거 급여 입금 근거는 현재 salaryAccountId 설정과 독립된 원천 사실이다. 설정을 바꾸거나 null로 해제해도 근거를 재작성하지 않는다. 근거 거래는 동일 사용자 소유의 posted 계좌 입금이며 잔액에 반영된 사실이어야 한다. 세션 발급·복구는 [API 인증 계약](api-contract.md#2-인증탈퇴)을 따른다.

작성·변경·검증 이력은 [API 문서 이력](../apps/api/docs/history/2026-10-22-api-doc-history.md)에 보존한다.
