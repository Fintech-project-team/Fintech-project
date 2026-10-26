# 2026-10-23 급여 회차 계약 인계

관련 이슈: #92(A 계약·저장 검증). #28 정상 사례의 누락 급여 근거는 별도 보완한다. 현재 계약의 단일 기준은 루트 data-model·api-response-models·database-schema 문서다.

| 대상          | A 반영                                           | B 후속 반영·검증                                                                                                                                                |
| ------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 원천/API 형식 | PAYSE-DRAFT-3 / PAYSE-API-0.6-3, PAYSE-FIXTURE-3 | FinancialSnapshot.supportedSchemas, SnapshotProjector, FakeRepository의 지원 버전·입력 파싱·자산 복사 검사 갱신. v2에 없는 payMonth를 날짜로 추정해 채우지 않음 |
| 급여 근거     | payMonth 필수, 기존 3개 급여 사례는 2026-10      | SalaryReceipt 입력에 명목 회차 추가. 근거 []와 접근 제한에 따른 미수신 null 구분                                                                                |
| 회차 선택     | 명목 월로 유일 식별                              | 다음 회차는 payMonth+1. 이동한 expectedPayDate의 달에 1을 더하지 않음                                                                                           |
| 구간 경계     | 확인된 변경 예정일·D5 적용 계약                  | resolveSalaryCycle와 projectPeriods 두 경로에서 명시 일정 우선·반복 가정 구분·현재 월급일 변경 후 과거 근거 보존 검증                                           |
| 중복 날짜     | 서로 다른 payMonth·같은 예정일은 원천/DB에 보존  | 해당 회차 구간 계산만 정보 부족. 원천 삭제·회차 병합·임의 순서·0일 구간 생성 금지                                                                               |
| 접근 제한     | 기존 salary.receiptEvidence 부모 생략/표식 유지  | 비공개 근거의 payMonth만 남기지 않음. confirmed 상태를 unknown으로 바꿔 공개하지 않음                                                                           |
| 조기 입금     | 예정일 유지, 명시 거래·confirmed 유지            | 같은 asOf/sourceVersion의 상태만 전달. 이미 반영된 급여를 잔액에 다시 더하지 않음                                                                               |
| DB 이행       | v2 공통 구조 이행과 명시 매핑 v3 이행 분리       | 모바일이 SQL·이행 도구를 실행하지 않음                                                                                                                          |

후속 수정 경로는 `apps/mobile/lib/data/financial_snapshot.dart`, `lib/data/connection/snapshot_projector.dart`, 관련 repository·자산·테스트와 `packages/payse_calculation/lib/src/inputs.dart`, `salary_cycle.dart`, `projection.dart` 및 대응 테스트·계산 문서다. A는 이 경로들을 수정하지 않았다. 기존 API 자산 6개의 표시명 동기화 대기도 새 버전 동기화와 함께 확인한다.

필수 공동 사례는 11월 1일→10월 30일 이동, 10월 31일→11월 2일 이동, 10월 25일 예정·24일 실제 입금, 동일 회차 중복, 다른 회차·같은 예정일, payMonth 누락, 월급일 설정 변경, 근거 접근 제한, 나중의 confirmed를 과거 스냅샷에 혼합하는 입력 거절이다. 유효한 이동 회차가 receiptScheduleMismatch로 다시 분류되지 않아야 한다.

정상 ready 사례 세 개의 receiptEvidence는 빈 배열로 보존했다. alpha/beta에는 직전 급여 거래가 있으나 명시 근거 연결이 없고, gamma-month-end에는 필요한 2027년 1월 급여 거래도 없다. 이 보완은 #28에서 별도로 확인하며 #92 완료나 정상 홈 동작을 대신하지 않는다.

기존 B 파서는 v2만 지원한다. A 계약/저장 검사 통과를 모바일·계산 통합 통과로 표시하지 않는다. B 반영 뒤 전체 verify-change와 앱/계산 테스트를 실행한다. 실제 API HTTP 응답 구현과 사용자 DB 이행도 이 파일 설치로 완료되지 않는다.
