# v0.6 응답 모델과 수정 권한

원천의 필드·타입·null·금액 단위는 [데이터 모델](../data-model-draft.md), 실제 관계·`isCurrent`는 [DB 설계](../database-design.md)가 기준이다. 기존 fixture `PAYSE-DRAFT-1`은 원본 자료다. HTTP 응답은 아래 adapter에서 권한·페이지를 적용한다.

## 1. 전달 버전과 정상 응답

이번 API 표현 제안은 `schemaVersion="PAYSE-API-0.6-1"`이다. 원본 fixture의 schemaVersion·파일은 바꾸지 않는다. 이 버전은 부분 연결 시 필드 생략과 accessRestrictions를 해석하는 소비자용이다. 기존 `PAYSE-DRAFT-1`을 받는 parser에 그대로 넘겨도 호환된다고 주장하지 않는다. Flutter Repository mapper/FakeRepository에 같은 변환을 적용하고, 미지원 schemaVersion은 오류로 처리한다.

Snapshot 및 TransactionPage의 공통 JSON 필드 H(HTTP 헤더가 아님):

```text
userId:ID, schemaVersion:string, currency:"KRW",
dataVersion:Version, sourceVersion:string, ruleVersion:string, asOf:Time
```

| 응답             | H 외 필수 키                                                                                                                                                                                                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 연결 전 Snapshot | `institutions`, `institutionLinks:[]`, `coverage:[]`. 다른 금융 키는 없음                                                                                                                                                                                                                                                |
| 연결 후 Snapshot | `institutions,institutionLinks,coverage,accounts,cards,transactions,statements,settings,obligations,reserves,allocations,settlements,recurringPlans,recurringDecisions,recurringPlanRevisions,occurrenceOverrides,relatedTransactions,referenceResolutions,transactionRelations,occurrenceLinks,page,accessRestrictions` |
| TransactionPage  | `transactions,relatedTransactions,referenceResolutions,transactionRelations,occurrenceLinks,coverage,page,accessRestrictions`                                                                                                                                                                                            |

settings만 객체이고 나머지 금융 복수 키는 배열이다. page는 `{nextCursor:string|null,dataVersion:Version,sourceVersion:string}`다. 원천 객체의 userId/sourceRef/sourceVersion을 제거하지 않으며 인증 비밀·rawFragment를 공개 필드 사전에 추가하지 않는다. sourceRef/evidenceRef에도 숨겨진 기관의 ID·계좌 번호·비밀이 섞이지 않도록 adapter에서 검사한다.

`null`은 원천 미상/해당 없음/사용자 설정 해제 중 각 필드가 정의한 의미를 유지한다. 실패 계좌를 0원으로 만들지 않는다. 배열 []는 해당 권한 범위에 반환할 객체가 없다는 뜻이며, 원천 완전성은 coverage와 참조 상태를 별도로 확인한다.

### 1.1 alpha·beta·gamma 최초 상태와 재로그인

변환 입력은 인증된 userId, **그 사용자의** 선택된 불변 원본, 하나의 일관된 저장 상태에서 읽은 연결·계좌 선택·사용자 설정, 요청 페이지 문맥이다. 이름·화면 전역 변수로 원본을 선택하지 않는다. userId·원천 선택·종속 소유자 또는 현재 요청의 버전 문맥이 맞지 않으면 오류로 처리하며 다른 계정 원본으로 대체하지 않는다. sourceVersion·asOf는 선택한 원본 기준이고, dataVersion은 현재 저장 상태의 버전이다. 최초 상태는 원본의 초기 dataVersion으로 시작하되 설정 저장으로 증가한 현재 dataVersion이 원본 fixture의 초기 값과 같을 필요는 없다. 불변 fixture의 초기 값으로 현재 버전을 되돌리지 않는다.

