# 커밋·PR·merge 규칙

AI는 커밋·PR 작업 전에 이 문서를 읽고 변경 내용에 맞는 제목을 만든다. 사용자에게 제목 작성을 떠넘기지 않는다.
이 문서는 Git 작업의 실행 승인이 아니다. 사용자가 요청한 commit·push·PR·merge만 수행한다.

## 빠른 안내: 제목

커밋 첫 줄과 PR 제목은 `type(scope): 한국어 설명` 형식이다. 현재 자동 검사는 이 형식을 필수로 요구한다.

| type     | 용도                      | 예시                                           |
| -------- | ------------------------- | ---------------------------------------------- |
| feat     | 기능 추가                 | feat(spending): 하루 가용금액 표시             |
| fix      | 오류 수정                 | fix(finance): 카드 청구액 중복 차감 수정       |
| refactor | 동작을 유지하며 코드 정리 | refactor(api): 거래 조회 함수 분리             |
| docs     | 문서 수정                 | docs(repo): 팀원 Git 안내 추가                 |
| test     | 테스트 추가·수정          | test(finance): 월급일 경계 사례 추가           |
| chore    | 설정·동기화·릴리스        | chore(repo): develop 변경을 hyeyeon-dev에 반영 |
| ci       | 자동 검사 변경            | ci(harness): PR 제목 검사 개선                 |

- 제목은 한 줄, 100자 이하이며 앞뒤 공백이 없어야 한다. 설명에는 한글이 한 글자 이상 있어야 한다.
- scope는 소문자 영문으로 시작한다. 소문자 영문·숫자를 쓰고 단어 사이는 하이픈 하나로 잇는다.
- 기본 scope: repo, harness, mobile, api, mock-bank, contracts, finance, spending, allocation. 새 영역도 같은 형식으로 추가할 수 있다.
- 콜론 뒤에는 공백 한 칸을 넣고 설명을 시작한다. 기존 API를 깨는 변경만 `type(scope)!: 설명`으로 표시하고 전환 방법을 본문에 적는다.
- 실패 예: `fix: 오류 수정`(scope 없음), `update(api): 응답 수정`(type 오류), `feat(API): 응답 추가`(대문자).
- `develop 브랜치 기본 구조 반영`은 뜻이 통하지만 현재 검사에서는 실패한다. 검사 완화는 아직 적용하지 않았다.
- 설명이 실제 변경과 맞는지는 작성자와 리뷰어가 확인한다. 무관한 변경을 한 커밋이나 PR에 묶지 않는다.

## PR 방향과 담당자

3명 모두 기여자이며 개발 관리자는 개발·통합을 맡는다. 프로젝트 소유자를 뜻하지 않는다.
base는 받는 브랜치, compare는 가져올 브랜치다. 활성 개인 브랜치는 sunghyun-dev, hyeyeon-dev, seonghwan-dev다. 팀 구성과 작업 역할은 docs/ownership.md를 따른다.

| compare → base             | merge 방식            | 담당             |
| -------------------------- | --------------------- | ---------------- |
| 기능 → 본인 전용 브랜치    | Squash and merge      | 해당 기여자      |
| 본인 전용 브랜치 → develop | Create a merge commit | 개발 관리자 enpl |
| develop → 본인 전용 브랜치 | Create a merge commit | 해당 기여자      |
| develop → main             | Create a merge commit | 개발 관리자 enpl |

enpl의 개인 브랜치는 sunghyun-dev다. 기능 브랜치는 merge 후 재사용하지 않는다. main·develop·활성 개인 브랜치는 삭제하지 않는다. 비활성 브랜치도 이 문서 수정만으로 삭제하지 않으며 인수인계 확인과 별도 삭제 요청 후 처리한다.
최종 merge 제목은 PR 제목을 사용한다. 개인↔develop 및 develop→main에서 반복 squash를 하지 않는다.

## 에이전트의 작성·검사 순서

1. 작업 범위와 diff를 확인하고 제목을 만든다. 제목과 커밋 메시지는 .harness/ 아래 UTF-8 파일에 저장한다.
2. PR 제목: `node scripts/harness/check-message.mjs --title-file .harness/pr-title.txt`
3. 커밋 첫 줄: `node scripts/harness/check-message.mjs --commit-file .harness/commit-message.txt`
4. 본문에는 기존 PR 템플릿에 따라 결과·완료 범위를 먼저 쓰고 변경·검증·미검증을 적는다. 변경 목적이 달라지면 제목도 갱신한다.
5. 검사 통과 후 사용자가 요청한 Git 작업을 진행한다. 종료 코드 0은 통과, 1은 형식 위반, 2는 실행 오류다.

## GitHub 검사와 한계

- Message policy / title은 PR 제목을 검사한다. 열린 PR의 제목 편집·새 커밋 push 등으로 다시 실행된다.
- Common harness / baseline은 npm run check로 구조·형식·린트·하네스 테스트를 실행한다. 제품 실행 검증은 별도다.
- 실패한 검사의 Details에서 FAIL: 로그를 확인한다. baseline 실패는 npm run check로 재현한다.
- 동일 커밋으로 여러 PR을 만들면 제목 검사 결과가 다른 PR 목록에도 표시될 수 있다. 실행 제목과 대상 PR을 확인한다.
- 이미 merge된 PR의 제목을 수정해도 기존 merge 커밋이나 과거 실행 기록이 바뀌지는 않는다.
- required checks와 bypass는 GitHub 설정이다. 검사 파일이 있다고 merge 차단까지 적용되는 것은 아니다.
- 로컬 hook은 제공하지 않는다. 사람이 직접 작성한 모든 커밋이나 최종 merge 메시지 수정을 강제로 막지는 않는다.
- PR 제목은 GitHub가 자동으로 고쳐주지 않는다. 형식이 틀리면 제목을 수정하고 검사한다.
- 검사 통과만을 위해 검사기·보호 규칙을 우회하지 않는다. 정책 변경이 승인되면 검사·문서·테스트를 함께 수정한다.
