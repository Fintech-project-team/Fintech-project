# 필수 참조와 검증 선택표

AGENTS.md와 CLAUDE.md의 3·5·6·7·23번 규칙이 이 표를 필수 실행 계약으로 지정한다. 단순 추천 링크가 아니다.

| 변경 영역           | 반드시 읽을 핵심 문서                             | 추가 검증                                             |
| ------------------- | ------------------------------------------------- | ----------------------------------------------------- |
| 모든 작업           | mvp-scope, ownership, 본 표, 작업 명세/readBefore | 범위·하네스 일치·Prettier·ESLint                      |
| UI 코드             | architecture, contracts                           | mobile typecheck/test                                 |
| API·더미·AI·DB 코드 | architecture, contracts                           | 해당 서버 typecheck/test                              |
| contracts 코드      | contracts, architecture, calculation-rules        | contracts 및 모든 소비자의 typecheck/test             |
| finance-core 코드   | calculation-rules, contracts                      | finance-core·mobile typecheck/test                    |
| 하네스·설정         | 본 표, development-workflow, toolchain            | 검사기 자체 테스트; 제품 코드가 있으면 제품 검사 전체 |
| 일반 문서만         | 해당 문서가 설명하는 영역의 명세                  | 구조·형식·린트, 제품 코드는 NOT_APPLICABLE            |

경로는 docs/ 아래 파일을 뜻한다. 변경된 파일뿐 아니라 작업 명세의 허용 경로도 참조 선택에 사용한다. 새 코드가 생기면 해당 workspace에 typecheck/test를 연결해야 한다. 없는 명령을 건너뛰고 PASS로 처리하지 않는다.

## 명령

```sh
npm ci
node scripts/harness/verify-change.mjs --task docs/tasks/FC-001.json --plan
node scripts/harness/verify-change.mjs --task docs/tasks/FC-001.json --format
node scripts/harness/verify-change.mjs --task docs/tasks/FC-001.json
```

--plan은 참조/검증 계획만 출력하며 상태 PLANNED·종료 코드 2다. --format은 범위 검사 후 변경된 허용 파일만 포맷하고 전체 검증 완료로 표시하지 않는다. 종료 검증은 --plan/--format 없이 실행한다.

PASS=선택된 검사를 모두 실행해 통과(종료 0), FAIL=범위/검사 실패(1), BLOCKED=명세·도구·명령·기준 부재(2). 결과는 .harness/reports/ 아래 새 JSON으로 남긴다. PLANNED는 통과가 아니며 코드가 없으면 제품 검사는 NOT_APPLICABLE이다. Android 실기기는 항상 별도 기록이다.

## 강제성의 한계

- 범위 검사는 변경 후 탐지다. 다른 파일을 물리적으로 읽기 전용으로 만들지는 않는다.
- 로컬 명세·역할·검사기를 고쳐 우회하는 악의적 사용을 막는 보안 시스템은 아니다. 공통 정책과 작업 명세를 코드 리뷰한다.
- 기본 CI는 전체 형식·린트·하네스 자체 검사다. 작업별 범위 검사는 명세를 지정해 실행하며 PR 보고서를 리뷰한다. 신뢰된 기준 정책으로 서버 측 범위 검사를 강제하는 CI는 후속 강화 작업이다.
- GitHub Rulesets의 merge 권한·required checks는 관리자가 별도 설정한다. CODEOWNERS는 담당 리뷰 표시다. 본인이 만든 PR은 본인이 승인할 수 없으므로 관리자 본인 PR의 리뷰/예외 흐름을 별도로 정한다.
- 앱·DB·AI·실기기 검사기 전체를 SDV에서 복사하지 않았다. Flowcast 실제 기능이 추가되면 필요한 실제 검사만 연결한다.
