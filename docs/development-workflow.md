# 개발 시작과 통합

개발 관리자 포함 3명의 기여자가 같은 저장소를 사용한다. 담당 범위는 docs/ownership.md를 따른다.

## 작업 시작

1. git status --short --branch와 diff를 확인하고 기존 변경을 보존한다.
2. develop→개인 브랜치 동기화 PR을 merge commit으로 반영한다. 공유 브랜치를 reset으로 맞추지 않는다.
3. 최신 개인 브랜치에서 기능 브랜치를 만든다. 한 폴더에서는 쓰기 에이전트 하나만 실행한다.
4. docs/tasks/TEMPLATE.json을 새 작업 파일로 복사해 역할·브랜치·허용 경로·완료 조건·필수 문서를 적는다.
5. baseCommit은 git rev-parse HEAD로 확인한 40자리 커밋을 사용한다. 기준 변경은 이유를 기록한다.
6. 처음 환경을 준비하거나 lockfile·도구 환경이 바뀌면 팀 도구 환경에서 npm ci를 실행한다. 같은 기준으로 설치된 의존성은 재사용한다. 버전은 docs/toolchain.md와 lockfile을 확인한다.

기존 작업을 이어가도록 승인받았다면 해당 브랜치와 변경을 유지하고 작업 명세를 맞춘다.
첫 수정 전에 [자기검증 기준](harness/AGENT_REVIEW.md)에 따라 목적·허용 경로·계약·필수 검사를 확정한다. 같은 작업에서 이미 확인한 문서는 변경되거나 새로 필요한 내용만 읽는다.

## 에이전트 시작 요청 예시

AGENTS.md 또는 CLAUDE.md와 지정한 작업 명세의 미확인·변경 부분을 읽고, 유효한 계획이 없으면 --plan을 실행해.
다른 영역은 읽어서 연결 방식을 확인하되 허용된 파일만 수정해.
최초 범위 안에서 구현→자기검증→필요한 수정을 반복해. 범위 밖 문제는 경로와 재현 방법을 보고해.
유효한 통과 결과는 재사용하고 누락된 필수 검사가 없는지 확인해. 네 지표와 근거를 기록하고 0건·해당 없음·미확인을 구분해.

## 검사와 포맷

- 같은 명세·변경에 대한 유효한 계획이 없으면 verify-change.mjs --task <작업명세.json> --plan으로 문서와 검사 목록을 확인한다.
- 필요한 경우 --format으로 허용된 변경 파일만 포맷한다. 전체 저장소에 자동 --fix를 실행하지 않는다.
- --plan/--format 없는 전체 검사는 기준 커밋 이후 변경·staged·unstaged·untracked를 다룬다. 전체 실행 시점과 통과 결과 재사용은 GATE_MATRIX.md를 따른다.
- rename은 삭제와 추가로 검사한다. 검사 대상에 다른 작업이 섞이면 범위를 확인하고 기존 변경을 보존한다.
- Node/문서는 기존 Prettier·ESLint·TypeScript 기준을 따른다. Flutter는 [전환 기준](harness/FLUTTER_TRANSITION.md)의 앱 초기화·경로 정책·Dart 분석/테스트가 먼저 필요하다.
- Node test runner의 하네스 테스트는 제품 테스트를 대신하지 않는다. 하네스 PASS와 별도로 완료 조건과 관련 문서의 내용 일치를 AGENT_REVIEW.md 기준으로 확인한다.
- AGENTS.md와 CLAUDE.md는 동일하게 수정하고 각각 30줄 이하로 유지한다. 두 파일은 Prettier 대상에서 제외한다.
- 계약 위반·검사 누락 0건을 목표로 수정 전에 계약을 확인하고 완료 전에 필수 목록과 유효한 결과를 대조한다. 위반을 고쳐도 발생 기록은 지우지 않는다.

## 작업 기록

- 종료 시 PR 템플릿의 네 지표와 근거를 작성한다. PR 생성 전에는 .harness/reviews/<작업ID>.md에 저장하고 최종 보고에 요약한다.
- PR 작성 시 같은 기록을 본문에 옮긴다. .harness/는 Git 공유 대상이 아니므로 필요한 검사 결과를 비밀값 없이 요약해 첨부한다.
- 리뷰에서 발견한 사건은 같은 작업 기록에 반영한다. 개인→develop→main 통합 PR은 원본 작업 기록을 링크해 중복 집계하지 않는다.

## PR과 merge

1. COMMIT_PR_POLICY.md의 미확인·변경 부분을 확인하고 제목을 만들고 검사한다. 본문은 결과·완료 범위를 먼저 쓰고 변경·검증·미검증을 적는다.
2. 기능→개인 PR은 해당 기여자가 Squash and merge로 반영한다.
3. 개인→develop과 develop→main은 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 Create a merge commit으로 반영한다.
4. 팀원은 develop 변경을 자기 브랜치에 merge commit으로 반영한다. main은 버전 배포 때만 갱신한다.

충돌이 나면 양쪽 변경 의도를 확인하고 관련 검사를 실행한다. 공유 브랜치 force push나 보호 규칙 해제를 하지 않는다.
GitHub 권한·required checks는 개발 관리자가 설정한다. 문서나 CODEOWNERS만으로 권한이 적용되지는 않는다.

스킬 사용과 팀원 준비는 [선정·설치 안내](harness/FLUTTER_SKILLS.md), [팀원용 빠른 시작](harness/TEAM_SKILLS_QUICKSTART.md)을 따른다. 저장소의 두 도구용 스킬은 같은 버전으로 관리한다.
