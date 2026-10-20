import test from 'node:test';
import assert from 'node:assert/strict';
import { runApi, API_GATE_TIMEOUT_MS } from '../run-api.mjs';

test('unknown command and wrong JDK are blocked', () => {
  assert.equal(
    runApi(
      'test; echo unsafe',
      () => {
        throw Error('must not spawn');
      },
      () => {},
    ),
    2,
  );
  assert.equal(
    runApi(
      'test',
      () => ({ status: 0, stderr: 'openjdk version "17.0.1"' }),
      () => {},
    ),
    2,
  );
  assert.equal(
    runApi(
      'test',
      () => ({ error: Error('missing') }),
      () => {},
    ),
    2,
  );
});
test('Windows and Unix fixed commands propagate Gradle failure', () => {
  for (const platform of ['win32', 'linux']) {
    const calls = [];
    const spawn = (...args) => {
      calls.push(args);
      return calls.length === 1
        ? { status: 0, stderr: 'openjdk version "21.0.12.1"' }
        : { status: 1 };
    };
    assert.equal(
      runApi('test', spawn, () => {}, platform),
      1,
    );
    assert.equal(calls[1][0], platform === 'win32' ? 'cmd.exe' : 'sh');
    assert.equal(calls[1][2].timeout, 840000);
  }
});
test('successful build, timeout and signal termination remain distinct', () => {
  for (const [result, expected] of [
    [{ status: 0 }, 0],
    [{ error: Error('timeout') }, 2],
    [{ status: null }, 2],
  ]) {
    let count = 0;
    assert.equal(
      runApi(
        'compile',
        () => (++count === 1 ? { status: 0, stderr: 'openjdk version "21"' } : result),
        () => {},
      ),
      expected,
    );
  }
});

test('API tests require the existing Python fixture tests to pass', () => {
  for (const [fixtureResult, expected] of [
    [{ status: 0 }, 0],
    [{ status: 1 }, 1],
    [{ error: Error('timeout') }, 2],
  ]) {
    const responses = [
      { status: 0, stderr: 'openjdk version "21"' },
      { status: 0 },
      { status: 0, stdout: 'Python 3.12.0' },
      fixtureResult,
    ];
    const calls = [];
    assert.equal(
      runApi(
        'test',
        (...args) => {
          calls.push(args);
          return responses.shift();
        },
        () => {},
      ),
      expected,
    );
    const maximumInternalWait = calls.reduce((sum, call) => sum + (call[2].timeout || 0), 0);
    assert.ok(API_GATE_TIMEOUT_MS > maximumInternalWait);
    assert.equal(calls[0][2].timeout, 10000);
    assert.equal(calls[2][2].timeout, 10000);
    assert.deepEqual(calls[3][1], [
      '-B',
      '-m',
      'unittest',
      'discover',
      '-s',
      'tests',
      '-p',
      'test_fixtures.py',
    ]);
  }
});

test('missing Python does not become a successful API test', () => {
  const responses = [
    { status: 0, stderr: 'openjdk version "21"' },
    { status: 0 },
    { error: Error('missing') },
  ];
  assert.equal(
    runApi(
      'check',
      () => responses.shift(),
      () => {},
    ),
    2,
  );
});
