import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../../', import.meta.url));
const mobile = path.join(root, 'apps/mobile');
const expected = JSON.parse(fs.readFileSync(path.join(mobile, 'flutter-toolchain.json'), 'utf8'));
const commands = {
  format: ['dart', ['format', '--output=none', '--set-exit-if-changed', 'lib', 'test']],
  analyze: ['flutter', ['--no-version-check', 'analyze', '--no-pub']],
  test: ['flutter', ['--no-version-check', 'test', '--no-pub']],
};

/**
 * @created 2026-10-19
 * @description 고정된 Flutter 검사만 실행하고 SDK 불일치·실패를 호출자에게 전달한다.
 * @param mode - sdk, format, analyze, test 또는 check.
 * @param spawn - 실제 실행 또는 검사에 주입할 프로세스 실행 함수.
 * @param output - 실행 출력의 수신 함수.
 * @returns 0은 통과, 1은 검사 실패, 2는 준비 부족 또는 잘못된 모드.
 */
export function runFlutterCheck(mode, spawn = spawnSync, output = console.log) {
  if (!['sdk', 'check', ...Object.keys(commands)].includes(mode)) {
    output('BLOCKED: use sdk, format, analyze, test or check');
    return 2;
  }
  const invoke = (executable, args) => {
    // Every argument is a fixed literal above; user input is never inserted into a shell command.
    const windows = process.platform === 'win32';
    return spawn(
      windows ? 'cmd.exe' : executable,
      windows ? ['/d', '/s', '/c', [executable, ...args].join(' ')] : args,
      {
        cwd: mobile,
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
  for (const name of mode === 'check' ? Object.keys(commands) : [mode]) {
    const [executable, args] = commands[name];
    const result = invoke(executable, args);
    if (result.stdout) output(result.stdout);
    if (result.stderr) output(result.stderr);
    if (result.error) {
      output(`BLOCKED: ${name}: ${result.error.message}`);
      return 2;
    }
    if (result.status !== 0) {
      output(`FAIL: Flutter ${name}, exit ${result.status}`);
      return 1;
    }
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = runFlutterCheck(process.argv[2]);
}
