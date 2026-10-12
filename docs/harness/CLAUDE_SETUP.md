# Claude Code와 Codex의 팀 스킬

현재 팀은 개발 관리자 포함 세 명이며, 사용자 한 명은 Codex, 다른 두 명은 Claude Code를 사용한다. 인원과 역할은 [ownership](../ownership.md), 작업 공통 규칙은 루트 CLAUDE.md/AGENTS.md, 검사 선택은 [GATE_MATRIX](GATE_MATRIX.md)가 기준이다.

## 공유 구성

| 파일                                          | 목적                                                 | 공유 |
| --------------------------------------------- | ---------------------------------------------------- | ---- |
| CLAUDE.md / AGENTS.md                         | 바이트가 같은 30줄 공통 규칙                         | Git  |
| .claude/settings.json                         | 기존 Git 조회·Node 하네스 명령에 대한 승인 부담 완화 | Git  |
| .claude/rules/reporting.md                    | 결과와 완료 범위를 먼저 보고                         | Git  |
| .claude/skills/각-스킬/SKILL.md               | Claude Code 프로젝트 스킬                            | Git  |
| .agents/skills/각-스킬/SKILL.md               | Codex 프로젝트 스킬. Claude 배포본과 내용 동일       | Git  |
| .claude/settings.local.json / CLAUDE.local.md | 개인 선호·개인 권한 설정                             | 개인 |
| .harness/ / .claude/worktrees/                | 실행 기록·설치 백업·로컬 사본                        | 개인 |

모델, 로그인, API 키, 개인 경로를 공통 설정에 고정하지 않는다. 설치본은 기존 9개 명령 허용을 보존하며 Flutter 명령의 자동 승인이나 권한 우회 설정을 추가하지 않는다. 이 allow 목록은 모든 다른 명령을 금지하는 목록이 아니며 실행 시 개인 권한 정책이 적용된다. 명령 허용만으로 파일 수정 범위가 물리적으로 차단되지는 않는다.

스킬의 이름·설명으로 자동 선택할 수 있고 이름을 지정해 직접 요청할 수도 있다. Claude에서는 `/flowcast-task`, Codex에서는 스킬 선택 또는 이름을 지정한 요청을 사용한다. 공통 배포본은 Claude 전용 `$ARGUMENTS` 치환에 의존하지 않고 대화에서 요청과 실제 명세를 읽는다.

## 설치와 확인

[선정과 각 스킬 설치법](FLUTTER_SKILLS.md), [팀원용 빠른 시작](TEAM_SKILLS_QUICKSTART.md)을 따른다. 설치 담당자가 두 도구용 파일과 공통 문서를 함께 반영하면 팀원은 Git으로 같은 버전을 받는다. 폴더는 실제 파일 복사 방식이므로 Windows 심볼릭 링크 설정은 필요 없다.

동일 이름의 개인 스킬이 있다면 프로젝트 스킬이 실제로 선택되는지 출처를 확인한다. 새 세션에서 목록·직접 호출을 확인하고 변화가 반영되지 않으면 클라이언트를 다시 시작한다. 정적 파일 검사와 실제 팀원 세션 확인은 별도다.

현재 여섯 스킬은 MCP 없이 사용 가능한 작업 지침이다. Flutter SDK·앱·역할 정책·테스트 전제는 [전환 기준](FLUTTER_TRANSITION.md)을 따른다. Flutter 앱 초기화와 E2E·디자인 시스템 구현은 설치만으로 완료되지 않는다.

## 변경과 유지

스킬 내용의 기준은 .agents/skills 쪽으로 관리하고 같은 변경에서 .claude/skills 배포본을 맞춘다. 내용이 다르면 통합 전에 정정한다. 팀원마다 외부 스킬을 최신 버전으로 다시 설치하지 않고 검토한 파일을 Git으로 배포한다.

유효한 PASS 재사용과 [네 지표](AGENT_REVIEW.md)를 유지한다. 저장 시 전체 검사를 실행하는 후크나 스킬별 중복 기록을 추가하지 않는다. commit·push·PR·merge는 기존 사용자 승인과 팀 흐름에 따른다.

공식 근거: [Claude 프로젝트 스킬](https://code.claude.com/docs/en/skills), [공유/개인 설정](https://code.claude.com/docs/en/settings), [Codex 프로젝트 스킬](https://learn.chatgpt.com/docs/build-skills).
