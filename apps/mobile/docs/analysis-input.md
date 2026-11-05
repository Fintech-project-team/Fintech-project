# 분석 입력과 입력 지문 (분석 연동 2단계)

- 작성: 2026-11-05 · B(hyeyeonso) · 작업 명세 `docs/tasks/PAYSE-MOBILE-ANALYSIS-INPUT-20261105.json`
- 상위 기준: [Java·Dart 분석 연동 합의](../../../docs/analysis-protocol.md) §1·§2·§4, [분석 HTTP 계약](../../api/contracts/analysis-http.schema.json), [분석 API](../../api/docs/analysis-api.md), [공유 반복 계산](../../../packages/payse_calculation/docs/recurring.md)

## 1. 완료 범위와 한계

| 구분    | 내용                                                                                                                                         |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 구현    | 스냅샷 → 공유 반복 계산 입력, 반복 후보 → `recurringMeaning` 분석 입력, 접수 본문(멱등 키 제외), 입력 지문 `inputHashHint`                   |
| 대조    | 공동 지문 사례 30개의 중간값 전부, v4 더미 전체의 입력·접수 본문을 HTTP 계약 스키마로 검사                                                   |
| 범위 밖 | 멱등 키·HTTP 호출·작업 추적·기기 저장·앱 복귀(3단계), 거래 의미(`transactionMeaning`) 입력 만들기, 승인 화면, `expandRecurring`·홈 계산 연결 |

`inputHashHint`는 서버 `analysisInputHash`가 아니다. 권한 확인·결과 재사용 판단에 쓰지 않는다.

## 2. 구조

```text
lib/data/analysis/recurring_source.dart          recurringInputFromSnapshot: 스냅샷·전체 거래·조회 범위 → calc.RecurringInput
lib/data/analysis/recurring_analysis_input.dart  planRecurringAnalysis: 탐지 결과 → 분석 묶음(input·accept·지문·itemKey 대응표)
lib/data/analysis/analysis_identity.dart         canonicalJson·canonicalDigest·identifyAnalysisInput (PAYSE-IDENTITY-1)
```

반복 판정·금액·일자는 공유 `calc.detectRecurring`이 계산한다. 앱에는 같은 규칙을 다시 두지 않는다.

## 3. 스냅샷 → 반복 계산 입력

입력 거래는 같은 `dataVersion`으로 모든 페이지를 받은 결과다(`TransactionHistoryReady` 또는 `hasMoreTransactions=false`인 스냅샷).

| 원천                                | 반복 계산 종류   | 날짜                                                 | 확정                |
| ----------------------------------- | ---------------- | ---------------------------------------------------- | ------------------- |
| `account_entry` · `out`             | `accountOutflow` | `withdrawalDate`(기장일 대체 없음)                   | `posted`            |
| `account_entry` · `in`              | `other`          | `bookingDate`                                        | `posted`            |
| `card_purchase`                     | `cardPurchase`   | `purchaseDate`                                       | `approved`·`posted` |
| `card_refund` · `card_cancellation` | `reversal`       | `refundDate` · `cancellationDate`, `originalId` 유지 | 같은 규칙           |

- 거래 수단은 계좌 내역=`accountId`, 카드 기록=`cardId`다. 연결 계좌·카드 전체(홈 합산 제외 계좌 포함)를 넘긴다.
- 제외 사유는 명시 근거만 쓴다. `internal_transfer` 관계·분류는 본인 이체, `card_payment` 분류는 카드대금, `card_account_pair`로 카드와 같은 사건이 확인된 계좌 내역은 중복(카드 쪽을 남김)이다. 금액·날짜가 같다는 이유로 제외하지 않는다.
- 조회 범위는 `complete`, 그리고 빈 구간이 적힌 `partial`에서 빈 구간을 뺀 나머지만 완료로 둔다. 빈 구간을 모르는 `partial`과 `failed`·`unconnected`는 미완료다.
- `decidedCandidateKeys`는 호출자가 넘긴다. 앱 스냅샷 모델은 아직 `recurringDecisions`를 읽지 않으므로 첫 연결 뒤에는 빈 목록이다.

## 4. 분석 입력과 접수 본문

- `context`: `schemaVersion=PAYSE-API-0.6-4`, 스냅샷의 `dataVersion`·`sourceVersion`·`ruleVersion`·`asOf`(기기 시각으로 바꾸지 않음), 호출자가 넘긴 `inputRevision`·`localSessionEpoch`, 홈 합산 계좌 ID 정렬 목록.
- 후보마다 직접 근거를 원거래·관계 양끝으로 넓힌 거래를 모두 넣는다. 서버는 닿는 원거래·관계 상대를 모두 받아야 검증하므로, 하나라도 보낼 수 없으면 그 후보는 보내지 않는다(5절).
- `currentClassifications`는 보내는 거래 중 `payseTransactionType`이 있는 것만 넣는다. 후보의 `ruleVersion`·`sourceVersion`은 `context`와 같다.
- `itemKey`는 묶음 안 순번 `recurring-N`이고 `candidateByItemKey`로 앱 후보 키에 되돌린다. 접수 `candidateIds`는 `[candidateKey]`다.
- 접수 본문은 `context`, `triggerKind`, `semanticTaskKind`, `items`, `inputHashHint`, `reasonCodes=[]`까지 만든다. `idempotencyKey`·`previousJobId`는 3단계가 붙인다.

