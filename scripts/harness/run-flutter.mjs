import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../../', import.meta.url));
const mobile = path.join(root, 'apps/mobile');
const calculation = path.join(root, 'packages/payse_calculation');
const workspaces = [mobile, calculation];
const expected = JSON.parse(fs.readFileSync(path.join(mobile, 'flutter-toolchain.json'), 'utf8'));
const commands = {
  format: ['dart', ['format', '--output=none', '--set-exit-if-changed', 'lib', 'test']],
  analyze: ['flutter', ['--no-version-check', 'analyze', '--no-pub']],
  test: ['flutter', ['--no-version-check', 'test', '--no-pub']],
};

/**
 * @created 2026-10-19
 * @description 앱과 계산 패키지에서 고정된 Flutter 검사만 실행하고 SDK 불일치·준비 누락·실패를 호출자에게 전달한다.
 * @param mode - sdk, format, analyze, test 또는 check.
 * @param spawn - 실제 실행 또는 검사에 주입할 프로세스 실행 함수.
 * @param output - 실행 출력의 수신 함수.
 * @param exists - 준비 파일 존재 확인 함수. 계산 패키지의 pub get 누락을 실패와 구분한다.
 * @returns 0은 통과, 1은 검사 실패, 2는 준비 부족 또는 잘못된 모드.
 */
export function runFlutterCheck(
  mode,
  spawn = spawnSync,
  output = console.log,
  exists = fs.existsSync,
) {
  if (!['sdk', 'check', ...Object.keys(commands)].includes(mode)) {
    output('BLOCKED: use sdk, format, analyze, test or check');
    return 2;
  }
  const invoke = (executable, args, cwd = mobile) => {
    // Every argument is a fixed literal above; user input is never inserted into a shell command.
    const windows = process.platform === 'win32';
    return spawn(
      windows ? 'cmd.exe' : executable,
      windows ? ['/d', '/s', '/c', [executable, ...args].join(' ')] : args,
      {
        cwd,
        encoding: 'utf8',
        windowsHide: true,
        timeout: 90000,
        maxBuffer: 8 * 1024 * 1024,
        env: { ...process.env, FLUTTER_SUPPRESS_ANALYTICS: 'true' },
      },
    );
  };
  const sdk = invoke('flutter', ['--no-version-check', '--version', '--machine']);
  if (sdk.error || sdk.status !== 0) {
    output(`BLOCKED: Flutter SDK unavailable: ${sdk.error?.message || sdk.stderr || sdk.stdout}`);
    return 2;
  }
  let actual;
  try {
    actual = JSON.parse(sdk.stdout);
  } catch {
    output('BLOCKED: Flutter version output is not valid JSON');
    return 2;
  }
  if (
    actual.frameworkVersion !== expected.flutter ||
    actual.channel !== expected.channel ||
    actual.dartSdkVersion !== expected.dart
  ) {
    output(
      `BLOCKED: expected Flutter ${expected.flutter} ${expected.channel} / Dart ${expected.dart}; received ${actual.frameworkVersion} ${actual.channel} / ${actual.dartSdkVersion}`,
    );
    return 2;
  }
  output(`PASS: Flutter ${expected.flutter} / Dart ${expected.dart}`);
  if (mode === 'sdk') return 0;
  if (!exists(path.join(calculation, '.dart_tool', 'package_config.json'))) {
    output(
      'BLOCKED: packages/payse_calculation is not prepared; run flutter pub get --enforce-lockfile there',
    );
    return 2;
  }
  for (const name of mode === 'check' ? Object.keys(commands) : [mode]) {
    const [executable, args] = commands[name];
    for (const cwd of workspaces) {
      const label = path.relative(root, cwd).split(path.sep).join('/');
      const result = invoke(executable, args, cwd);
      if (result.stdout) output(result.stdout);
      if (result.stderr) output(result.stderr);
      if (result.error) {
        output(`BLOCKED: ${name} (${label}): ${result.error.message}`);
        return 2;
      }
      if (result.status !== 0) {
        output(`FAIL: Flutter ${name} (${label}), exit ${result.status}`);
        return 1;
      }
    }
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = runFlutterCheck(process.argv[2]);
}
