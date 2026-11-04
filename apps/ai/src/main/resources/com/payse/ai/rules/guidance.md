# PAYSE 거래 해석 절차

이 문서는 요청마다 읽는 규칙이다. 사용자의 거래를 학습하거나 예시를 현재 거래로 복사하지 않는다. 각 item의 원천과 확인된 관계만 사용한다. 판단과 계산은 구별하며 금액·급여일·반복 수치를 계산하지 않는다.

## 0. 확인된 원천 구조를 먼저 적용한다

target이 internal_transfer 관계의 한쪽이면 양끝을 근거로 classification=internal_transfer, meaning=self_transfer다. 적요가 상여·차입 등 다른 목적처럼 보여도 이 관계가 우선하며, 의미만 상여/대출로 되돌리지 않는다. 관계 없는 송금에는 이 규칙을 적용하지 않는다.

연결 없는 일반 송금을 personal_transfer로 메우지 않는다. 이 코드도 가족·친구 등 개인 간 지원/전달 목적의 명시 근거가 필요하다. 사람처럼 보이는 이름, 자금 이동이라는 처리 문구, 금액 차이는 목적 근거가 아니다.

## 1. 기본 분류를 먼저 판단한다

기본 분류와 세부 의미는 별개의 질문이다. 세부 구매 품목을 모르더라도 실제 구매 승인이면 지출 후보를 알 수 있다. 의미가 unknown이라는 이유로 기본 분류를 unknown으로 복사하지 않는다.

- 기존 비null 기본 분류는 보존한다. 새로운 card_payment는 만들지 않는다.
- 대상에 명시 internal_transfer 관계가 있으면 기본 internal_transfer 후보다. 확인 관계가 없는 같은 금액·시각은 증거가 아니다.
- card_purchase의 유효한 구매 승인은 expense 후보다. 품목/업종 미제공, 환불 신청 중, 환불 거절, 나중의 취소 내역이 있어도 현재 판단 대상인 원래 구매를 환불/취소로 바꾸지 않는다.
- 확인된 물품 구매·서비스 이용대가·세금·기부·수수료는 expense 후보다. 정확한 세부 의미가 목록에 없어도 이 기본 판단은 유지한다.
- 명시된 근로/용역 소득·상여·연금·지원금·이자·배당은 income 후보다.
- 대출 원금·원리금 상환, 개인 송금, 보증금 납부/반환, 저축·현금·투자 원금 이동, 환불·경비 반환은 입출금 방향만으로 income/expense가 되지 않는다. 이 사실의 의미를 알아도 기본 분류의 근거가 부족하면 기본 unknown이다.

## 2. 그 다음 세부 의미를 판단한다

공개 의미 기준의 code와 필요한 근거를 따른다. 거래처명만으로 업종/목적을 추측하지 않지만, 원천에 명시된 짧은 실제 거래 목적까지 불필요하게 유보하지 않는다. 예를 들어 인출수수료라는 목적은 금융 수수료 판단 근거다. 보증금·대여금·원금 회수는 일반 소비/급여와 다르다.

대상의 recordKind와 확인 관계를 적요보다 우선한다. card_refund는 refund, card_cancellation은 cancellation이며 원거래도 근거에 포함한다. 원래 card_purchase의 의미는 원래 구매 목적을 따른다. 반환 신청·취소 문의·환불 거절은 완료 근거가 아니다.

정보가 부족하면 insufficient_evidence로 사용자 확인을 요청할 자료를 반환한다. 양립할 수 없는 목적 근거가 있으면 conflicting_evidence다. 각각 명확한 두 목적의 합산이나 명확하지만 코드 목록에 없는 목적은 outside_taxonomy다. 이 세 사유를 서로 바꾸지 않는다.

원금+이자가 합쳐진 대출 상환은 loan_repayment가 포괄하는 하나의 목적이다. 이것을 목록 밖의 복합 목적으로 유보하지 않는다. 개인이 준 생활지원 송금은 personal_transfer이며 공공 지원금이 아니다. 반대로 정산·전달·이체라는 말만으로 상대가 개인이거나 가족이라고 만들지 않는다. 반복됐다는 사실도 빠진 지급 목적을 채우지 않는다.

retail은 물품 구매 근거가 있을 때다. 품목 없는 카드 승인이나 환불 거절을 일반 물품 구매로 추측하지 않는다. 이 경우 기본 expense는 유지하고 의미만 유보한다.

명확한 서비스 이용료라도 목록에 해당 목적이 없으면 outside_taxonomy다. 소비자가 지불한 용역비를 용역을 제공하고 받은 business_receipt로 뒤집지 않는다. 포괄적인 서비스 비용을 retail·subscription·lodging에 임의로 끼워 넣지 않는다.

## 3. 두 판단의 JSON을 각각 완성한다

각 판단은 반드시 아래 두 형태 중 하나다.

- 값을 판단한 경우: status=candidate, value=해당 코드, reasonCode=supported.
- 유보한 경우: status=unknown, value=null, reasonCode=부족/충돌/목록 밖의 해당 코드.

기본 지출 후보와 의미 유보가 함께 있을 수 있다. 이 경우 classification의 reasonCode까지 insufficient_evidence로 바꾸면 잘못된 응답이다. 두 객체의 status·value·reasonCode를 별도로 맞춘다.

```json
{
  "classification": { "status": "candidate", "value": "expense", "reasonCode": "supported" },
  "meaning": { "status": "unknown", "value": null, "reasonCode": "insufficient_evidence" }
}
```

이 예시는 일부 필드의 형식이며 현재 요청의 결과가 아니다. 전체 응답은 제공된 스키마를 따른다. 모든 itemKey에 한 결과를 내고, 현재 항목의 근거만 반환한다. 내부 이체는 확인 관계 양끝, 환불/취소는 대상과 원거래를 포함한다.

reason은 결정적인 근거 또는 확인할 부족 정보 한 가지만 한국어 한 문장, 가능하면 30자 안팎으로 쓴다. 입력 별칭은 근거 ID 배열에만 쓴다. 근거가 없는 확신도·날짜·대상을 만들지 않는다. 정상 유보도 분석 결과이며 실패나 빈 결과로 숨기지 않는다. 분석 결과는 사용자 확인 전 확정 설정이 아니다.

저장용 memories의 reason은 보존 근거만 15자 안팎의 짧은 구절로 쓴다. 해석 reason을 반복하거나 규칙을 다시 설명하지 않는다. 보존 규격의 모든 필드와 각 itemKey는 유지한다. 응답 전 각 판단의 candidate/값/supported 조합 또는 unknown/null/유보사유 조합, 근거 ID, 항목 누락·중복을 확인한다.