최초 연결 전은 현재 연결된 기관이 없는 준비 상태다. alpha-ready/beta-ready/gamma-month-end 원본 각각에서 H와 institutions를 구성하되, schemaVersion은 PAYSE-API-0.6-1로, dataVersion은 위 현재 저장 상태 값으로 설정한다. 반환 키는 H 7개+institutions+institutionLinks+coverage **10개뿐**이다. institutionLinks와 coverage는 []다. settings·accounts·cards·transactions·page·accessRestrictions 등 나머지 키를 null·[]로 채우지 않고 생략한다. 기관별 확인된 개수 메타데이터는 그 사용자 원본 값을 유지한다.

세 계정에 같은 변환 책임을 적용하며 연결 전 JSON 파일을 각 계정마다 추가하는 것은 필수가 아니다. 기존 alpha-unconnected는 예시 원본이며 beta/gamma의 대체 원본이 아니다. 원본 fixture를 수정·초기화하지 않고 새 응답 객체를 만든다. 구조 공유는 가능하지만 사용자별 가변 상태를 공유하지 않는다.

| 상태/사건                       | 응답·상태 처리                                                                                                   |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| 최초 연결 전 GET /snapshot      | 위 10개 키만 반환. 로그인 성공과 금융기관 동의/연결 성공을 구분                                                  |
| 기관 동의/제외 목록의 저장 요청 | 기존 POST /institution-links 계약대로 실제 성공을 확인한 뒤 연결 상태·버전을 반영. 연출 완료만으로 확정하지 않음 |
| 연결 후 GET /snapshot           | 현재 허용 기관 범위의 필수 배열/설정과 page/accessRestrictions를 포함. 미연결 종속 정보는 §2 적용                |
| 같은 계정의 재로그인            | 저장된 연결·계좌 선택·설정 복원. 최초 연결 전 변환을 무조건 다시 실행하지 않음                                   |
| 계정/세션 전환                  | 이전 계정 캐시·누적 페이지·제한 상태·늦은 응답을 새 계정에 적용하지 않음                                         |
| 연결/계좌 선택 저장 후 새 버전  | 기존 cursor·누적 거래 페이지 폐기 후 새 Snapshot. 불변 원본의 sourceVersion/asOf를 현재 시각으로 조작하지 않음   |

계좌 선택은 연결 권한과 별개다. 아직 계산 계좌를 선택하지 않았거나 included=false라고 연결 전 응답으로 되돌리지 않는다. FakeRepository의 상태 저장 모사는 실제 서버/DB 영속화가 구현됐다는 증거가 아니다.

### 1.2 대표 응답 — beta 최초 연결 전

아래는 beta-ready 원본 메타/기관 목록에서 만든 **명세 예시**이며 실제 API 호출 결과가 아니다. alpha/gamma는 같은 키 규칙에 각자의 값으로 생성한다. 이름은 로그인 201에 있으며 이 Snapshot에는 추가하지 않는다.

```json
{
  "userId": "87f7bbf9-2355-5210-9325-f25d83a8ff35",
  "schemaVersion": "PAYSE-API-0.6-1",
  "currency": "KRW",
  "dataVersion": "1",
  "sourceVersion": "fixture-1:beta:2026-10-19:base",
  "ruleVersion": "PAYSE-CALC-1",
  "asOf": "2026-10-19T12:00:00+09:00",
  "institutions": [
    {
      "code": "bank.kb",
      "kind": "bank",
      "name": "국민",
      "accountCount": 2,
      "cardCount": 0
    },
    {
      "code": "bank.shinhan",
      "kind": "bank",
      "name": "신한",
      "accountCount": 1,
      "cardCount": 0
    },
    {
      "code": "bank.hana",
      "kind": "bank",
      "name": "하나",
      "accountCount": 1,
      "cardCount": 0
    },
    {
      "code": "bank.ibk",
      "kind": "bank",
      "name": "기업",
      "accountCount": 1,
      "cardCount": 0
    },
    {
      "code": "bank.kakao",
      "kind": "bank",
      "name": "카카오뱅크",
      "accountCount": 1,
      "cardCount": 0
    },
    {
      "code": "card.hyundai",
      "kind": "card",
      "name": "현대",
      "accountCount": 0,
      "cardCount": 1
    },
    {
      "code": "card.samsung",
      "kind": "card",
      "name": "삼성",
      "accountCount": 0,
      "cardCount": 1
    },
    {
      "code": "card.woori",
      "kind": "card",
      "name": "우리",
      "accountCount": 0,
      "cardCount": 1
    },
    {
      "code": "card.kb",
      "kind": "card",
      "name": "국민",
      "accountCount": 0,
      "cardCount": 1
    }
  ],
  "institutionLinks": [],
  "coverage": []
}
```

