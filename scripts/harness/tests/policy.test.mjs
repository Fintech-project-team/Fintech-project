import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { relativePath, violations, selectGates, references } from '../lib.mjs';
import { inspectCodeSpec } from '../code-spec.mjs';
const policy = JSON.parse(fs.readFileSync(new URL('../policy.json', import.meta.url), 'utf8'));
const task = {
  role: 'cashflow',
  allowedPaths: ['apps/mobile/src/features/spending/'],
  readBefore: [],
};
test('role and task paths are an intersection, other area reads do not grant write scope', () => {
  assert.deepEqual(
    violations(
      ['apps/mobile/src/features/spending/Screen.tsx'],
      task,
      'docs/tasks/FC-1.json',
      policy,
    ),
    [],
  );
  assert.equal(
    violations(
      ['apps/mobile/src/features/allocation/Screen.tsx'],
      { ...task, allowedPaths: ['apps/mobile/'] },
      'docs/tasks/FC-1.json',
      policy,
    ).length,
    1,
  );
});
test('shared manifests cannot be edited by workspace owner', () => {
  assert.equal(
    violations(
      ['apps/api/package.json'],
      { role: 'data', allowedPaths: ['apps/api/'] },
      'docs/tasks/FC-1.json',
      policy,
    ).length,
    1,
  );
});
test('own task record is allowed, another task record is not', () => {
  assert.deepEqual(violations(['docs/tasks/FC-1.json'], task, 'docs/tasks/FC-1.json', policy), []);
  assert.equal(
    violations(['docs/tasks/FC-2.json'], task, 'docs/tasks/FC-1.json', policy).length,
    1,
  );
});
test('path prefixes cannot accidentally include sibling directories', () => {
  assert.equal(
    violations(['apps/mobile/src/features/spending-extra/x.ts'], task, 'docs/tasks/x.json', policy)
      .length,
    1,
  );
});
test('unsafe and wildcard paths are rejected', () => {
  for (const p of ['../a', '/tmp/a', 'C:/a', 'apps\\a', 'apps/../a', 'apps/*', ''])
    assert.throws(() => relativePath(p));
});
test('contracts changes select all consumers and finance selects mobile', () => {
  assert.equal(selectGates(['packages/contracts/src/x.ts'], policy, true).length, 5);
  assert.deepEqual(
    selectGates(['packages/finance-core/src/x.ts'], policy, true).map((x) => x.name),
    ['mobile', 'finance'],
  );
});
test('missing product implementation does not require a fake product test for docs', () => {
  assert.equal(selectGates(['docs/mvp-scope.md'], policy, false).length, 0);
});
test('fixtures and migration files select their owning product gate', () => {
  assert.deepEqual(
    selectGates(['apps/mock-bank/fixtures/normal.json'], policy, false).map((x) => x.name),
    ['mockBank'],
  );
  assert.deepEqual(
    selectGates(['apps/api/src/schema.prisma'], policy, true).map((x) => x.name),
    ['api'],
  );
});
test('reading list is derived before a task has changes', () => {
  assert.ok(references(task, [], policy).includes('docs/contracts.md'));
  assert.ok(references(task, [], policy).includes('docs/harness/CODE_SPEC.md'));
});
test('missing function docs are caught and callbacks are not demanded', () => {
  assert.equal(
    inspectCodeSpec(
      'packages/finance-core/src/a.ts',
      'export function sum(a: number) { return a; }',
    ).length,
    1,
  );
  assert.equal(inspectCodeSpec('apps/api/src/a.ts', '[1].map(x => x + 1);').length, 0);
});
test('complete function docs pass and undocumented params fail', () => {
  const doc =
    '/**\n * @created 2026-09-28\n * @description 금액을 전달한다.\n * @param amount - 원화 정수.\n * @returns 같은 금액.\n */\n';
  assert.deepEqual(
    inspectCodeSpec(
      'packages/finance-core/src/a.ts',
      doc + 'export function pass(amount: number) { return amount; }',
    ),
    [],
  );
  assert.equal(
    inspectCodeSpec(
      'packages/finance-core/src/a.ts',
      doc + 'export function pass(other: number) { return other; }',
    ).length,
    1,
  );
});
test('class, method and named arrow declarations need their own specifications', () => {
  assert.equal(
    inspectCodeSpec('apps/api/src/a.ts', 'export class Store { read(key: string) { return key; } }')
      .length,
    2,
  );
  assert.equal(
    inspectCodeSpec('apps/api/src/a.ts', 'export const read = (key: string) => key;').length,
    1,
  );
});
test('parameter names without meaningful documentation do not pass', () => {
  const doc =
    '/**\n * @created 2026-09-28\n * @description 입력을 전달한다.\n * @param amount\n * @returns 같은 금액.\n */\n';
  assert.equal(
    inspectCodeSpec(
      'packages/finance-core/src/a.ts',
      doc + 'export function pass(amount: number) { return amount; }',
    ).length,
    1,
  );
});
