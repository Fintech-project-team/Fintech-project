# 최근 3개월 지출 후보·AI 해석·사용자 승인 연결

기준: `docs/calculation-rules.md`, `docs/data-model.md` §5·§6, `docs/team-plan.md`, `docs/payse-execution-contract.md`. 기간/금액/예정일/U는 공유 순수 Dart, 의미와 설명은 AI, 인증/참조/확정 설정 저장은 API가 담당한다.

## 제공 흐름

1. 같은 버전의 1년 원천과 조회 완전성을 확보한다. `detectRecurring`은 최신 달력 3개월을 우선 근거로 월간 후보를 만든다. 오래된 반복으로 최근 증거 부족을 보충하지 않는다.
2. 후보 0개와 원천 미확보를 구별한다. 후보가 있으면 기존 분석 API의 `recurringMeaning` 작업에 최소 원천·candidateKey·features를 제출한다. 정답 분류, 전체 계좌번호, 확정하지 않은 미래 금액/일정을 보내지 않는다.
3. 완료 작업은 기존 결과 조회로 복호화·현재 근거 검증을 통과한 결과만 받는다. 결과 없음/조회 제한과 의미 unknown, 작업 실패는 별개다. `GET /analysis-jobs/{id}`의 선택적 `Prefer: wait=5`는 상태 전달 대기이며 모델 재호출이 아니다.
4. `reviewRecurring`으로 최근 원천과 AI 의미를 결합한다. 일정/금액이 일정하고 아직 관측되지 않은 이번 달 현금 후보를 우선 제안한다. 사용자가 금액·월간 일자·첫 회차월·출금 계좌를 확인한다. AI 후보는 확정 지출이 아니다.
5. 명시 승인/제외를 아래 API로 저장한다. 성공 스냅샷으로 계획을 투영한 뒤 기존 Dart 계산을 다시 실행한다. 실패 응답에서는 성공 화면이나 예상 U를 확정하지 않는다.

## POST /recurring-decisions

기존 Bearer 세션과 `database,auth,finance` 프로필을 사용한다. 세션 확인→사용자 행 잠금/RLS→입력 형식→멱등 영수증→버전→소유권/연결→원자 저장 순서를 유지한다. userId는 받지 않는다. 성공은 기존 금융 쓰기의 `receipt`, `replayed`, `snapshot` 봉투이며 `Cache-Control: no-store`다.

```json
{
  "expectedDataVersion": "42",
  "ruleVersion": "PAYSE-CALC-1",
  "idempotencyKey": "클라이언트가 생성한 고유 작업키",
  "candidateKey": "로컬 후보 키",
  "sourceVersion": "현재 스냅샷 원천 버전",
  "evidenceTransactionIds": ["소유 거래 UUID 1", "소유 거래 UUID 2", "소유 거래 UUID 3"],
  "normalizedName": "통신 요금",
  "decision": "approved",
  "plan": {
    "firstOccurrenceMonth": "2026-11",
    "label": "통신 요금",
    "amountKRW": 50000,
    "monthlyDay": 20,
    "paymentTiming": "immediate",
    "scheduleBasis": "withdrawal",
    "withdrawalAccountId": "소유 출금 계좌 UUID",
    "cardId": null
  }
}
```

이 예시는 형태 설명이며 UUID 자리의 설명문은 실제 요청에서 사용할 수 없다. `decision=excluded`는 `plan=null`이며 같은 근거/규칙의 후보 재제안 방지를 저장한다. 승인 시 결정·계획·첫 revision·영수증·dataVersion 증가를 한 트랜잭션으로 저장한다. 어떤 단계라도 실패하면 전부 롤백한다. 원천 잔액/거래·미래 의무·AI 호출은 이 명령에서 생성하거나 변경하지 않는다.