## 2. 부분 연결과 종속 참조

미연결 계좌·카드 ID를 연결된 객체의 FK라는 이유로 공개하지 않는다. 반대로 확인된 원천 ID를 미상 null로 덮어쓰지도 않는다. 원천 저장은 유지하고 **API 표현에서 제한 필드를 생략**한다. 아래 경우에만 정상 필수 키의 생략을 허용한다.

### 2.1 제한 위치 규격 — 사용자 확정

AccessRestriction은 **서버가 응답을 만들 때 생성하는 읽기 전용 메타데이터**다. 클라이언트가 보낸 제한 목록으로 조회 권한을 확대하지 않는다. 아래 허용 조합과 schemaVersion으로 검증하며 요청 DTO·DB 금융 사실로 저장하지 않는다.

```text
AccessRestriction = {
  ownerType: "response"|"settings"|"card"|"transaction"|"statement"|
             "obligation"|"allocation"|"recurringPlan"|"recurringPlanRevision",
  ownerId: ID|null,
  field: string,
  targetKind: "account"|"card"|"transaction"|"statement"|"obligation"|"reserve"|"plan",
  reason: "not_connected"
}
```

- response의 기준점은 해당 Snapshot/TransactionPage JSON 루트, settings는 공개된 settings 객체, 나머지는 ownerId로 식별한 **공개 가능한 객체**다. response/settings의 ownerId는 반드시 null, 그 외는 공개 자원 자신의 ID다. 계획 버전은 revisionId를 쓰며 planId로 대신하지 않는다. 거래가 허용 범위의 다음 페이지에 있으면 공개 가능한 ID 참조를 유지한다.
- field는 아래 등록 표의 리터럴이다. 중첩 객체는 `salary.salaryAccountId`처럼 점으로 표현한다. 배열 전체의 일부 행을 생략하면 배열 속성을 가리키며 인덱스·와일드카드·숨겨진 ID·임의 동적 경로는 허용하지 않는다. 이 문자열을 코드·JSONPath·DB 경로로 실행하지 않는다.
- targetKind는 **아래 허용 표가 지정한 비공개 자원 종류**다. 원천 목록 accounts/cards/transactions/relatedTransactions에서는 생략된 행 자체의 자원 종류(account/card/transaction)를 쓴다. 예를 들어 미연결 은행 때문에 거래 행을 숨겨도 response/transactions의 targetKind는 transaction이다. 다른 위치에서는 해당 슬롯의 비공개 참조 종류를 쓴다. statements는 부모 카드, allocations는 부모 reserve/obligation, releaseEvidence는 정산 근거 transaction을 가리킨다. 더 위의 미연결 계좌까지 재귀적으로 종류를 바꾸지 않는다. 같은 위치에 여러 종류의 제한이 있으면 종류별 표식 하나를 보낸다. 제한 목록·오류·로그에는 숨겨진 대상 ID·개수·금액·원문을 넣지 않는다. 최초 연결 전의 institutions에 이미 허용한 기관별 개수와 이 표식은 별개다.
- 같은 `(ownerType,ownerId,field,targetKind,reason)`은 한 번만 반환한다. 목록 순서에는 의미를 부여하지 않는다. 값 자체를 숨겨야 하면 키 생략, 배열의 비공개 행만 숨기면 공개 행을 남기며 빈 배열도 가능하다. 후자는 표식과 함께 읽어 원천 전체가 없다고 판단하지 않는다.
- 아래 `transactionRelations`와 `settlements`의 객체별 표식은 **등록된 관계 슬롯**이다. 실제 객체에 그 이름의 배열 키를 추가한다는 뜻이 아니다. 실제 행은 응답 루트의 동명 배열에 있으며, 공개 부모를 이용하는 계산/편집의 제한을 특정하기 위한 참조다. 이 두 슬롯 외의 가상 속성을 만들지 않는다.

