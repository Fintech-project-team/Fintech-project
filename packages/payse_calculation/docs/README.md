# payse_calculation — 로컬 계산 패키지

PAYSE-CALC-1([계산 기준](../../../docs/calculation-rules.md))의 순수 Dart 구현이다. 필드 의미는 [공통 데이터 모델](../../../docs/data-model.md), 기대값은 [상세 계획 §7-1](../../../docs/references/detailed-plan-v7.source.md)의 TC-C01~12를 따른다. 이 문서는 구현 경계와 보류 항목만 적고 산식을 다시 정의하지 않는다.

## 준비와 검사

```sh
cd packages/payse_calculation
flutter pub get --enforce-lockfile
```

저장소 루트의 `node scripts/harness/run-flutter.mjs check`가 앱과 이 패키지에서 Dart 포맷·분석·테스트를 차례로 실행한다. 이 패키지의 `.dart_tool/package_config.json`이 없으면 BLOCKED다. lib는 flutter·입출력·현재 시각·난수를 쓰지 않으며 테스트만 SDK의 flutter_test를 쓴다.

## 공개 함수

| 함수                     | 용도                                                                                                                                                                                                                                     |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `calculateCurrentAmount` | 홈 U=B−E−(R−O)와 B·E·R·O·R−O, 의무별 금액·정산액(이미 나간 돈)·잔여·위치. 02-2 근거로 포함 계좌별 잔액, 보호액별 설정액·현재 구간 배정·남겨둘 금액, E+(R−O), 위치별 잔여 합계·건수, 포함 계좌 정산액 합계(2026-10-26 추가, 기존 값 불변) |
| `resolveSalaryCycle`     | t0와 월급 설정으로 정상·입금 대기·입금 정보 부족 구간                                                                                                                                                                                    |
| `projectPeriods`         | C1~C3 일 마감 시작 H·종료 H·종료 직전 A·최소 H/A, 가상 소비 반영 결과와 종료 A 차이                                                                                                                                                      |
| `assumedPayDates`        | 월급일 규칙으로 가정한 p1~p3와 말일 보정 표시                                                                                                                                                                                            |
| `scheduledPayDates`      | 홈과 같은 규칙의 p1~p3(날짜 출처 표시)와 예상 급여 입금이 불확실해지는 날짜                                                                                                                                                              |

결과는 입력의 `CalculationContext`(dataVersion·sourceVersion·ruleVersion·asOf·inputRevision)를 그대로 담는다. 입력·결과 목록은 수정할 수 없다.

## 입력 계약

