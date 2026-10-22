# PAYSE 더미 데이터 사용 기준

[공통 데이터 모델](../../../../docs/data-model.md)과 [DB 사전](../../../../docs/database-schema.md)를 사용한다. CODEF는 참고만 하며 실제 공급자 형식·카드사 결제 규칙 준수를 주장하지 않는다.

## 자료 구성

- 개발용 합성 사용자 3명(alpha/beta/gamma), 사용자당 5은행의 계좌 6개·4카드사 카드 4개. 한 은행에 입출금+정기예금을 두어 선택 합산을 확인한다. 적금도 포함한다. 샘플 계정 수·금융 금액·상품/가맹점 표시는 제품의 영구 제한이 아니다. 합성 인증 이름은 [API 이름 계약](../../../../docs/api-contract.md#인증-입력과-단일-이름)의 확정 매핑을 따른다.
- 기준 시각은 파일에 고정한다. alpha/beta는 2026-10-19, 급여 상태는 10-25, gamma 월말은 2027-01-31이다. 서로 다른 기준시각·자료 버전을 섞지 않는다.
- 연결한 전체 계좌/카드는 최근 달력1년 범위를 가진다. 홈 선택과 별개다. 정상 완전 조회·정상 0건·부분 누락·조회 실패를 구분한다. 날짜만인 거래에 자정 시각을 만들지 않는다.
- `generated/snapshots/*.json`은 전달 형식 초안의 완전한 독립 스냅샷이다. 페이지 분할·실패 HTTP 응답은 [공통 API 계약](../../../../docs/api-contract.md)과 [응답 모델](../../../../docs/api-response-models.md)의 규격이며 `nextCursor:null`이 실제 API 구현 완료를 뜻하지 않는다.
- `generated/server-seeds.json`은 서버 전용 합성 시드 메타데이터다. 사용자 키는 userId·name·syntheticPhone·codeVerifier·createdAt·initialCase다. 구 syntheticName/displayName은 허용하지 않는다. 이름/전화번호/비활성 코드 표식을 금융 응답·LLM에 섞지 않는다. 실제 SMS·인증 기능은 없다.
- `generated/catalog.json`은 시나리오 설명·검증 기대값·후속 Flutter 입력이다. 기대값과 검증용 기초잔액을 앱 API 결과로 반환하지 않는다. 일부는 수기로 지정한 벡터이며 Flutter 구현 테스트 통과 근거가 아니다.
- `generated/manifest.json`은 키 정렬·공백 제거한 UTF-8 JSON 의미값의 SHA-256이다. 파일 포맷 변경과 데이터 변경을 구분한다. 배포 ZIP의 바이트 무결성은 별도 검증한다. 검증기는 해시 외에도 합성 사용자 매핑·저장 형식·소유권·초기 시나리오를 대조하므로 잘못된 시드를 다시 해시해도 거절한다.

## 시나리오

| 파일 이름                        | 검증 목적                                             |
| -------------------------------- | ----------------------------------------------------- |
| alpha-ready.json                 | 연간 자료·선택 계좌·카드 정산·부분 정산·보호 배정     |
| beta-ready.json                  | 동일한 금융 표시명/금액을 가진 다른 사용자 격리       |
| alpha-unconnected.json           | 초기 복원: 연결0·금융 자료 미노출                     |
| salary-wait.json                 | 급여일 미입금; 당일/연체 예정 지출 홈 반영 대기       |
| salary-partial.json              | 부분 입금도 원천 잔액에는 반영; confirmed 전까지 대기 |
| salary-confirmed.json            | 명시 confirmed 사건에서만 급여 입금 완료              |
| alpha-shock.json                 | 준비 사건으로 잔액 하락; 기존 보호액 유지             |
| refund-outside-window.json       | 기간 밖 원구매와 당기 부분 환불                       |
| refund-unavailable-original.json | 확인된 환불 사실·미확보 원거래 참조 보존              |
| partial-history.json             | 한 계좌의 8월 자료 미확보; 0건으로 위장 금지          |
| failed-card-history.json         | 카드 내역 조회 실패와 정상 빈 결과 구별               |
| unknown-card-schedule.json       | 카드 미래 출금 일정 미확보                            |
| settlement-corrected.json        | 잘못된 지급 연결 해제·보호 배정 복원 상태             |
| cancelled-approval.json          | 미성립 승인 취소는 지급·환불과 별개                   |
| gamma-month-end.json             | 말일·확인 일정 우선·미래 이력·기존 회차 보존          |

## 생성 규칙과 고정값

Python 3.10+ 표준 라이브러리만 사용한다. 이는 준비 도구이며 백엔드 언어 선택이 아니다. UUID는 사용자/객체/고정 시나리오 키로 재현한다. 같은 객체는 sourceVersion이 바뀌어도 ID를 유지한다. 원천 사실이 달라진 시나리오에는 다른 sourceVersion을 부여하고, 지급 연결만 정정한 경우 sourceVersion을 유지하고 dataVersion만 바꾼다.

원천 잔액과 거래는 준비 시드이며, 생성 시 검증용 기초잔액+현금 기장 순액=현재 잔액을 맞춘다. 앱에서는 현재 잔액에 이 거래들을 다시 합산하지 않는다. 신용 구매는 계좌 현금 차감이 아니고, 카드 대금은 구매와 중복 소비가 아니다. 청구 110,000원은 준비한 100,000원·10,000원 구매와 실제 110,000원 출금으로 연결한다. 체크카드는 명시한 구매/계좌 쌍, 내부 이체는 양쪽 기장 관계가 있다.

부분 정산 40,000원은 100,000원 의무의 잔여 60,000원 근거다. 보호 설정은 이미 해제된 40,000원을 반영한 현재 400,000원이다. 연결 정정 상태는 원천 잔액/거래를 유지하고 의무 잔여와 보호 배정을 복원한다. 실제 정정 API·이력 생성 동작은 아직 없다.

급여 확인은 임시 합의대로 explicit unknown/partial/confirmed와 입금 거래 ID를 사용한다. 월말 계획은 원래 31일을 보존하고 2월 확인 일정 26일·없는 날짜의 말일·3월부터 새 버전·기존 3월 저장 회차 보존·4월 개별 편집을 구분한다. 미래 회차를 전부 DB에 생성하지 않는다.

샘플의 정기 소비는 월별 자료로 준비하며 이름·날짜·금액 임계값의 실제 반복 탐지와 연간 소비 수치는 Flutter에서 검증해야 한다. 상품/가맹점 이름은 합성 표기다. 카드 이용기간/결제일은 명시 fixture 일정이며 실제 카드사 운영 규칙으로 추정하지 않는다.

## 실행

저장소 루트에서 실행한다. 출력 디렉터리/SQL 파일이 이미 있으면 덮지 않고 중단한다.

```powershell
python apps/api/fixtures/generate.py --out .harness/payse-fixtures-new
python apps/api/fixtures/validate.py .harness/payse-fixtures-new
python -m unittest discover -s apps/api/tests -p test_fixtures.py -v
python apps/api/fixtures/export_sql.py apps/api/fixtures/generated --out .harness/payse-initial.sql
```

마지막 명령의 기본 시드는 연결0·선택0이다. 검증용 준비 상태가 필요할 때만 `--ready`를 추가한다. SQL exporter는 DB에 접속하지 않는다. 실제 적재는 새 검증 DB에 DDL 001→002→생성 SQL 순으로 한다. 기존 DB에 임의 적용하지 않는다. 운영 reset/upsert 도구는 아니다. 구 이름 열이 있는 DB는 [기존 DB 전환 절차](../../docs/identity-migration.md)를 따르며 이 시드로 덮지 않는다.

새 JSON을 공유할 때 저장소의 Prettier로 변경 파일만 포맷한다. manifest는 의미값 해시이므로 포맷 후에도 검증된다. 생성기는 같은 버전/입력에서 동일 바이트를 만들며 포맷 파이프라인 적용 후 바이트는 달라질 수 있다.

## 팀원 인계·미구현

- Flutter는 우선 alpha-unconnected→alpha-ready, salary-wait→partial→confirmed, settlement-corrected, gamma-month-end를 FakeRepository 입력으로 확인한다.
- 원천 필드 읽기 전용, null·coverage 표시, 급여 대기·회차 편집·분류 정정을 확인한다. 새 공통 형식 문자열과 필드 배치는 두 담당자 확인 후 API에서 고정한다.
- 연간/월별 결과는 v0.7, 지급 연결 수동 정정은 v0.9라는 최신 GitHub 합의를 유지한다.
- 세션/인증·API·실제 LLM·실제 금융 API·Flutter 숫자 계산을 이 자료가 구현하지 않는다. 같은 JSON이 DB에 적재된 사실과 앱 동작 검증을 혼동하지 않는다.
- 페이지·오류·공개 투영은 [HTTP 계약](../../../../docs/api-contract.md)과 [응답 모델](../../../../docs/api-response-models.md)에 정의된 범위를 따른다. 실행 가능한 JSON Schema/OpenAPI와 실제 API 구현은 별도이며 공급자 ID alias 매핑·외부 호환은 후속 실연동에서 검증한다. 원본과 공개 응답은 아래 형식 경계를 따른다.

## 원본과 공개 응답의 형식

- 원본 schemaVersion은 PAYSE-DRAFT-2다. recurringPlans는 userId/planId/firstOccurrenceMonth만 제공한다. 금액·명칭·일정·출금 계좌·카드·상태는 recurringPlanRevisions에서 읽는다. 중복 필드가 남은 계획은 검증 실패다.
- 기존 금융값·UUID·asOf·sourceVersion·dataVersion·고정된 planRevisionId는 보존한다. API/FakeRepository 표현은 PAYSE-API-0.6-2이며 원본 JSON을 그대로 공개하지 않는다. 부분 연결·민감 값 제거 규칙은 [응답 모델](../../../../docs/api-response-models.md)을 따른다.
- Flutter는 새로운 미래 회차에 해당하는 현재 버전을 선택하고 기존 회차는 고정 버전을 유지한다. 숨겨진 버전 때문에 완전성이 확보되지 않으면 영향받는 미래 회차 계산을 보류한다. 원본 복사본·입력 계약의 일치 검사와 실제 부분 연결 mapper·미래 회차 계산·실기기 동작 검증을 구분한다. 후자의 구현·통합은 별도 검증 대상이다.

작성·변경·검증 이력은 [API 문서 이력](../../docs/history/2026-10-22-api-doc-history.md)에 보존한다.
