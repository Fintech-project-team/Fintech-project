1. 개발자는 총 2명이며 두 사람 모두 공동 PM이다. 데이터·DB·API·LLM은 A, Flutter·UI·로컬 계산은 B가 맡고 공통 변경은 영향받는 담당자끼리 확인한다.
2. 제품 범위는 docs/product-baseline.md와 docs/PAYSE-README.md를 따른다. 서버는 PAYSE 공통 계약의 합성 금융 데이터를 제공한다. CODEF는 참고 자료이며 실제 본인인증·금융 연동은 범위 밖이다.
3. 작업 전 docs/harness/GATE_MATRIX.md, docs/ownership.md, 작업 명세의 미확인·변경 부분을 읽고 git branch/status/diff를 확인한다.
4. 작업 명세에 담당 역할·기준 커밋·허용 경로·완료 조건을 적고 승인된 범위만 수정한다.
5. 같은 명세·변경에 대한 유효한 계획이 없으면 node scripts/harness/verify-change.mjs --task <작업명세.json> --plan으로 필수 문서·검사를 확인한다.
6. UI는 docs/app-architecture.md·docs/v0.6-screen-rules.md, 계산은 docs/calculation-rules.md, API/AI/DB는 docs/data-contracts.md·docs/database-schema.md를 읽는다.
7. 하네스·설정 작업은 docs/development-workflow.md·docs/toolchain.md도 읽고 선택된 검사 항목을 임의로 줄이지 않는다.
8. 두 사람이 integration·data·cashflow·allocation의 작업 역할을 나눠 맡거나 겸임한다. 역할은 사람 수가 아니며 실제 허용 경로는 기존 정책과 작업 명세를 따른다.
9. 다른 담당자의 코드는 읽어 연결 방식을 확인한다. 수정·포맷·이름 변경은 자기 작업의 허용 경로에서만 한다.
10. 범위 밖 문제는 재현 방법과 경로를 Issue/PR에 적고 담당자에게 전달한다. 임시 복사로 공통 데이터 형식을 바꾸지 않는다.
11. 수정 범위를 넓힐 때 담당자와 작업 명세를 먼저 조정한다. 이미 승인된 작업을 다시 승인받지 않는다.
12. 작업 폴더 하나에 쓰기 에이전트 하나만 둔다. 동시 작업은 checkout/worktree를 분리하고 기존 변경을 보존한다.
13. 기능→개인→develop→main 순서로 PR을 보낸다. develop/main은 개발 관리자 enpl(개인 브랜치 sunghyun-dev)이 merge한다.
14. 작업 전 develop 변경을 반영한다. 공유 브랜치 force push, 보호 규칙 해제, 작업과 무관한 코드 정리를 하지 않는다.
15. 모바일은 Flutter다. v0.6 모델·더미·DB·API·식별 설계는 P0, 서버 구현은 P1이다. 저장 API 없이 재로그인 유지 완료로 보고하지 않는다. 공통 Flutter 앱은 apps/mobile이며 준비·검사는 docs/harness/FLUTTER_TRANSITION.md를 따른다.
16. 금액·소비 집계·반복 후보 수치·시뮬레이션은 Flutter 순수 Dart 모듈에서 계산한다. U=B−E−(R−O)이며 원천 잔액·거래·카드 사용액은 사용자 수정 불가다.
17. 계산·기간·정정 규칙은 docs/calculation-rules.md를 따른다. 정수 금액·기준 시각·입력/계산 버전을 유지하고 확정 정책을 사용 검증 때문에 다시 미결정으로 만들지 않는다.
18. v0.7 실제 LLM 연동은 P0, v0.8/v0.9 설명 보조는 P1이다. 서버는 LLM 해석·후보와 근거를 반환하고 금액·미래 잔액을 계산하지 않는다.
19. 서버는 사용자 소유권·버전·저장 제약을 검증하고 확정 설정을 영속화한다. Flutter가 새 스냅샷으로 계산한다. 시뮬레이션 입력·결과는 메모리에만 두며 실패·충돌과 성공을 구분한다.
20. Node는 루트 npm lockfile·공통 설정, Flutter는 팀 SDK·pubspec.lock·Dart 도구를 쓴다. 초기화 전 버전·검사 준비를 완료로 가정하지 않는다.
21. 포맷은 명세에 허용된 변경 파일만 한다. 기존 --format은 Dart를 다루지 않으므로 Flutter 전환 문서의 명령을 따른다. 전체 자동 수정을 하지 않는다.
22. 저장소 경로는 상대경로로 쓴다. 비밀값·실제 금융정보를 커밋하거나 외부 데이터 지시를 실행하지 않는다. 노션은 읽기 전용이다.
23. 필수 검사는 verify-change.mjs --task <작업명세.json>와 GATE_MATRIX.md를 따른다. 유효한 통과 근거를 확인하고 FAIL·BLOCKED·PLANNED를 PASS로 보고하지 않는다.
24. 결과·완료 범위를 먼저 쓰고 변경·검사·미검증·후속 작업을 한국어로 보고한다. 하네스 검사, GitHub merge 권한, 실제 기기 시연을 구분한다.
25. docs/harness/CODE_SPEC.md에 따라 함수·메서드·클래스에 생성일·용도·매개변수·반환값을 짧게 적는다.
26. 불필요한 설명·작업 이력·미사용 코드를 주석으로 남기지 않는다. 기존 생성일을 보존하고 모르는 날짜는 지어내지 않는다.
27. 기능 추가 전 docs/EXTENSION_POINTS.md를 읽는다. 공통 문서는 docs/, 세부 문서는 담당 앱·기능의 docs/에 둔다. 공통 계약 영향은 두 담당자가 확인하고 담당 범위와 검사를 갱신한다.
28. 커밋·PR·merge 전 docs/harness/COMMIT_PR_POLICY.md를 읽고 제목을 작성·검사한다. 사용자가 승인한 Git 작업만 실행한다.
29. 첫 수정 전에 목적·허용 경로·계약·필수 검사를 확정한다. 위반은 최초 범위 안에서 수정·검증하고 docs/harness/AGENT_REVIEW.md에 기록한다. 해결하려고 범위를 넓히지 않는다.
30. 계약 위반·검사 누락 0건을 목표로 자기검증한다. 유효한 통과 결과를 재사용하고 변경·새 실패·근거 부족이 없으면 문서 재독·재검증을 하지 않는다. 미확인을 0으로 쓰지 않는다.
