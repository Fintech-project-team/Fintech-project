# 할부·계정별 예외 시연 인계

2026-10-28 작업 기록. 관련 이슈: #29, #32. 기존 [금융 계약](../../../../docs/data-model.md), [공통 저장](../common-storage.md), [LLM 실행](../llm-execution.md)을 유지한다. 이 기록은 새 API·분석 저장 구현 완료 선언이 아니다.

## 준비한 데이터

| 사용자 | 새 사례              | 금융 원천·설정                                                                                            | 검증 의도                                                                         |
| ------ | -------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| alpha  | `demo-installments`  | `demo-ready`의 월세·통신비·청구·급여 근거 유지                                                            | 정상 시연에 할부 표시 추가                                                        |
| beta   | `beta-cashflow-edge` | `beta-ready`에 10/10 입금 785,000원, 10/12 의료 지출 687,400원, 10/18 동일 가맹점 지출 8,900원씩 2건 추가 | 부수입·일회성 지출을 반복 지출로 단정하지 않기, 표시가 같아도 서로 다른 거래 유지 |
| gamma  | `gamma-ai-misread`   | 10/19 기준 일반 gamma 원천에 9/25 입금 3,000,000원 추가. 기존 `gamma-month-end`는 별도 보존               | 금액·날짜만으로 대출 입금을 급여로 단정하는 오판 평가                             |

세 사례 모두 현대카드 10/18 구매 180,000원·할부 1/3, 삼성카드 8/18 구매 360,000원·할부 2/6을 추가한다. `amountKRW`는 원구매 금액이고 할부 회차는 명시된 합성 원천 값이다. 구매일에서 현재 회차를 추정하거나 금액을 월별로 나누지 않는다. 회차별 청구·결제의 전체 이력을 구성한 사례가 아니다.

새 구매를 기존 110,000원 청구에 연결하지 않는다. 기존 청구·출금과 중복 차감하지 않으며 카드 구매 자체로 계좌 잔액을 차감하지 않는다. 선택 계좌의 원천 잔액 합계는 alpha 2,000,000원, beta 2,079,800원, gamma 5,000,000원이다. 이는 가용 금액 계산 결과가 아니다. 추가 거래가 있으므로 새 사례의 소비 분석 합계는 기존 사례와 다르다.

기존 18개 Snapshot·모바일 7개 자산·사용자 ID·기존 거래 ID/금액/날짜·기본 `initialCase`는 유지한다. 신규 사례의 `sourceVersion`만 분리하며 공개 응답 스키마는 v3 그대로다. 새 사례를 선택하기 전 기존 기본 시연에는 할부가 나타나지 않는다.

## DB와 평가 자료의 경계

- 일반 `users` → `user_attributes` → 계좌/카드/거래 구조를 사용한다. 할부는 기존 `financial_transactions.installment_current`, `installment_total`에 저장한다. 테스트 전용 테이블·컬럼을 추가하지 않는다.
- 초기 금융 적재는 미입력 사용자 속성으로 시작한다. 연결 완료 시연용 계획·보호금·설정은 기존 시나리오 도구로 명시 선택한다. 두 SQL은 대안이며 같은 DB에 연이어 실행하지 않는다.
- 기존 사용자 행에 다시 적재하면 거절하고 전체 롤백한다. 이미 사용 중인 DB를 덮어쓰거나 초기화하는 도구가 아니다.
- 감마의 원천은 일반 `income` 거래이며 급여 `receiptEvidence`를 생성·확정하지 않는다. 별도 준비 도구가 모델 입력, 모의 오판, 작성자만 아는 정답을 각각 생성한다. 정답의 대출 의미는 모델 입력에 넣지 않으며 입력만으로 급여/대출을 확정할 수 없는 사례다.
- 오판 결과는 테스트용 임시 형식으로서 공개 API 스키마가 아니다. 실제 LLM 실행·암호화 저장·정정/기억 삭제·재보존 차단은 실행하지 않았다. 실제 분석 DB 적재는 #32 저장 구현과 연결한다.

