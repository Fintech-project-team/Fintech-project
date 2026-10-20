import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { isProductSource, selectGates, references } from '../lib.mjs';
const policy = JSON.parse(fs.readFileSync(new URL('../policy.json', import.meta.url), 'utf8'));

test('API rules are mandatory for API work without imposing them on Flutter', () => {
  assert.ok(
    references({ allowedPaths: ['apps/api/'], readBefore: [] }, [], policy).includes(
      'apps/api/src/AGENTS.md',
    ),
  );
  assert.equal(
    references({ allowedPaths: ['apps/mobile/'], readBefore: [] }, [], policy).includes(
      'apps/api/src/AGENTS.md',
    ),
    false,
  );
});

test('Java source participates in common-change consumer detection', () => {
  assert.equal(isProductSource('apps/api/src/main/java/com/payse/App.java'), true);
  assert.equal(isProductSource('apps/api/docs/App.md'), false);
  assert.equal(isProductSource('scripts/harness/App.java'), false);
  assert.equal(isProductSource('apps/mobile/lib/main.dart'), true);
  assert.deepEqual(
    selectGates(['scripts/harness/lib.mjs'], policy, true, ['mobile', 'api']).map((g) => g.name),
    ['mobile', 'api'],
  );
});
test('Flutter-only edits do not demand Java or API checks', () => {
  for (const file of [
    'apps/mobile/lib/features/overview/view.dart',
    'apps/mobile/pubspec.yaml',
    'apps/mobile/docs/design.md',
  ]) {
    assert.deepEqual(
      selectGates([file], policy, true, ['mobile', 'api']).map((g) => g.name),
      file.endsWith('.md') ? [] : ['mobile'],
    );
  }
});
test('API-only edits do not demand Flutter checks', () => {
  assert.deepEqual(
    selectGates(['apps/api/src/main/java/com/payse/App.java'], policy, true, ['mobile', 'api']).map(
      (g) => g.name,
    ),
    ['api'],
  );
});
