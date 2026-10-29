# #22 인증 HTTP 구현 인계

2026-10-28. 기존 AuthService·Repository·PostgreSQL 001~004를 재사용했다. 새 DB 테이블·금융 필드·모바일 파일을 추가하거나 수정하지 않았다.

## 실제 연결한 경로

- `POST /demo-sessions`: IP 기록 커밋 → 엄격한 JSON 검사·자격 대조·기존 활성 세션 거절 → 커밋 성공 후 201과 최초 토큰.
- `POST /demo-sessions/current/reverify`: IP 기록 커밋 → 토큰 확인 → 본문·조합 검사 → 최종 세션/계정 재검증 → 200. 새 토큰 없음.
- `DELETE /demo-sessions/current`: 본문 없이 현재 토큰 세션만 종료 → 204. 이미 무효면 401. 금융 자료·PIN 변경 없음.

외부 필드·오류·헤더는 [공통 API 계약](../../../../docs/api-contract.md)을 따른다. 내부 결과를 외부 DTO로 직접 노출하지 않는다. 확정된 인증 본문 4096바이트 상한과 재확인의 토큰 오류 우선순위를 반영했다. IP 제한 429/저장 실패 503은 그대로다.

`AuthHttpInput`은 본문/Bearer 해석, `AuthHttpResponse`는 공개 DTO·오류·no-store·401 Bearer·올림한 Retry-After를 담당한다. `AuthService`의 지연 입력 콜백은 HTTP 파싱 전에 IP 기록이 커밋되게 한다. 재확인 사전 잠금은 즉시 반환하고 최종 조합→사용자 잠금 순서를 유지한다.

## 실행 조건

기존 [인증 DB](../auth-database.md)와 [암호 설정](../auth-foundation.md)의 명시적 DB/키 설정이 필요하다. `database`+`auth` 프로필, `PAYSE_AUTH_PEER_MODE=direct`, `server.forward-headers-strategy=none`을 사용한다. 기본 바인딩은 127.0.0.1이다. 프록시 신뢰 모드를 임의로 추가하지 않았다.

```powershell
# 기존 안내대로 DB·역할·서버 비밀을 먼저 준비한 로컬 개발 환경에서 실행
Set-Location apps/api
$env:PAYSE_AUTH_PEER_MODE = "direct"
.\gradlew.bat bootRun --args="--spring.profiles.active=database,auth"
```

기동은 DB 마이그레이션·DISABLED 데모 코드 활성화·더미 적재를 실행하지 않는다. 실제 계정 준비와 운영 자격은 별도다. 휴대폰/팀원 외부 접속을 위한 HTTPS·접속 주소·신뢰 프록시·방화벽과 Flutter HTTP/보안 저장소 연결은 완료하지 않았다. 로컬 HTTP 검사를 외부 배포 완료로 해석하지 않는다.

## 검증 방법과 인계

```powershell
# 저장소 루트, 새 경로만 사용. 기존 DB 주소를 받지 않는 격리 검사
python -B apps/api/database/test_session_service.py --pg-bin "C:\Program Files\PostgreSQL\15\bin" --work-dir "C:\검증경로\새폴더"
node scripts/harness/verify-change.mjs --task docs/tasks/PAYSE-AUTH-HTTP-22-20261028.json
```

실행기는 실제 서버·PostgreSQL의 HTTP 검사와 기존 JDBC/서비스 회귀를 실행하고 건너뜀을 성공으로 처리하지 않는다. 기본 Gradle 검사에서는 명시적 검사 DB가 없으면 DB 의존 테스트가 건너뛰어지므로 두 결과를 구분한다.

B는 기존 Fake 인증을 실제 HTTP 저장소로 연결할 때 토큰의 안전한 기기 저장과 상태 정리를 구현한다. 유효 토큰의 422/429/503을 로그아웃으로 취급하지 않으며 `SESSION_INVALID`와 전송 실패를 구분한다. 재확인 200에는 accessToken이 없고 PIN은 계속 로컬이다. 신규 사용자 필드를 요구하지 않는다.

#22에는 아직 Snapshot·거래 페이지·금융사 연결 조회와 관련 HTTP 검증이 남아 있다. 탈퇴·설정 저장·LLM 경로는 열지 않았다. 이 작업만으로 #22·#23·#32를 종료하지 않는다.

## 공통 문서 정합성 기록

2026-10-28 data 역할 검사에서 공통 문서 수정 1건이 범위 밖으로 검출되어 원복했다. 그 발생 기록은 보존한다. 2026-10-29 사용자가 취소 날짜·JOIN·공통 계약 보완을 명시 승인하여 별도 integration 작업 명세를 작성했다. 이 승인 범위에서 공통 API의 실제 세 HTTP 경로 상태·4096바이트 확정·재확인 토큰 오류 우선순위도 기존 결정과 일치시켰다. 검사 정책은 변경하지 않았다.

