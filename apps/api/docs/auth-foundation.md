# 인증 입력·암호 기반

`com.payse.api.auth`는 [인증 설계](v0.6/auth-design.md)의 입력·암호 연산을 담당한다. [외부 API 계약](../../../docs/api-contract.md)을 따른다. 암호 모듈 자체에는 DB 세션/제한 저장이 없다. AuthService·DB 함수·HTTP 연결과 활성화 조건은 [인증 DB·HTTP](auth-database.md)에 정의한다. `auth` 프로필만으로 업무 경로를 열지 않으며 코드 시드는 자동 활성화하지 않는다.

## 책임과 호출 경계

| 구성요소                  | 책임                                                           | 호출 시 주의                                                                                        |
| ------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `AuthCredentials`         | 합성 name/phone/code의 형식 검사와 계약상 정규화               | 값이 유효하다는 것이 계정 존재나 인증 성공을 뜻하지 않는다. HTTP 추가 키 거절은 HTTP 계층 책임이다. |
| `AuthSecrets`             | 코드 키 ID와 서로 다른 두 32바이트 키의 검증·방어적 복사       | 키의 길이·형식·상이함을 검사한다. 무작위 생성 품질을 판정하지 않는다.                               |
| `AuthCrypto`              | 토큰 생성/digest, 코드 verifier 생성/대조, 조합/IP 제한 식별값 | 계정·세션·실패 횟수를 보관하지 않는다. 제한 키를 만드는 것만으로 요청 제한이 집행되지 않는다.       |
| `IssuedToken`             | 첫 응답용 원문과 DB 저장용 digest를 나누는 내부 전달 값        | 외부 응답 DTO로 직접 직렬화하지 않는다. 원문은 성공 응답에만, digest는 저장 계층에만 전달한다.      |
| `AuthCryptoConfiguration` | `auth` 프로필에서 필수 설정 검증과 생성자 주입                 | 기본값으로 비밀키를 만들지 않는다. 비활성 bootstrap에는 키를 요구하지 않는다.                       |

사용자별 가변 상태를 전역 객체에 두지 않는다. 연산 서비스는 생성자로 설정을 받으며 각 HMAC 호출에서 `Mac`을 새로 만든다. 키 배열은 사본을 반환하고 사용한 사본은 지운다. Java `String`·JDK 내부 복사까지 즉시 지워짐을 보장하는 구현은 아니다. 자격·키·토큰의 `toString()`은 원문을 포함하지 않는다. 명시적인 getter/직렬화/로그 호출까지 자동 차단하지 않으므로 원문 비로깅 규칙은 호출부에도 적용한다.

## 입력 규칙

- 이름: 앞뒤 U+0020만 제거한 뒤 `[가-힣A-Za-z]{2,20}`. 내부 공백·자모·탭·NBSP는 거절한다. 대소문자나 Unicode 정규형을 바꾸지 않는다.
- 전화번호: ASCII 숫자·U+0020·하이픈만 받고 공백/하이픈 제거 후 `010[0-9]{8}`. 국가번호·전각 숫자를 자동 변환하지 않는다.
- 코드: ASCII 숫자 6자리이며 공백 제거·숫자형 변환을 하지 않는다.

이는 `apps/mobile/lib/data/auth/auth_input_rules.dart`와 같은 규칙이다. 입력 객체는 인증 원문을 요청 처리에 필요한 동안만 사용한다. 금융 상품명·메모에 이 정규화를 적용하지 않는다.

## 필수 설정

`auth` 프로필의 Spring Environment에 아래 3개를 제공한다. 저장소·명령 이력·보고서에 실제 값을 넣지 않고 배포 환경에서 주입한다. 고정 테스트 벡터를 배포 키로 사용하지 않는다.

| 이름                          | 검증                                                                               |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `PAYSE_AUTH_CODE_KEY_ID`      | 비어 있지 않은 ASCII `[A-Za-z0-9_-]+`. verifier의 형식 식별자이며 비밀키가 아니다. |
| `PAYSE_AUTH_CODE_KEY_BASE64`  | 무작위 32바이트의 표준 Base64 정규 인코딩. 패딩 포함, 공백 없음.                   |
| `PAYSE_AUTH_LIMIT_KEY_BASE64` | 별도로 생성한 무작위 32바이트의 같은 인코딩. 코드 키와 동일한 바이트면 거절.       |

