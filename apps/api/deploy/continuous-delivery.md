# 검증된 서버 묶음과 수동 배포

push는 CI 검사와 산출물 생성만 수행한다. 사람이 성공한 실행을 선택하여 다운로드·호환성 점검 후 배포한다. 팀원이 사용하는 서버를 push만으로 재시작하지 않는다. 새 PC에도 같은 JAR를 사용하며 PC 경로·IP·키는 Git 밖 properties에서 받는다.

## CI와 배포 대상

`Verified server release`는 관련 경로의 브랜치 push·PR에서 Windows·Linux·macOS 배포 도구 검사, 기존 API·AI 검사, 새 폐기 PostgreSQL 15의 실제 HTTP/JPA 회귀를 순서대로 실행한다. 모두 통과한 `develop` 또는 `sunghyun-dev` push/수동 실행만 `payse-api-<40자리 커밋>` 산출물을 만든다. 기능 브랜치·PR 실행은 배포 산출물을 게시하지 않는다.

묶음에는 실행 JAR, 빈 예제 설정, 배포 도구·안내, 파일별 SHA-256, 커밋·브랜치·CI 실행 ID가 들어간다. DB·실제 설정·토큰·키·인증서는 넣지 않는다. CI에는 서버 접속 권한이나 자체 호스팅 runner가 필요하지 않다.

다운로드는 GitHub CLI의 기존 로그인 또는 로컬 properties의 읽기 전용 토큰을 사용한다. 성공한 지정 workflow, 같은 저장소·허용 브랜치의 현재 HEAD, 산출물 ZIP 지문과 각 파일 지문을 대조한 뒤 `ci-receipt.json`을 만든다. 이 로컬 영수증은 검사 기록이며 별도 전자서명이나 공격자가 수정할 수 없는 증명은 아니다. 배포 PC와 설정 디렉터리의 신뢰·접근 제한을 유지한다.

## 새 PC 준비

Windows·Linux·macOS에서 Python 3.10 이상, Java 21, PostgreSQL `psql`, GitHub CLI를 준비한다. 자동 탐지는 Java의 표준 설치 경로·PATH와 로컬 IP 후보만 읽는다. 누락 도구는 공식 설치 안내를 확인하고 PC 소유자의 승인으로 설치한다. 관리자 권한을 자동 획득하거나 OS 패키지·서비스·방화벽을 조용히 설치하지 않는다.

```text
python -m venv <작업용-가상환경>
<가상환경-Python> -m pip install -r apps/api/deploy/requirements.txt
<가상환경-Python> -B apps/api/tools/portable_server.py doctor
<가상환경-Python> -B apps/api/tools/portable_server.py configure --directory <Git-밖의-새-설정폴더>
```

Windows의 가상환경 Python은 `Scripts/python.exe`, Linux·macOS는 `bin/python`이다. 배포 도구를 담은 산출물에서 실행할 때는 `apps/api/tools/` 접두사를 생략한다.

configure는 생성 위치에 대한 `YES` 승인을 받은 뒤 설치 위치, Java·psql 경로, 포트, 메모리 예산, 기존 준비 DB, 기존 인증 키를 묻는다. 비밀 입력은 화면에 표시하지 않으며 새 설정 폴더에 사용자 전용 ACL 또는 0700/0600 권한을 적용한다. 기존 폴더는 덮어쓰지 않는다. 실제 값은 `deployment.properties`와 `server.properties`에만 저장하며 Git에는 빈 예제만 공유한다.

DB는 먼저 별도로 준비되어 있어야 한다. 이 도구는 사용자·원천 자료를 생성하거나 DB를 초기화·이행하지 않는다. 같은 DB를 옮겨 쓰면 기존 verifier 키 ID와 세 키를 유지한다. 새 PC의 로컬 IP 후보는 공인 주소나 NAT/포트포워딩 상태를 뜻하지 않는다. API는 loopback에서만 시작한다. 다른 기기의 연결은 [HTTPS 안내](android-https.md)에 따라 승인한 주소·서버 인증서·mTLS·방화벽을 별도로 준비한다. 자동 IP 감지로 인터넷 접근을 허용하지 않는다.

## 성공한 CI 가져오기와 신규 설치

```text
<Python> -B apps/api/tools/release_server.py fetch --properties <비공개-deployment.properties> --run-id <성공한-CI-ID> --output <새-묶음-폴더>
<Python> -B apps/api/tools/portable_server.py install --properties <비공개-deployment.properties> --package <새-묶음-폴더> --commit <40자리-커밋>
<Python> -B apps/api/tools/portable_server.py install --properties <비공개-deployment.properties> --package <새-묶음-폴더> --commit <40자리-커밋> --apply
<Python> -B <설치폴더>/tools/portable_server.py start --home <설치폴더>
<Python> -B <설치폴더>/tools/portable_server.py status --home <설치폴더>
```

