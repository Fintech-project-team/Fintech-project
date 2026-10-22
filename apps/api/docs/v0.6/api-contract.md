# v0.6 API 계약

[기준·범위](README.md) · [응답](response-models.md) · [인계·검증](review-checklist.md). 경로는 배포 prefix를 제외한 상대 경로다. HTTPS, UTF-8 JSON, `Authorization: Bearer <opaque-token>`, 인증·금융 응답 `Cache-Control: no-store`를 사용한다.

## 1. 공통 타입·검증

| 타입                  | 규칙                                                                                |
| --------------------- | ----------------------------------------------------------------------------------- |
| ID                    | 표준 UUID 문자열. 출력은 소문자                                                     |
| Version               | 1~9223372036854775807의 10진 문자열, 선행 0 없음. DB bigint와 구분                  |
| Money / PositiveMoney | JSON 원화 정수 0~9조 / 1~9조. 원천 잔액은 절댓값 9조 내 음수 허용                   |
| Date / Time           | 유효 `YYYY-MM-DD` / 오프셋 있는 시각. 업무일 Asia/Seoul. 날짜에 임의 자정 생성 금지 |
| Label                 | 구현 제한안: trim 후 1~80 grapheme. 공백뿐인 값 거절                                |
| W                     | `expectedDataVersion:Version`, `ruleVersion:string`, `idempotencyKey:string`        |

W는 요청 최상위 필드다. 키는 1~128 ASCII 영숫자·점·밑줄·하이픈이며 UUID 사용을 권장한다. 필드 표의 `?`만 생략 가능하다. `|null`은 명시 null 허용이며 PATCH에서 생략과 구별한다.

알 수 없는 쓰기 키, 숫자 문자열·소수·boolean 금액, 중복 ID, 빈 PATCH, 허용하지 않은 null은 422다. 필드 자동 보정·DB 객체 일괄 바인딩은 하지 않는다. 요청 본문 userId·원천 금액·지급 완료 boolean·기기 PIN을 허용하지 않는다. 구현 보호 한도안은 인증 본문 4 KiB, 기타 쓰기 본문 64 KiB이며 초과는 413이다. 응답을 같은 크기로 잘라 반환하지 않는다.

## 2. 인증·탈퇴

| 메서드·경로                          | 요청                                                       | 성공                                                                                           |
| ------------------------------------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| POST /demo-sessions                  | `{name:string,phone:string,code:string,installationId:ID}` | 201 `{userId:ID,name:string,sessionId:ID,accessToken:string,tokenType:"Bearer",issuedAt:Time}` |
| DELETE /demo-sessions/current        | Bearer, 본문 없음                                          | 204, 현재 세션 종료                                                                            |
| POST /demo-sessions/current/reverify | Bearer + `{name:string,phone:string,code:string}`          | 200 `{userId:ID,sessionId:ID,verified:true}`. 새 토큰 없음                                     |
| POST /account-deactivation           | Bearer + `{idempotencyKey:string}`                         | 200 `{receiptId:ID,deactivatedAt:Time,purgeAfter:Time,replayed:boolean}`. 금융 Snapshot 없음   |

이름은 요청·사용자 모델·성공 응답에서 `name` 하나로 사용한다. `POST /demo-sessions`의 201에는 검증된 사용자 레코드의 비어 있지 않은 `name`을 필수 반환한다. 제출 문자열을 그대로 반사하거나 `syntheticName`·`displayName`을 별도 이름 필드로 반환하지 않는다. 재확인 200에는 이름 필드를 추가하지 않는다. 사용자 식별·소유권은 기존 UUID `userId`를 유지한다.

인증 식별값만 정규화 후 공백 없이 저장한다. 허용된 입력 구분자 처리와 거절 기준은 [인증 설계 §2](auth-design.md)를 따른다. 이름 내부 공백을 삭제해 다른 이름으로 바꾸거나 상품명·거래 메모·계좌 별칭의 공백을 일괄 삭제하지 않는다. 이름 이행은 기존 SQL·더미에 아직 구현되지 않았으며 확정된 시드 값과 적용 경계는 같은 설계에 명시한다.

이름·전화번호는 합성 입력만 안내한다. 앞뒤 공백/명시 허용 구분자 정규화는 기존 화면 기준을 따른다. code는 ASCII 숫자 6자리다. 로컬 형식 오류 문구와 서버 자격 존재 여부를 구분한다. 형식에 맞는 자격 불일치·이미 활성 세션 존재·비활성 계정은 같은 `401 AUTH_REJECTED`와 일반 메시지다.

