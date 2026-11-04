# 최근 3개월 반복 후보와 확정 계획 계산

기준은 `docs/calculation-rules.md`의 **연간 소비와 반복 후보**, `docs/data-model.md` §5, §6이다. 1년 자료에서 최근 **달력 3개월 `(asOf−3개월, asOf]`**을 후보 판정의 우선 근거로 사용한다. 임의의 70/30 점수나 LLM 확신도는 추가하지 않는다. 과거 9개월의 반복만으로 최근 누락을 채우지 않는다.

## 입력과 탐지

`detectRecurring(RecurringInput)`은 같은 스냅샷의 `CalculationContext`, 전체 연결 계좌/카드 ID, `RecurringEntry`, `RecurringCoverage`, 기존 승인/제외 `candidateKey`를 받는다. 홈 합산 제외 계좌도 탐지 대상이다. 현재 기기 시각·네트워크·DB를 읽지 않는다.

- 계좌 출금은 원천의 출금일, 카드 구매는 확인된 이용일을 사용한다. 모르는 날짜는 null이며 임의 기장일로 채우지 않는다.
- 이름은 공백 정리·소문자화까지만 한다. 업체명에서 숫자/지점/의미 있는 접두어를 임의 삭제하지 않는다. 의미 정규화 보조를 적용하더라도 원천 근거로 다시 검사한다.
- 동일 수단·종류·정규화명, 서로 다른 월 3회 이상, 월간 날짜 ±5일, 중앙값 금액 ±10%를 확인한다. 창이 네 달의 일부에 걸치면 최신 3회 근거를 사용한다. 같은 달 여러 구매는 월간 3회로 보지 않는다.
- 제안 금액은 마지막 확인 금액이다. 월간 일자가 유일하게 확인되지 않으면 `suggestedDay=null`로 남긴다. 금액 변동도 확인 사항이다.
- 명시된 자기 이체·카드대금 납부·동일 사건 중복은 어댑터가 `RecurringExclusion`으로 전달한다. 같은 금액/날짜라는 이유만으로 제외하면 안 된다. 체크카드 구매와 계좌 출금의 확인된 한 쌍은 하나의 경제적 사건으로 정규화한다.
- 미확정 거래, 원거래에 연결된 취소/환불, 조회 누락, 날짜/이름 미상, 날짜·금액 규칙 이탈은 `issues`에 보존한다. 취소/환불 행은 별도로 전달하며 `originalId`를 유지한다.

`completeWithoutCandidates=true`만 완전 조회의 정상 후보 0개다. 부분 조회·원천 불일치·분석 실패를 0개로 표시하지 않는다. 후보는 메모리 객체이며 U나 DB 의무에 자동으로 넣지 않는다.

## AI 해석과 이번 달 제안

후보별 `features`와 최소 원천 근거를 기존 `recurringMeaning` 작업으로 보낸다. `RecurringMeaning`은 서버가 검증한 의미 코드(`value`), 명칭, 이유, `reasonCode`, 근거 및 정상/unknown/실패/진행 상태를 전달하는 어댑터 타입이다. 계산 숫자를 AI 출력에서 읽는 필드는 없다.

candidate는 비어 있지 않은 value와 reasonCode=supported, unknown은 value=null과 부족/충돌/목록 밖 사유를 전달한다. 불일치한 조합은 입력 오류이며 우선 추천하지 않는다. 의미 코드의 전체 허용 목록·원문 이유 검증은 기존 서버 계약과 B의 응답 파서에서 유지한다.

`reviewRecurring`은 같은 dataVersion/sourceVersion/ruleVersion/asOf/inputRevision과 전체 근거 집합만 결합한다. 저장 결과의 과거 provenance를 현재 응답 문맥으로 대체하지 않는다. `candidateKey`와 서버 작업의 itemKey는 어댑터가 명시적으로 대응한다.

