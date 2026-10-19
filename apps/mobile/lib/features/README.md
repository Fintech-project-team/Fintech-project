# 기능 구현 위치

기능 코드를 작성할 때 `auth`, `connection`, `overview`, `planning`, `recurring`, `simulation`, `adjustment` 아래 필요한 파일을 생성한다. 초기화 작업은 제품 기능을 구현하지 않는다.

- 공통 앱 진입점·라우팅·구성: `../app/`.
- 공유 Repository·외부 adapter: `../data/`. 실제 계약 구현 시 필요한 파일만 생성한다.
- 위젯은 금액을 직접 계산하지 않는다. 순수 계산은 후속 구현의 `packages/payse_calculation/`에 둔다. 아직 패키지를 생성하거나 계산 함수를 구현하지 않았다.
- 각 기능의 세부 문서는 `<feature>/docs/`, 테스트는 `../../test/features/<feature>/`다.
- `planning`, `adjustment`는 allocation 역할, 나머지 위 기능은 cashflow 역할이다. 공통 경로와 manifests는 integration 역할이 조정한다.
- 공통 제품·계산·데이터 기준은 루트 `docs/`를 참조하고 기능 문서에 복제하지 않는다.