`install` 기본은 점검이다. `--apply`가 새 설치 파일 생성을 승인하며 자동 시작은 하지 않는다. 최초 설치 이후에는 설치 폴더의 도구로 관리한다. `stop --home <설치폴더>`는 해당 Java만 정상 종료한다. DB·HTTPS는 이 관리 도구가 소유하거나 종료하지 않는다. Windows 전용 콘솔 또는 POSIX 별도 세션으로 실행 터미널과 서버 수명을 분리하며, 분리할 수 없는 환경에서는 시작을 실패시킨다.

## 기존 서버 업데이트

새 PC용 설치는 다음과 같이 점검한 후, 짧은 API 중단 시간을 팀원과 정하고 `--apply`를 실행한다.

```text
<Python> -B <설치폴더>/tools/portable_server.py deploy --home <설치폴더> --package <새-묶음-폴더> --commit <40자리-커밋>
<Python> -B <설치폴더>/tools/portable_server.py deploy --home <설치폴더> --package <새-묶음-폴더> --commit <40자리-커밋> --apply
```

기존 `launch.json`·`runtime.json`·시작/종료 제어 모듈을 사용하는 Windows 설치는 전용 호환 어댑터를 쓴다. 설치 경로와 메모리 상한을 Git 밖 `deployment.properties`에 지정한다. PowerShell 7.2 이상이 필요하다.

```powershell
./apps/api/deploy/Deploy-Payse.ps1 -Properties <비공개-properties> -Package <새-묶음-폴더> -ExpectedCommit <40자리-커밋>
./apps/api/deploy/Deploy-Payse.ps1 -Properties <비공개-properties> -Package <새-묶음-폴더> -ExpectedCommit <40자리-커밋> -Apply
```

두 경로 모두 무결성·Java·프로필·기존 DB 구조·역할·메모리 여유를 확인한다. 설치별 잠금, PID·생성 시각·실행 파일·명령 일치 후 해당 API만 정상 종료한다. 이전 JAR·메타를 `releases/`에 보존하고 교체 후 생존 응답을 확인한다. 새 API가 시작하지 못하면 이전 JAR를 복구해 기동하며, 복구까지 실패하면 실패 상태를 남기고 강제 종료나 DB 삭제로 해결하지 않는다. 배포 도구 자체의 변경은 새 도구 검증과 명시적 갱신으로 관리하며 JAR 교체에 숨기지 않는다.

## 호환성 검사의 한계

현재 수동 교체는 `database,auth,finance,salary-notices`를 지원한다. `analysis` 활성화, KMS·LLM 설정, 011 DB 이행은 별도 승인·검증 대상이다. 분석 또는 알려지지 않은 프로필이면 교체 전에 중단한다. DB 점검은 read-only catalog에서 필요한 표·열·함수와 비관리자 runtime 역할을 확인한다. 이는 전체 스키마 의미·실데이터·외부 공급자·모바일 통합 검증을 대신하지 않는다. CI의 격리 DB 회귀와 실제 설치 점검을 함께 확인한다.

새 OS의 CI가 아직 실행되지 않았다면 해당 OS를 실측 통과로 보고하지 않는다. 실제 서버에 Apply하지 않은 점검 결과와 원격 CI 실행도 구분한다. 키·DB는 변경하지 않으므로 이 도구의 rollback 대상에 포함하지 않는다.

근거: [GitHub 산출물](https://docs.github.com/en/enterprise-cloud%40latest/actions/tutorials/store-and-share-data), [GitHub CLI](https://cli.github.com/manual/gh_run_download), [PostgreSQL 공식 Ubuntu 패키지](https://www.postgresql.org/download/linux/ubuntu/), [psutil 프로세스·신호 API](https://psutil.readthedocs.io/stable/).

## 감마 AI 준비

새 설치는 `portable_server.py configure`의 감마 AI 선택을 사용한다. 같은 구성은 시작 시 준비 기록을 재사용하고 유료 분석/전체 평가는 실행하지 않는다. `status`의 `ai`에서 준비·현재 프로세스·마지막 접근 확인·실제 분석 검증 시각을 구별한다. 설정·키·비용/스키마 전제와 제거 방법은 [AI 시작 안내](../docs/ai-startup.md)를 따른다.