- 금액은 정수 원이다. 잔액·합계·H·A·차이는 ±9,000,000,000,000원, Money는 0 이상, 배정·정산·가상 소비는 1 이상이다. 각 입력과 덧셈·뺄셈마다 검사하고 넘으면 `amountOutOfRange` 오류다.
- 날짜는 YYYY-MM-DD, 시각은 오프셋이 필요하다. t0는 asOf의 서울 날짜다. 달력 n개월 뒤는 원래 기준일에서 한 번에 더하고 없는 날은 말일이다.
- 목록의 null은 미확인이라 영향 값이 null·`insufficient` 사유가 되고, 빈 목록은 확인된 0건이다.
- B는 included 계좌만 더한다. 포함 계좌가 없거나 잔액·asOf가 없거나 asOf 시각이 다르면 B는 null이다.
- 정산은 invalidatedAt이 null인 연결의 allocatedKRW만 의무에서 뺀다. 거래 금액·날짜로 자동 연결하지 않는다. 중복 연결·의무별 초과 정산·없는 참조는 오류다. 거래별 배분 합계·출금 계좌 일치는 거래 금액이 입력에 없어 검사하지 않으며 #28 어댑터 책임이다.
- R은 포함 계좌의 미취소 보호액이다. O는 현재 E 의무와 R 보호액 사이 미해제 배정(amountKRW−releasedKRW) 합계다. 의무 잔여·보호액을 넘는 배정은 잘라내지 않고 `overAllocation` 오류다.
- 월급 근거는 payMonth(명목 회차, YYYY-MM)로 회차에 연결한다. 회차 예정일은 근거가 있으면 그 expectedPayDate(확인된 이동 예정일, 입금 전 unknown 근거 포함), 없으면 salaryDay 반복 월급일로 예상한 경계다. 예상 경계는 원천 근거를 만들어 채운 것이 아니며(상태 absent) 입금 완료로 보지 않고 잔액에 더하지 않는다. unknown 근거도 경계로만 쓴다. 휴일 보정은 하지 않는다. payMonth와 예정일 사이 기간은 제한하지 않는다. 현재(직전) 회차는 예정일 ≤ t0인 회차 중 가장 큰 payMonth(모든 근거 회차 포함)다. 다음 경계는 그보다 뒤 회차의 예정일(같은 회차는 원천 근거 날짜만, 근거가 없으면 반복 설정 날짜) 중 t0 이후 가장 먼저 도래하는 날짜이며 이동한 날짜의 달에 1을 더하지 않는다. 날짜 출처(원천 근거·반복 설정)와 입금 상태(confirmation)는 따로 본다. 같은 payMonth 근거 중복은 `duplicateId` 오류다. 서로 다른 회차의 예정일이 같으면 그날 회차의 입금이 모두 확인된 경우만 계산하고, 길이 0 구간이나 회차 구분이 필요한 현재 구간만 `payDateConflict`로 제한한다. 늦게 입금된 과거 회차 때문에 현재 회차를 되돌리지 않는다. 회차별 근거는 absent(항목 없음)·unknown·partial·confirmed로 구분한다. 다음 회차가 confirmed면 확인 시점부터 그다음 월급일까지 구간으로 전환하고, 아니면 직전 회차가 confirmed일 때 정상, unknown·partial일 때 입금 대기, absent일 때 입금 정보 부족이다. confirmed 근거 거래가 asOf 잔액에 반영된 posted 입금이라는 계약은 #28 어댑터가 검증한다.
- 정상 구간 E는 출금 계좌가 포함 계좌인 활성 미정산 의무 중 dueDate<구간 끝(연체 포함)이다. 입금 대기에서는 급여일 당일·연체(dueDate<t0) 의무만 반영 대기로 두고 나머지는 D5의 이전 구간 유지에 따라 구간 밖이다. '대기 중 E는 0'이라는 별도 규칙은 없고 이전 구간 의무가 모두 연체라 결과적으로 0이 된다. confirmed 입력에서는 obligationId 한 집합으로 한 번만 넣는다.
- 출금 계좌가 제외 계좌인 의무는 E·대기·구간 계산에서 빼고 `excludedAccount`(구간 계산은 `excludedAccountObligationIds`)로 따로 반환한다. 포함 계좌에서 송금한다고 가정하지 않으며 U를 null로 만들지 않는다. 출금 계좌가 연결 계좌 목록에 없으면 `unknownReference` 오류다.
- 구간 계산은 cap=min(p3, t0+달력3개월), 오른쪽 끝 제외다. 의무는 dueDate에, 즉시출금은 구매일에, 카드 일시불은 확인된 출금일에 현금 이벤트가 된다. A의 예약은 '해당 주기 끝까지 남은 지출 예약'(상세 계획 190행)으로 같은 구간에서 그날 이후 남은 출금과 연체 미지급 잔여다. 가상 출금 때 H 감소와 예약 해제를 함께 처리하고, 그 의무에 연결된 미해제 배정 중 출금액만큼만 R을 해제한다. 이 해제는 구간 계산 안의 값이며 `calculateCurrentAmount`의 R·O·U와 입력 객체를 바꾸지 않는다.
- 가상 소비는 출금일과 귀속 구간이 모두 정해지면 `reflected`, 출금일은 정해졌지만 월급일 정보가 없어 구간을 못 정하면 `periodUndetermined`, 출금일 미상은 `scheduleUnknown`, 상한 이후는 `outOfRange`다. 같은 구간에 여러 정보 부족 사유가 걸리면 모두 남긴다.
- 시각 없는 같은 날 입금·출금은 `DayOrderWarning`으로 표시하고 최소값은 일 마감 값만 쓴다.

## TC 대응

원래 완료 조건은 #27 본문과 [상세 계획](../../../docs/references/detailed-plan-v7.source.md) 588행의 'TC-C01~12 모두 검증'이다. 이번 범위는 아래처럼 C05·C07이 부분 충족이라 #27 전체 완료가 아니다.

| TC        | 테스트                                                | 충족                                                                                                         |
| --------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| C01~04    | `current_amount_tc_test.dart`                         | 원문 기대값 전체                                                                                             |
| C05       | `current_amount_tc_test.dart`                         | 부분. B 유지만. 미충족 '수입·소비로 집계하지 않음'(§7-1 605행) → #59 연간 순소비의 내 계좌 이체 제외, B 검증 |
| C06, C08  | `projection_tc_test.dart`                             | 원문 기대값 전체                                                                                             |
| C07       | `projection_tc_test.dart`                             | 부분. 일 마감 H·경고만. 미충족 '최초 부족 시점·최대 부족액에 넣지 않음'(607행) → #34 부족 지표와 함께 B 검증 |
| C09       | 두 TC 파일                                            | 말일 보정·카드일 불명 null·연체 유지                                                                         |
| C10~12    | `current_amount_tc_test.dart`                         | 원문 기대값 전체                                                                                             |
| 경계 사례 | `boundaries_test.dart`·`projection_reasons_test.dart` | 배정·정산 한도, 월말·윤년·끝점, 전환 중복·대기 분류, 누락, 한도, 순서·불변, 구간 가정 분리                   |

