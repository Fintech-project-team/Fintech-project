# 공통 개발 도구 기준

2026-09-27 설치 보고서에서 정한 팀 기준을 이어받는다. 이번 구조 패키지에서는 프레임워크 패키지를 설치하거나 호환성 검증을 다시 수행하지 않았다.

| 영역            | 팀 기준                                     | 현재 골격에 포함              |
| --------------- | ------------------------------------------- | ----------------------------- |
| Node / npm      | 24.21.0 / 11.19.0                           | engines·packageManager·.nvmrc |
| 앱              | Expo 57.0.25 / RN 0.86.3 / React 19.2.3     | 폴더만 있음                   |
| Router / TS     | Expo Router 57.0.23 / TypeScript 6.0.3      | 설치 전                       |
| API / 더미 서버 | Fastify 5.12.5                              | 폴더만 있음                   |
| DB              | PostgreSQL 18.6                             | 연결·초기화 전                |
| Android         | JDK 17.0.20.1 / API 36 / Build Tools 36.0.0 | 실기기 검증 후속              |

프레임워크 초기화 담당자는 공식 배포 정보와 Expo 호환 패키지를 다시 확인하고 첫 lockfile을 갱신한다. 버전이 제공되지 않거나 요구조건이 달라졌다면 실패 사실을 공유하고 합의해 갱신한다. 다른 사람이 각각 latest로 프로젝트를 생성하지 않는다.

루트 package-lock.json은 공통 개발 도구와 workspace 연결을 고정한다. 실제 앱·서버 프레임워크 의존성은 아직 포함하지 않는다. 이후 루트에서 npm install을 한 번 수행해 공통 lockfile을 확정하고 팀원은 npm ci를 사용한다.

명령은 저장소 루트 기준 상대경로이며 Windows/macOS 공통이다. Windows PowerShell에서는 필요 시 npm 대신 npm.cmd를 사용한다. 기존 도구 활성화 스크립트는 각자가 설치했던 기준 폴더에서 먼저 실행한다. IDE는 자동 설치하지 않는다.

## 공통 하네스 도구

2026-09-28 npm 배포 메타데이터 확인: Prettier 3.9.9, ESLint 10.11.0, @eslint/js 10.0.1, typescript-eslint 8.70.1, globals 17.12.0. TypeScript는 6.0.3 유지. 최신 TypeScript 7.0.2는 현재 typescript-eslint의 <6.1.0 요구와 맞지 않아 채택하지 않았다. 실제 설치·검사 결과는 배포 안내의 검증 기록을 참조한다.