| ownerType / ownerId                | 허용 field                                                                    | 허용 targetKind                          |
| ---------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------- |
| response / null                    | accounts                                                                      | account                                  |
| response / null                    | cards, statements                                                             | card                                     |
| response / null                    | transactions, relatedTransactions, referenceResolutions, transactionRelations | transaction                              |
| response / null                    | coverage                                                                      | account, card                            |
| response / null                    | obligations                                                                   | account, plan                            |
| response / null                    | reserves                                                                      | account                                  |
| response / null                    | allocations                                                                   | reserve, obligation                      |
| response / null                    | settlements                                                                   | obligation, transaction                  |
| response / null                    | recurringPlans                                                                | account                                  |
| response / null                    | recurringPlanRevisions, occurrenceOverrides                                   | plan, account                            |
| response / null                    | recurringDecisions                                                            | plan, transaction                        |
| response / null                    | occurrenceLinks                                                               | plan, transaction, statement, obligation |
| settings / null                    | salary.salaryAccountId                                                        | account                                  |
| settings / null                    | salary.receiptEvidence                                                        | account, transaction                     |
| settings / null                    | cardPlans                                                                     | card                                     |
| card / cardId                      | withdrawalAccountId                                                           | account                                  |
| transaction / transactionId        | accountId                                                                     | account                                  |
| transaction / transactionId        | cardId                                                                        | card                                     |
| transaction / transactionId        | originalTransactionId, transactionRelations                                   | transaction                              |
| statement / statementId            | includedTransactionRefs                                                       | transaction                              |
| obligation / obligationId          | statementId                                                                   | statement                                |
| obligation / obligationId          | settlements                                                                   | transaction                              |
| allocation / allocationId          | releaseEvidence                                                               | transaction                              |
| recurringPlan / planId             | cardId                                                                        | card                                     |
| recurringPlanRevision / revisionId | cardId                                                                        | card                                     |

응답 종류에 없는 배열에는 표식을 만들지 않는다. 다른 사용자 자원은 not_connected로 설명하거나 ID를 공개하지 않으며 기존 인증·소유권 오류로 처리한다. 실제 미상 null·권한 있는 미확보·다음 페이지 상태를 이 표식으로 바꾸지 않는다.

확장은 등록 표·타입·서버/FakeRepository 검증 벡터를 함께 갱신한다. 미지원 schemaVersion 또는 등록되지 않은 ownerType/field/targetKind 조합은 계약 오류로 처리한다. 이를 무시하고 정상 계산을 계속하거나 임의로 response 전체의 제한으로 바꾸지 않는다. 전달 규격이 바뀌면 schemaVersion도 갱신하며, 여러 구현이 같은 타입 정의·허용 조합·입출력 벡터를 사용한다. 전역 가변 저장소나 특정 화면에 종속된 분기 대신 요청별 userId·현재 상태·원본을 입력으로 받는 변환 책임을 둔다. 라이브러리·구체 클래스 선택은 담당 구현에서 정한다.

### 2.2 거래 공개 기준 — 사용자 확정