기존 세션 유지·신규 거절·자동 만료 없음은 유지한다. 재확인은 현재 세션 소유자의 자격만 확인한다. 기기 PIN 생성·검사·재설정은 로컬이다. 토큰 원문은 최초 성공 응답에서만 보낸다. 로그인 성공 응답이 유실되어 토큰을 잃었으면 기존 정책대로 운영 세션 종료 전 신규 발급을 허용하지 않는다.

로그아웃·PIN 생성 화면에서 처음으로 돌아가기: 서버 종료 성공(또는 해당 토큰이 이미 무효라는 확인) 뒤 기기 토큰·PIN·금융 메모리를 정리한다. 전송 실패만으로 종료 성공 처리하지 않는다. 종료된 토큰으로 같은 로그아웃을 다시 보내면 401이어도 효과는 중복되지 않는다.

### 인증 시도 제한 — 사용자 확정

- 대상은 로그인과 재확인이다. 정규화한 **이름+전화번호 조합**을 키로 사용하며 code·installationId 변경으로 제한을 우회할 수 없다.
- 최근 5분 동안 자격 대조 실패가 5회면 5번째 실패부터 429, 그 시점부터 5분 차단한다. 차단 중 시도는 종료 시각을 연장하지 않는다. 차단 종료 시 이전 실패 창을 초기화한다.
- 존재하지 않는 조합에도 같은 규칙을 적용한다. 정확한 자격이지만 기존 세션/비활성 때문에 발급이 거절된 경우는 실패 누적 대신 IP 제한으로 처리하며 응답으로 사유를 구분하지 않는다.
- IP별 최근 60초 인증 요청 60개까지 허용하고 61번째부터 429다. 성공·실패·형식 오류·재확인 요청을 함께 센다.
- 차단 응답은 `Retry-After` 초를 제공한다. 두 제한이 겹치면 더 늦게 해제되는 시간을 쓴다.
- 제한 저장소 장애 시 우회 허용하지 않고 인증에 503을 반환한다. 정상 금융 조회를 인증 시도 횟수로 세지 않는다.
- 동시 요청·서버 재시작으로 위 제한을 우회할 수 없어야 한다. 저장·동시성 구현은 후속 인증 작업 범위다.

공식 자료는 일반 오류·인증 제한의 필요성 근거다. **5회/5분·60회/분 숫자는 사용자 선택**이다. [OWASP Authentication](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)

### 탈퇴 처리 — 최신 사용자 결정

1. 계정 비활성화·모든 활성 세션 종료·최소 탈퇴 영수증을 전부 성공하거나 전부 실패하는 한 작업으로 처리한다. `deactivatedAt`·`purgeAfter`를 반환하며 금융 W·Snapshot을 요구하지 않는다.
2. 1년은 탈퇴 확정 시각의 Asia/Seoul 달력상 다음 해 같은 월·일·시각이다. 2월 29일은 다음 해 2월 말일을 사용한다. 기산일을 재시도로 연장하지 않는다. 실제 데이터 삭제는 이 시각 전에는 실행하지 않는다.
3. 성공 후 즉시 앱 접근 정보를 지우고 인증 시작 화면으로 이동한다. 모든 로그인·재확인·금융 경로는 비활성 계정을 거절한다. 탈퇴 전 시작된 금융 쓰기도 탈퇴가 먼저 확정되면 저장을 거절한다.
4. 응답 유실 재시도는 **그 탈퇴로 종료된 동일 토큰 + 동일 탈퇴 키**로 동일 사용자·세션의 기존 탈퇴 영수증을 확인할 수 있을 때만 위 최소 완료 응답을 다시 허용한다. 토큰 재발급·금융 조회·다른 쓰기에는 예외를 적용하지 않는다. 다른 키·없는 영수증은 401이며 다른 action의 키를 탈퇴 완료로 해석하지 않는다.
5. 성공 응답은 비활성화 완료와 파쇄 예정 시각을 뜻하며 실제 파쇄 완료를 뜻하지 않는다. 1년 보관 후 파쇄 정책은 유지하며, DB 변경·파쇄 작업·백업 처리는 이번 명세의 구현 범위에 포함하지 않는다.

## 3. 조회·설정 경로

