# 공통 사용자·금융 저장 구조

필드·타입·제약의 단일 기준은 [DB 사전](../../../docs/database-schema.md)이다. 이 문서는 준비·이행 경계만 정의한다.

- `users(id,name,phone,code_verifier,data_version,created_at)`: 일반 사용자 기본 정보. 이름·전화번호만으로 로그인할 수 없다.
- `user_attributes(user_id,salary_day,salary_amount_krw,salary_account_id,card_plan_overrides)`: 사용자당 한 행의 타입이 정해진 속성. 현재 정의되지 않은 자유 속성이나 중복 이름은 추가하지 않는다.
- 계좌·카드·거래·청구·설정은 동일한 users.id를 소유자로 사용한다. 계좌·카드의 기관은 공통 institutions.code를 참조한다. 속성 행 생성은 사용자 초기화 트랜잭션 책임이며 FK만으로 자식 행 존재를 강제하지 않는다.
- `demo_sessions`와 `/demo-sessions`는 승인된 예외다. 사용자/금융 테이블에 demo/test 구분 컬럼을 두지 않는다. 준비 도구의 고정 계정 세 개는 서비스 DB의 사용자 수 제한이 아니다.
- 기본 적재와 선택한 검증 사례의 차이는 [준비 도구](../fixtures/docs/dummy-data.md)에 정의한다. 일반 API는 시나리오 ID를 받아 사건을 실행하지 않는다.

## 기존 DB 이행

새 빈 DB에는 현재 `001_initial.sql` → `002_storage_guards.sql` → 기관 기준정보 → 기본 사용자/금융 SQL 순서로 적재한다. 기존 DB에는 초기 DDL이나 INSERT 시드를 재실행하지 않는다.

기존 DB의 은행 기준 행 보완은 [기관 기준정보 도구](../reference_data/docs/README.md)의 `--synchronize-reviewed` SQL로 별도 실행한다. 사용자·금융 스키마 이행은 기관의 이름이나 기존 행을 바꾸지 않는다. 새 금융 준비 자료를 사용하려면 공통 스키마와 기관 기준정보가 모두 맞아야 한다.

기존 DB는 전체 DB 백업을 별도로 확보한 뒤 `database/migrate_common_storage.py`의 `--plan`으로 외부 검토 파일을 만든다. `--psql`, `--database`, `--backup`, `--timeout-seconds`, `--lock-timeout-ms`는 필수다. 출력 SHA-256과 대상 DB를 확인한 뒤 같은 인자와 `--apply --expected-sha256 <검토한 값>`을 사용한다. 검토 파일은 전체 DB 백업을 대체하지 않는다.

도구는 demo_users→users, synthetic_phone→phone, user_settings→user_attributes를 이름만 바꾸고 공통 구조 v2 저장 트리거를 적용한다. 이 단계는 `database/migrations/002_storage_guards.v2.sql`에 고정된 함수만 사용하며 payMonth를 보충하거나 급여 원천 버전을 올리지 않는다. demo_event_receipts는 모든 기존 행을 검토 파일에 보존한 뒤 삭제한다. 기존 write_receipts의 과거 값은 이력으로 보존한다. 새 준비 이력은 일반 import_user_state와 실제 상태 해시를 사용하며 과거 API가 실행된 것처럼 기록하지 않는다.

적용 직전에 테이블을 잠그고 검토 당시 DB 식별·원천·스키마와 대조한다. ID·금액·날짜를 포함한 남은 모든 행의 해시가 달라지면 롤백한다. 미승인 컬럼·구 테이블 참조 함수·제거 대상 의존성·사후 변경·이전 계획 재사용은 거절한다. 다른 구버전이나 사용자 정의 변경은 별도 검토가 필요하다. 과거 두 이름/installation_id가 남아 있으면 [과거 이름 이행](identity-migration.md)을 먼저 처리한다.

배치 설치는 DB나 모바일을 실행·수정하지 않는다. 실제 HTTP 인증·조회·저장 구현 여부는 코드 검증 결과와 구분한다. 금융 계산은 Flutter가 담당한다.

## 급여 원천 v2에서 v3으로 이행

일반 사용자 공통 구조로 이행한 기존 DB는 `database/migrate_salary_evidence.py`로 급여 계약을 별도 전환한다. 전체 DB 백업을 확보하고 도구의 `--help`에 따라 명시 매핑을 준비한 뒤 `--plan`의 검토 파일·해시를 확인하고 `--apply`한다. 배치파일은 이 도구를 실행하지 않는다.

명시 매핑은 사용자 ID, 검토한 기존 sourceVersion, 새 sourceVersion 및 기존 근거 내용의 해시와 payMonth를 연결한다. 근거 배열 인덱스·표시명·입금월·현재 salaryDay·날짜 근접성으로 회차를 추정하지 않는다. 근거가 없는 사용자는 빈 매핑을 명시하며 새 근거를 추가하지 않는다. 누락·중복·원천/DB 식별 변경·사후 수정은 적용을 중단한다.

도구는 source_contexts와 accounts/cards/transactions/statements의 현재 source_version, source schema_version, 기존 근거의 payMonth만 같은 트랜잭션에서 변경하고 v3 검증을 적용한다. 사용자의 data_version, ID·금액·날짜·설정·정산·승인 당시 source_version은 보존한다. 새 빈 DB에는 이 도구 없이 현재 초기 DDL과 v3 자료를 사용한다. v2 DB에 초기 DDL·새 guard만 개별 적용하거나 기존 데이터를 재적재하지 않는다.
