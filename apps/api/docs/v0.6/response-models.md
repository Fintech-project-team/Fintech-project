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

## 2. 부분 연결과 종속 참조

미연결 계좌·카드 ID를 연결된 객체의 FK라는 이유로 공개하지 않는다. 반대로 확인된 원천 ID를 미상 null로 덮어쓰지도 않는다. 원천 저장은 유지하고 **API 표현에서 제한 필드를 생략**한다. 아래 경우에만 정상 필수 키의 생략을 허용한다.

```text
AccessRestriction = {
  ownerType: string, ownerId: ID|null, field: string,
  targetKind: "account"|"card"|"transaction"|"statement"|"obligation"|"reserve"|"plan",
  reason: "not_connected"
}
```

- ownerId는 **이미 공개된 부모 객체**의 ID만 가능하다. settings 등 단일 묶음/전체 배열에는 null이다. field는 아래 표의 속성명/배열명이며 배열 인덱스나 숨겨진 ID를 담지 않는다.
- 이 구조에 숨겨진 대상 ID·개수·잔액을 넣지 않는다. 같은 `(ownerType,ownerId,field,targetKind,reason)`은 한 번만 보낸다.
- 제한된 자원에 의존하는 계산/편집만 보류한다. 금융 원천이 없는 것처럼 0원·미지급·관계 없음으로 확정하지 않는다. 미연결 은행을 자동 연결하거나 전체 기관 연결을 강제하지 않는다.

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

관계 노출은 **참조 전체에 같은 규칙**을 적용한다. 카드·청구·거래 원거래·급여 증거·배정·정산·월간 계획 버전·회차 연결·sourceRef/evidenceRef를 검사한다. 숨긴 부모를 가리키는 고아 자식만 반환하지 않는다.

부분 연결에서 settings.salary의 제한된 두 필드는 다른 필드와 구별되는 상태로 mapper에 전달한다. accountId가 필수인 내부 정상 모델에 억지로 null을 대입하지 않는다. 화면은 ‘연결 정보 필요’ 상태를 표현할 수 있어야 한다. UI 문구 자체는 API 계약이 아니다.

연결/계좌 선택이 달라지면 dataVersion이 바뀌므로 기존 cursor와 페이지 누적을 폐기한다. **홈 included=false는 접근 제한이 아니다.** 연결된 미선택 계좌·카드의 연간 거래는 계속 제공한다.

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