| 메서드·경로                 | W 외의 입력                                         | 결과·제약                                                                             |
| --------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------- |
| GET /snapshot               | 없음                                                | 200 Snapshot. 처음부터 현재 버전으로 시작                                             |
| GET /transactions           | `cursor` 1개                                        | 200 TransactionPage. 첫 페이지는 Snapshot. 별도 offset/limit/필터 없음                |
| POST /institution-links     | `institutionCodes:string[]`                         | 최종 동의−제외 집합. 사용자에게 제공된 기관만, 중복 없음, 계좌를 제공할 은행 최소 1곳 |
| PATCH /account-selection    | `accountIds:ID[]`                                   | 연결·조회 가능한 계좌 1개 이상. 전체 선택 집합 교체. 예금/적금도 선택 가능            |
| PATCH /accounts/{accountId} | `nickname:string\|null`                             | null은 해제. trim 후 grapheme 1~12, 특수문자만 금지. 상품명·잔액 불변                 |
| PATCH /settings             | `salary?:SalaryPatch`, `cardPlans?:CardPlanPatch[]` | 아래 허용 필드만 변경                                                                 |

§3의 GET에는 W가 없다. §3·§4의 금융 쓰기만 W와 §5의 S를 사용한다. §2의 인증·탈퇴는 해당 표의 전용 요청·응답을 사용한다. 최초 연결에서 계좌 포함 여부를 자동 확정하지 않는다. 연결 전 금융 자료를 내려주거나 로그인마다 시드를 초기화하지 않는다.

`SalaryPatch={salaryDay?:1..31|null,salaryAmountKRW?:Money|null,salaryAccountId?:ID|null}`. `{}`는 거절한다. 신규 급여 계좌는 선택된 계좌여야 한다. 급여 입금 근거를 수정하거나 입금 완료로 만드는 API가 아니다.

`CardPlanPatch={cardId:ID,plannedPaymentDay:1..31|null}`. 배열에서 명시한 카드만 변경하고 미기재 카드는 유지한다. null은 사용자 override 해제다. 실제 출금 계좌·원천 청구 예정일은 쓰지 않는다. 29~31 말일 안내는 사용자 계획에만 적용한다.

화면 재진입에서 같은 기관 목록을 다시 보내는 **동일 논리 작업**은 같은 본문·버전·키다. 사용자가 목록을 바꿨으면 최신 Snapshot 확인 후 새 키로 저장한다. 집합 교체를 화면 클릭마다 새 키로 반복하지 않는다. 기관 추가/해제 화면의 P1 우선순위를 바꾸지 않는다.

계좌 제외는 그 계좌의 보호 설정·원천·급여 근거를 삭제하지 않는다. 홈 선택과 연결 권한은 별개다. 연결 목록 변경 시 유지된 설정의 숨김·읽기 제한은 응답 모델을 따른다.

## 4. 예정 지출·모아둘 돈·명시 배정

| 메서드·경로                   | W 외의 입력                                                                        | 저장 의미                                                               |
| ----------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| POST /obligations             | `label:Label,withdrawalAccountId:ID,amountKRW:Money,dueDate:Date`                  | 사용자 단건 의무 생성, status=active. 원천 청구·반복 계획 생성이 아님   |
| PATCH /obligations/{id}       | `label?:Label,withdrawalAccountId?:ID,amountKRW?:Money,dueDate?:Date`              | 단건 의무 또는 이미 저장된 개별 미지급 회차 편집. 실제 거래·정산은 보존 |
| DELETE /obligations/{id}      | 본문 없음, W는 아래 헤더                                                           | 논리 취소. 삭제·배정 정책은 아래 확인 항목                              |
| POST /reserves                | `accountId:ID,label:Label,amountKRW:Money,allocationChanges:AllocationChanges`     | 보호 설정과 명시 배정을 원자 생성                                       |
| PATCH /reserves/{id}          | `accountId?:ID,label?:Label,amountKRW?:Money,allocationChanges?:AllocationChanges` | 명시한 설정·배정만 원자 변경                                            |
| DELETE /reserves/{id}         | 본문 없음, W는 아래 헤더                                                           | cancelledAt 기록. 삭제·배정 정책은 아래 확인 항목                       |
| POST /obligations/{id}/cancel | `detachAllocations:DetachAllocation[]`                                             | 사용자 확인한 미지급 배정 해제와 의무 취소를 원자 처리                  |
| POST /reserves/{id}/cancel    | `detachAllocations:DetachAllocation[]`                                             | 사용자 확인한 미지급 배정 해제와 보호 설정 취소를 원자 처리             |

DELETE W 헤더는 `Payse-Expected-Data-Version`, `Payse-Rule-Version`, `Idempotency-Key`다. 다른 쓰기는 본문에만 W를 두어 이중 권위를 만들지 않는다. [HTTP DELETE 본문 의미](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.5)

