# 개발 시작과 통합

## 최초 적용 담당자

이 폴더는 배포용 템플릿이다. Git 저장소를 만들거나 원격 변경을 하지 않았다. 기존 README와 충돌하므로 ZIP을 바로 덮어쓰지 않는다. 별도 로컬 checkout의 기능 브랜치에 새 파일을 적용하고 README는 내용을 병합한다.

1. 기존 개인 브랜치를 기준으로 초기 구조용 기능 브랜치를 만든다.
2. 이 패키지의 숨김 폴더(.github/.vscode 등)까지 복사하고 git diff로 확인한다.
3. 팀 Node 24.21.0/npm 11.19.0 환경에서 npm ci와 npm run check를 실행한다.
4. 본인 전용 브랜치 PR → develop PR 순서로 공통 골격을 통합한다.
5. 다른 개발자는 공통 구조가 들어온 develop을 개인 브랜치에 반영한 후 기능 브랜치를 만든다.

공유 브랜치를 reset으로 맞추지 않는다. 기본은 develop→개인 동기화 PR과 merge commit이다. 기능 PR squash는 선택 가능하나 개인↔develop과 release는 공통 이력 유지를 위해 merge commit을 권한다. 충돌 시 양쪽 의도를 읽고 관련 테스트를 실행한다.

## 에이전트에게 줄 시작 요청

```text
AGENTS.md 또는 CLAUDE.md를 읽고 docs/tasks/FC-001.json 작업만 수행해.
먼저 --plan으로 핵심 참조와 검증을 확인해.
상대 영역은 읽어서 계약을 확인하고, 수정은 허용 범위에만 해.
범위 밖 문제가 있으면 경로·재현·필요 변경을 보고해.
끝나면 전체 verify 결과와 실제 미검증을 구분해 보고해.
```

작업 명세의 baseCommit은 시작할 때 git rev-parse HEAD로 얻은 40자리 커밋이다. 추후 develop 통합으로 기준을 바꿀 때 변경 이력을 남긴다. 검사에는 기준 이후 커밋된 변경, staged/unstaged, untracked 파일 모두 포함된다. rename은 삭제+추가로 검사한다.

## 도구 사용

- Prettier: 공유 설정으로 코드 형태 통일. --format은 작업의 허용된 변경 파일만 쓴다.
- ESLint: 코드 오류와 기본 TS 규칙. 검사는 읽기 전용이다. 자동 --fix를 전체 저장소에 돌리지 않는다.
- TypeScript: 공통 엄격 설정. 실제 각 앱/서버 초기화 시 환경에 맞는 tsconfig/typecheck를 연결한다.
- Node test runner: 하네스 자체 회귀 검사. 제품 테스트를 대신하지 않는다.
- .editorconfig/.gitattributes: Windows/macOS 줄바꿈·들여쓰기 통일.
- VS Code: 추천 확장 공유. 저장 시 자동 수정은 기본 꺼서 타 영역을 실수로 포맷하지 않게 한다.

AGENTS.md·CLAUDE.md는 동일한 27줄이며 수동 동시 수정 후 check:structure가 일치·줄 수를 검사한다. Prettier 대상에서는 제외해 번호 목록을 재배치하지 않게 했다. 세부 규칙은 docs/harness/engineering-rules.md에서 보충하되 핵심 참조/검증 선택은 GATE_MATRIX를 따른다.

## PR과 권한

기능→개인→develop→main. develop/main merge는 sunghyun-dev만 한다. 이 패키지는 원격 권한을 바꾸지 않는다. CI 최초 성공 후 Repository Settings → Rules → Rulesets에서 기존 보호 정책과 required check 설정을 확인한다. 개인 브랜치의 자율 merge와 관리자의 자기 PR 검토 경로를 막지 않게 설정한다.