## 5. 그룹·나누기와 보내지 못한 후보

- 넓힌 근거가 하나라도 겹치는 후보는 연쇄로 한 그룹이다(a–b, b–c면 a·b·c). 그룹은 쪼개지 않고 한 작업에 넣는다. 독립 근거 그룹만 별도 작업이다([분석 API](../../api/docs/analysis-api.md) §3, [LLM 실행](../../api/docs/llm-execution.md) `ai.shard.*`).
- 한 묶음은 후보 20개·거래 60개(중복 제거) 이하다. 그룹을 첫 후보의 `candidateKey` 순으로 채우다 넘으면 새 묶음을 시작한다. 같은 입력은 항상 같은 그룹·묶음 순서를 만든다. `ai.job.maxShards`는 미확정 제안이라 적용하지 않는다.
- 보내지 못한 후보는 `notAnalyzed`에 사유·원인 거래·그룹 후보 키와 함께 둔다. 이번 준비 결과에만 담고 영구 제외로 저장하지 않으며, 0개나 분석 실패로 바꾸지 않는다.

| 사유                     | 뜻                                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `groupTooLarge`          | 그룹 전체가 후보 20개 또는 거래 60개를 넘는다. 그룹의 후보 전부에 붙인다                                    |
| `transactionNotReceived` | 근거에 닿는 거래(관계 상대 포함)를 이번 조회에서 받지 못했다. 일시적이며 다시 조회하면 풀릴 수 있다         |
| `originalUnavailable`    | 서버 `referenceResolutions`가 원거래를 `unavailable`로 명시했다. `serverReason`에 서버 사유 원문을 보존한다 |
| `sourceFieldMissing`     | 근거 거래에 필수 원천 필드(`reflectionReason`)가 없다. v4 파서가 먼저 거절하므로 앱 내부 방어용이다         |
| `groupMemberHeld`        | 이 후보는 문제가 없지만 같은 그룹의 다른 후보를 보낼 수 없어 함께 보류한다                                  |

- 여러 사유가 겹치면 서버 명시 미확보 → 미수신 → 필드 누락 순으로 하나를 고른다.
- 후보가 없으면 묶음을 만들지 않는다. 정상 0개인지는 탐지 결과의 `completeWithoutCandidates`로 따로 판단한다.

## 6. 접수 기준 (2026-11-05 확정)

[실행 계약](../../../docs/payse-execution-contract.md)·분석 API·서버 코드·테스트를 대조해 정했다.

| 상황                          | 처리                                                             |
| ----------------------------- | ---------------------------------------------------------------- |
| 연결 저장 뒤 처음 공개된 범위 | `triggerKind: "A"`(EX-A)로 접수                                  |
| 같은 연결·같은 근거를 다시 봄 | EX-R. 새 접수 없이 `/analysis-results/query`로 저장 결과 조회    |
| 홈 합산 계좌 선택만 바꿈      | EX-AC. 새 접수·AI 호출 0회. 홈 선택과 전체 연결 분석 범위는 독립 |
| 새 연결로 공개 범위가 늘어남  | 늘어난 범위만 EX-A로 접수                                        |

## 7. 3단계 참고: 만료 처리

3단계 작업 추적의 기준이다. 구현은 [분석 작업 추적](analysis-tracking.md)에 있다. 근거는 `AnalysisJobs.effectiveState`·`status`와 `AnalysisHttpTest.expiresPermitAndExecutionWindow`다.

| 경우                           | 서버 응답                                          | 앱 처리                                                                                            |
| ------------------------------ | -------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 제출 허가 60초 지남(실행창 안) | 상태 재조회 시 새 `permit` 발급, 실행창은 그대로   | 다시 조회해 새 허가로 제출. 사용자 조작 없음                                                       |
| 180초 실행창이 제출 전에 끝남  | `failed`·`action: retry`, 허가 없음, 모델 호출 0회 | 분석 미완료(G)·다시 시도. 누르면 새 멱등 키로 `/retry`, 새 180초 창 시작                           |
| 3개월 작업 식별 기한 지남      | `expired`·`action: refreshInput`                   | 사용자 복구 동작에서만 `triggerKind: "recovery"`·`previousJobId`로 새 접수. 기한 전 recovery는 409 |

- 같은 요청의 전송 재확인은 같은 멱등 키, 사용자의 새 재시도는 새 키다.

## 8. 검사

| 테스트                                                  | 내용                                                                                                                                                                                             |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `test/data/analysis/analysis_identity_test.dart`        | 공동 사례 30개의 canonicalEvidence·memoryKey·evidenceHash·canonicalHint·inputHashHint, sameHintAs, 중복 대상, 정수 외 숫자 거절                                                                  |
| `test/data/analysis/recurring_analysis_input_test.dart` | v4 더미 전체의 스키마 검사·결정성, 날짜·제외·조회 범위 매핑, 20개·60개 나누기, 근거 공유 후보 한 작업(재현 사례), 연쇄 그룹, 그룹 한도 초과, 미확보 사유 구분·그룹 동반 보류, 스키마 검사기 자체 |
