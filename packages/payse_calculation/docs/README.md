# payse_calculation — 로컬 계산 패키지

PAYSE-CALC-1([계산 기준](../../../docs/calculation-rules.md))의 순수 Dart 구현이다. 필드 의미는 [공통 데이터 모델](../../../docs/data-model.md), 기대값은 [상세 계획 §7-1](../../../docs/references/detailed-plan-v7.source.md)의 TC-C01~12를 따른다. 이 문서는 구현 경계와 보류 항목만 적고 산식을 다시 정의하지 않는다.

## 준비와 검사

```sh
cd packages/payse_calculation
flutter pub get --enforce-lockfile
```

저장소 루트의 `node scripts/harness/run-flutter.mjs check`가 앱과 이 패키지에서 Dart 포맷·분석·테스트를 차례로 실행한다. 이 패키지의 `.dart_tool/package_config.json`이 없으면 BLOCKED다. lib는 flutter·입출력·현재 시각·난수를 쓰지 않으며 테스트만 SDK의 flutter_test를 쓴다.

## 공개 함수

| 함수                     | 용도                                                                                |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `calculateCurrentAmount` | 홈 U=B−E−(R−O)와 B·E·R·O·R−O, 의무별 금액·정산액(이미 나간 돈)·잔여·위치            |
| `resolveSalaryCycle`     | t0와 월급 설정으로 정상·입금 대기·입금 정보 부족 구간                               |
| `projectPeriods`         | C1~C3 일 마감 시작 H·종료 H·종료 직전 A·최소 H/A, 가상 소비 반영 결과와 종료 A 차이 |
| `assumedPayDates`        | 월급일 규칙으로 가정한 p1~p3와 말일 보정 표시                                       |

결과는 입력의 `CalculationContext`(dataVersion·sourceVersion·ruleVersion·asOf·inputRevision)를 그대로 담는다. 입력·결과 목록은 수정할 수 없다.

## 입력 계약

- 금액은 정수 원이다. 잔액·합계·H·A·차이는 ±9,000,000,000,000원, Money는 0 이상, 배정·정산·가상 소비는 1 이상이다. 각 입력과 덧셈·뺄셈마다 검사하고 넘으면 `amountOutOfRange` 오류다.
- 날짜는 YYYY-MM-DD, 시각은 오프셋이 필요하다. t0는 asOf의 서울 날짜다. 달력 n개월 뒤는 원래 기준일에서 한 번에 더하고 없는 날은 말일이다.
- 목록의 null은 미확인이라 영향 값이 null·`insufficient` 사유가 되고, 빈 목록은 확인된 0건이다.
- B는 included 계좌만 더한다. 포함 계좌가 없거나 잔액·asOf가 없거나 asOf 시각이 다르면 B는 null이다.
- 정산은 invalidatedAt이 null인 연결의 allocatedKRW만 의무에서 뺀다. 거래 금액·날짜로 자동 연결하지 않는다. 중복 연결·의무별 초과 정산·없는 참조는 오류다. 거래별 배분 합계·출금 계좌 일치는 거래 금액이 입력에 없어 검사하지 않으며 #28 어댑터 책임이다.
- R은 포함 계좌의 미취소 보호액이다. O는 현재 E 의무와 R 보호액 사이 미해제 배정(amountKRW−releasedKRW) 합계다. 의무 잔여·보호액을 넘는 배정은 잘라내지 않고 `overAllocation` 오류다.
- 월급 근거는 expectedPayDate가 월급일 규칙 날짜와 같을 때만 그 회차로 본다. 회차별 근거는 absent(항목 없음)·unknown·partial·confirmed로 구분한다. 다음 회차가 confirmed면 확인 시점부터 그다음 월급일까지 구간으로 전환하고, 아니면 직전 회차가 confirmed일 때 정상, unknown·partial일 때 입금 대기, absent일 때 입금 정보 부족이다. confirmed 근거 거래가 asOf 잔액에 반영된 posted 입금이라는 계약은 #28 어댑터가 검증한다.
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
| Q2-1 | 규칙 날짜와 다른 근거(휴일 이동)는 회차를 확인할 수 없어 정보 부족(보류)                        | 같은 파일 `sameMonthAsPrevious` 비교                            | Q1과 같은 null, `receiptScheduleMismatch`                      | Q2-1                                    |
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