저장소 루트에서 실행하며 출력 파일·폴더는 아직 없어야 한다. **별도 빈 검증 DB**에 `database/001_initial.sql` → `database/002_storage_guards.sql` → [기관 기준정보](../../reference_data/docs/README.md) → 아래 초기 또는 연결 시나리오 SQL 순으로 적재한다(DDL 경로는 `apps/api/` 기준). 배치파일은 SQL을 실행하지 않는다.

```powershell
# 일반 사용자·금융 원천, 사용자 설정은 미입력
python apps/api/fixtures/export_sql.py apps/api/fixtures/generated --cases demo-installments beta-cashflow-edge gamma-ai-misread --out initial-demo.sql

# 또는: 연결 완료 상태와 사용자 설정까지 명시 준비
python apps/api/testing/scenarios/prepare.py apps/api/fixtures/generated --cases demo-installments beta-cashflow-edge gamma-ai-misread --out connected-demo.sql

# 별도 평가용: model-input.json / mock-output.json / expected.json
python apps/api/testing/scenarios/prepare_ai_case.py apps/api/fixtures/generated --out gamma-evaluation
```

## 모바일 담당자 전달

1. `apps/mobile/lib/data/financial_snapshot.dart`의 거래 모델에서 `installmentCurrent`, `installmentTotal`을 선택 필드로 읽고 둘 다 있을 때 할부 `현재/전체`를 표시한다. 원천 거래 금액·기존 청구 계산은 바꾸지 않는다.
2. 신규 세 Snapshot을 모바일 자산으로 추가하고 계정별 시연 선택 경로·자산 목록·동일성 테스트를 함께 맞춘다. 기존 7개 자산은 회귀용으로 유지한다. 원본 경로는 `apps/api/fixtures/generated/snapshots/`다.
3. 초기 SQL은 미연결·설정 미입력, 시나리오 SQL은 연결 완료 상태다. 앱 시연 의도에 맞게 하나를 선택한다. 서버 기본 적재 선택은 자동 전환하지 않았다.
4. gamma 모의 오판 파일은 금융 Snapshot에 합치거나 원천 급여 근거로 쓰지 않는다. #32 분석 저장/조회가 연결되기 전 금융 화면에서 잘못된 분석 결과가 나타난다고 가정하지 않는다.
5. 예정 지출·모아둘 돈의 삭제는 기존 [cancel 계약](../../../../docs/api-contract.md)을 유지한다. 해제할 미지급 배정과 사용자 확인을 함께 보내며 이미 정산된 이력을 삭제하지 않는다.

API 담당자는 모바일·계산 패키지를 수정하지 않았다. 모바일 파싱·시나리오 선택·실제 기기 표시 및 HTTP로의 제공은 후속 검증 대상이다.

## 재현 검사

```powershell
python -B -m unittest discover -s apps/api/tests
python -B apps/api/fixtures/validate.py apps/api/fixtures/generated
python -B apps/api/database/test_demo_edges.py --pg-bin "C:\Program Files\PostgreSQL\15\bin" --work-dir "C:\검증경로\새폴더"
python -B apps/api/database/test_demo_ready.py --pg-bin "C:\Program Files\PostgreSQL\15\bin" --work-dir "C:\검증경로\별도새폴더"
node scripts/harness/verify-change.mjs --task docs/tasks/PAYSE-DEMO-29-20261028.json
```

DB 검사는 소유한 임시 PostgreSQL만 생성·종료한다. 준비 자료에서 ID·관계·건수를 검증한 뒤 해당 값을 SQL에 전달한다. 원천 적재·소유권·할부 회차 오류·중복 적재·전체 롤백을 검사하며 실제 HTTP·LLM·Flutter 계산 통과를 대신하지 않는다.
