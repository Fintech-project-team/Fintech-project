# 테스트폰 기기 인증서(mTLS) 절차

실제 테스트 서버(주소는 성현님이 Git 밖으로 전달하며 로컬 빌드 설정에만 둔다)는 등록한 테스트폰 인증서만 받는다. 이 문서는 SM-G988N에서 키·CSR을 만들고 발급 인증서를 붙이는 앱 쪽 절차다. 서버 쪽 등록은 [Android HTTPS 준비](../../api/deploy/android-https.md)를 따른다.

## 1. 원칙

- 키는 앱 전용 Android Keystore의 내보낼 수 없는 **EC P-256** 키이며 별칭은 `payse.device_tls`다. 개인키·P12·PFX는 만들지도 내보내지도 않는다.
- 에뮬레이터 키·CSR은 쓰지 않는다. 에뮬레이터 결과는 코드 확인용일 뿐이다.
- CSR을 만든 뒤에는 **같은 설치를 유지**한다. 앱 삭제·데이터 초기화·다른 applicationId 설치·다른 서명 키로 만든 빌드 설치를 하지 않는다. 키를 잃으면 새 CSR과 재등록이 필요하다.
- 로그인 정보 초기화는 세션·PIN·동의만 지우며 기기 인증서 키·인증서는 지우지 않는다.
- 서버 인증서는 기기 기본 신뢰 저장소와 IP 일치로 검증한다. 사설 CA 예외나 검증 끄기를 넣지 않는다.

## 2. CSR 만들기

로컬 전용 도구 `lib/zz_dev_device_cert_main.dart`(커밋하지 않음)를 실기기에 설치해 실행한다. 키가 없으면 만들고 있으면 그대로 쓴다.

```bash
flutter build apk --debug -t lib/zz_dev_device_cert_main.dart --dart-define=MODE=csr --dart-define=DEV_CSR_CN=PAYSE-Test-Phone
```

로그(`CERTTOOL PEM` 줄)를 모아 `test-phone.csr`로 저장하고 Mac에서 확인한다.

```bash
openssl req -in test-phone.csr -noout -verify -subject -text
```

```bash
openssl req -in test-phone.csr -outform DER | openssl dgst -sha256
```

ECDSA 서명은 실행마다 달라 CSR DER 지문도 실행마다 다르다. **보내는 파일에서 계산한 지문**을 함께 보낸다. 같은 키로 만든 CSR이면 어느 것이든 발급에 쓸 수 있다.

## 3. 전달 자료 양식

| 항목            | 값                                                                      |
| --------------- | ----------------------------------------------------------------------- |
| CSR 파일        | `test-phone.csr` (PKCS#10 PEM)                                          |
| CSR DER SHA-256 | (파일에서 계산한 64자리)                                                |
| 주체            | `CN=PAYSE-Test-Phone` (2026-11-02 성현님 확인, 추가 필수 항목 없음)     |
| 키              | EC P-256, 별칭 `payse.device_tls`, 보관 위치(도구 로그의 securityLevel) |
| 앱              | applicationId `com.example.payse`, 버전 `0.1.0+1`, debug 빌드           |
| 소스 기준       | 브랜치·커밋과 미커밋 변경 여부                                          |

CSR DER 지문은 발급 인증서 DER 지문과 다른 값이다. Caddy 등록과 대조할 값은 발급 인증서 지문이다.

## 4. 발급 인증서 붙이기

성현님이 `client.pem`·`chain.pem`·`enrollment.json`과 발급 인증서 DER 지문·유효기간·Caddy 등록 여부를 보낸다.

`client.pem` 뒤에 `chain.pem`을 이어 붙인 파일을 같은 설치의 기존 키에 연결한다. 공개키가 기기 키와 다르면 거절된다. 도구가 인증서 DER SHA-256·주체·발급자·유효기간을 출력하므로 성현님이 준 값과 대조한다.

```bash
flutter build apk --debug -t lib/zz_dev_device_cert_main.dart --dart-define=MODE=cert --dart-define=DEV_CHAIN_B64=<client.pem+chain.pem의 base64> --dart-define=DEV_PROBE_URL=<테스트 서버 주소>/snapshot
```

토큰 없이 `/snapshot`을 요청해 401 JSON이 오면 TLS·기기 인증서·프록시는 통과한 것이다. 이후 실제 앱(서버 모드)을 같은 설치 위에 덮어 설치한다.