| recordKind                                    | 공개에 필요한 원천 연결 | 반대쪽 참조 처리                                                                              |
| --------------------------------------------- | ----------------------- | --------------------------------------------------------------------------------------------- |
| account_entry                                 | accountId의 은행 연결   | 미연결 카드의 cardId는 생략+제한 표시. 카드 연결만으로 은행 입출금을 공개하지 않음            |
| card_purchase, card_refund, card_cancellation | cardId의 카드사 연결    | 미연결 은행의 accountId는 생략+제한 표시. 은행 연결만으로 카드 구매·환불·취소를 공개하지 않음 |

recordKind·원천 계좌/카드의 소유자·기관을 검증한 뒤 공개 여부를 판정한다. 주 원천 참조가 실제로 없거나 모순되면 공개 기준을 추정하지 않고 계약 오류로 처리한다. 원천은 연결됐지만 반대쪽 참조가 원래 미상이면 null을 유지한다. originalTransactionId·relatedTransactions·관계의 양 끝에도 동일한 거래 공개 기준을 적용한다. 부분 연결 후 사용자 선택 included는 이 판단에 쓰지 않는다. 확보된 거래에는 위 원천 필드 검증을 적용한다. 실제 미확보 원거래는 원천 관계에 대해 검증된 사용자·기관 근거가 있을 때만 공개 가능한 ID로 유지한다. 거래가 미확보라는 이유만으로 공개 권한까지 추정하지 않는다. 소유/기관 근거가 없어 권한을 판정할 수 없으면 503으로 실패하며, 임의 not_connected 표식·가짜 원거래·null로 대체하지 않는다. 기존 `refund-unavailable-original`의 referenceResolutions는 ID/상태/사유만 제공하므로 이 항목만으로 기관 권한 검증을 완료했다고 볼 수 없다. 후속 adapter가 그 미확보 ID를 정상 응답에 포함하려면 검증 가능한 원천 관계 근거를 확인해야 한다. 근거를 확보하지 못한 상태의 오류 처리는 허용되며 이번 결정이 원본 fixture 수정이나 전체 기관 강제 연결을 요구하지 않는다.

### 2.3 종속 참조 처리

제한된 자원에 의존하는 계산/편집만 보류한다. 금융 원천이 없는 것처럼 0원·미지급·관계 없음으로 확정하지 않는다. 미연결 은행을 자동 연결하거나 전체 기관 연결을 강제하지 않는다.

| 상황                                                                        | 공개·제한 규칙                                                                                                                                                         |
| --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 카드 연결, 출금 은행 미연결                                                 | Card의 다른 허용 필드는 유지. withdrawalAccountId 키를 생략하고 ownerType=card, ownerId=공개 cardId, field=withdrawalAccountId, targetKind=account로 표시              |
| 원래 카드 출금 계좌가 미상                                                  | withdrawalAccountId=null. not_connected 제한을 만들지 않음                                                                                                             |
| 공개 거래의 cardId/accountId/originalTransactionId가 미연결 자원을 가리킴   | 해당 필드를 생략하고 공개 transactionId 부모의 제한으로 표시. 실제 원천 미상 null과 구별                                                                               |
| 공개 의무의 statementId 또는 공개 계획·버전의 cardId가 미연결 자원을 가리킴 | 해당 필드를 생략하고 공개 부모 ID의 제한 표시. 숨겨진 청구/카드를 임의 생성하지 않음                                                                                   |
| 급여 계좌가 미연결                                                          | settings.salary.salaryAccountId와 해당 계좌를 노출하는 receiptEvidence를 생략, 각각 settings/null 부모의 제한으로 표시. 나머지 사용자 설정을 원천 미상으로 바꾸지 않음 |
| 의무·보호·계획의 주 계좌가 미연결                                           | 해당 객체 전체와 그 객체에 종속된 배정/회차/결정 행을 생략. 최상위 해당 배열의 제한을 ownerId=null로 표시                                                              |
| 배정·정산·계획 버전·회차·결정의 필수 부모가 위 규칙으로 숨겨짐              | 자식 행도 생략하고 해당 공개 배열 제한 표시. 부모를 노출하거나 고아 자식을 남기지 않음                                                                                 |
| 공개 의무의 정산 거래 또는 청구의 포함 거래가 미연결                        | 부모 객체 유지, 해당 참조/관계 항목을 생략하고 공개 부모의 해당 필드에 제한 표시. 합계가 완전하다고 판정하지 않음                                                      |
| 이체/카드-계좌 관계 중 한쪽이 미연결                                        | 관계 행을 생략. 공개된 쪽 거래의 관계 제한으로 표시. 상대 ID·evidenceRef를 유출하지 않음                                                                               |
| 권한은 있지만 다음 페이지에 있는 거래                                       | ID 참조 유지. not_connected/unavailable로 바꾸지 않음. 페이지 완료까지 미수신으로 관리                                                                                 |
| 권한은 있으나 실제 원천 미확보                                              | 기존 referenceResolutions/coverage의 근거 있는 누락 표현. 연결 제한과 구별                                                                                             |