`AllocationChanges={create:[{obligationId:ID,amountKRW:PositiveMoney}],update:[{allocationId:ID,amountKRW:PositiveMoney}],remove:ID[]}`. 세 배열은 모두 필요하며 변화가 없으면 []다. 하나의 ID를 여러 변경에 중복 기재하면 422다.

- 배정은 같은 사용자의 활성 의무에만 가능하다. 타 사용자·숨겨진 자원·취소된 자원을 거절한다. 서로 다른 계좌라는 이유만으로 배정을 거절하지 않으며, 배정이 실제 계좌 이체를 의미하지 않는다.
- update 금액은 해제분을 포함한 총 배정액이다. 기존 releasedKRW 미만으로 줄이지 못한다. releasedKRW/releaseEvidence 자체는 입력 불가다.
- remove는 해제 이력 없는 배정에만 허용한다. 해제 이력이 있으면 amountKRW를 releasedKRW까지 줄여 미해제분 0으로 남긴다. 지급 이력을 삭제하지 않는다.
- 유효 배정 미해제 합계 ≤ 보호액, 의무별 미해제 합계 ≤ 미정산 의무액이다. 실제 U·미래 잔액을 계산하거나 응답하지 않는다.
- 보호 신규/증액은 선택된 계좌 기준으로 계좌별·선택 전체 보호 상한을 검증한다. 원천 잔액 감소로 기존 보호액이 초과된 경우 자동 감액하지 않는다. 감소와 새 증액은 구분한다.
- 보호 설정의 계좌를 바꿀 때도 이전 지급 근거를 바꾸지 않는다. 변경 후 선택 계좌·보호 증액 한도·미해제 배정 한도를 검증한다.
- 의무 총액은 이미 유효 정산된 금액보다 작아질 수 없다. 유효 정산이 있는 의무의 계좌 변경·취소는 409다. 금액은 잔여가 아니라 총 의무액이다.
- statementId가 있는 청구 의무의 원천 금액·일정·출금 계좌는 변경/취소하지 않는다. 이미 저장된 월간 계획의 개별 미지급 회차는 이 PATCH로 허용 필드만 수정하며 recurringPlanId/planRevisionId/recurrenceKey를 유지한다. 월간 계획·버전·다른 회차·부분 정산 근거를 덮지 않는다. 미저장 미래 회차의 확정 생성과 계획 버전 편집은 후속 경로다.

### 삭제와 미지급 배정 해제 — 사용자 확정

예: 모아둘 돈 10만 원 중 3만 원을 미지급 통신비에 연결해 둔 경우, 사용자가 **통신비와 3만 원 연결을 함께 해제**하는 안내를 확인하면 한 요청으로 처리한다. 실제 계좌 잔액·모아둘 돈 총액 10만 원은 이 연결 해제로 변하지 않는다.

명시적 해제 목록을 받기 위해 POST cancel 경로를 사용한다. `DetachAllocation={allocationId:ID,unreleasedKRW:PositiveMoney}`이며 W와 함께 보낸다. 현재 대상에 연결된 미해제분을 **모두 정확한 ID·금액으로** 명시해야 한다. 빈 목록은 현재 미해제 배정이 없을 때만 가능하다. 중복 ID는 422 VALIDATION_FAILED, 없거나 접근 권한 밖인 배정은 403 RESOURCE_FORBIDDEN이다. 최신 버전 불일치는 409 STALE_DATA, 접근 가능한 배정이 취소 대상 밖이거나 목록 누락·현재 미해제 금액 불일치가 있으면 409 RELATION_CONFLICT다. 어느 실패에서도 일부만 저장하지 않는다.

최신 버전을 검증하고 각 배정의 미해제분 제거·대상 취소·영수증·dataVersion 증가를 원자 처리한다. releasedKRW=0인 배정은 제거하되 변경 이력에 남긴다. 이미 해제된 이력이 있으면 amountKRW를 releasedKRW까지 줄이고 releaseEvidence를 보존한다. **지급에 의한 보호 해제로 기록하거나 reserves.amountKRW를 차감하지 않는다.**

의무 취소는 status=cancelled, 보호 설정 취소는 cancelledAt 기록이다. 보호 설정 자체를 취소하면 로컬 계산에서 그 보호 설정이 제외되지만 실제 잔액은 바꾸지 않는다. 실제 유효 정산이 있는 의무 취소와 원천 청구 의무 취소는 기존 이력 보호 규칙에 따라 409다.

