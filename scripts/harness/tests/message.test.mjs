import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { validateTitle } from '../check-message.mjs';

test('기능·설정·통합·릴리스 제목과 확장 scope를 허용한다', () => {
  for (const title of [
    'feat(spending): 소비 전후 가용금액 비교 추가',
    'chore(harness): 공통 하네스와 개발 구조 추가',
    'chore(repo): sunghyun-dev 변경을 develop에 통합',
    'chore(repo): v0.1.0 출시',
    'feat(future-chat)!: 응답 계약 변경',
  ])
    assert.deepEqual(validateTitle(title), []);
});

test('잘못된 형식과 빈 제목, 여러 줄, 긴 제목을 거부한다', () => {
  for (const title of [
    undefined,
    '',
    'Merge pull request #1',
    'fix: 오류 수정',
    'update(api): 응답 수정',
    'feat(API): 응답 추가',
    'feat(api): add endpoint',
    ' feat(api): 응답 추가',
    'feat(api): 응답 추가\n다음 줄',
    'feat(api): 응답 추가 ',
    'feat(api): ' + '가'.repeat(100),
  ])
    assert.ok(validateTitle(title).length > 0);
});

test('실제 CLI는 이벤트 제목을 읽고 변경된 제목 및 잘못된 입력을 거부한다', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'flowcast-message-'));
  const script = fileURLToPath(new URL('../check-message.mjs', import.meta.url));
  const eventPath = path.join(directory, 'event.json');
  try {
    for (const [payload, expected] of [
      [{ pull_request: { title: 'fix(api): 카드 청구 중복 응답 수정' } }, 0],
      [{ pull_request: { title: '수정 완료' } }, 1],
      [{}, 1],
    ]) {
      fs.writeFileSync(eventPath, JSON.stringify(payload));
      const result = spawnSync(process.execPath, [script, '--event'], {
        env: { ...process.env, GITHUB_EVENT_PATH: eventPath },
        encoding: 'utf8',
        windowsHide: true,
      });
      assert.equal(result.status, expected, result.stderr);
    }
    fs.writeFileSync(eventPath, 'invalid JSON');
    assert.equal(
      spawnSync(process.execPath, [script, '--event'], {
        env: { ...process.env, GITHUB_EVENT_PATH: eventPath },
        windowsHide: true,
      }).status,
      2,
    );
    fs.writeFileSync(eventPath, 'docs(repo): 설치 안내 보완\n\n변경 이유와 검증 결과\n');
    assert.equal(
      spawnSync(process.execPath, [script, '--commit-file', eventPath], {
        windowsHide: true,
      }).status,
      0,
    );
    assert.equal(
      spawnSync(process.execPath, [script, '--title-file', eventPath], {
        windowsHide: true,
      }).status,
      1,
    );
  } finally {
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(directory).startsWith('flowcast-message-'));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