## #29 거래 표시 자료 인계

같은 작업에 팀원 요청의 거래명/적요 개선을 포함했다. 계좌 거래 147건인 demo-ready를 포함한 금융 Snapshot 20개와 manifest를 재생성하고 catalog의 현재 전이 버전 포인터를 맞췄다. alpha-unconnected·server-seeds·은행 기준정보와 catalog의 계산 기대값은 그대로다. 거래 표시·원천 버전 이외의 금융 필드, 사용자 설정·승인 기록·관계·계산 기대값을 보존한다. 상세 규칙은 [금융 자료 준비](../../fixtures/docs/dummy-data.md)를 따른다.

B의 기존 모바일 사본 중 demo-ready, alpha-ready, alpha-shock, salary-wait, beta-ready, gamma-month-end 6개는 새 원본으로 동기화가 필요하다. alpha-unconnected는 변경하지 않았다. 현재 SourceTransaction은 description을 읽지 않으므로 거래 방법 표시를 위해서는 B가 필드 파싱·전달·화면 표시를 연결해야 한다. API 작업에서는 모바일 자산·모델·테스트를 수정하지 않았으며 앱 표시나 모바일 사본 동일성 검사를 완료로 기록하지 않는다. 별도 세 계정 프로필의 도입 여부도 기존 인계와 같다.

`apps/mobile/test/data/fixture_copy_test.dart`는 API 원본과 앱 사본 바이트를 비교하므로 동기화 전 6개 사례가 불일치한다. API 경로만 바뀌면 현재 Flutter 워크플로가 자동 실행되지 않을 수 있지만 이는 호환 통과 근거가 아니다. B의 6개 사본 동기화와 모바일 검증을 통합 전 확인한다.

사본 동기화 시 `apps/mobile/test/data/fake_repository_test.dart`의 `alpha-ready keeps integer amounts, as-of and versions` 검사에 있는 alpha-ready sourceVersion 기대값도 `fixture-3:alpha:2026-10-19:base:reversals-1:labels-1`로 갱신한다.

## 2026-10-29 취소·환불과 날짜 보완

관련 이슈 #22·#29. 세 계정의 기본 금융 자료에 승인 취소 30,000원·전액 환불 18,000원·부분 환불 12,000원을 각각 1건씩 추가했다. 각 사건에 신규 원결제 1건이 연결되며 기존 원결제·잔액·은행 기장·청구·계산 기대값을 수정하지 않는다. 기존 취소/환불 예외 사례는 보존하므로 해당 파생 사례에는 4건이 있을 수 있다. failed-card-history는 실패한 카드사의 자료를 누락하는 기존 전제를 유지한다. 반복 승인 당시 버전도 보존한다.

`cancellationDate?: Date|null`를 공통 거래·fixture·DB에 추가했다. 날짜만 있는 경우 시각을 만들지 않는다. 원천 금액·방향·원거래 관계와 공개 권한의 기준은 [데이터 모델](../../../../docs/data-model.md)과 [응답 계약](../../../../docs/api-response-models.md)을 따른다. 새 준비 자료 표식은 `:reversals-1:labels-1`이며 선택 필드 추가여서 DRAFT/API v3는 유지한다.

Java TransactionRepository.findLink는 동일 인증 트랜잭션의 사용자 문맥과 기관 연결을 확인하고 원거래를 LEFT JOIN한다. 원참조 없음·확보·미확보·기관 제한을 내부 상태로 구분한다. 공개 거래 HTTP 경로는 아직 없으며 미확보 원거래의 공개 권한을 입증하는 기능까지 구현한 것은 아니다. 신규 조회 객체를 그대로 API 응답으로 직렬화하지 않는다.

B 반영 필요: 앞의 6개 사본과 sourceVersion 기대값을 동기화하고, SourceTransaction의 cancellationDate·description 및 취소/환불 화면에 필요한 refundDate·occurredAt·occurredAtBasis·originalTransactionId 파싱을 연결한다. 취소일 우선, 없으면 확인된 cancellation 시각의 한국 날짜, 모두 없으면 날짜 미상으로 처리한다. 원결제 상세는 확인된 관련 거래에만 표시한다. 모바일·계산 파일은 API 작업에서 수정하지 않았다. 금융 계산·새 HTTP 거래 API·기존 DB 이행을 완료로 보고하지 않는다.

검사: Python fixture 회귀, 새 PostgreSQL의 취소일 CHECK·005 이행·중간 실패 롤백, 기존 175컬럼 이행 회귀, JDBC JOIN·인증 HTTP 회귀, 통합 작업 하네스. 실제 실행 결과와 건너뜀은 해당 작업 PR에 기록한다. 최종 작업 명세는 docs/tasks/PAYSE-CARD-RETURN-CONTRACT-20261029.json이다.
