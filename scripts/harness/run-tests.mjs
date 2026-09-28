import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
const files = fs
  .readdirSync('scripts/harness/tests')
  .filter((p) => p.endsWith('.test.mjs'))
  .map((p) => 'scripts/harness/tests/' + p);
if (!files.length) throw new Error('No harness tests');
const result = spawnSync(process.execPath, ['--test', ...files], {
  stdio: 'inherit',
  windowsHide: true,
  timeout: 120000,
});
process.exitCode = result.status ?? 2;
