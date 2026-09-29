# 팀 개발 도구

아래는 저장소에 기록된 팀 기준이다. 이번 문서 수정에서는 버전이나 의존성을 변경하지 않았다.

| 영역                | 기준                                              | 현재 상태                             |
| ------------------- | ------------------------------------------------- | ------------------------------------- |
| Node / npm          | 24.21.0 / 11.19.0                                 | engines·packageManager·.nvmrc에 고정  |
| 앱                  | Expo 57.0.25 / React Native 0.86.3 / React 19.2.3 | 초기화 전 제안                        |
| Router / TypeScript | Expo Router 57.0.23 / TypeScript 6.0.3            | Router 설치 전, TS는 공통 도구에 포함 |
| API / 더미 서버     | Fastify 5.12.5                                    | 초기화 전 제안                        |
| DB                  | PostgreSQL 18.6                                   | 연결·초기화 전                        |
| Android             | JDK 17.0.20.1 / API 36 / Build Tools 36.0.0       | 앱 빌드와 실기기 검증은 별도          |

## 설치와 변경

- integration이 프레임워크 초기화 전에 공식 배포와 호환성을 확인한다. 제공되지 않는 버전이나 달라진 요구조건은 팀에 알리고 기준을 수정한다.
- 각자 latest로 앱을 만들지 않는다. Expo와 React Native 버전을 따로 올리지 않는다.
- 루트 package-lock.json 하나로 의존성을 관리한다. 새 패키지는 루트에서 추가하고 팀원은 npm ci로 같은 버전을 설치한다.
- 현재 lockfile에는 공통 개발 도구와 workspace가 있다. 실제 앱·서버 프레임워크는 아직 포함하지 않는다.
- 명령은 저장소 루트의 상대경로를 기준으로 쓴다. Windows PowerShell에서는 필요하면 npm.cmd를 사용한다.
- 기존 설치 위치의 도구 활성화 스크립트를 실행해 팀 버전을 선택한다. IDE는 자동 설치하지 않는다.

## 공통 검사 도구

Prettier 3.9.9, ESLint 10.11.0, @eslint/js 10.0.1, typescript-eslint 8.70.1, globals 17.12.0, TypeScript 6.0.3을 사용한다.
Prettier는 형태를 맞추고 ESLint는 코드 문제를 찾는다. 각 앱·서버의 실제 타입 검사와 테스트는 초기화 때 연결한다.
버전 변경은 호환성 확인과 lockfile 변경을 함께 검토한다. 문서의 버전만 바꾸지 않는다.
