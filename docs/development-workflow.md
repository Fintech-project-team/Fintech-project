# 개발 시작과 통합

개발 관리자 포함 4명의 기여자가 같은 저장소를 사용한다. 담당 범위는 docs/ownership.md를 따른다.

## 작업 시작

1. git status --short --branch와 diff를 확인하고 기존 변경을 보존한다.
2. develop→개인 브랜치 동기화 PR을 merge commit으로 반영한다. 공유 브랜치를 reset으로 맞추지 않는다.
3. 최신 개인 브랜치에서 기능 브랜치를 만든다. 한 폴더에서는 쓰기 에이전트 하나만 실행한다.
4. docs/tasks/TEMPLATE.json을 새 작업 파일로 복사해 역할·브랜치·허용 경로·완료 조건·필수 문서를 적는다.
5. baseCommit은 git rev-parse HEAD로 확인한 40자리 커밋을 사용한다. 기준 변경은 이유를 기록한다.
6. 팀 도구 환경에서 npm ci를 실행한다. 실제 버전은 docs/toolchain.md와 lockfile을 확인한다.

기존 작업을 이어가도록 승인받았다면 해당 브랜치와 변경을 유지하고 작업 명세를 맞춘다.

## 에이전트 시작 요청 예시

AGENTS.md 또는 CLAUDE.md와 지정한 작업 명세를 읽고 --plan을 실행해.
다른 영역은 읽어서 연결 방식을 확인하되 허용된 파일만 수정해.
범위 밖 문제는 경로와 재현 방법을 보고하고, 끝나면 전체 검사를 실행해 결과와 미검증을 알려줘.

## 검사와 포맷

- verify-change.mjs --task <작업명세.json> --plan으로 문서와 검사 목록을 확인한다.
- 필요한 경우 --format으로 허용된 변경 파일만 포맷한다. 전체 저장소에 자동 --fix를 실행하지 않는다.
- 마지막에는 --plan/--format 없이 전체 검사를 실행한다. 기준 커밋 이후 변경·staged·unstaged·untracked가 모두 검사 대상이다.
- rename은 삭제와 추가로 검사한다. 검사 대상에 다른 작업이 섞이면 범위를 확인하고 기존 변경을 보존한다.
- Prettier·ESLint·TypeScript·줄바꿈 설정은 저장소 기준을 따른다. 앱 초기화 때 실제 typecheck/test를 연결한다.
- Node test runner의 하네스 테스트는 제품 테스트를 대신하지 않는다.
- AGENTS.md와 CLAUDE.md는 동일하게 수정하고 각각 30줄 이하로 유지한다. 두 파일은 Prettier 대상에서 제외한다.

## PR과 merge

1. COMMIT_PR_POLICY.md를 읽고 제목을 만들고 검사한다. 본문에 변경·검증·미검증을 적는다.
2. 기능→개인 PR은 해당 기여자가 Squash and merge로 반영한다.
3. 개인→develop과 develop→main은 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 Create a merge commit으로 반영한다.
4. 팀원은 develop 변경을 자기 브랜치에 merge commit으로 반영한다. main은 버전 배포 때만 갱신한다.

충돌이 나면 양쪽 변경 의도를 확인하고 관련 검사를 실행한다. 공유 브랜치 force push나 보호 규칙 해제를 하지 않는다.
GitHub 권한·required checks는 개발 관리자가 설정한다. 문서나 CODEOWNERS만으로 권한이 적용되지는 않는다.
