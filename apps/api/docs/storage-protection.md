# 저장 자료의 암호화와 복구

## 적용 범위

기존 분석 결과의 항목별 AES-256-GCM·AAD·소유권 검증은 유지한다. 새 도구는
원천 DB의 구조나 분석 마스터키를 변경하지 않고 **백업 파일**과 **원격 DB 전송**을
보호한다. 이름·전화번호·거래 적요·잔액에 필드 암호화가 추가된 것은 아니다.
저장 장치·DB/WAL·설정·키의 OS 보호는 별도 확인이 필요하며 ACL은 암호화와 구별한다.

실행 중인 서버를 자동 배포/재시작하지 않는다. 직접 JAR의 원격 TLS 검사는 이 변경을
포함한 검증된 배포 이후 적용된다. 기존 명시 loopback은 유지한다. 다른 호스트는
`sslmode=verify-full`이 필요하며 단일 호스트·DB명과 `sslmode`, `sslrootcert`,
`sslcert`, `sslkey`만 허용한다. 중복 옵션·인증서 검증 우회 factory는 거절한다.

## 새 PC 설치와 백업

배포 묶음의 `requirements.txt`를 설치한다. 암호화 도구와 이 문서도 묶음에 포함된다.
실제 경로는 모두 Git 밖의 일반 절대경로여야 한다. 링크·Git 내부·기존 목적지
덮어쓰기를 거절한다. 키와 백업은 각각 접근이 제한된 별도 디렉터리에 둔다.

```text
python secure_backup.py init-directory --directory <새-비공개-키-디렉터리>
python secure_backup.py init-directory --directory <새-비공개-백업-디렉터리>
python secure_backup.py init-key --key <새-백업키> --protection dpapi
python secure_backup.py dump --pg-dump <실행파일> --properties <DB-properties> --key <백업키> --output <새-백업>
python secure_backup.py verify --input <백업> --key <백업키>
```

DB properties는 `PAYSE_JDBC_URL`, `PAYSE_DB_USER`, `PAYSE_DB_PASSWORD`가 있는
비공개 파일이다. Git에는 빈 값의 예시만 둔다. 덤프 역할은 전체 원천·RLS 행을 읽을
권한이 있어야 한다. 일부 행만 읽은 결과를 성공으로 보지 않으며 앱 계정 권한을 자동
확장하지 않는다. 암호는 자식 프로세스 환경으로만 전달한다.

`pg_dump` custom-format stdout을 1MiB씩 AES-256-GCM 암호화하므로 평문 덤프
파일이 생기지 않는다. 랜덤 96-bit nonce, 128-bit 태그, 버전 헤더 AAD를 사용한다.
백업당 32GiB, 전체 300초, 연결 5초, 잠금 대기 5초 상한을 적용한다. 실패 시 해당
덤프 프로세스와 새 불완전 암호문만 정리한다. 성공 후 인증 복호화의 SHA-256·바이트 수를
대조한다. 원천 지문도 일반 로그나 Git에 공유하지 않는다. API·DB·HTTPS는 중지하지 않는다.

기존 파일은 `seal --input <원본> --output <새-암호문> --key <키>`로 복사 암호화한다.
원본 삭제는 수행하지 않는다. 옛 평문 사본이 남으면 저장 보호 완료로 볼 수 없다.

## 키와 다른 PC 복구

Windows 기본 `dpapi`는 실행한 사용자 계정·컴퓨터에 묶인다. 다른 실행 계정은 자동
복호화하지 못한다. DPAPI 파일만 보관한 상태는 다른 PC 재해 복구가 준비된 상태가 아니다.

```text
python secure_backup.py export-key --key <백업키> --output <새-복구봉투>
python secure_backup.py import-key --input <복구봉투> --key <다른-PC의-새-백업키> --protection dpapi
python secure_backup.py verify --input <백업> --key <가져온-백업키>
```

복구 암호는 터미널의 숨긴 입력으로만 받는다. 12자 이상의 길고 독립적인 암호를 쓴다.
scrypt N=32768/r=8/p=1과 AES-256-GCM을 사용한다. 복구 봉투와 암호는 별도로
보관한다. 새 PC에서 실제 백업 검증까지 통과해야 복구 준비 완료다. 백업 키는 기존
분석 마스터키와 다르며 분석 마스터키를 생성·교체·삭제하지 않는다.

