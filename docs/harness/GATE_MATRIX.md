# 작업별 필수 문서와 검사

작업 시작 전에 이 표를 읽는다. docs/ 아래 문서와 작업 명세의 readBefore는 해당 작업에서 필수다.

| 작업 영역        | 읽을 문서                                           | 추가 검사                                                |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------- |
| 모든 작업        | mvp-scope.md, ownership.md, 이 문서, 작업 명세      | 범위·구조·Prettier·ESLint·하네스 테스트·코드 명세        |
| UI               | architecture.md, contracts.md                       | mobile typecheck/test                                    |
| API·더미·AI·DB   | architecture.md, contracts.md                       | 해당 서버 typecheck/test                                 |
| 공통 데이터 형식 | contracts.md, architecture.md, calculation-rules.md | contracts와 이를 사용하는 모든 앱·서버 typecheck/test    |
| 금융 계산        | calculation-rules.md, contracts.md                  | finance-core·mobile typecheck/test                       |
| 하네스·설정      | development-workflow.md, toolchain.md               | 검사기 테스트; 제품 코드가 있으면 전체 제품 검사         |
| 일반 문서        | 설명하는 기능의 문서                                | 공통 검사; 제품 코드가 없으면 제품 검사는 NOT_APPLICABLE |

검사기는 변경 파일과 allowedPaths로 읽을 문서와 검사를 선택한다. 새 기능을 추가하면 실제 typecheck/test 명령을 연결한다.
CODE_SPEC.md와 EXTENSION_POINTS.md도 공통 필수 문서다. Git 작업은 COMMIT_PR_POLICY.md를 읽는다.

## 실행 순서

저장소 루트에서 실제 작업 명세 경로로 실행한다.

1. `node scripts/harness/verify-change.mjs --task docs/tasks/FC-001.json --plan`: 계획 확인. 검사를 실행한 것은 아니다.
2. 필요한 경우 같은 명령의 --plan을 --format으로 바꿔 허용된 변경 파일만 포맷한다.
3. --plan/--format 없이 실행해 전체 검사를 마친다.

| 상태    | 뜻                                        | 종료 코드 |
| ------- | ----------------------------------------- | --------- |
| PASS    | 필요한 검사를 모두 실행해 통과            | 0         |
| FAIL    | 범위 위반 또는 검사 실패                  | 1         |
| BLOCKED | 명세·도구·명령·기준 커밋이 없어 검사 불가 | 2         |
| PLANNED | 계획만 확인                               | 2         |

보고서는 .harness/reports/에 저장한다. Android 기기 검증은 별도로 기록한다.

## 적용 범위

- 범위 검사는 잘못된 수정을 찾아낸다. 다른 파일의 수정을 물리적으로 차단하지는 않는다.
- 작업 명세·역할·검사기를 바꿔 통과시키지 않는다. 공통 규칙 변경은 PR에서 검토한다.
- 기본 CI는 공통 검사다. 작업별 범위 검사는 작업 명세를 지정해 실행하고 보고서를 확인한다.
- GitHub 권한과 required checks는 개발 관리자가 설정한다. CODEOWNERS는 리뷰 담당 표시다.
- 자기 PR은 스스로 승인할 수 없다. 팀의 리뷰·merge 절차로 처리하고 승인 완료를 꾸미지 않는다.
- 하네스 통과를 제품 구현 완료나 실기기 시연 완료로 보고하지 않는다.