## Q2-1 계약 검토안(보류, 변경하지 않음)

현재 SalaryReceipt는 expectedPayDate 하나라, 휴일 이동한 근거가 어느 회차인지 표현할 수 없다. 아래는 A·B 검토용 안이며 계약·더미·DB를 바꾸지 않았다.

- **`payMonth`(YYYY-MM, 필수 후보)는 명목 급여 회차다.** '몇 월분 월급인가'를 뜻하며 입금월이 아니다. 반복 월급일 규칙(salaryDay)은 바꾸지 않는다.
- **`expectedPayDate`는 그 회차의 확인된 예정일로 의미를 고정한다.** 휴일 이동을 반영한 날짜다. 계획에 없던 조기 입금은 예정일을 바꾸지 않고 confirmation으로만 표현한다(현재 Q2-2 동작).
- **월 경계를 넘는 예시:**
  - 월급일 1일, 2026-11-01(일) → 10-30(금)으로 앞당김: payMonth 2026-11, expectedPayDate 2026-10-30. 입금월은 10월이지만 11월분이다.
  - 월급일 31일, 2026-10-31(토) → 11-02(월)로 미룸: payMonth 2026-10, expectedPayDate 2026-11-02.
  - 월급일 25일, 10월분이 계획보다 하루 먼저 10-24 입금: payMonth 2026-10, expectedPayDate 2026-10-25, confirmed.
- **중복.** (userId, payMonth)당 근거 최대 1개. 현재의 '같은 expectedPayDate 중복 오류'는 payMonth 기준으로 바꾼다. 서로 다른 회차가 같은 expectedPayDate를 가지면 오류다.
- **기존 데이터.** 현재 더미(salary-wait·partial·confirmed의 2026-10-25)처럼 expectedPayDate가 생성 당시 규칙 날짜와 같은 항목은 그 달로 payMonth를 채울 수 있다. 규칙 날짜와 다른 기존 항목은 날짜 근접성으로 채우지 않고 원천 확인이 필요하다. 대상은 `source_contexts.salary_evidence` JSON, `apps/api/fixtures`(generate·validate·export_sql), `apps/api/tests/test_fixtures.py`, `apps/api/database/test_*.sql`이다.
- **기존 소비자 영향.**
  - 이 패키지: 회차 식별을 '규칙 날짜와 같음'에서 payMonth로 바꾼다.
  - 앱 FinancialSnapshot·SnapshotProjector: 배열 형태와 transactionIds 접근 제한만 다루므로 필드 추가에는 영향이 작다. 다만 새 필드의 투영·제한 규칙이 필요하다.
  - 사용자가 03-7에서 월급일을 바꾸면, 지금은 과거 근거의 expectedPayDate가 새 규칙 날짜와 달라 정보 부족이 된다. payMonth가 있으면 회차가 유지된다.
- **함께 정할 점.** 이동한 회차의 구간 경계를 확인 날짜(예: 10-30)로 둘지. '급여일 당일 출금은 다음 구간'(D5)도 그 날짜에 적용할지.

A 담당 전달용 문구(초안, 아직 전달하지 않음):

> #27 계산 패키지에서 휴일 이동 급여 근거를 회차와 연결할 수 없어 정보 부족(receiptScheduleMismatch)으로 보류했습니다. SalaryReceipt에 명목 급여 회차 `payMonth`(YYYY-MM, 입금월 아님)를 추가하고, `expectedPayDate`를 '그 회차의 확인된 예정일(휴일 이동 반영)'로 고정하는 안을 검토 부탁드립니다. 확인할 점: (userId, payMonth) 유일성, 기존 salary_evidence·더미의 채움 방식(규칙 날짜와 다른 항목은 원천 확인), 이동 회차의 구간 경계 날짜입니다. 패키지 문서의 'Q2-1 계약 검토안'에 예시와 영향 범위를 정리했습니다. 정상 시나리오 더미의 직전 회차 급여 근거가 비어 있는 점(#28 연결 시 U null)도 함께 확인 부탁드립니다.

## 범위 밖

FinancialSnapshot 어댑터와 배정·정산·급여 근거 파싱(#28), 최대 부족액·최초 부족 시점·전체 시뮬레이션 결과 계약(#34), 연간 소비·반복 회차 생성(#59), 카드 일정에서 출금일 산출, 보호액 저장 상한(M5) 검사는 이 패키지에 없다.
