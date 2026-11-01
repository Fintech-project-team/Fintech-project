import test from 'node:test';
import assert from 'node:assert/strict';
import { FLUTTER_GATE_TIMEOUT_MS, runFlutterCheck } from '../run-flutter.mjs';

const quiet = () => {};
const prepared = () => true;
const goodSdk = {
  status: 0,
  stdout: JSON.stringify({
    frameworkVersion: '3.47.7',
    channel: 'stable',
    dartSdkVersion: '3.13.5',
  }),
};

test('unsupported commands cannot reach a subprocess', () => {
  assert.equal(
    runFlutterCheck('analyze; echo unwanted', () => assert.fail('must not spawn'), quiet),
    2,
  );
});
test('missing SDK and malformed version output remain blocked', () => {
  assert.equal(
    runFlutterCheck('check', () => ({ error: new Error('not installed') }), quiet),
    2,
  );
  assert.equal(
    runFlutterCheck('check', () => ({ status: 0, stdout: 'broken' }), quiet),
    2,
  );
});
test('different SDK prevents analysis and test from running', () => {
  let calls = 0;
  const code = runFlutterCheck(
    'check',
    () => {
      calls += 1;
      return {
        status: 0,
        stdout: JSON.stringify({
          frameworkVersion: '3.47.8',
          channel: 'stable',
          dartSdkVersion: '3.13.5',
        }),
      };
    },
    quiet,
  );
  assert.equal(code, 2);
  assert.equal(calls, 1);
});
test('format failure stops the sequence and is not reported as success', () => {
  let calls = 0;
  assert.equal(
    runFlutterCheck(
      'check',
      () => (++calls === 1 ? goodSdk : { status: 1, stdout: 'unformatted' }),
      quiet,
      prepared,
    ),
    1,
  );
  assert.equal(calls, 2);
});
test('full sequence runs each fixed command in the app and calculation package, without pub resolution', () => {
  const calls = [];
  const code = runFlutterCheck(
    'check',
    (executable, args, options) => {
      calls.push({ executable, args, options });
      return calls.length === 1 ? goodSdk : { status: 0 };
    },
    quiet,
    prepared,
  );
  assert.equal(code, 0);
  assert.equal(calls.length, 7);
  assert.ok(
    FLUTTER_GATE_TIMEOUT_MS > calls.reduce((total, call) => total + call.options.timeout, 0),
    'parent budget must include all child limits and startup overhead',
  );
  assert.match(calls[0].options.cwd, /apps[\\/]mobile[\\/]?$/u);
  const roots = calls
    .slice(1)
    .map(
      (call) =>
        call.options.cwd.match(/(apps[\\/]mobile|packages[\\/]payse_calculation)[\\/]?$/u)?.[1],
    );
  assert.deepEqual(
    roots.map((r) => r?.replace(/\\/gu, '/')),
    [
      'apps/mobile',
      'packages/payse_calculation',
      'apps/mobile',
      'packages/payse_calculation',
      'apps/mobile',
      'packages/payse_calculation',
    ],
  );
  const lines = calls.map((call) => call.args.join(' ')).join('\n');
  assert.match(lines, /--output=none --set-exit-if-changed/u);
  assert.match(lines, /analyze --no-pub/u);
  assert.match(lines, /test --no-pub/u);
  assert.doesNotMatch(lines, /pub get/u);
});
test('calculation package test failure fails the whole check after the app passed', () => {
  const calls = [];
  const code = runFlutterCheck(
    'check',
    (executable, args, options) => {
      calls.push(options.cwd);
      if (calls.length === 1) return goodSdk;
      return calls.length === 7 ? { status: 1, stdout: 'calc test failed' } : { status: 0 };
    },
    quiet,
    prepared,
  );
  assert.equal(code, 1);
  assert.match(calls[6], /packages[\\/]payse_calculation[\\/]?$/u);
});
test('single mode stops at the first failing root', () => {
  const calls = [];
  const code = runFlutterCheck(
    'analyze',
    (executable, args, options) => {
      calls.push(options.cwd);
      return calls.length === 1 ? goodSdk : { status: 1 };
    },
    quiet,
    prepared,
  );
  assert.equal(code, 1);
  assert.equal(calls.length, 2);
  assert.match(calls[1], /apps[\\/]mobile[\\/]?$/u);
});
test('unprepared calculation package is blocked before any check runs', () => {
  let calls = 0;
  const seen = [];
  const code = runFlutterCheck(
    'check',
    () => {
      calls += 1;
      return goodSdk;
    },
    (line) => seen.push(line),
    (file) => {
      seen.push(file);
      return false;
    },
  );
  assert.equal(code, 2);
  assert.equal(calls, 1);
  assert.ok(
    seen.some((line) =>
      /packages[\\/]payse_calculation[\\/]\.dart_tool[\\/]package_config\.json$/u.test(line),
    ),
  );
  assert.ok(
    seen.some((line) => /^BLOCKED: packages\/payse_calculation is not prepared/u.test(line)),
  );
});

test('a 130-second test fits the test budget without extending format or analysis', () => {
  const calls = [];
  const code = runFlutterCheck(
    'check',
    (executable, args, options) => {
      calls.push(options);
      if (calls.length === 1) return goodSdk;
      const duration = calls.length >= 6 ? 130000 : 0;
      return duration < options.timeout
        ? { status: 0 }
        : { error: Object.assign(new Error('spawnSync flutter ETIMEDOUT'), { code: 'ETIMEDOUT' }) };
    },
    quiet,
    prepared,
  );
  assert.equal(code, 0);
  assert.deepEqual(
    calls.slice(0, 5).map((call) => call.timeout),
    [90000, 90000, 90000, 90000, 90000],
  );
  assert.deepEqual(
    calls.slice(5).map((call) => call.timeout),
    [180000, 180000],
  );
});

test('app and calculation timeouts remain blocked and identify the limit and workspace', () => {
  for (const [stopAt, workspace] of [
    [6, 'apps/mobile'],
    [7, 'packages/payse_calculation'],
  ]) {
    let calls = 0;
    const output = [];
    const code = runFlutterCheck(
      'check',
      () => {
        calls += 1;
        if (calls === 1) return goodSdk;
        if (calls === stopAt) {
          return {
            error: Object.assign(new Error('spawnSync flutter ETIMEDOUT'), { code: 'ETIMEDOUT' }),
          };
        }
        return { status: 0 };
      },
      (line) => output.push(line),
      prepared,
    );
    assert.equal(code, 2);
    assert.equal(calls, stopAt);
    assert.ok(output.some((line) => line.includes(`BLOCKED: test (${workspace}): exceeded 180s`)));
  }
});

test('an app test assertion failure stops before calculation tests', () => {
  let calls = 0;
  const output = [];
  const code = runFlutterCheck(
    'test',
    () => (++calls === 1 ? goodSdk : { status: 1, stdout: 'Expected: true; Actual: false' }),
    (line) => output.push(line),
    prepared,
  );
  assert.equal(code, 1);
  assert.equal(calls, 2);
  assert.ok(output.includes('FAIL: Flutter test (apps/mobile), exit 1'));
});
