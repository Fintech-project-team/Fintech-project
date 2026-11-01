# 급여 회차별 안내 상태

큰 “월급 입금 확인이 필요해요” 안내의 닫기 기록을 관리한다. 사용자 전역 플래그가 아니며, **인증 사용자와 명목 급여 회차 payMonth**가 대상이다. 이 API를 구현·연동할 때 이 문서와 [공통 API 계약](../../../docs/api-contract.md)을 필수 참조한다.

## 책임과 보존

- 같은 회차는 앱 재실행·재로그인·서버 재시작 후에도 닫기 기록을 유지한다. 급여일·금액·계좌·예정일 변경만으로 같은 회차의 큰 안내를 다시 펼치지 않는다.
- 작은 “월급 입금 확인 필요” 표시·직접 확인 경로·계산 제한 사유는 Flutter가 유지한다. 입금 확인 상태와 안내 표시 상태는 다르다.
- 다른 회차는 독립적이다. 두 회차의 예정일이 같아도 payMonth로 구분하며, 11월분이 10월에 지급 예정이면 2026-11을 사용한다.
- 원천 receiptEvidence가 없는 회차도 안내 상태만 저장한다. 나중에 같은 payMonth의 원천이 들어오면 같은 표시 기록을 참조한다. 입금 근거·예정일·거래·confirmation을 생성하거나 변경하지 않는다.
- payMonth는 Flutter가 이미 확인한 명목 회차를 전달한다. 회차를 알 수 없으면 요청하지 않는다. 서버가 현재 달·입금월·예정일로 회차를 추정하지 않는다.
- 금융 Snapshot·receiptEvidence·dataVersion·sourceVersion·ruleVersion·write_receipts는 변경하지 않는다. 금융 거래 페이지 cursor도 안내 저장만으로 무효화되지 않는다.
- 닫기 기록은 금융 설정이나 AI 기억이 아니다. 분석 결과의 3개월 만료를 적용하지 않으며 자동 재표시나 초기화 API를 추가하지 않는다. 기존 계정 최종 파쇄 시에는 이 사용자 소유 기록도 먼저 삭제해야 한다. 기존 탈퇴·파쇄 서비스의 미구현 범위를 이 기능으로 완료 처리하지 않는다.
- 일반 사용자 보류의 세션 메모리 원칙 중 **이 급여 건의 큰 안내 닫기만** 영속 보관 예외다. 다른 질문·후보 보류까지 확대하지 않는다.

## 공개 API

기존 database,auth,finance 프로필에 salary-notices를 함께 활성화한 경우에만 제공한다. Bearer·no-store·기존 오류 봉투를 사용한다.

| 경로                                     | 입력                           | 정상 응답                                                           |
| ---------------------------------------- | ------------------------------ | ------------------------------------------------------------------- |
| GET /salary-notices/{payMonth}           | YYYY-MM 경로만. 본문·쿼리 없음 | 200 현재 안내 상태. 기록이 없으면 dismissed=false, dismissedAt=null |
| PUT /salary-notices/{payMonth}/dismissal | 동일 경로 형식. 본문·쿼리 없음 | 200 최초 또는 이미 저장된 동일 안내 상태                            |

성공 응답 키는 contractVersion, userId, payMonth, dismissed, dismissedAt 다섯 개다. contractVersion은 PAYSE-SALARY-NOTICE-1, userId는 현재 인증 소유자, dismissedAt은 DB의 최초 기록 시각(ISO 8601)이다.

```json
{
  "contractVersion": "PAYSE-SALARY-NOTICE-1",
  "userId": "00000000-0000-4000-8000-000000000001",
  "payMonth": "2026-11",
  "dismissed": true,
  "dismissedAt": "2026-10-30T03:00:00Z"
}
```

위 시각·UUID는 형식 설명용 예시이며 실제 계정 ID가 아니다. 응답은 인증된 사용자 UUID와 저장된 시각을 반환한다.

- 인증을 먼저 확인한다. 무효/종료 세션은 401 SESSION_INVALID, 유효 세션의 잘못된 회차·본문·쿼리는 422 VALIDATION_FAILED, 기존 금융 입력 상한 64 KiB 초과는 413 REQUEST_TOO_LARGE다.
- 0001-01~9999-12의 고정 YYYY-MM만 허용한다. 공백·축약 월·날짜·0000년을 보충/교정하지 않는다.
- userId·dismissed·dismissedAt·confirmation을 요청으로 받지 않는다. 금융 버전/멱등 키 헤더와 Content-Encoding도 받지 않는다.
- PUT 자체가 사용자+회차의 고정 닫기 자원을 설정한다. 별도 멱등 키 없이 반복 요청은 최초 기록을 유지한다. 응답 유실 시 같은 PUT 재전송 또는 GET으로 확인한다.
- 인증 확인·사용자 잠금·INSERT·SELECT는 같은 JPA 트랜잭션이다. commit 전 실패는 rollback하며 DB/commit 장애는 503 TEMPORARILY_UNAVAILABLE다. commit 이후 응답 유실은 성공 기록을 지우지 않는다.
- 원천 유무·입금 여부는 이 응답으로 판단하지 않는다. 기록 없음은 급여 근거 없음과 다르다. 다른 사용자를 지정하거나 그 상태를 읽는 경로는 없다.

