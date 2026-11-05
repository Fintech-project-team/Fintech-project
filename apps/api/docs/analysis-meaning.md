# PAYSE 거래·반복 의미 해석 계약

상태: **분석 전용 계약·공유 Java 모듈·API/DB 연결 및 모의 공급자 검증 완료, Flutter 연동 미검증**. 기본 운영 runtime은 실제 공급자/KMS 전송을 열지 않는다. [AI 구조·검사](../../ai/docs/README.md)를 함께 따른다. 금융 Snapshot v4와 원천·설정은 변경하지 않는다. 의미 입력/출력, 평가 또는 Flutter 분석 연동을 개발할 때 이 문서와 [분석 API](analysis-api.md), [실행 상세](llm-execution.md)를 필수 참조한다.

## 기준의 범위

[의미 기준표](../../ai/contracts/meaning-policy.json)가 `PAYSE-MEANING-1`의 단일 기준이다. **41개 의미** 각각에 코드·표시명·범주·필수 근거·불충분 근거·혼동 사례·기본 분류 정책·긍정/구체 혼동 예시가 있다. 사용자 요청에 따라 세부 의미의 범위를 넓힌 PAYSE 설계이며 금융기관 공식 분류표나 실측 정확도를 뜻하지 않는다.

| 범주           | 개수 | 세부 의미                                                                                                                                                            |
| -------------- | ---: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 입금·정산 성격 |   14 | 급여, 상여, 사업·용역 대금, 연금, 공적 지원금, 이자, 배당, 대출 실행금, 개인 송금, 경비 정산, 보증금 반환, 투자 원금 회수, 개인 자산 매각, 예금 원금 회수            |
| 생활 지출      |   18 | 임차료, 관리비, 공과금, 통신, 보험, 대출 상환, 세금·공적 부담금, 교육, 의료, 장보기, 외식, 일반 물품, 대중교통·택시, 차량 유지, 서비스 구독, 기부, 금융 수수료, 숙박 |
| 자금 이동      |    6 | 본인 이체, 저축 계좌 이동, 카드대금 납부, 현금 인출, 현금 입금, 보증금 납부                                                                                          |
| 취소·환불      |    3 | 카드 승인 취소, 카드 환불, 계좌로 받은 이용대금 반환                                                                                                                 |

- 기존 `expense/income/internal_transfer/card_payment/null`과 별도 `meaning.value`를 둔다. 두 값을 일대일 변환하지 않는다. 기본 분류를 알고 세부 의미만 모르면 기본 후보는 유지하고 의미만 unknown이다.
- 의미 후보는 `candidate`, 근거 부족·충돌·목록 밖 의미는 `unknown + value:null`이다. 모르는 뜻을 가장 가까운 코드에 강제로 넣지 않는다. 후보는 확정 사실·계획 승인·급여 입금 확정이 아니다.
- 원천 종류·확인된 관계 → 해당 거래의 사용자 정정 → 검증된 현재 근거 순으로 충돌을 확인한다. 사용자 정정은 원천 자체를 수정하지 않는다. 기존 분류의 출처가 없으면 사용자 확인으로 추정하지 않는다.
- 사업 매출과 개인 자산 처분은 명시 목적이 있어야 구분한다. `매각대금`만 있으면 유보한다. 통신·보험처럼 목적이 명시되면 그 의미를 우선하고, 매월 출금된다는 이유로 구독이라고 정하지 않는다.
- 상호 하나로 업종·구매 물품·가족 관계를 단정하지 않는다. 같은 통신사라도 통신료/기기 구매, 보험사라도 보험료/대출금, 마트라도 식재료/전자제품을 구분한다. 일반 이체 적요만 있으면 유보한다.
- 환불·취소가 `in`이어도 새 수입으로 바꾸지 않는다. 원거래·잔액 반영과 표시 의미는 별개다. 대출 원금·보증금 반환·투자 회수·상환도 방향만으로 수입/소비를 확정하지 않는다.
- `card_account_pair`는 카드/계좌의 동일 사건 관계이며 **청구대금 납부 증거가 아니다**. 현재 최소 입력에는 청구·지급 연결의 상세 근거가 없으므로 새로운 기본 `card_payment` 판정은 제공하지 않는다. 기존 값 보존과 표시용 `card_bill_payment` 후보는 구분한다. 청구 근거 투영은 후속 계약 범위다.

## 업무별 입출력

실행 가능한 자료 규격은 [거래 입력](../../ai/contracts/transactionMeaning.input.schema.json)·[거래 출력](../../ai/contracts/transactionMeaning.output.schema.json)·[반복 입력](../../ai/contracts/recurringMeaning.input.schema.json)·[반복 출력](../../ai/contracts/recurringMeaning.output.schema.json)이다. JSON Schema 생성 원본은 [build_schemas.py](../testing/analysis/build_schemas.py)이며 게시 파일과 자동 대조한다. 금융 응답에 필드를 추가하는 규격이 아니다.