settings.cardPlans는 미연결 카드의 항목만 생략하고 settings/null/cardPlans 제한으로 표시한다. 급여 근거에 비공개 거래가 있으면 salary.receiptEvidence 키를 생략하고 제한을 표시한다. 확인 상태를 confirmed/partial/unknown으로 임의 변경하지 않는다. Allocation의 부모가 모두 공개돼도 releaseEvidence가 비공개 정산 거래를 드러내면 그 키를 생략하고 transaction 제한을 표시한다. 이미 확인된 releasedKRW를 0으로 바꾸거나 해제 취소로 해석하지 않는다.

RecurringDecision의 승인 계획 또는 근거 거래, 계획 버전/개별 회차의 필수 계획·출금 계좌, OccurrenceLink의 명시된 참조 중 하나라도 비공개이면 해당 행 전체를 생략한다. 이미 공개된 부모·자식 객체의 ID/수치/상태는 새로 추정하지 않는다. obligations/recurringPlans/reserves는 주 계좌를 먼저 검사하고 필수 부모에 대한 종속 생략을 반복 적용하여 고아 참조가 남지 않게 한다. 연결 범위 밖 참조를 referenceResolutions에 다시 넣어 우회 공개하지 않는다.

관계 노출은 **참조 전체에 같은 규칙**을 적용한다. 카드·청구·거래 원거래·급여 증거·배정·정산·월간 계획 버전·회차 연결·sourceRef/evidenceRef를 검사한다. 숨긴 부모를 가리키는 고아 자식만 반환하지 않는다.

부분 연결에서 settings.salary의 제한된 두 필드는 다른 필드와 구별되는 상태로 mapper에 전달한다. accountId가 필수인 내부 정상 모델에 억지로 null을 대입하지 않는다. 화면은 ‘연결 정보 필요’ 상태를 표현할 수 있어야 한다. UI 문구 자체는 API 계약이 아니다.

연결/계좌 선택이 달라지면 dataVersion이 바뀌므로 기존 cursor와 페이지 누적을 폐기한다. **홈 included=false는 접근 제한이 아니다.** 연결된 미선택 계좌·카드의 연간 거래는 계속 제공한다.

### 2.4 부분 연결 예시와 실패 처리

아래는 **위치 표식만 발췌한 명세 예시**다. 완전한 Snapshot/거래 객체가 아니며 실제 API 실행 결과도 아니다. 공개 카드 ID가 `11111111-1111-4111-8111-111111111111`이고 그 출금 은행이 미연결이면 첫 표식이 해당 카드의 생략된 withdrawalAccountId를 설명한다. 급여 계좌도 미연결이고 그 계좌의 보호 설정이 숨겨진 예시를 함께 보인다.

