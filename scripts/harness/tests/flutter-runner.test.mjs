import test from 'node:test';
import assert from 'node:assert/strict';
import { runFlutterCheck } from '../run-flutter.mjs';

const quiet = () => {};
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
    ),
    1,
  );
  assert.equal(calls, 2);
});
test('full sequence uses the app root and read-only formatting, without pub resolution', () => {
  const calls = [];
  const code = runFlutterCheck(
    'check',
    (executable, args, options) => {
      calls.push({ executable, args, options });
      return calls.length === 1 ? goodSdk : { status: 0 };
    },
    quiet,
  );
  assert.equal(code, 0);
  assert.equal(calls.length, 4);
  assert.ok(calls.every((call) => /apps[\\/]mobile[\\/]?$/u.test(call.options.cwd)));
  const lines = calls.map((call) => call.args.join(' ')).join('\n');
  assert.match(lines, /--output=none --set-exit-if-changed/u);
  assert.match(lines, /analyze --no-pub/u);
  assert.match(lines, /test --no-pub/u);
  assert.doesNotMatch(lines, /pub get/u);
});
