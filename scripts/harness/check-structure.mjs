import fs from 'node:fs';
import path from 'node:path';
const root = process.cwd();
const problems = [];
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const a = read('AGENTS.md');
const b = read('CLAUDE.md');
if (a !== b) problems.push('AGENTS.md and CLAUDE.md must be identical');
if (a.trimEnd().split(/\r?\n/u).length > 30) problems.push('Core harness must be at most 30 lines');
for (const p of [
  'docs/harness/GATE_MATRIX.md',
  'docs/harness/CODE_SPEC.md',
  'scripts/harness/policy.json',
  '.prettierrc.json',
  'eslint.config.mjs',
  'package-lock.json',
]) {
  if (!fs.existsSync(p)) problems.push(`Missing ${p}`);
}
const manifest = JSON.parse(read('package.json'));
const lock = JSON.parse(read('package-lock.json'));
if (!manifest.private || manifest.packageManager !== 'npm@11.19.0')
  problems.push('Root workspace/toolchain mismatch');
for (const area of [
  'apps/mobile',
  'apps/api',
  'apps/mock-bank',
  'packages/contracts',
  'packages/finance-core',
]) {
  const m = JSON.parse(read(area + '/package.json'));
  if (!m.private || !lock.packages[area])
    problems.push(`Workspace not private or not locked: ${area}`);
  for (const name of ['package-lock.json', 'yarn.lock', 'pnpm-lock.yaml'])
    if (fs.existsSync(path.join(area, name))) problems.push(`Nested lockfile: ${area}/${name}`);
}
if (problems.length) {
  console.error(problems.join('\n'));
  process.exitCode = 1;
} else
  console.log(
    'PASS: identical core harness <=30 lines, shared configs and five locked workspaces. Product build not checked.',
  );