## 결정 사항과 남은 질문

2026-10-23 사용자 결정. 더미 구성은 근거로 쓰지 않았다.

| ID   | 결정·현재 동작                                                                                  | 코드                                                            | 결과·사유 코드                                                 | 테스트(`boundaries_test.dart`)          |
| ---- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------- |
| Q1   | 직전 회차 근거 항목 없음은 입금 정보 부족. 정상 입금·명시 대기로 추정하지 않음                  | `salary_cycle.dart` `SalaryReceiptStatus.absent` 분기           | E·O·rEff·U·미정산 의무 placement null, `receiptEvidenceAbsent` | Q1, 근거 상태 구분                      |
| Q2-1 | 2026-10-26 로컬 반영(#92): payMonth로 회차를 식별하고 이동 예정일을 그 회차 경계로 사용         | `salary_cycle.dart` `SalarySchedule`                            | 정상 계산. 같은 날짜 모호 구간만 `payDateConflict`             | Q2-1 해결, `salary_month_test.dart`     |
| Q2-2 | 규칙 날짜와 같은 다음 회차가 confirmed면 확인 시점부터 다음 구간. partial·unknown이면 기존 구간 | 같은 파일 `nextStatus == confirmed` 분기                        | 정상 구간, periodStart null                                    | Q2-2 그룹                               |
| Q3   | 제외 계좌 출금 의무는 E·구간 계산에서 빼고 따로 반환                                            | `current_amount.dart` `_placement`, `projection.dart` 제외 분기 | `excludedAccount`, `excludedAccountObligationIds`              | 제외 계좌 의무(Q3) 그룹                 |
| Q4   | 대기 분류는 날짜 기준(급여일 당일·연체). 금액 영향 없음                                         | `current_amount.dart` `salaryDayOrOverdue`                      | 없음                                                           | `current_amount_tc_test.dart` 대기 대상 |
| Q5   | 가상 출금 때 그 의무에 연결된 미해제 배정 중 출금액만큼만 R 해제                                | `projection.dart` `linked`·`release`                            | 없음                                                           | Q5 그룹, 구간 가정 분리                 |

## 입금 확인 시점과 입력 전제

- **판정 근거.** 확인 전후는 `SalaryReceipt.confirmation` 값으로만 나눈다(`lib/src/salary_cycle.dart`의 `statusOf`·`nextStatus == confirmed` 분기). 계산은 근거 거래의 `occurredAt`·`bookingDate`나 다른 시각을 읽지 않는다. 계약에도 급여 확인 시각 필드는 없다. data-model의 근거 거래 규칙('posted 계좌 입금이며 잔액에 반영된 사실')과 `balanceReflected`(같은 sourceVersion·잔액 asOf 기준)는 asOf까지 반영됐다는 사실만 보장하며, 정확한 확인 시각을 뜻하지 않는다.
- **계산의 전제.** 계산기는 '전달된 근거가 그 asOf에 유효한 상태'라는 전제로만 계산한다. 더 나중의 confirmed 상태를 과거 asOf와 함께 넘기면 확인 전 상태를 복원하지 못한다(`boundaries_test.dart` '입력 전제' 테스트가 그 결과를 기록).
- **테스트 성격.** Q2-2 테스트는 confirmation을 unknown·partial·confirmed로 바꿔 넣는 상태별 동작 검증이다. 확인 시각 판정은 검증하지 않는다.
- **구간 시작일.** 조기 전환 구간의 `periodStart` null은 표시용 메타데이터다. 홈 E는 구간 끝만 쓰고(연체는 시작일과 무관하게 포함) 일수 계산이 없다. 구간 계산(`projectPeriods`)은 SalaryCycle을 쓰지 않고 t0와 p1~p3로 경계를 정한다. 같은 의무로 계산한 정상 구간 결과와 E·U·의무 배치가 같음을 테스트로 확인했다. 확인 시각을 만들어 넣지 않는다.
- **근거 목록 미수신.** 접근 제한 등으로 receiptEvidence를 받지 못하면 `null`을 넘긴다. 결과는 `receiptEvidenceUnavailable` 정보 부족이며, `[]`(확인된 근거 없음, Q1)과 구분한다.

#28 어댑터 책임:

1. 같은 스냅샷(동일 asOf·sourceVersion·dataVersion)의 receiptEvidence만 넘긴다. 다른 시점의 근거 상태를 섞지 않는다.
2. partial·confirmed 근거의 transactionIds가 그 스냅샷 거래에 있고, posted 계좌 입금이며 `reflectionReason=reflected`인지 확인한다. 어긋날 때의 처리(입력 오류 또는 정보 부족)는 #28에서 정한다.
3. 접근 제한으로 생략된 receiptEvidence·의무·보호액·배정·정산은 `[]`가 아니라 `null`로 넘긴다.
4. 정산 연결을 넘기기 전에 거래 단위 제약을 확인한다. 이 패키지는 거래 금액을 받지 않아 의무별 정산 합계만 검사하므로, 아래는 어댑터가 확인하고 거절 테스트를 둔다.
   - 같은 거래에 연결된 유효 allocatedKRW 합계 ≤ 그 거래의 실제 출금액(예: 100,000원 출금을 두 의무에 80,000원씩 연결하면 거절).
   - 거래의 출금 계좌가 의무의 withdrawalAccountId와 같다(data-model §4).
   - 근거 거래가 같은 스냅샷의 posted 계좌 출금(account_entry·out)이며 evidenceRefs가 있다.
5. 정상 시나리오 더미(alpha-ready·beta-ready·gamma-month-end)는 receiptEvidence가 비어 있어 그대로 연결하면 Q1로 U가 null이다. 직전 회차의 명시 급여 근거가 필요하다(A와 확인).

## #92 급여 회차: 현재 구현된 동작

진행 상태: v3 모바일·계산 패키지 대응은 로컬 구현·검증까지 했고 API 연동·통합 검증은 대기 중이다. v3 전체나 #92가 끝났다는 뜻이 아니다.

PAYSE-DRAFT-3/PAYSE-API-0.6-3의 `SalaryReceipt.payMonth`로 Q2-1을 풀었다(docs/data-model.md '급여 회차와 예정일').

- 회차 예정일은 원천 근거가 있으면 그 expectedPayDate(입금 전 unknown 근거 포함), 없으면 salaryDay 반복 설정으로 예상한 날짜다. 예상 날짜를 근거로 만들거나 입금 완료로 보거나 잔액에 더하지 않는다. 휴일 보정은 하지 않는다. payMonth와 예정일 사이 기간은 제한하지 않는다.
- 현재(직전) 회차는 예정일 ≤ t0인 회차 중 가장 큰 payMonth다. 늦게 입금된 과거 회차 때문에 되돌리지 않는다.
- 다음 경계는 현재 회차보다 뒤 회차의 예정일 중 기준 시점 이후 가장 먼저 도래하는 날짜다(`SalarySchedule.earliestAfter`). 홈(`resolveSalaryCycle`)과 구간 계산(`scheduledPayDates`→`projectPeriods`)이 같은 규칙을 쓰고 D5도 그 날짜에 적용한다. 명목상 다음 회차(payMonth+1)와 다음 계산 경계는 구분한다. `SalaryCycle.nextPayDate`는 계산 경계 회차이며 날짜 역전 때는 payMonth+1이 아닐 수 있다.
- `PayDateBasis`는 날짜 출처(`sourceEvidence`·`recurringSetting`)이고 입금 상태는 `confirmation`이다. 원천 근거도 unknown일 수 있다.
- 같은 payMonth 근거 중복은 `duplicateId` 오류다. 서로 다른 회차의 예정일이 같으면 그날 회차의 입금이 모두 확인된 경우만 홈을 계산하고, 길이 0 구간이나 회차 구분이 필요한 현재 구간만 `payDateConflict`로 제한한다.
- 예정일 전에 confirmed인 회차는 이미 잔액에 있어 경계·입금으로 다시 넣지 않는다(Q2-2 조기 전환과 같은 의미). 근거 예정일이 말일 보정한 규칙 날짜와 같으면 말일 보정 표시를 유지한다.
- 구간 계산의 예상 입금: 단일 경계 회차에는 설정 월급 S를 넣는다(회차별 실제 금액 확인이 아님). `scheduledPayDates.uncertainFrom`은 경계로 쓰이지 않고 남은 미확인 회차의 예정일(지났으면 t0), 같은 날 여러 회차가 예정된 경계일, partial 회차 예정일 중 가장 이른 날이다. `ProjectionInput.salaryUncertainFrom`으로 넘기면 그날이 든 구간부터 H·A·최소값을 두지 않고 `salaryInflowUncertain`을 남긴다. 현재 회차가 confirmed가 아니면 C1부터 정보 부족이다.
- 예정일 전에 여러 회차가 연속으로 confirmed면 홈도 입금 전인 첫 회차의 예정일까지 건너뛴다(예: 10/20에 10월분·11월분 confirmed면 홈 종료 12/25). 이미 잔액에 든 급여를 다시 더하지 않는다.
- 가상 소비의 `reflected`는 출금일과 귀속 구간을 찾았다는 뜻이다. 그 구간이 정보 부족이면 귀속은 유지한 채 그 구간 금액과 구매 전후 차이가 null이다. 계산 성공 여부는 `reflected`만으로 판단하지 말고 해당 구간의 `insufficient`와 금액을 함께 확인한다.
- 앱은 아직 `projectPeriods`를 호출하지 않는다. 구간 계산 쪽 동작은 이 패키지 테스트로만 검증했다.
- 회귀 테스트: `salary_month_test.dart`(이동·사전 제공 이동 예정일·같은 예정일·날짜 역전·기간 무제한·월급일 변경), `salary_simulation_test.dart`(역전·같은 날·조기 지급 사례 1~4, partial, 현재 회차 선행조건), `boundaries_test.dart` Q2-1·중복.

## 향후 소비 시뮬레이션의 미결 정책(논의 중, 확정 요구사항 아님)

구매 시점·구매 후 가용 금액 화면을 위해 논의 중인 항목이다. 아래는 결정되지 않았고 위 현재 동작을 바꾸라는 뜻이 아니다. 추가 동작 변경은 결정과 별도 승인 뒤에 한다.

1. 계산할 수 없는 범위: 불확실한 날짜가 든 구간 전체를 막을지, 그 전날까지는 보일지.
   - 현재 동작: 현재 잔액이 확인됐어도 과거 미확인 급여 하나로 미래 비교 전체가 제한된다. 예를 들어 7월분 unknown과 10월분 confirmed가 있는 10/26 조회는 `uncertainFrom`이 10/26이라 C1부터 정보 부족이다. 오래됐다는 이유로 무시하거나 제한을 완화하는 동작은 정책 결정 뒤에 구현한다.
2. 불확실한 월급: '계산할 수 없음'으로 둘지, '들어오지 않는 것'으로 보고 보수적으로 보일지.
3. 현재 회차 입금 확인 전(월급날 당일 등): 시뮬레이션 전체를 막을지, 월급 없이 계산한 결과를 안내와 함께 보일지.
4. 구매일(카드는 결제일)이 계산할 수 없는 구간에 있을 때 결과를 숨길지, 이유만 보일지.
5. 사례별 화면 안내 문구.
6. 회차별 월급 금액 계약(같은 날 여러 회차·partial 잔여분 계산용). A와 협의가 필요하다.

## A 측 확인 대기(실제 응답·공동 fixture)

- 실제 조회 응답(PAYSE-API-0.6-3)에 입금 전 이동 예정일이 receiptEvidence(confirmation=unknown, transactionIds=[])로 실리는지와 접근 제한 때 부모 생략·표식이 유지되는지.
- 입금 전 이동 예정일(예: 10/29 기준 11월분 10/30) 공동 fixture. 지금은 모바일 테스트 입력으로만 검증했다.
- 같은 예정일·날짜 역전·기간이 먼 지연 사례의 공동 fixture와 API 검증기·DB 저장 동작 대조.
- 정상 ready 사례 세 개의 직전 회차 급여 근거 보완(#96). 반영 전 공통 더미 홈은 입금 정보 부족이 정상이다.
- 회차별 금액 계약 추가 여부(미결 정책 6).
- 다음 회차 정의: 2026-10-26 A와 정책 합의 완료. 명목상 다음 회차는 payMonth+1, 다음 계산 경계는 이후 회차 중 기준 시점보다 늦고 가장 먼저 도래하는 유효한 예정일(같은 회차는 원천 예정일 우선, 없으면 반복 설정 예상)이며, 원천 근거 보존과 예정 급여의 현재 잔액 선가산 금지는 유지한다. 상태: A의 공통 계약 문서(docs/data-model.md '급여 회차와 예정일') 반영 및 정합성 확인 대기. 문서 변경이 오면 현재 구현·테스트와 대조한다.

## 범위 밖

FinancialSnapshot 어댑터와 배정·정산·급여 근거 파싱(#28), 최대 부족액·최초 부족 시점·전체 시뮬레이션 결과 계약(#34), 연간 소비·반복 회차 생성(#59), 카드 일정에서 출금일 산출, 보호액 저장 상한(M5) 검사는 이 패키지에 없다.