- 후보 키 1~4096자, 원천 버전 1~512자, 정규화명/명칭 1~80자. 근거는 중복 없는 UUID 3~60개다. 이 개수 제한은 서버의 반복 산술 재판정이 아니다.
- 계획 금액은 양수 원화 정수 최대 9조 원, monthlyDay는 1~31, 첫 회차월은 유효한 YYYY-MM이며 asOf의 서울 현재 월보다 이를 수 없다.
- immediate는 withdrawal 기준·cardId=null이며 근거의 계좌와 출금 계좌가 같아야 한다.
- card_bill은 확인된 credit 카드·실제 출금 계좌와 연결되어야 한다. 근거는 그 카드의 구매이며 scheduleBasis=purchase/withdrawal 의미를 보존한다. 구매일을 출금일로 해석하지 않는다. debit/unknown 카드는 이 경로에서 신용카드 계획으로 변환하지 않는다.
- 모든 근거는 현재 연결된 같은 수단/종류의 소유 거래여야 한다. 승인 근거의 확인된 자기 이체, 카드대금, 미확정/취소 거래 및 취소·환불 연결이 있는 원구매는 거절한다. 로컬 패턴 수치와 미래 금액은 서버가 다시 계산하지 않는다.
- 다른 멱등 키/근거 순서/후보 키로 같은 근거 집합·ruleVersion을 다시 승인하거나 제외하면 `409 RELATION_CONFLICT`다. 같은 작업키·같은 본문 재전송은 원래 영수증을 반환한다.
- 오래된 dataVersion/sourceVersion은 `409 STALE_DATA`, 다른 사용자/연결 해제 근거는 `403 RESOURCE_FORBIDDEN`, 미허용 필드/형식은 `422 VALIDATION_FAILED`다. 기존 일반 금융 오류 봉투를 유지한다.

새 계획은 Snapshot의 기존 `recurringPlans`, `recurringPlanRevisions`, `recurringDecisions`에 나타난다. 로그아웃 후에도 남는다. 후보를 저장하는 별도 테이블은 추가하지 않았다.

## 배포·권한

기존 금융 마이그레이션 이후 `database/013_recurring_access.sql`을 관리자 절차로 적용해야 새 쓰기 API가 동작한다. 이 SQL은 기존 강제 RLS와 정확한 own_rows 정책을 검증하고 세 기존 테이블의 명시 열 INSERT만 추가한다. UPDATE/DELETE·금융 원천 쓰기 권한은 추가하지 않는다. 멱등 재적용 가능하며 서버 시작이 자동 적용하지 않는다.

격리 DB 검사에서만 자동 준비한다. 운영 DB와 실행 중인 서버에는 이 작업에서 적용하지 않았다. 현재 서버 파일 교체·마이그레이션 적용과 프론트 동시 배포는 별도 배포 단계다.

## 프론트 반영 명세

- 공유 패키지 `packages/payse_calculation/docs/recurring.md`의 입력 매핑과 예외 규칙을 적용한다. 모바일의 실제 파일은 이번 작업에서 수정하지 않는다.
- AI 결과의 후보 키/근거/현재 문맥을 매핑한다. 실패/진행/unknown을 정상 0개와 구분하고 실패 목록에서만 사용자가 명시 재시도한다. 자동 재호출은 0이다.
- 우선 제안에는 “이번 달 예상 지출 — 확인 필요”처럼 표시한다. 이번 달 이미 관측된 출금, 가격 변동, 카드 청구 미확인, 날짜 미상은 별도 확인 영역에 둔다.
- 승인/제외 중복 탭에는 같은 멱등 키를 재사용한다. 409이면 최신 스냅샷으로 재탐지한다. 성공 후 새 스냅샷만 사용하고 이전 후보/지연 AI 결과는 버린다.
- 승인한 계획의 필요한 월별 회차를 `expandRecurring`으로 투영한다. 저장 회차와 청구 대표 의무를 중복 추가하지 않고 기존 급여 구간·정산·보호금 규칙으로 U를 계산한다. 미확인 청구의 null 결과를 []로 바꾸지 않는다.
- 전체 화면 연동, 회차 개별 저장/향후 계획 편집·취소 API 및 실기기 시연은 이 기능의 현재 제공 범위에 포함하지 않는다. 기존 저장된 버전/개별 수정은 계산 입력에서 보존한다.

검사 근거는 `FinancialHttpTest`의 반복 승인/제외/멱등/롤백/권한 검사와 공유 Dart 반복 검사다. 실제 모델 품질·시간은 `apps/ai/docs/continuous-evaluation.md`와 별도 실행 기록으로 구분한다.