기존 DELETE는 미해제 배정이 없을 때의 간단한 취소 경로로 유지한다. 미해제 배정(amountKRW>releasedKRW)이 있으면 409이며 자동 해제하지 않는다. 완전히 해제되어 보존만 하는 배정 이력은 이 거절 조건이 아니다. UI는 배정 유무와 관계없이 명시 목록을 갖춘 POST cancel 하나로 일관되게 구현할 수 있다. 두 경로의 취소·이력 보존 결과는 동일하다.

## 5. 쓰기 응답·경합·재시도

금융 쓰기 성공 S는 HTTP 200:

```text
{
  receipt: {receiptId:ID, operationKey:string, resultVersion:Version,
            createdAt:Time, changedRefs:[{resource:string,id:string}]},
  replayed:boolean,
  snapshot:Snapshot
}
```

ChangedRef의 resource는 `institutionLink/account/settings/obligation/reserve/allocation`이다. id는 해당 객체 ID이며 settings는 userId다. 영수증 전체 내부 before/after·digest·토큰을 노출하지 않는다. 조회 권한이 제한된 changedRefs는 제외한다. 응답 receipt는 내부 감사 영수증의 공개 요약이다.

1. 현재 계정·세션이 유효한 사용자에게만 허용한다. 형식 확인 뒤 같은 작업 키를 먼저 확인하고, 새 작업만 버전·규칙·소유권·제약을 검사하여 변경·영수증·dataVersion 증가를 원자 확정한다.
2. 같은 키·같은 요청은 **옛 버전 검사 전에** 기존 영수증으로 replay한다. 같은 키·다른 요청은 409. 설정 저장은 sourceVersion·asOf를 바꾸지 않는다.
3. 같은 요청의 판정 대상은 메서드·정규 경로·W의 버전·허용 본문이다. 객체 키 순서는 무시하되 null과 생략, 배열 순서는 구분한다. 집합 배열도 재시도에서는 최초 순서를 유지한다. 키 자체와 토큰 값은 요청 내용 비교에서 제외한다.
4. 저장 성공 후 최신 일관 Snapshot을 반환한다. resultVersion보다 Snapshot 버전이 높을 수 있다. replay에서도 과거 Snapshot이 아닌 현재 조회 권한의 최신 Snapshot을 반환한다.
5. 커밋/응답 상태가 불명인 실패는 같은 본문·키로 재시도한다. 새 키 자동 발급 금지. 실패한 트랜잭션에는 성공 영수증·버전 증가가 남지 않는다.
6. Flutter는 다른 세션·낮은 버전의 늦은 응답을 폐기한다. 1년치 페이지를 모두 받기 전 연간 집계 완료로 표시하지 않는다.

## 6. 오류 응답

오류 형태는 `{error:{code,message,requestId:ID,details:[{field,reason}]}}`다. 원문 입력·SQL·스택·계정 존재 여부·숨겨진 ID를 싣지 않는다.

| HTTP | code                                                      | 호출부 처리                                                  |
| ---- | --------------------------------------------------------- | ------------------------------------------------------------ |
| 400  | INVALID_JSON / INVALID_CURSOR                             | 구문·변조 수정. 무한 재시도 금지                             |
| 401  | AUTH_REJECTED / SESSION_INVALID                           | 금융 접근 중단. 서버 거절을 로컬 PIN으로 우회하지 않음       |
| 403  | RESOURCE_FORBIDDEN                                        | 없는 자원·다른 사용자·연결 권한 밖 자원을 같은 메시지로 처리 |
| 409  | STALE_DATA / RULE_VERSION_MISMATCH                        | 현재 Snapshot 재조회 후 초안 재검토                          |
| 409  | IDEMPOTENCY_CONFLICT / RELATION_CONFLICT / HISTORY_LOCKED | 입력 키 또는 관계·보존 이력 충돌 해결                        |
| 413  | REQUEST_TOO_LARGE                                         | 본문 제한 초과. 일부만 저장하지 않음                         |
| 422  | VALIDATION_FAILED / LIMIT_EXCEEDED                        | 허용 필드에 오류 표시                                        |
| 429  | RATE_LIMITED                                              | Retry-After 준수                                             |
| 503  | TEMPORARILY_UNAVAILABLE                                   | 금융 쓰기는 동일 키로 결과 확인. 탈퇴는 전용 재시도 계약     |

401에는 `WWW-Authenticate: Bearer`를 제공한다. 미정의 5xx도 실패이며 0원 정상 응답으로 대체하지 않는다. 서버 내부 로그 수집·저장 설계는 후속 구현에서 다룬다.