| 구분      | Flutter → 서버                                | 모델 → 서버 → Flutter                                              |
| --------- | --------------------------------------------- | ------------------------------------------------------------------ |
| 거래 의미 | 대상 거래 ID, 공개 근거, 명시 관계, 기존 분류 | itemKey별 기본 분류 후보와 세부 의미 후보 각각의 상태·사유·근거 ID |
| 반복 의미 | 기존 RecurringCandidate + 로컬 features       | 입력 candidateKey, 표시 이름, 세부 의미 후보·사유·근거 ID          |

공통 입력은 `contractVersion`, `semanticTaskKind`, `context`, `items`, `transactions`, `relations`, `unavailableReferences`, `currentClassifications`, `candidates`다. itemKey는 응답 대응용이며 분석 기억의 영구 식별이 아니다. 현재 의미 입력은 본문 제출의 `input` 규격이다. 접수 descriptor의 `candidateIds`와 의미 본문의 단일 `candidateKey`는 서버가 같은 대상인지 대조한다.

- `context`: 금융 v4, 10진 문자열 dataVersion, sourceVersion, ruleVersion, 오프셋 있는 asOf, 정수 inputRevision/localSessionEpoch, 선택 계좌 집합. dataVersion의 bigint 상한을 검사한다. 세션은 인증 헤더로 검증하며 사용자 ID를 본문에서 받지 않는다.
- `transactions`: 거래 ID·원천 종류·방향·상태·반영 이유·nullable 거래명/적요·원거래 ID만 사용한다. 공개 앱 입력은 유지하고, 서버가 현재 권한을 확인한 요청 거래의 금액·실제 날짜·계좌/카드 대체 ID·asOf를 모델 전용으로 보충한다. 계좌번호·잔액·인증·비공개 정답은 전달하지 않는다. 세부 경계는 [실행 설정](analysis-runtime.md#원천-입력과-앱-호환성)을 따른다. 서버는 현재 권한과 실제 DB 값에 대조해야 한다. 모델 입력 절약을 이유로 관계를 지우지는 않는다.
- `relations`: 현재 공개된 명시 관계의 kind/fromId/toId만 투영한다. 서버가 원천의 evidenceRef·소유권을 확인한다. 공개된 미확보 원거래는 unavailableReferences로 구분하며 숨겨진 타 사용자/미연결 ID를 복원하지 않는다.
- `currentClassifications`: 해당 거래의 기존 값이다. 출처를 검증하지 않은 값을 정답/사용자 확인으로 표시하지 않는다. 출력이 기존 비null 값과 충돌하면 적용을 막고 확인 대상으로 남긴다. unknown을 기존 DB 분류를 null로 덮는 명령으로 쓰지 않는다.
- `features`: occurrenceCount, observedMonths, dayWithinRule, amountWithinRule, hasUnresolvedReversal. 모두 **Flutter 산출**이다. 서버는 허용 타입·버전·근거·로컬 판정의 준비 상태만 확인하며 중앙값/일자 편차/회차를 계산하지 않는다. 3개월·3회·기존 날짜/금액 편차 규칙은 [계산 기준](../../../docs/calculation-rules.md)이 원본이다.
- 반복 suggestedAmountKRW/suggestedDay는 기존 후보를 보존하지만 모델 투영에서 제외한다. 원화 상한은 기존 Money 규칙이다. 모델은 이름을 제안할 수 있으나 금액·날짜·승인·새 후보 ID를 만들 수 없다.
- 응답 순서는 의미가 없다. itemKey 집합이 정확히 일치해야 하며 누락·중복·허용 밖 ID·필드를 거절한다. 두 종류 모두 형식상 정상 unknown과 통신 실패를 구분한다. 표시 이유는 240자, 반복 이름은 80자 이내의 계약 작성값이며 실제 품질/토큰은 미측정이다.

모델의 confidence 숫자를 정답 확률이나 자동 승인 조건으로 사용하지 않는다. 메모리 중요보존/참조 지정은 같은 공급자 응답의 내부 `{output, memories}` 봉투로 받는다. `output`은 기존 의미 출력 그대로이며, `memories`는 입력 itemKey별 `active`, `isReference`, `important`, `referencePolicy`, `reason`을 가진다. 누락·중복·허용 밖 itemKey 및 important=true/isReference=false를 거절한다. 출력 의미 항목에 플래그를 끼워 넣거나 별도 메타데이터용 모델 호출을 추가하지 않는다. 구조·지침은 `StorageContract`를 따른다. 실제 보존은 API의 사용자·근거·삭제 차단 검증 이후다.

## Flutter 전달·재사용 경계

모델의 raw 출력은 그대로 공개하지 않는다. 실제 서비스는 검증 후 기억별 암호화 저장에 성공한 결과를 [분석 API](analysis-api.md)의 상태/사용 가능 범위와 함께 전달해야 한다. 이 순서의 HTTP·저장 연결을 추가했으며 실제 DB·HTTP 검사는 별도로 실행한다. 오프라인/모의 공급자 통과는 실제 LLM 정확도·KMS 운영·모바일 통합의 완료를 뜻하지 않는다.

- 작업 상태와 resultAvailability, 현재 응답 context와 최초 분석 provenance를 분리한다. 원래 sourceVersion/asOf를 현재 값으로 덮어 쓰지 않는다. 최초 화면의 선택 계좌·epoch/revision은 공개 provenance에 포함하지 않는다. Flutter는 세션 epoch·revision·현재 입력·권한에 맞는 결과만 사용한다.
- 기본 분류와 세부 의미는 독립 표시 후보다. 금액·급여 확인·청구 의무·계획을 자동 변경하지 않는다. 후보 이름·설명은 식별자나 실행 명령으로 쓰지 않는다.
- 재사용 지문은 의미 작업·관련 원천/관계·관련 분류·로컬 특징·정책/모델/프롬프트/응답 버전에 의존한다. 전체 dataVersion 상승만으로 유효 결과를 일괄 폐기하지 않는다. 현재 권한/원천은 매번 재검증한다.
- 정규 JSON·UTF-8 SHA-256의 기억/근거 지문과 개별 기억 응답은 [분석 API](analysis-api.md#21-입력-지문기억-식별)를 따른다. itemKey·epoch/revision·전체 dataVersion·조회 시각은 동일 기억 식별을 바꾸지 않고, 모델/프롬프트 버전은 캐시 자격에만 반영한다. 모든 항목이 불가하면 최상위 missing과 개별 실제 사유를 반환한다. B는 공개 최소 입력의 inputHashHint를 재현하며 서버의 실제 DB 결합 지문은 제출하지 않는다. 서버는 관련 금액·날짜 변경을 캐시/삭제 근거에 반영한다. 모델 전용 원천 보충은 공개 입력 지문 계약을 바꾸지 않으며 별도 프롬프트 버전으로 구분한다. B의 같은 직렬화·응답 파서는 아직 공동 실행 검증 전이다.
- B는 Snapshot+전체 거래 페이지의 버전·asOf·coverage·관계·제한 정보를 유지하고 첫 Snapshot/후속 페이지의 같은 ID·다른 원천을 거절해야 한다. `nextCursor=null`만으로 완전 자료라고 간주하지 않는다.

읽기 검사에서 확인한 B 보완 대상: [financial_snapshot.dart](../../mobile/lib/data/financial_snapshot.dart)의 nullable merchantName·관계/coverage 보존·enum 검사와 [transaction_history.dart](../../mobile/lib/data/connection/transaction_history.dart)의 첫 Snapshot 중복 대조. 실제 수정·앱 입력 생성/응답 parser 테스트는 B 담당이다. 2026-11-04 공유 순수 Dart에 반복 후보·features·의미 결과 결합·확정 계획 투영을 추가했다([계산 연결](../../../packages/payse_calculation/docs/recurring.md)). 모바일 원천 어댑터와 HTTP 연결은 별도 인수 대상이며, [Java·Dart 공통 합의](../../../docs/analysis-protocol.md)의 30개 지문 사례와 모의 서버로 대조한다.

## 평가·정확도·비용

[평가 안내](../testing/analysis/README.md)를 따른다. 원본 104개는 보존하고, 확장 생성기로 **5,083개 합성 개발 사례(거래 5,078·반복 5, 명목 사례군 344)**를 검증한다. 이름·숫자만 다른 기존 별칭 5개는 확장 집계에서 제외했다. 근거의 부정/정정·미실행/실패·과거/현재·원천 관계·누락·충돌, 원거래 접근 조건과 짧은 은행 적요를 포함한다. 같은 생성 문법의 사례군은 연결된 개발 집합 하나이며 **독립 최종 10만 건은 아직 준비되지 않았다**.

목표는 **PAYSE 전체 판단의 서로 다른 거래 100,000건에서 기본 분류/세부 의미 오류·불필요 유보·누락/실패를 합쳐 10건 이하(0.01%)**다. 같은 거래에서 여러 오류가 나도 1건이다. 판단 불가능한 입력의 올바른 unknown은 정답이다. 반복 의미의 품질은 별도 집계하며 이 거래 목표의 분모로 섞지 않는다. 원천 확인·사용자 정정·유효 결과 재사용·LLM 처리의 최종 답을 같은 기준으로 평가하고 LLM 처리분은 별도 보고한다. 실제 전체 경로/모델 평가·목표 달성은 미검증이다. 입력이 충분한데 분류표에 코드가 없으면 안전한 unknown 응답은 허용하되 목표 평가에서는 분류 범위 부족 오류로 센다.

원천 데이터·허용 정답·판정 가능 여부를 사람이 검토한 고정 최종셋이 필요하다. 단순 이름/ID 치환이나 같은 거래 반복을 10만 개 독립 근거로 세지 않는다. 프롬프트 조정에 쓴 calibration과 최종셋을 사용자·기간·거래군 기준으로 분리한다. 최종셋을 보고 바꾼 프롬프트의 결과를 같은 독립 검증으로 재보고하지 않는다.

현재 외부/유료 호출 0회. 추후 작은 표본에서 실제 토큰·품질을 측정하고 비용 추정 후 단계적으로 확대한다. 동일 고정 후보에서 11오류가 관측되면 그 최종 목표는 통과할 수 없으므로 남은 호출을 중단할 수 있다. 실패를 숨기거나 다른 모델 결과로 조용히 교체하지 않는다. 기존 API 총예산/차단선은 유지하며 토큰 수 미측정을 0으로 보고하지 않는다.

현재 확장셋에는 단일 의미로 표현할 수 없는 복수 목적 281개·목록 밖 서비스 7개가 있다. 올바른 unknown 형식이어도 처리 범위 부족 288개로 집계한다. 새 복합 의미/세부 코드 또는 금융 분할을 임의로 추가하지 않는다. 의미 기준표의 positive/contrast와 예시 의존 basicTypePolicy는 모델 입력에서 제외한다.

오프라인 도구의 성공은 실제 API·LLM의 정확도 향상 근거가 아니다. 현재 채점 계층은 분석 후보이며, 기존 저장 분류와 후보를 합친 최종 PAYSE 판단 어댑터는 미구현이다. 유효 unknown 결과의 재사용은 처리 완료/실패 구분을 유지하고 기존 분류를 삭제하지 않는다. 입력 압축·개별 결과 사전 검사는 금융 응답 v4·DB·모바일을 변경하지 않으며 운영 권한 검증을 대신하지 않는다.

근거: [OpenAI 평가 지침](https://developers.openai.com/api/docs/guides/evaluation-best-practices)은 업무별 평가·반례·사람 검토, [구조화 출력](https://developers.openai.com/api/docs/guides/structured-outputs)은 형식 준수와 내용 오류의 구분, [최적화 절차](https://developers.openai.com/api/docs/guides/model-optimization)는 기준 평가 후 개선의 참고다. [Plaid 분류 이행 안내](https://plaid.com/docs/transactions/pfc-migration/)는 입금/대출/이체 등 세분류와 버전 분리의 시장 사례이며 PAYSE 코드·한국어 기준·정확도를 검증하는 자료는 아니다.

## API 원천 대조와 지원 경계

`AnalysisEvidence`는 인증된 `FinancialRepository.load` 결과의 전체 거래에서 원천 8개 필드·현재 분류·명시 관계·활성 금융사 연결을 대조한다. 첫100건에 없다는 이유로 존재하지 않는 거래나 미확보 원거래로 취급하지 않는다. 기존 비null 분류와 관련 명시 관계를 빼서 판정 충돌 검사를 우회하지 못한다. 평가용 `verified=true`는 요청·권한·원천 사실의 증명이 아니다.

공개되지 않은 원거래 ID를 unavailableReferences로 복원하거나 생략을 null로 바꾸지 않는다. 미확보 사유만으로 소유·기관 공개 권한을 인정하지 않는다. 현재 DB의 referenceResolutions는 ID·상태·사유만 제공하므로 실제 미확보 원거래를 포함한 입력은 기존 금융 API와 동일하게 503 TEMPORARILY_UNAVAILABLE로 거절한다. 검증 가능한 원천 관계의 권한 근거를 확보한 뒤 해당 경로를 지원해야 하며, 클라이언트의 표식만으로 허용하지 않는다. 미연결 원거래도 현 입력 규격으로 복원하지 않는다. 이 제한을 이유로 금융 원천·계산 규칙을 변경하지 않으며 서버는 로컬 후보 수치를 다시 계산하지 않는다.

현재 금융 페이지 구현의 미확보 원거래 공개/제한 표식과 B의 분석 입력 생성은 별도 호환 확인 대상이다. 이 검증기를 추가한 사실만으로 모든 미확보 사례의 모바일→API 흐름이 완성됐다고 보고하지 않는다.
