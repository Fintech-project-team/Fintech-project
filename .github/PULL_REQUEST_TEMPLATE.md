<!--
PR 제목: type(scope): 한국어 설명  (한 줄, 100자 이하, 설명에 한글 포함)
  예) feat(spending): 소비 전후 가용금액 비교 추가
      fix(finance): 카드 청구액 중복 차감 수정
      docs(harness): Git 규칙 빠른 안내 추가
      chore(repo): develop 변경을 sunghyun-dev에 동기화
  type: feat, fix, refactor, docs, test, chore, ci / 기존 API를 깨는 변경만 type(scope)!: 설명

base(받는 쪽) ← compare(보내는 쪽)
  본인 전용 브랜치 ← 기능 브랜치        : Squash and merge
  develop          ← 본인 전용 브랜치    : Create a merge commit (개발 관리자 enpl이 merge)
  본인 전용 브랜치 ← develop             : Create a merge commit
  main             ← develop             : Create a merge commit (개발 관리자 enpl이 merge)

상세: docs/harness/COMMIT_PR_POLICY.md 의 빠른 안내
-->

> 개발 관리자 포함 4명의 기여자가 참여합니다. 관리자는 개발·통합을 맡으며 프로젝트 소유자를 뜻하지 않습니다.

## 해결하는 문제와 결과

- 작업 명세: docs/tasks/FC-000.json
- 담당 역할 / 대상 브랜치:
- 사용자 관점의 변경:

## 범위와 연동 확인

- 수정한 경로:
- 읽어서 확인한 다른 영역의 데이터 형식/호출부:
- 공통 파일 또는 범위 밖 변경: 없음 / 합의 근거
- 상대 담당자가 후속 반영할 내용:

## 검증

- 실행 명령 / 결과 / 보고서 runId:
- 실패·차단·미실행 항목:
- Android 실제 기기: 미실행 / 실행 결과

## 리뷰 확인

- [ ] 자기 허용 범위를 벗어난 자동 포맷·수정이 없다.
- [ ] 변경된 데이터 형식을 사용하는 코드를 읽고 호환성을 확인했다.
- [ ] 전체 필수 검증 결과와 미검증을 구분했다.
- [ ] main/develop 및 개인 브랜치의 올바른 PR 대상을 확인했다.