```json
{
  "accessRestrictions": [
    {
      "ownerType": "card",
      "ownerId": "11111111-1111-4111-8111-111111111111",
      "field": "withdrawalAccountId",
      "targetKind": "account",
      "reason": "not_connected"
    },
    {
      "ownerType": "settings",
      "ownerId": null,
      "field": "salary.salaryAccountId",
      "targetKind": "account",
      "reason": "not_connected"
    },
    {
      "ownerType": "settings",
      "ownerId": null,
      "field": "salary.receiptEvidence",
      "targetKind": "account",
      "reason": "not_connected"
    },
    {
      "ownerType": "response",
      "ownerId": null,
      "field": "reserves",
      "targetKind": "account",
      "reason": "not_connected"
    }
  ]
}
```

정상 제한 응답은 기존 GET의 200이다. 200의 제한 표식은 인증 실패·원천 오류를 감추는 용도가 아니다. 토큰/소유권/버전/잘못된 요청은 [기존 API 오류](api-contract.md#6-오류-응답)를 유지한다. 조립 실패·타임아웃은 기존 503으로 처리한다. 서버가 생성할 수 없는 계약(원천 분류 모순·등록되지 않은 제한 조합·숨김 정보 잔류)도 503 TEMPORARILY_UNAVAILABLE로 실패시키고 내부 원문을 응답하지 않는다. 구체 FakeRepository 오류 클래스는 B가 정하되 같은 실패를 성공·0원·빈 배열로 바꾸지 않는다. 요청 오류와 서버의 잘못된 응답을 같은 400으로 분류하지 않는다.

## 3. 페이지와 관계 조립

거래 본문은 페이지당 최대 100건이다. transactionId의 UUID 값 오름차순이며 금융 시간순이 아니다. 다음 자료가 있으면 nextCursor를 반환한다. 실제 조회 쿼리·인덱스는 후속 서버 구현에서 검증한다.

cursor는 사용자·세션·schema/data/source/ruleVersion·asOf·연결 범위·요청 달력1년 범위·마지막 UUID·페이지 크기에 묶인 검증 가능한 불투명 문자열이다. cursor에 자격·토큰·금융 원문을 넣지 않는다. 클라이언트는 해석하지 않는다.

각 응답은 한 버전의 일관된 자료를 제공한다. 변조는 400, 다른 사용자/세션의 유효 cursor는 403, 자료 버전 변경은 409다.

| 배열                                                      | Snapshot 첫 응답                                                                           | 후속 거래 페이지                                         |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| accounts/cards/statements/settings 및 확정 계획·배정·정산 | 연결 권한 내 현재 객체. 거래가 미수신이어도 공개 가능한 ID 참조 유지                       | 반복 전송하지 않음                                       |
| transactions                                              | 달력1년 원천 목록의 첫 최대 100건                                                          | 이어지는 최대 100건                                      |
| relatedTransactions                                       | 첫 거래 페이지와 반환한 확정 객체를 시작점으로 아래 참조 탐색에서 필요한 기간 밖 확보 거래 | 현재 거래 페이지를 시작점으로 필요한 기간 밖 확보 거래   |
| referenceResolutions                                      | 동일 참조 탐색에서 발견한 실제 미확보 항목                                                 | 현재 페이지에서 시작한 동일 참조 탐색의 실제 미확보 항목 |
| transactionRelations                                      | 현재 거래 페이지에 한쪽 이상 포함된 허용 관계                                              | 같은 기준. 중복은 관계 식별 튜플로 병합                  |
| occurrenceLinks                                           | 반환한 확정 의무·계획·청구와 직접 연결된 허용 근거                                         | 현재 페이지 거래를 직접 참조하는 허용 근거만             |
| coverage                                                  | 연결한 원천 전체의 확보 범위                                                               | 같은 버전 전체 범위. 페이지 다운로드 진척률이 아님       |

기간 안 참조 거래는 원래 transactions 페이지로만 내려받고 relatedTransactions로 전량 복제하지 않는다. 기간 밖 보조 거래가 다시 기간 밖 거래를 참조하면 같은 사용자·원천 버전·권한 범위에서 직접·간접 참조된 확보 거래를 각각 한 번 포함한다. 순환 참조 때문에 같은 거래를 반복 반환하지 않는다. 각 보조 거래에 붙는 실제 미확보 참조와 접근 제한도 같은 응답에 포함한다.

자료가 실제로 없을 때만 referenceResolutions의 미확보 이유를 사용한다. 처리 한도/타임아웃으로 근거 조립이 끝나지 않으면 503으로 실패하며, 전송하지 못한 근거를 원천 미확보로 바꾸거나 부분 응답을 완전 응답으로 반환하지 않는다.

보조 배열은 위 참조 탐색 범위로 줄이되 임의 상한으로 조용히 잘라내지 않는다. 100건 제한은 transactions 배열에 적용하며 보조 배열까지 합친 전체 응답 크기의 상한을 뜻하지 않는다. 후속 별도 관계 페이지가 필요하면 schema 변경으로 검토한다.

동일 transactionId/revisionId/linkId는 ID로 병합한다. revisionId는 계획 버전 자체 ID, planRevisionId는 해당 버전을 참조하는 필드이며, 정산 응답의 자체 ID는 linkId다. transactionRelations는 `(kind,fromId,toId,evidenceRef)`, occurrenceLinks는 `(recurrenceKey,purchaseTransactionId,statementId,obligationId,evidenceRef)` 튜플로 중복 제거한다. 같은 버전의 같은 ID가 다른 값이면 마지막 응답으로 덮지 말고 계약 오류로 처리한다.

달력1년의 원천 조회 범위와 소비 귀속일은 기존 [계산 기준](../../../../docs/calculation-rules.md)을 유지한다. API는 준비 원천 목록과 실제 coverage를 제공하고 월별·연간 소비를 계산하지 않는다. nextCursor=null만으로 원천 완전성/참조 확보를 판정하지 않는다.

## 4. 자원별 수정 권한

물리 저장 위치는 기존 [DB 설계](../database-design.md)를 참조하며 이번 작업은 SQL·테이블·컬럼을 변경하지 않는다.

| 자원                                                 | v0.6에서 허용하는 쓰기                                                               |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------ |
| userId/dataVersion                                   | 사용자 식별은 서버 권위, 금융 쓰기 성공 시 dataVersion 증가                          |
| sourceVersion/asOf/coverage/급여 입금 근거/회차 연결 | 사용자 원천 수정 불가                                                                |
| institutions/institutionLinks                        | 제공된 기관 중 확정 연결만 변경                                                      |
| Account                                              | included/nickname만 변경                                                             |
| Card/Statement/Transaction 및 원거래·청구 포함 관계  | 원천 읽기만 허용                                                                     |
| settings                                             | 사용자 급여·카드 계획만 변경                                                         |
| Obligation                                           | 단건 계획·이미 저장된 개별 미지급 회차의 허용 필드; 청구 원천·반복 참조 키 변경 금지 |
| Reserve/Allocation/Settlement                        | 보호·명시 배정만 변경; 지급 정정 API는 v0.9                                          |
| 반복 계획/버전/개별 회차/승인 근거                   | 기존 기록 읽기; 신규 계획 편집 경로는 후속 버전                                      |
| receipt                                              | 서버가 제공하는 공개 요약; 사용자 임의 작성 불가                                     |
| accessRestrictions/cursor                            | 조회 표현; 사용자가 금융 사실로 저장하지 않음                                        |

RecurringPlanRevision.isCurrent를 유지한다. 같은 시작 월의 이전 버전과 현재 권위 버전을 구별하고 이미 저장된 회차는 자신의 planRevisionId를 유지한다. 서버가 새 미래 회차를 열거하거나 지급 완료로 바꾸지 않는다.
