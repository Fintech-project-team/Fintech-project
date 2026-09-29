import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const types = new Set(['feat', 'fix', 'refactor', 'docs', 'test', 'chore', 'ci']);

/**
 * @created 2026-09-28
 * @description 커밋 또는 PR 제목의 공통 형식을 검사한다.
 * @param {string} title 검사할 제목
 * @returns {string[]} 위반 사유; 빈 배열이면 통과
 */
export function validateTitle(title) {
  if (typeof title !== 'string') return ['제목이 문자열이어야 합니다.'];
  const errors = [];
  if (title !== title.trim() || /[\r\n]/u.test(title)) {
    errors.push('제목은 앞뒤 공백 없는 한 줄이어야 합니다.');
  }
  if ([...title].length > 100) errors.push('제목은 100자 이하여야 합니다.');
  const match = /^([a-z]+)\(([a-z][a-z0-9]*(?:-[a-z0-9]+)*)\)(!)?: (\S[^\r\n]*)$/u.exec(title);
  if (!match) {
    errors.push('type(scope): 한국어 설명 형식으로 작성하세요.');
    return errors;
  }
  if (!types.has(match[1])) errors.push('허용 type: feat, fix, refactor, docs, test, chore, ci');
  if (!/[가-힣]/u.test(match[4])) errors.push('설명에 한국어를 포함하세요.');
  return errors;
}

/**
 * @created 2026-09-28
 * @description 파일 또는 GitHub 이벤트에서 제목을 읽고 검사 결과를 출력한다.
 * @param {string[]} args 실행 인자
 * @returns {number} 성공 0, 형식 위반 1, 실행 오류 2
 */
export function main(args) {
  try {
    let title;
    if (args.length === 1 && args[0] === '--event') {
      if (!process.env.GITHUB_EVENT_PATH) throw new Error('GITHUB_EVENT_PATH가 없습니다.');
      const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
      title = event.pull_request?.title;
    } else if (args.length === 2 && ['--title-file', '--commit-file'].includes(args[0])) {
      const content = fs.readFileSync(args[1], 'utf8').replace(/^\uFEFF/u, '');
      title =
        args[0] === '--commit-file' ? content.split(/\r?\n/u)[0] : content.replace(/\r?\n$/u, '');
    } else {
      throw new Error('사용법: --event | --title-file <파일> | --commit-file <파일>');
    }
    const errors = validateTitle(title);
    if (errors.length) {
      for (const error of errors) console.error('FAIL: ' + error);
      return 1;
    }
    console.log('PASS: message format');
    return 0;
  } catch (error) {
    console.error('ERROR: ' + error.message);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