다른 OS는 암호화된 볼륨과 제한된 권한을 준비한 뒤 `--protection file`을 명시한다.
이 형식 자체는 키를 암호화하지 않으며 자동으로 선택되지 않는다. Windows DPAPI/EFS도
이미 같은 계정이 침해된 상황을 방어하는 기능은 아니다.

## 복원 경계

`restore --input <암호문> --output <새-평문-복원파일> --key <키>`는 비공개 디렉터리에
임시 평문을 쓰고 최종 인증 태그 통과 후에만 목적지를 공개한다. 변조·잘림·다른 키는
거절하며 임시 파일을 정리한다. 기존 목적지는 덮지 않는다. 복원 디렉터리도 OS 암호화와
ACL이 필요하다. 전원 장애 후 남은 `.payse-restore-*`를 인증된 결과로 취급하지 않는다.
`verify`는 평문 파일 없이 검증한다.

도구는 DB 덮어쓰기나 `pg_restore`를 실행하지 않는다. 먼저 격리 DB에서 소유권·제약·버전·
기존 키에 의한 분석 암호문 복호화·삭제 대상 미노출을 확인하고 별도로 배포한다.

## 원천 DB·설정·기존 키의 OS 보호

`storage_protection.ps1 -Path <파일/디렉터리>`는 EFS 속성과 조회 가능한 BitLocker
상태만 읽는다. 권한 부족/조회 실패는 `Unknown`이다. 디렉터리 속성이 하위 기존 파일
전체의 암호화를 보증하지 않으며 `recoveryVerified=false`를 자동 성공으로 바꾸지 않는다.

1. DB·WAL·임시 파일·백업·설정·마스터키·TLS/CA 개인키와 과거 사본을 목록화한다.
2. BitLocker 또는 동등한 볼륨 보호의 복구 키를 서버 밖에 보관하고 복구를 확인한다.
   부팅/원격 연결에 영향이 있는 정책 변경은 무인 상태에서 적용하지 않는다.
3. EFS를 적용하려면 실제 서비스 실행 계정을 확인하고 해당 계정의 EFS 인증서·개인키를
   암호화 PFX로 먼저 내보내 복구 시험한다. `cipher /x` 암호는 로컬 보안 입력으로만 받는다.
   인증서가 없다면 생성·내보내기·복구 검증을 먼저 한다.
4. 기존 키/설정의 원문 지문을 비공개로 보존한 뒤 파일 단위 보호를 적용한다. 실행 계정의
   읽기와 내용 지문 유지까지 확인한다. 열린 DB 파일을 즉석에서 이동/일괄 변환하지 않는다.
   DB/WAL 보호는 복구가 검증된 유지보수 계획으로 수행한다.
5. 새 파일 상속·과거 사본·서비스 계정·인증서 갱신 때의 보호를 확인한다.

복구 전제 없이 기존 키를 지우거나 DPAPI 파일로 대체하지 않는다. 미확인 상태를
“모든 데이터 암호화 완료” 또는 “디스크 암호화 꺼짐”으로 보고하지 않는다.

### 실제 EFS 복구 파일 준비

```text
python recovery_setup.py prepare-efs --key <백업키> --archive <새-EFS-복구파일>
python recovery_setup.py verify-efs --key <백업키> --archive <EFS-복구파일>
python recovery_setup.py export-key --key <백업키> --archive <EFS-복구파일> --output <새-암호-보호-복구키>
```

첫 명령은 현재 Windows 사용자의 EFS 개인키를 암호화한 PFX로 내보낸다. EFS 인증서가
없으면 `cipher /k`로 준비하며 기존 분석 키·TLS 인증서·서버 파일을 변경하지 않는다.
PFX와 그 내부 암호를 함께 AES-GCM 봉투에 넣고, 인증서를 저장소에 설치하지 않는
메모리 가져오기로 개인키 복구를 검증한다. 암호/PFX는 자식 프로세스 파이프로만 전달하며
명령줄·환경·평문 임시 파일에 보관하지 않는다. Windows PowerShell 실행 정책을 자동 변경하지
않으며 설치된 PowerShell 7을 우선 사용한다.

마지막 명령은 사람이 로컬 터미널에서 복구 암호를 두 번 입력하는 단계다. 암호 관리자 등에
암호를 보관하고, 암호 보호 복구 키·EFS 복구 파일·암호화 DB/설정 백업을 서버 밖 장소로
복사한다. 현재 PC에 준비/검증된 상태와 외부 사본까지 검증된 상태를 구별한다. 외부 장소가
없으면 기존 키·평문 사본 삭제 및 기존 자료의 EFS 변환을 보류한다.

