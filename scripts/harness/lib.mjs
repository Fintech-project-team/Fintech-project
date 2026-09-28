import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

/**
 * @created 2026-09-28
 * @description 저장소 상대경로를 검증한다.
 * @param value - 입력 경로.
 * @returns 정규화 경로.
 */
export function relativePath(value) {
  if (
    typeof value !== 'string' ||
    !value ||
    /[\\:*?\0]/u.test(value) ||
    value.startsWith('/') ||
    value.split('/').some((x) => x === '..' || x === '.')
  )
    throw new Error(`Invalid relative path: ${value}`);
  return value;
}

/**
 * @created 2026-09-28
 * @description 경로가 지정 파일 또는 폴더에 속하는지 판정한다.
 * @param file - 파일 경로.
 * @param entry - 허용 경로.
 * @returns 일치 여부.
 */
export function matches(file, entry) {
  return entry === '' || (entry.endsWith('/') ? file.startsWith(entry) : file === entry);
}

/**
 * @created 2026-09-28
 * @description symlink로 저장소 경계가 우회되는지 검사한다.
 * @param root - 저장소.
 * @param file - 상대경로.
 * @returns void. 위반 시 예외.
 */
export function assertNoSymlink(root, file) {
  let current = root;
  for (const part of relativePath(file).split('/').filter(Boolean)) {
    current = path.join(current, part);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink())
      throw new Error(`Symlink not allowed: ${file}`);
  }
}

/**
 * @created 2026-09-28
 * @description 읽기 전용 Git 조회를 실행한다.
 * @param root - 저장소.
 * @param args - Git 인자.
 * @returns 표준 출력.
 */
export function git(root, args) {
  const result = spawnSync('git', args, {
    cwd: root,
    encoding: 'utf8',
    timeout: 20000,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.error || result.status !== 0)
    throw new Error(`Git inspection failed: ${result.error?.message || result.stderr.trim()}`);
  return result.stdout;
}

/**
 * @created 2026-09-28
 * @description 현재 소스 목록과 변경 목록을 읽는다.
 * @param root - 저장소.
 * @param base - 기준 SHA.
 * @returns changed와 sources 경로 배열.
 */
export function gitFiles(root, base) {
  const split = (text) => text.split('\0').filter(Boolean);
  const untracked = split(git(root, ['ls-files', '--others', '--exclude-standard', '-z']));
  const changed = [
    ...new Set([
      ...split(git(root, ['diff', '--name-only', '--no-renames', '-z', base, '--'])),
      ...untracked,
    ]),
  ].sort();
  const sources = [...new Set([...split(git(root, ['ls-files', '-z'])), ...untracked])].sort();
  return { changed, sources };
}

/**
 * @created 2026-09-28
 * @description 작업 경로와 역할의 교집합을 검사한다.
 * @param files - 변경 경로.
 * @param task - 작업 명세.
 * @param taskPath - 명세 경로.
 * @param policy - 역할 정책.
 * @returns 범위 밖 경로 배열.
 */
export function violations(files, task, taskPath, policy) {
  if (
    !policy.roles[task.role] ||
    !Array.isArray(task.allowedPaths) ||
    task.allowedPaths.length === 0
  )
    throw new Error('Missing role or allowedPaths');
  task.allowedPaths.forEach(relativePath);
  return files.filter((file) => {
    relativePath(file);
    if (file === taskPath) return false;
    const isShared =
      policy.shared.some((p) => matches(file, p)) ||
      /(^|\/)(package(-lock)?\.json|[^/]*lock[^/]*|[^/]*config\.[^/]+)$/u.test(file) ||
      (file.startsWith('docs/') && !file.startsWith('docs/demo/'));
    return (
      !task.allowedPaths.some((p) => matches(file, p)) ||
      !policy.roles[task.role].some((p) => matches(file, p)) ||
      (isShared && task.role !== 'integration')
    );
  });
}

/**
 * @created 2026-09-28
 * @description 코드 변경에 필요한 제품 검사를 선택한다.
 * @param files - 변경 파일.
 * @param policy - 검사 정책.
 * @param productPresent - 기존 제품 코드 여부.
 * @returns workspace 검사 목록.
 */
export function selectGates(files, policy, productPresent) {
  const code = files.filter((p) => /^(apps|packages)\//u.test(p) && !/\.md$/u.test(p));
  const shared = files.some(
    (p) =>
      p.startsWith('scripts/') ||
      p.startsWith('.github/') ||
      /^[^/]*(?:config|package)[^/]*$/u.test(p),
  );
  const all = (shared && productPresent) || code.some((p) => p.startsWith('packages/contracts/'));
  return Object.entries(policy.productGates)
    .filter(
      ([name, gate]) =>
        all ||
        gate.prefixes.some((p) => code.some((f) => f.startsWith(p))) ||
        (name === 'mobile' && code.some((p) => p.startsWith('packages/finance-core/'))),
    )
    .map(([name, gate]) => ({ name, ...gate }));
}

/**
 * @created 2026-09-28
 * @description 작업별 핵심 참조를 선택한다.
 * @param task - 작업 명세.
 * @param files - 변경 파일.
 * @param policy - 참조 정책.
 * @returns 반드시 읽을 경로 배열.
 */
export function references(task, files, policy) {
  const refs = new Set([...policy.mandatoryReferences, ...(task.readBefore || [])]);
  const paths = [...files, ...task.allowedPaths];
  if (paths.some((p) => /^(apps|packages)\//u.test(p))) {
    refs.add('docs/architecture.md');
    refs.add('docs/contracts.md');
  }
  if (paths.some((p) => p.startsWith('packages/'))) refs.add('docs/calculation-rules.md');
  if (task.role === 'integration') {
    refs.add('docs/development-workflow.md');
    refs.add('docs/toolchain.md');
  }
  return [...refs];
}

/**
 * @created 2026-09-28
 * @description 검증 전후 소스 지문을 계산한다.
 * @param root - 저장소.
 * @param files - 소스 목록.
 * @returns SHA256 문자열.
 */
export function digest(root, files) {
  const hash = crypto.createHash('sha256');
  for (const file of files) {
    assertNoSymlink(root, file);
    const full = path.join(root, file);
    hash.update(file + '\0');
    if (fs.existsSync(full) && fs.statSync(full).isFile()) hash.update(fs.readFileSync(full));
    else hash.update('DELETED');
  }
  return hash.digest('hex');
}
