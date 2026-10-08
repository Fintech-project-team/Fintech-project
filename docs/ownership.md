# 3명 기여자의 개발 역할

개발 참여자는 개발 관리자 1명을 포함한 총 3명(contributors)이다. 개발 관리자는 개발 환경, 공통 코드, 리뷰와 통합을 관리하는 기여자이며 프로젝트 소유자를 뜻하지 않는다.
이 문서가 현재 팀 구성과 역할 배정 기준이다. 과거 작업 명세의 인원 기록은 당시 이력으로 보존한다.

## 기여자와 작업 역할

| 기여자 식별 기준          | 활성 개인 브랜치 | 현재 배정 기준                                                    |
| ------------------------- | ---------------- | ----------------------------------------------------------------- |
| 개발 관리자 enpl          | sunghyun-dev     | integration 조정, develop/main 통합. 기능 작업은 별도 명세로 배정 |
| hyeyeon-dev 담당 기여자   | hyeyeon-dev      | 작업별 담당 기능을 명시. 고정 기능 배정은 아직 미확정             |
| seonghwan-dev 담당 기여자 | seonghwan-dev    | 작업별 담당 기능을 명시. 고정 기능 배정은 아직 미확정             |

integration·data·cashflow·allocation은 수정 경로를 구분하는 네 작업 역할이며 네 사람을 뜻하지 않는다. 세 명이 역할을 나누어 맡거나 겸임할 수 있고 개발 관리자도 기능 작업에 참여한다. 기능별 고정 담당자를 임의로 정하지 않는다.

작업마다 Issue/PR 또는 작업 기록에 담당자를 적고, 작업 명세의 role에는 해당 작업 역할 하나를 적는다. 한 사람이 여러 역할을 맡으면 작업별 명세와 허용 경로를 나눈다. 여러 영역을 함께 바꾸는 공통 작업은 integration이 사전에 조정하고 필요한 경로만 명세에 적는다. 검사 실패를 피하려고 role을 integration으로 바꾸지 않는다.

| 역할        | 담당 경로                                                                 | 확인할 다른 영역                                           |
| ----------- | ------------------------------------------------------------------------- | ---------------------------------------------------------- |
| integration | packages/, scripts/, 공통 설정, apps/mobile/app/, apps/mobile/src/shared/ | 각 기능 영역의 코드와 통합 결과                            |
| data        | apps/api/, apps/mock-bank/                                                | contracts, finance-core 입력, 앱의 API 사용 방식           |
| cashflow    | apps/mobile/src/features/connection/, recurring/, spending/               | contracts, finance-core 출력, shared, allocation 공개 함수 |
| allocation  | apps/mobile/src/features/allocation/, docs/demo/                          | contracts, finance-core, spending 결과, 계획 저장 API      |

cashflow 표의 recurring/와 spending/은 apps/mobile/src/features/ 아래 경로다. 사람 수가 줄었다는 이유로 이 기능 영역이나 검사기의 역할을 삭제하지 않는다.

## 수정 범위

- scripts/harness/policy.json은 역할별 수정 범위를 정한다. 작업 명세의 allowedPaths로 범위를 더 좁힌다.
- integration도 작업 명세에 허용된 파일만 수정한다. 관리 역할이 다른 사람의 변경을 덮을 권한을 주지는 않는다.
- 다른 담당자의 코드를 읽어 연결 방식을 확인할 수 있다. 수정·포맷·이름 변경은 허용 범위 안에서만 한다.
- package.json, lockfile, 공통 설정, 하네스, 공통 데이터 형식 변경은 integration이 조정한다.
- 최초 범위 밖 문제는 필요한 경로와 원인을 보고한다. 범위 변경이 별도로 승인되면 이유와 새 명세를 남긴다. 이미 승인된 작업을 다시 승인받지 않는다.

## 협업과 merge

1. 각 작업에 담당자, 역할, 허용 파일, 완료 조건과 검사 방법을 적는다.
2. 공통 데이터 형식을 develop에 반영한 뒤 각 담당자가 같은 기준으로 개발한다.
3. 한 작업 폴더에서는 쓰기 에이전트 하나만 실행한다. 동시 작업은 checkout/worktree를 분리한다. 역할 겸임이 같은 폴더의 동시 수정을 허용하지는 않는다.
4. 작은 PR로 통합하고 범위 밖 문제는 재현 방법과 해당 경로를 전달한다.
5. 개인 브랜치는 배정된 담당자가 merge한다. develop/main은 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 merge한다.

위 세 브랜치가 현재 운영 대상이다. 제외된 기여자의 계정 권한, 인수인계, 비활성 브랜치 삭제와 보호 규칙 정리는 별도 후속 작업이다. 이 문서 수정만으로 실제 GitHub 설정이 바뀌지는 않는다. CODEOWNERS도 리뷰 담당 표시이며 프로젝트 소유권이나 실제 merge 권한을 정하지 않는다.

## Flutter 전환 경로

위 표는 현재 policy.json과 일치하는 이전 골격의 경로다. 신규 Flutter 앱은 [전환 기준](harness/FLUTTER_TRANSITION.md)에 따라 lib·test·integration_test 경로와 역할별 검사를 초기화 작업에서 함께 반영한다. 그 전에는 cashflow/allocation 명세를 임의로 integration으로 바꿔 Flutter 파일을 수정하지 않는다.
