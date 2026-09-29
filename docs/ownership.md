# 4명 기여자의 개발 역할

개발 참여자는 개발 관리자 1명을 포함한 총 4명(contributors)이다.
개발 관리자는 개발 환경, 공통 코드, 리뷰와 통합을 관리하는 기여자다. 프로젝트 소유자를 뜻하지 않는다.
개발 관리자는 integration을 맡고, 나머지 3명은 data, cashflow, allocation을 나누어 맡는다. 세 역할의 개인별 배정은 팀에서 정한다.

| 역할        | 담당 경로                                                                 | 확인할 다른 영역                                           |
| ----------- | ------------------------------------------------------------------------- | ---------------------------------------------------------- |
| integration | packages/, scripts/, 공통 설정, apps/mobile/app/, apps/mobile/src/shared/ | 세 기능 담당자의 코드와 통합 결과                          |
| data        | apps/api/, apps/mock-bank/                                                | contracts, finance-core 입력, 앱의 API 사용 방식           |
| cashflow    | apps/mobile/src/features/connection/, recurring/, spending/               | contracts, finance-core 출력, shared, allocation 공개 함수 |
| allocation  | apps/mobile/src/features/allocation/, docs/demo/                          | contracts, finance-core, spending 결과, 계획 저장 API      |

cashflow 표의 recurring/와 spending/은 apps/mobile/src/features/ 아래 경로다.

## 수정 범위

- scripts/harness/policy.json은 역할별 수정 범위를 정한다. 작업 명세의 allowedPaths로 범위를 더 좁힌다.
- integration도 작업 명세에 허용된 파일만 수정한다. 관리 역할이 다른 사람의 변경을 덮을 권한을 주지는 않는다.
- 다른 담당자의 코드를 읽어 연결 방식을 확인할 수 있다. 수정·포맷·이름 변경은 허용 범위 안에서만 한다.
- package.json, lockfile, 공통 설정, 하네스, 공통 데이터 형식 변경은 integration이 조정한다.
- 범위 밖 수정은 담당자와 조정하고 작업 명세에 반영한다. 이미 승인된 범위는 다시 승인받지 않는다.

## 협업과 merge

1. 각 작업에 담당자, 허용 파일, 완료 조건과 검사 방법을 적는다.
2. 공통 데이터 형식을 develop에 반영한 뒤 각 담당자가 같은 기준으로 개발한다.
3. 한 작업 폴더에서는 쓰기 에이전트 하나만 실행한다. 동시 작업은 checkout/worktree를 분리한다.
4. 작은 PR로 통합하고 범위 밖 문제는 재현 방법과 해당 경로를 전달한다.
5. 개인 브랜치는 배정된 담당자가 merge한다. develop/main은 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 merge한다.

CODEOWNERS는 GitHub의 리뷰 담당 파일 이름이다. 프로젝트 소유권이나 실제 merge 권한을 정하지 않는다.
