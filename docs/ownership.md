# 세 개발자의 범위와 통합 담당

개발 역할은 data, cashflow, allocation 세 개다. integration은 공통 계약·계산·설정·통합 책임이며 네 번째 병렬 기능 개발 영역을 뜻하지 않는다. 관리자가 겸임하거나 총원이 세 명이면 한 명이 겸임한다. 사람별 최종 배정은 팀 합의 후 이 표에 기록한다.

| 역할        | 쓰기 영역                                           | 상대 코드에서 읽을 것                                                      |
| ----------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| data        | apps/api, apps/mock-bank                            | contracts·finance-core 입력, mobile API 호출 요구                          |
| cashflow    | mobile/src/features/connection, recurring, spending | contracts·finance-core 출력, shared 클라이언트, allocation 공개 인터페이스 |
| allocation  | mobile/src/features/allocation, docs/demo           | contracts·finance-core, spending 결과 의미, API 계획 저장 계약             |
| integration | 공통 구조·packages·라우팅·shared·CI·설정            | 세 영역 변경·통합 테스트                                                   |

쓰기 영역은 scripts/harness/policy.json에서 검사한다. 각 작업은 그 안에서도 allowedPaths로 범위를 더 좁힌다. **다른 영역의 읽기는 허용하며 연동 확인을 위해 권장한다.** 읽었다고 수정 권한이 생기지는 않는다.

각 package.json과 모든 lockfile·설정·하네스는 공통 담당자 영역이다. data가 apps/api를 맡아도 package.json 변경은 자동으로 허용되지 않는다. 필요 패키지·API 필드·라우트 등록은 작은 공통 선행 PR로 취합한다. 담당자가 이미 승인한 작업이면 작업 명세/역할을 반영하고 반복 승인받지 않는다.

## 공유 작업을 안전하게 나누는 방법

1. 작업 Issue의 허용 파일과 완료 조건을 먼저 합의한다.
2. 공통 계약을 먼저 develop에 합친다. 기능 담당자는 그 기준에서 시작한다.
3. 다른 코드의 호출부와 타입을 읽고, 문제는 상대 파일을 수정하는 대신 재현·영향·제안을 전달한다.
4. 한 checkout당 쓰기 에이전트 하나. 같은 PC에서 병렬 작업이면 별도 checkout/worktree를 쓴다.
5. 작은 PR로 자주 통합하고 작업 명세는 작업별 파일로 나눈다. 하나의 진행상황 문서를 모두 고치지 않는다.

main/develop merge 담당 sunghyun-dev와 기존 개인 브랜치 구조는 유지한다. CODEOWNERS는 접근 통제가 아니며 개인 브랜치에 관리자 필수 승인을 일괄 적용하지 않는다.
