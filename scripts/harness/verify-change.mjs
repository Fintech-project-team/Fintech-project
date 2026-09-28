import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  assertNoSymlink,
  relativePath,
  git,
  gitFiles,
  violations,
  selectGates,
  references,
  digest,
} from './lib.mjs';
import { inspectCodeSpec } from './code-spec.mjs';

const root = process.cwd();
const report = {
  runId: crypto.randomUUID(),
  startedAt: new Date().toISOString(),
  status: 'BLOCKED',
  checks: [],
  android: 'NOT_RUN',
};
const args = process.argv.slice(2);
let exitCode = 2;

/**
 * @created 2026-09-28
 * @description 로컬 검사 명령을 제한 시간 내 실행한다.
 * @param name - 검사 이름.
 * @param script - Node 실행 파일.
 * @param argv - 인자.
 * @returns 검사 성공 여부.
 */
function run(name, script, argv = []) {
  const r = spawnSync(process.execPath, [script, ...argv], {
    cwd: root,
    encoding: 'utf8',
    timeout: 120000,
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.stdout) process.stdout.write(r.stdout);
  if (r.stderr) process.stderr.write(r.stderr);
  report.checks.push({
    name,
    status: r.error ? 'BLOCKED' : r.status === 0 ? 'PASS' : 'FAIL',
    exitCode: r.status,
  });
  return !r.error && r.status === 0;
}

try {
  if (
    args.some((a, i) => !['--task', '--plan', '--format'].includes(a) && args[i - 1] !== '--task')
  )
    throw new Error('Unknown argument');
  if (args.includes('--plan') && args.includes('--format'))
    throw new Error('Choose either --plan or --format');
  const taskPath = relativePath(args[args.indexOf('--task') + 1]);
  if (
    !args.includes('--task') ||
    !/^docs\/tasks\/[^/]+\.json$/u.test(taskPath) ||
    taskPath.endsWith('/TEMPLATE.json')
  )
    throw new Error('Use a real task file in docs/tasks');
  assertNoSymlink(root, taskPath);
  const task = JSON.parse(fs.readFileSync(taskPath, 'utf8'));
  if (
    !/^[0-9a-f]{40}$/u.test(task.baseCommit) ||
    !task.branch ||
    !task.id ||
    !task.acceptance?.length ||
    !Array.isArray(task.readBefore)
  )
    throw new Error('Complete baseCommit, branch, id, acceptance and readBefore');
  if (
    path.resolve(git(root, ['rev-parse', '--show-toplevel']).trim()).toLowerCase() !==
    root.toLowerCase()
  )
    throw new Error('Run from the actual repository root');
  if (git(root, ['branch', '--show-current']).trim() !== task.branch)
    throw new Error('Current branch differs from task.branch');
  git(root, ['cat-file', '-e', task.baseCommit + '^{commit}']);
  git(root, ['merge-base', '--is-ancestor', task.baseCommit, 'HEAD']);
  const policy = JSON.parse(fs.readFileSync('scripts/harness/policy.json', 'utf8'));
  const { changed, sources } = gitFiles(root, task.baseCommit);
  changed.forEach((p) => assertNoSymlink(root, p));
  const outside = violations(changed, task, taskPath, policy);
  Object.assign(report, {
    task: taskPath,
    role: task.role,
    baseCommit: task.baseCommit,
    changed,
    outsideScope: outside,
  });
  if (outside.length) {
    report.status = 'FAIL';
    exitCode = 1;
    throw new Error('Out of scope: ' + outside.join(', '));
  }
  const refs = references(task, changed, policy);
  for (const ref of refs) {
    assertNoSymlink(root, ref);
    if (!fs.existsSync(ref)) throw new Error('Missing core reference: ' + ref);
  }
  const hasProduct = sources.some((p) => /^(apps|packages)\/.*\.[cm]?[jt]sx?$/u.test(p));
  const gates = selectGates(changed, policy, hasProduct);
  Object.assign(report, {
    references: refs,
    productGates: gates.map((g) => g.name),
    sourceDigest: digest(root, sources),
  });
  console.log(
    JSON.stringify(
      {
        changed,
        requiredReading: refs,
        requiredChecks: [
          'structure',
          'format',
          'lint',
          'code-spec',
          'harness-tests',
          ...gates.map((g) => g.name),
        ],
      },
      null,
      2,
    ),
  );
  if (args.includes('--plan')) report.status = 'PLANNED';
  else if (args.includes('--format')) {
    const prettier = await import('prettier');
    for (const file of changed) {
      if (!fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
      const info = await prettier.getFileInfo(file, { ignorePath: '.prettierignore' });
      if (info.ignored || !info.inferredParser) continue;
      const config = await prettier.resolveConfig(file);
      fs.writeFileSync(
        file,
        await prettier.format(fs.readFileSync(file, 'utf8'), { ...config, filepath: file }),
      );
    }
    report.status = 'FORMATTED';
    console.log('Formatting complete. Full verification must still run.');
  } else {
    const needed = ['node_modules/prettier/bin/prettier.cjs', 'node_modules/eslint/bin/eslint.js'];
    for (const p of needed) if (!fs.existsSync(p)) throw new Error('Run npm ci first: ' + p);
    const checks = [
      run('structure', 'scripts/harness/check-structure.mjs'),
      run('format', 'node_modules/prettier/bin/prettier.cjs', ['.', '--check']),
      run('lint', 'node_modules/eslint/bin/eslint.js', ['.', '--max-warnings=0']),
      run('harness-tests', 'scripts/harness/run-tests.mjs'),
    ];
    const specErrors = changed
      .filter((p) => fs.existsSync(p) && fs.statSync(p).isFile())
      .flatMap((p) => inspectCodeSpec(p, fs.readFileSync(p, 'utf8')));
    report.checks.push({
      name: 'code-spec',
      status: specErrors.length ? 'FAIL' : 'PASS',
      errors: specErrors,
    });
    checks.push(specErrors.length === 0);
    let blocked = false;
    for (const gate of gates) {
      const pkg = JSON.parse(fs.readFileSync(gate.workspace + '/package.json', 'utf8'));
      for (const name of gate.scripts) {
        if (!pkg.scripts?.[name]) {
          report.checks.push({
            name: gate.name + ':' + name,
            status: 'BLOCKED',
            reason: 'Missing actual product check script',
          });
          blocked = true;
          continue;
        }
        const npmCli =
          process.env.npm_execpath ||
          path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js');
        if (!fs.existsSync(npmCli)) {
          report.checks.push({
            name: gate.name + ':' + name,
            status: 'BLOCKED',
            reason: 'npm CLI unavailable',
          });
          blocked = true;
          continue;
        }
        checks.push(
          run(gate.name + ':' + name, npmCli, ['run', name, '--workspace', gate.workspace]),
        );
      }
    }
    if (!gates.length) report.checks.push({ name: 'product', status: 'NOT_APPLICABLE' });
    const after = gitFiles(root, task.baseCommit);
    const unchanged = report.sourceDigest === digest(root, after.sources);
    report.checks.push({ name: 'source-unchanged', status: unchanged ? 'PASS' : 'FAIL' });
    blocked ||= report.checks.some((c) => c.status === 'BLOCKED');
    report.status =
      checks.every(Boolean) && unchanged
        ? blocked
          ? 'BLOCKED'
          : 'PASS'
        : report.checks.some((c) => c.status === 'FAIL')
          ? 'FAIL'
          : 'BLOCKED';
    exitCode = report.status === 'PASS' ? 0 : report.status === 'FAIL' ? 1 : 2;
  }
} catch (error) {
  report.reason = error.message;
  console.error(error.message);
}
report.finishedAt = new Date().toISOString();
fs.mkdirSync('.harness/reports', { recursive: true });
fs.writeFileSync(
  '.harness/reports/' + report.runId + '.json',
  JSON.stringify(report, null, 2) + '\n',
);
console.log(`Result: ${report.status}; report: .harness/reports/${report.runId}.json`);
process.exitCode = exitCode;