- `isThisMonthRecommendation`: 이번 달 아직 관측되지 않은 계좌 출금이며, 일정이 알려져 있고 경과하지 않았으며, 금액이 일정하고, AI 의미가 candidate인 **우선 확인 제안**이다. 실제 출금 보증은 아니다.
- `isThisMonthCashCandidate`: 위 AI/금액 확인이 끝나지 않은 경우도 포함하는 현금 후보다. 추가 확인 영역에 표시한다.
- 카드 구매는 구매 예정일을 현금 출금일로 바꾸지 않는다. 카드 청구 확인 영역에 표시한다.
- 이번 달 이미 관측한 회차, 금액 변동, 일정 미상, AI unknown/실패/진행은 별도 이유를 유지한다. 사용자가 직접 확인·설정할 수 있으며 실패 시 자동 모델 재호출은 없다.

## 사용자 승인 후 계산

승인은 `POST /recurring-decisions` 성공 후 받은 새 스냅샷으로 시작한다. 상세 요청은 `apps/api/docs/recurring-recommendations.md`를 따른다. `expandRecurring`에는 **서버에 저장된 사용자 확정 계획/버전**만 전달한다.

`expandRecurring`은 필요한 명목 월 하나만 투영한다. `firstOccurrenceMonth` 이전 회차를 만들지 않고, isCurrent=true인 버전 중 회차월 이하의 가장 늦은 시작 월을 선택한다. 29/30/31일 말일 보정 후에도 원래 monthlyDay를 유지하며 확인된 개별 일정이 우선한다. 고정된 저장 의무 또는 개별 수정은 `FixedRecurringOccurrence`로 전달하고 그 버전·금액·날짜·의무 ID를 그대로 사용한다. 저장 의무와 별도의 로컬 회차를 동시에 추가하지 않는다. `revisionIds`는 회차별 선택 버전이다.

직접 현금 회차의 `cashObligations`를 기존 의무와 **obligationId 기준으로 한 번** 합친다. 로컬 회차 ID `planId:YYYY-MM`은 DB UUID가 아니며 그 값을 기존 의무 저장 API에 보내면 안 된다. 지급 연결/보호 배정 대상으로 회차를 저장하는 후속 API는 이번 승인 API에 포함하지 않는다.

카드 회차는 같은 버전의 occurrenceLinks와 청구 대표 의무가 확인된 키만 `coveredCardKeys`로 전달한다. 해당 청구 의무는 기존 장부에 한 번 포함한다. 카드 회차에서 별도 현금 의무는 추가하지 않는다. 연결이 없으면 `issues`와 `cashObligations=null`을 반환한다. 이를 빈 목록으로 대체하지 말고 해당 계산의 정보 부족으로 표시한다. 잘못된 버전·중복·외부 키는 입력 오류다.

현재 사용 가능 금액은 기존 `calculateCurrentAmount`의 **U=B−E−(R−O)**를 유지한다. 이번 달 후보 목록과 홈의 급여 회차 계산 구간은 다르다. 홈/미래 계산에 필요한 명목 월들을 요청하고 급여 경계 밖 지출을 임의로 홈 E에 추가하지 않는다. 이미 잔액에 반영된 출금과 정산 연결은 기존 장부 규칙이 처리한다. 예정일 경과만으로 지급 완료를 만들지 않는다.

## 검증과 연결 범위

`test/recurring_test.dart`, `recurring_review_test.dart`, `recurring_schedule_test.dart`에서 최근 기간, 월별 반복, 가격 변동, 취소/환불, 정보 부족, AI 실패/유보, 구문맥, 월말, 고정 버전, 카드 중복, 승인 전후 U 및 실제 지급 뒤 재차감 금지를 검사한다.

이 패키지는 공유 순수 계산 구현이다. 모바일 Repository의 타입 매핑, 후보 화면, 승인 버튼, 결과 복원 및 실기기 검증은 프론트 연결 작업이다. `apps/mobile` 파일은 이 작업에서 변경하지 않는다.
