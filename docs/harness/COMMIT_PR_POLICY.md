# 커밋·PR·merge 메시지 필수 규칙

이 문서는 AGENTS.md와 CLAUDE.md가 지정하는 필수 참조다. 커밋 또는 PR 작업을 요청받은 에이전트가 변경 내용을 읽고 제목을 직접 작성한다. 사용자가 제목을 미리 작성할 필요는 없다. 이 규칙 자체가 commit·push·PR 생성·merge 실행을 승인하지는 않는다.

## 제목

`type(scope): 한국어 설명` 형식을 커밋 첫 줄과 PR 제목에 공통 적용한다. 한 줄, 앞뒤 공백 없음, 100자 이하로 작성한다. 설명은 실제 변경 결과를 구체적으로 표현한다. 의미 있는 계약 파괴 변경에만 `type(scope)!: 설명`을 사용하고 본문에 영향과 전환 방법을 적는다.

| type     | 사용 기준                        |
| -------- | -------------------------------- |
| feat     | 사용자 기능 추가                 |
| fix      | 잘못된 동작 수정                 |
| refactor | 동작을 유지하는 구조 개선        |
| docs     | 문서 변경                        |
| test     | 검증 추가·수정                   |
| chore    | 개발 설정·브랜치 통합·릴리스     |
| ci       | GitHub Actions 등 자동 검증 변경 |

scope는 변경의 중심 영역을 쓴다. 기본값은 `repo`, `harness`, `mobile`, `api`, `mock-bank`, `contracts`, `finance`, `spending`, `allocation`이다. 새 기능 영역은 소문자 영문·숫자와 단어 사이 하이픈으로 확장할 수 있다. 여러 영역을 바꿨다는 이유만으로 관련 없는 변경을 한 PR에 묶지 않는다.

예시:

```text
feat(spending): 소비 전후 가용금액 비교 추가
fix(finance): 카드 청구액 중복 차감 수정
chore(harness): 공통 하네스와 개발 구조 추가
chore(repo): sunghyun-dev 변경을 develop에 통합
chore(repo): develop 변경을 sunghyun-dev에 동기화
chore(repo): v0.1.0 출시
```

## 에이전트 작업 순서

1. 허용된 작업 범위와 diff를 읽고 변경 목적에 맞는 제목을 만든다. 무관한 변경을 stage하지 않는다.
2. 커밋할 때 생성한 메시지를 UTF-8 파일에 저장하고 `node scripts/harness/check-message.mjs --commit-file .harness/commit-message.txt`로 검사한다. `.harness`는 기존 ignore 대상이다.
3. PR을 만들거나 변경 목적이 바뀌었을 때 제목을 생성·갱신하고 `node scripts/harness/check-message.mjs --title-file .harness/pr-title.txt`로 검사한다.
4. PR 본문에는 기존 템플릿에 따라 변경 내용, 검증 결과, 미검증 항목을 적는다. PR 제목 검사 통과가 제품 검증 통과를 뜻하지 않는다.
5. 사용자가 merge를 요청했다면 대상 브랜치에 맞는 방식을 선택하고 최종 메시지 제목에도 PR 제목을 사용한다. 수동 UI에서는 미리 채워진 제목을 그대로 사용한다.

검사 실패 시 제목을 수정한다. 형식을 맞추기 위해 검사기를 완화하거나 보호 규칙을 우회하지 않는다. 설명의 정확성과 변경 목적 일치는 에이전트와 리뷰어가 확인한다. 자동 검사는 형식만 보장한다.

## 브랜치별 merge 방식

| 이동                           | 방식                  | 이유                                  |
| ------------------------------ | --------------------- | ------------------------------------- |
| 기능 브랜치 → 본인 전용 브랜치 | Squash and merge      | 기능 PR을 한 커밋으로 정리            |
| 본인 전용 브랜치 → develop     | Create a merge commit | 지속 사용하는 브랜치의 공통 이력 유지 |
| develop → 본인 전용 브랜치     | Create a merge commit | 다음 작업에 통합 변경 반영            |
| develop → main                 | Create a merge commit | 릴리스 이력과 develop의 연결 유지     |

기능 브랜치는 merge 후 새 작업에 재사용하지 않는다. 개인 브랜치와 develop처럼 계속 사용하는 브랜치 사이에서는 반복 squash를 피한다. develop/main의 merge 담당과 기존 권한 정책은 그대로 따른다.

## 자동 검증의 범위

`Message policy` 워크플로의 `title` 작업이 PR 제목을 검사한다. 제목만 편집해도 재검사한다. 기존 `Common harness / baseline` 검사는 별도로 유지한다. GitHub의 required status check에 새 검사를 등록해야 실패 시 merge가 차단된다.

로컬 커밋은 하네스 규칙을 읽는 에이전트가 작성·검사한다. 사용자가 직접 다른 방식으로 만든 모든 커밋을 강제 검증하는 hook은 이 패키지에 포함하지 않는다. PR 제목을 기본 merge 메시지로 설정해도 사용자가 최종 메시지를 직접 수정하는 것까지 방지되지는 않는다. 검사 파일 자체의 임의 변경은 공통 파일 소유권·리뷰 정책으로 관리한다.
