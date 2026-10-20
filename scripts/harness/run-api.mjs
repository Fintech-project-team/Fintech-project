import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

export const API_GATE_TIMEOUT_MS = 1020000;
const apiRoot = fileURLToPath(new URL('../../apps/api/', import.meta.url));
const modes = {
  compile: ['classes', 'apiDocsCheck'],
  test: ['test'],
  check: ['check', 'bootJar'],
  start: ['bootRun'],
};

/**
 * @created 2026-10-20
 * @description JDK 21과 API 전용 Gradle 빌드 및 기존 Python 더미 검사를 실행한다.
 * @param mode - compile, test, check 또는 start.
 * @param spawn - 실제 또는 테스트용 프로세스 실행 함수.
 * @param output - 출력 수신 함수.
 * @param platform - 실행 OS. 테스트에서는 Windows와 Unix 분기를 확인한다.
 * @returns 0 통과, 1 빌드/검사 실패, 2 도구 부재 또는 잘못된 모드.
 */
export function runApi(mode, spawn = spawnSync, output = console.log, platform = process.platform) {
  if (!Object.hasOwn(modes, mode)) {
    output('BLOCKED: use compile, test, check or start');
    return 2;
  }
  const java = process.env.JAVA_HOME
    ? path.join(process.env.JAVA_HOME, 'bin', platform === 'win32' ? 'java.exe' : 'java')
    : 'java';
  const version = spawn(java, ['-version'], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 10000,
  });
  if (
    version.error ||
    version.status !== 0 ||
    !/\bversion "21(?:[."])/u.test((version.stderr || '') + (version.stdout || ''))
  ) {
    output('BLOCKED: JDK 21 is required; check JAVA_HOME and PATH.');
    return 2;
  }
  const wrapper = path.join(apiRoot, platform === 'win32' ? 'gradlew.bat' : 'gradlew');
  if (!fs.existsSync(wrapper)) {
    output('BLOCKED: API Gradle Wrapper missing');
    return 2;
  }
  // Shell text contains fixed literals only; user input is never interpolated.
  const args = [...modes[mode], '--no-daemon', '--console=plain'];
  const result = spawn(
    platform === 'win32' ? 'cmd.exe' : 'sh',
    platform === 'win32'
      ? ['/d', '/s', '/c', ['gradlew.bat', ...args].join(' ')]
      : ['./gradlew', ...args],
    {
      cwd: apiRoot,
      stdio: 'inherit',
      windowsHide: true,
      timeout: mode === 'start' ? undefined : 840000,
    },
  );
  if (result.error) {
    output(`BLOCKED: ${result.error.message}`);
    return 2;
  }
  if (result.status !== 0) return result.status === null ? 2 : 1;
  if (mode === 'test' || mode === 'check') {
    const python = spawn('python', ['--version'], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 10000,
    });
    const match = /Python (\d+)\.(\d+)/u.exec((python.stdout || '') + (python.stderr || ''));
    if (
      python.error ||
      python.status !== 0 ||
      !match ||
      Number(match[1]) !== 3 ||
      Number(match[2]) < 10
    ) {
      output('BLOCKED: Python 3.10+ is required for the existing synthetic-data tests.');
      return 2;
    }
    const fixtures = spawn(
      'python',
      ['-B', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_fixtures.py'],
      {
        cwd: apiRoot,
        stdio: 'inherit',
        windowsHide: true,
        timeout: 120000,
      },
    );
    if (fixtures.error || fixtures.status === null) return 2;
    if (fixtures.status !== 0) return 1;
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = runApi(process.argv[2]);
}