## DB와 코드

payse.salary_notice_dismissals는 user_id UUID, pay_month text, dismissed_at timestamptz를 갖는다. PK(user_id,pay_month), users FK(RESTRICT), 회차 형식·유한 시각 CHECK를 적용한다. 행 존재에서 dismissed를 파생하므로 boolean 컬럼을 중복 저장하지 않는다. 원천이 나중에 들어올 수 있어 salary_evidence 존재를 FK 조건으로 삼지 않는다.

runtime은 강제 RLS 아래 SELECT와 INSERT(user_id,pay_month)만 가능하다. 최초 시각은 DB가 정하며 UPDATE·DELETE·TRUNCATE·시각 지정 INSERT는 허용하지 않는다. 계정 파쇄는 별도 권한의 관리 절차다.

코드는 salary/{controller,service,mapper,dto,vo}로 나눈다. 기존 AuthTransactions·AuthRepository·AuthCrypto·오류 봉투를 재사용한다. 저장은 같은 EntityManager의 바인딩된 native SQL이며 원천 적재나 서버 날짜 계산기가 아니다.

## 적용

1. 기존 001→002→003→004→007까지 준비된 DB에 009_salary_notices.sql을 관리자 절차로 한 번 적용한다. 008 분석 SQL은 필요하지 않다. 기존 DB에 초기 001을 다시 실행하지 않는다.
2. psql -X -v ON_ERROR_STOP=1 -f apps/api/database/009_salary_notices.sql을 기존 배포 접속 설정으로 실행한다. SQL 전체는 하나의 트랜잭션이다.
3. API의 기존 활성 프로필에 salary-notices를 추가한다. 이행·필수 권한이 없으면 기능을 켠 서버는 시작에 실패한다. 프로필을 추가하지 않은 기존 서버는 기존 금융 API만 제공한다.
4. 공개 서버는 기존 HTTPS 배포 기준을 적용한다. 테스트 loopback HTTP를 외부 배포 기준으로 사용하지 않는다.

파일 제공·폐기용 DB 검증과 기존 서비스 DB 적용은 별개다. 이 작업에서 실행 중인 기존 DB에는 SQL을 적용하지 않는다.

## Flutter 연결 시 필수 확인

- result.salaryCycle?.previousPayDate?.payMonth에서 회차가 확인될 때만 호출한다. 없음/접근 제한이면 회차를 추정하지 않는다.
- 기존 안내 종류·예정일·급여 설정 조합 키를 사용자+payMonth로 바꿔야 한다. 사용자별 첫 계산 기록 FirstCalcRecord로 대체하지 않는다.
- 안내 GET 실패가 이미 성공한 금융 Snapshot 조회나 로컬 계산을 실패로 바꾸지 않게 분리한다. 금융 응답에 필드를 추가하지 않는다.
- 닫기 저장의 성공/실패/응답 유실을 구분한다. 낙관적 화면 접기를 하더라도 서버 저장 성공으로 확정하지 않는다.
- 로그아웃·계정 전환 뒤 늦은 응답을 새 사용자에게 적용하지 않는다. 성공 응답의 userId·payMonth와 현재 요청 문맥을 대조한다.
- 큰 안내를 접어도 작은 확인 표시·반영 대기 지출 설명·계산 불가 사유를 숨기지 않는다.

## 검사

실제 PostgreSQL·HTTP 검사는 [DB 테스트](database-tests.md)의 급여 안내 실행기를 사용한다. 회차별 독립성, 근거 없는 회차, 동일 예정일의 여러 회차, 원천 후발 제공, 중복/동시 요청, 최초 시각 보존, 재로그인/서버 재시작, 타 사용자·무효 세션, SQL 취소/롤백, 원천/금융 버전/cursor 보존을 검사한다.

모바일 코드·계산 패키지는 수정하지 않으며 앱 서버 연동·실기기 확인은 별도다. API 검사 통과를 앱 연동 완료로 기록하지 않는다.
