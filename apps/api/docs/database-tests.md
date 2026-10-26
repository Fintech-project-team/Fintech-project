# 데이터베이스 테스트 준비와 실행

저장 계약은 [DB 사전](../../../docs/database-schema.md), 코드 규칙은 [API 필수 규칙](../src/AGENTS.md)이 기준이다. 이 문서는 테스트 대상 선택과 실행만 정의하며 제품 필드·계산 규칙을 추가하지 않는다.

## 준비 자료와 대상 선택

`database/test_context.py`는 검증된 `fixtures/generated`의 catalog에서 `alpha-ready`, `beta-ready`, `gamma-month-end` 사례를 읽는다. 사용자·계좌·지출·정산·배정·반복 버전·영수증은 실제 참조 관계로 찾는다. 표시명·고정 UUID·배열 첫 항목으로 대체하지 않는다. 같은 역할이 없거나 여러 개면 자료 준비 오류다. 여러 건이 필요한 카드 구매 근거는 집합 전체를 검사한다.

`test_context.sql`의 임시 함수는 같은 연결에서 DB의 ID·소유자·관계·자료 버전과 검사에 필요한 사전 상태를 다시 대조한다. 준비 오류는 기대 SQLSTATE를 포착하는 본 검사 밖에서 발생해야 한다. 행이 없는 UPDATE가 성공했다는 이유로 제약 검사를 통과시키지 않는다. 생성한 context를 DB·파일에 영구 저장하거나 서비스의 공통 모델로 사용하지 않는다.

준비 모듈은 주소와 사전 상태만 제공한다. 원화 상한·bigint 넘침·부분 정산의 1원 초과·날짜 경계·기대 SQLSTATE는 각 검사에 명시된 독립 벡터다. 현재 테스트가 전제하는 정산 금액과 반복 회차가 달라지면 전제를 검토해야 하며, DB 구현에서 한도나 정답을 읽어 검사를 자동 변경하지 않는다.

## SQL 검사

별도로 준비한 **로컬 전용 폐기 가능 DB**만 사용한다. `PGHOST`는 `127.0.0.1` 또는 `localhost`, DB명은 `payse_fixture_` 뒤에 소문자·숫자·밑줄이 붙는 이름이어야 한다. 이름 규칙만으로 안전한 DB가 되는 것은 아니므로 테스트 담당자가 데이터와 용도를 확인한다. 연결 자격은 환경 변수/별도 비밀번호 파일에 두고 Git에 저장하지 않는다.

빈 테스트 DB에는 `001_initial.sql`, `002_storage_guards.sql`, 기관 기준 INSERT, 같은 fixture 디렉터리의 선택한 시나리오 INSERT를 순서대로 적재한다. 아래 exporter는 파일만 만들고 DB에 접속하지 않는다. 명시 선택한 세 사례는 테스트 전제이며 앱의 최초 연결 상태를 바꾸는 설정이 아니다.

```powershell
python -B apps/api/reference_data/export_sql.py --out "검증용-새-reference.sql"
python -B apps/api/testing/scenarios/prepare.py apps/api/fixtures/generated `
  --cases alpha-ready beta-ready gamma-month-end --out "검증용-새-seed.sql"

python -B apps/api/database/run_sql_tests.py `
  --psql "검증한-psql-경로" --database payse_fixture_sql_review `
  --fixtures apps/api/fixtures/generated
```

두 번째 명령은 스키마·시드를 생성하거나 기존 DB를 초기화하지 않는다. 준비된 DB에서 제약·극한값·원천/설정 관계·인증 저장의 네 SQL을 실행한다. 각 SQL은 준비 함수와 같은 연결에서 실행되고 ROLLBACK한다. SQL 파일만 단독 실행하면 준비 함수가 없으므로 실패한다. 애플리케이션 서버·HTTP API의 실행은 필요하지 않다.

## 두 연결 경합과 기존 DB 이행

```powershell
python -B apps/api/database/test_native_concurrency.py `
  --psql "검증한-psql-경로" --database payse_fixture_race_review `
  --seed "검증용-새-seed.sql" --fixtures apps/api/fixtures/generated
```

이 명령은 **빈 DB만** 허용하며 초기 DDL·기관 기준·입력 시드를 적재한 뒤 네 SQL과 두 연결 경합을 실행한다. 입력 시드는 기관 기준 SQL 다음에 시나리오 SQL을 연결한 파일이어야 하며, 테스트 담당자가 검토한 로컬 생성 SQL만 사용한다. 활성 세션·버전 비교 갱신·작업 키의 세 경합은 실제 커밋을 수행하므로 전용 DB를 사용한다. 완료 후 DB는 검사 목적으로 남고 자동 삭제하지 않는다. 시드와 fixture가 다르면 준비 검사가 실패한다.

단일 이름 이행은 [별도 이행 회귀 검사](identity-migration.md#회귀-검증)를 따른다. 승인된 세 계정의 과거→현재 매핑은 `fixtures/identity_contract.py`가 기준이다. 그 매핑을 임의 사용자 추정 로직으로 바꾸지 않으며, 검사에서 동일 UUID·표시명을 복사해 조회하지 않는다.

## 검증 범위

`python -B -m unittest discover -s apps/api/tests`는 fixture와 context 준비의 정상·누락·모호성·관계 오류를 검사한다. 실제 PostgreSQL의 SQL·RLS·잠금·경합은 위 별도 명령으로 검증한다. 단위 검사나 JUnit 통과를 실제 DB 검사 완료로 대체하지 않는다. 실행한 PostgreSQL 버전과 미실행 환경을 결과에 기록한다. 팀 목표 버전은 [도구 기준](../../../docs/toolchain.md)을 유지한다.

## 공통 구조 이행 검사

`test_common_storage_migration.py --database payse_fixture_common_review --psql <경로> --temp <검사 임시 폴더>`는 전용 DB의 payse 스키마를 재생성한다. 기존 서비스 DB에서 실행하지 않는다. 임의 추가 사용자, 활성 세션, 남아 있는 시나리오 기록의 외부 보존, 변경된 원천/해시/스키마/함수/권한, 중복 실행 거절을 검사한다. 기존 identity 회귀 검사는 과거 DDL만 사용한다.

## 급여 회차 검사

`test_salary_receipts.sql`은 필수 payMonth·잘못된 형식·동일 회차 중복 거절과 월 경계 이동·서로 다른 회차의 같은 예정일 보존을 검사한다. 원천 보존 뒤 구간 정보 부족 판정은 Flutter 담당이다. SQL의 사용자·거래 ID는 준비 context에서 받으며 명목 회차 프로브는 독립된 테스트 전제다. 입금 거래일에서 월을 추정하는 서비스 규칙으로 사용하지 않는다.

`python -B -m unittest discover -s apps/api/tests`는 기존 검사와 test_salary_receipts.py를 포함한다. 별도 급여 이행 테스트는 검토 매핑·버전 FK·이력 보존·변경 감지·롤백을 실제 폐기용 PostgreSQL에서 검사한다. 실행 인자는 `python -B apps/api/database/test_salary_evidence_migration.py --help`에서 확인한다. 일반 DB에 테스트를 실행하지 않는다.