누락·잘못된 형식·동일 키는 인증 설정 생성을 실패시킨다. 오류에는 입력값과 Base64 파싱 원인 예외를 포함하지 않는다. 다중 키·자동 키 교체는 구현하지 않았다. 제한 키를 바꾸면 기존 제한 상태와 연결되지 않으므로, 상태 연속성을 유지하는 이행을 검증하기 전에는 교체하지 않는다. 코드 키 변경도 기존 verifier 이행과 함께 다뤄야 한다.

## 내부 형식

아래는 서버 내부 값으로 금융 응답 필드가 아니다. UTF-8, 소문자 hex, UUID 표준 소문자 표기를 사용한다. `\n`은 실제 LF 한 글자다.

| 값            | 형식/입력                                                                              |
| ------------- | -------------------------------------------------------------------------------------- |
| 토큰 원문     | SecureRandom 32바이트를 Base64url 무패딩으로 인코딩한 43자. 정규 인코딩만 허용         |
| 토큰 검증값   | `sha256:<원문 UTF-8의 SHA-256 hex>`                                                    |
| 코드 verifier | `hmac-sha256:<codeKeyId>:<HMAC hex>`; 코드 키로 `payse-code-v1\n<userId>\n<code>` 계산 |
| 조합 제한 키  | 제한 키로 `payse-limit-combo-v1\n<정규화된 name>\n<정규화된 phone>` 계산한 hex         |
| IP 제한 키    | 제한 키로 `payse-limit-ip-v1\n<정규 IP>` 계산한 hex                                    |

`verifyCode`는 DISABLED·미지원 키·형식 오류·다른 코드/사용자의 verifier를 거절한다. `verifyToken`은 형식 오류·다른 토큰의 digest를 거절한다. 유효한 형식의 digest 바이트는 `MessageDigest.isEqual`로 비교한다. 전체 HTTP 처리 시간이 일정하다는 보장은 아니다.

IP 입력은 서버 연결 또는 검증한 프록시에서 얻은 `InetAddress`다. 이 모듈은 DNS와 `X-Forwarded-For`를 읽지 않는다. IPv4는 십진수 4그룹, IPv4-mapped IPv6는 같은 IPv4로, 그 외 IPv6는 소문자·0축약 없는 8그룹(그룹 안의 선행 0 없음)·zone 제외로 고정한다. HTTP 어댑터에서 신뢰할 주소를 결정해야 하며, 헤더를 그대로 신뢰하는 구현은 포함하지 않는다.

## 검증과 확장

`node scripts/harness/run-api.mjs check`는 Java 주석/컴파일/JUnit·실행 JAR·기존 Python 더미 검사를 실행한다. 신규 검사는 문자·길이 경계, 비정규 토큰/키/verifier, 사용자·키·도메인 분리, 배열 변경 방어, 비밀 문자열 표현, 독립 암호 기대값, 병렬 연산과 프로필 설정을 다룬다. 고정 암호 벡터는 공개 알고리즘 검증 입력이며 DB 테스트 대상을 고르는 고정 ID가 아니다.

DB 세션·제한·권한과 HTTP를 연결할 때는 기존 [인증 검증 사례](v0.6/auth-verification.md)를 실제 Spring/PostgreSQL로 확인한다. `AuthCredentials` 형식 통과, 토큰 난수 생성 또는 단위검사 통과만으로 로그인 성공·요청 제한·사용자 격리가 완성됐다고 판정하지 않는다.

공식 API 근거: [JDK 21 SecureRandom](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/security/SecureRandom.html), [MessageDigest](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/security/MessageDigest.html), [Mac](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/javax/crypto/Mac.html). 32바이트와 내부 도메인 형식은 PAYSE 인증 설계를 따른 선택이다. 라이브러리 사용 자체가 금융 서비스 전체의 보안 적합성을 입증하지 않는다.
