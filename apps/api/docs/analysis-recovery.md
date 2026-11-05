# 분석 실패 확인과 수동 복구

2026-11-04 사용자 선택에 따라 공통 실행 계약 D3의 **자동 공급자 재호출 0회**를 유지한다. 실패 후 사용자 재시도는 횟수 제한을 새로 두지 않고 현재 원천·권한·동시 실행·유효 DB 결과·비용을 매번 검사한다. 타임아웃·형식 검증 실패를 정상 `unknown` 해석이나 성공으로 바꾸지 않는다. 같은 결과의 DB 조회·재사용과 새 모델 호출을 구분한다.

## API 동작

`GET /analysis-jobs/{jobId}` 및 기존 접수·입력·재시도 상태 봉투에 선택 필드 `review`를 추가한다. 정상 완료·실행 중·대기 중에는 없다. 기존 `state`, `action`, `progress`, `resultAvailability`의 의미는 유지한다.

```json
{
  "state": "outcomeUnknown",
  "action": "retry",
  "resultAvailability": "unchecked",
  "review": {
    "reason": "outcomeUnknown",
    "requiresUserInput": true,
    "itemsAvailable": true,
    "retryRequiresAcknowledgement": true,
    "items": [{ "itemKey": "transaction-item-1" }]
  }
}
```

위는 상태 봉투 중 관련 필드만 발췌한 예시다. 실패한 묶음은 전체 출력 검증에 실패했으므로 해당 묶음의 모든 항목을 확인 대상으로 남긴다. 성공한 다른 작업은 이 목록에 섞지 않는다. 항목별 정상적인 근거 부족은 조회된 해석의 `unknown` 및 확인 필요 규격으로 처리하며 실행 장애와 합산하지 않는다.

`reason`은 `failed`, `outcomeUnknown`, `cancelled`, `expired` 중 현재 state다. `items`에는 본문 없는 `itemKey`만 담는다. 종료 시각부터 정확히 7일이 되거나 상세가 정리되면 `itemsAvailable:false`와 함께 `items`를 생략한다. 과거 목록을 복원하기 위해 새 분석을 호출하지 않는다. 기존 금융·해석 저장 수명은 변경하지 않는다.

## 프론트 연결 명세

현재 checkout에는 모바일 분석 API 클라이언트가 연결되어 있지 않다. B 담당자는 분석 작업 응답 모델·실패 목록·재시도 호출부에 아래 내용을 반영해야 한다. 이 변경에는 모바일 파일 수정이나 실제 기기 연동 검증이 포함되지 않는다.

1. `review.items[].itemKey`를 현재 흐름에서 보유한 요청 항목과 대조해 실패 목록을 표시한다. 상태 응답으로 금융 본문을 복원하지 않는다. 목록이 없거나 매핑이 유실되면 현재 원천을 다시 조회하고 새 입력을 구성한다.
2. 사용자가 직접 분류·설정을 확인하거나 수정할 수 있게 한다. 금융 원천 값은 수정하지 않으며 기존 저장 API·버전·멱등 규칙을 사용한다. 목록을 닫거나 무응답이라고 정답·승인으로 기록하지 않는다.
3. ‘다시 시도’ 선택 때만 현재 입력으로 기존 retry API를 호출한다. `retryRequiresAcknowledgement:true`이면 완료 여부 불명과 중복 실행·과금 가능성을 알리고 동의 후 `acknowledgeDuplicateRisk:true`를 전송한다. 자동 반복 호출은 금지한다.
4. `expired`이면 `action:refreshInput`에 따라 명시적 recovery 접수를 사용한다. 유효 DB 결과는 재사용하고 관련 원천이 달라진 같은 작업 retry는 409를 유지한다.
5. 수동 재시도가 다시 실패하면 목록을 그대로 제공한다. 성공 시 `review`가 사라지고 현재 입력 검증 후 결과 조회로 이동한다. 부분 실패를 전체 분석 성공으로 표시하지 않는다.

## 검증 범위

무료 모의 공급자와 폐기 PostgreSQL에서 검증한다. 상태 반복 조회의 모델 추가 호출 0회, 명시 재시도의 새 시도 1회, 완료 불명 동의 없는 재시도 거절, 성공 후 목록 해제, 7일 경계·상세 부재·비밀/본문 비노출을 검사한다. 이 결과는 실제 모델 정확도나 실제 기기 화면 구현 완료의 근거가 아니다.
