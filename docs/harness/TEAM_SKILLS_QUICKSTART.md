# 팀원용 스킬 시작 가이드

팀원은 **Git으로 받은 저장소 스킬을 바로 사용**하면 됩니다. 아래는 저장소의 6개 스킬을 사용하는 절차입니다.

1. **팀 변경 받기** — 기존 develop→개인 브랜치 동기화 절차로 공유 설정과 스킬을 받습니다. 진행 중인 변경을 먼저 보존합니다.
2. **프로젝트 열기** — 본인 Claude Code 또는 Codex에 로그인하고 PAYSE 저장소를 엽니다. 앱 설치가 필요하면 [Claude 안내](https://code.claude.com/docs/en/setup)를 사용합니다.
3. **스킬 확인하기** — Claude 입력창에서 `/`를 입력해 `flowcast-` 이름을 찾습니다. Codex는 스킬 선택에서 찾습니다. 안 보이면 프로젝트 위치를 확인하고 새 세션을 엽니다.
4. **처음 한 번 읽기 확인** — 아래를 입력합니다. 실제 코드 수정 없이 적용 규칙과 출처가 나오는지 확인합니다.

```text
flowcast-task 스킬을 읽고 적용할 규칙과 스킬 파일 위치만 설명해. 파일은 수정하지 마.
```

5. **작업 시작하기** — 실제 작업 명세를 지정합니다. Claude에서는 아래처럼, Codex에서는 같은 스킬을 선택하거나 이름을 적어 요청합니다.

```text
/flowcast-task <실제 작업 명세 JSON 경로> 이 작업을 진행해.
```

| 필요할 때                      | 선택할 스킬                                     |
| ------------------------------ | ----------------------------------------------- |
| 작업 진행 / 완료 근거 확인     | flowcast-task / flowcast-verify                 |
| Dart 로직 / 위젯 테스트        | flowcast-dart-test / flowcast-widget-test       |
| 앱 흐름·서버 연결 / Flutter UI | flowcast-integration-test / flowcast-flutter-ui |

**Flutter 개발 전:** 저장소에 고정한 SDK 버전을 [공식 설치 안내](https://docs.flutter.dev/install)로 준비하고 `flutter doctor`로 확인합니다. 공통 앱은 `apps/mobile`, SDK는 Flutter 3.47.7 stable / Dart 3.13.5입니다. 공통 앱 파일을 받은 뒤 앱 폴더에서 `flutter pub get --enforce-lockfile`로 의존성을 받습니다. 처음 준비하거나 잠금 파일이 바뀔 때만 수행합니다. 기기 E2E는 팀이 정한 에뮬레이터/실기기도 필요합니다.

이 여섯 스킬에는 별도 npx 실행·플러그인·MCP 설치가 필요 없습니다. 개인 로그인·API 키·개인 경로는 Git에 올리지 않습니다. 유효한 통과 결과는 재사용합니다. 호출되지 않거나 준비가 부족하면 오류와 스킬 출처를 담당자에게 전달합니다.

제품 범위·버전별 우선순위·준비 상태는 [PAYSE 제품 기준](../product-baseline.md)과 해당 기능의 문서를 확인합니다. 팀원은 저장소의 최신 스킬 파일을 사용하며, 과거 스킬 ZIP으로 문서를 덮어쓰거나 새 플러그인을 다시 설치하지 않습니다. 도입 당시의 작업 단계·보류 설명은 [이력](../../apps/api/docs/history/2026-10-22-harness-doc-history.md)에 보존합니다.

Mac의 6·7단계는 [공유된 Mac 안내](MAC_FLUTTER_VSCODE_GUIDE.md)를 따릅니다. 앱을 각자 새로 생성하지 않고 Git으로 같은 pubspec·lockfile·lib/test를 받습니다.