다른 PC에서는 `secure_backup.py import-key`로 새 계정의 DPAPI 키를 만든 뒤
`recovery_setup.py verify-efs`로 확인한다. EFS 파일 접근을 복구할 때만 명시적으로
`recovery_setup.py import-efs --key <키> --archive <EFS-복구파일>`을 실행한다.
이 명령은 현재 사용자의 인증서 저장소에 복구 인증서를 설치하며 서버를 시작/중지하지 않는다.

관리자 확인이 필요한 디스크 상태는 관리자 PowerShell에서
`storage_admin.ps1 -MountPoint <드라이브>`로 확인한다. 이 도구는 보호 상태·진행률·복구
보호자 존재 여부만 출력하고 복구 비밀번호를 출력하지 않는다. BitLocker 설정 변경이나
재부팅은 수행하지 않는다. 실제 원천 열의 필드 암호화/검색 인덱스는 실제 금융 연동 전에
별도로 설계하며, 현재의 분석 전용 암호화 계약을 원천 전체 암호화로 확대 해석하지 않는다.

## 백업과 삭제 결정

현재 DB에서 암호문/래핑 키를 삭제해도 과거 백업·WAL·키 사본이 남을 수 있다.
복원 전에 최신 삭제/보관 만료 결정을 확보하고 격리 상태에서 해당 항목과 래핑 키를
재삭제한 뒤 조회를 허용한다. 결정 이력이 불명확하면 복원본을 서비스에 연결하지 않는다.
`restore_guard.py`는 원본의 삭제 결정·동일 근거 재사용 차단을 읽기 전용으로 캡처하고
암호화된 불변 파일로 보존한다. 이전 파일을 지정하면 삭제 결정을 합치며 과거 삭제를
철회하지 않는다. 이 도구는 실시간 복제기나 외부 영구 저장 서비스가 아니다. 마지막 캡처
이후의 삭제까지 보호한다고 보지 않는다.

```text
python restore_guard.py capture --psql <실행파일> --properties <원본-DB-properties> --key <키> --archive <새-삭제자료> --previous <이전-삭제자료>
python restore_guard.py apply --psql <실행파일> --properties <격리-복원-DB-properties> --key <키> --archive <삭제자료> --expected-sha256 <검토한-암호문-지문> --target-data-directory <검토한-격리-데이터-디렉터리>
```

최초 캡처만 `--previous`를 생략한다. apply는 `payse_restore_` 접두어의 명시 loopback DB,
원본과 다른 PostgreSQL 클러스터, 일치하는 데이터 디렉터리, 다른 접속 없음, 검토 지문,
5분 이내의 권위 있는 삭제 자료를 모두 요구한다. 새 클러스터라는 사실만으로 운영 접속을
허용하지 않는다. 복원 원본과 삭제 자료의 출처를 함께 확인하고 적용/검증이 끝날 때까지
앱 연결을 열지 않는다. 자료가 오래됐거나 최신 삭제 여부를 확인할 수 없으면 공개하지 않는다.

항목 ID와 소유자를 함께 확인하고, 삭제/차단 대상 및 일반 보관 만료의 암호문·래핑 키를
같은 트랜잭션에서 제거한다. 중요 보관 예외는 유지하며 기존 금융 원천을 갱신하지 않는다.
동일 근거 차단도 복원해 재분석이 삭제 요청을 우회하지 않게 한다. 원본 DB에서는 캡처만
실행하며, 자동 스케줄 등록·현재 사용자 자료 삭제·키 파쇄는 수행하지 않는다. 디스크/WAL/
과거 백업의 모든 사본 폐기까지 검증되기 전에는 완전 파쇄 완료로 보고하지 않는다.

구 `migrate_identity.py`의 새 계획은 `--backup-key-file`을 요구하며 암호문 파일의
지문을 검토한다. 옛 평문 계획 apply에는 `--allow-legacy-plaintext`를 명시한다.
인증 실패 후 평문으로 넘어가지 않는다. 운영 DB에서 과거 이행을 재실행하지 않는다.
역사적 `migrate_common_storage.py`, `migrate_salary_evidence.py`도 같은 암호화/명시
평문 호환 경계를 사용한다. 과거 계획 적용은 현재 서버에 재실행하지 않는다.

근거: [PostgreSQL 암호화 범위](https://www.postgresql.org/docs/15/encryption-options.html),
[pgJDBC TLS](https://jdbc.postgresql.org/documentation/ssl/),
[Windows DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata),
[EFS cipher](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cipher).
