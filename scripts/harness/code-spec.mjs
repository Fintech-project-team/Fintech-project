import ts from 'typescript';

/**
 * @created 2026-09-28
 * @description 이름 있는 선언의 핵심 JSDoc 태그와 매개변수 명세를 검사한다.
 * @param file - 상대 파일 이름.
 * @param text - 파일 내용.
 * @returns 명세가 누락된 위치와 이유 배열.
 */
export function inspectCodeSpec(file, text) {
  if (
    !/^(apps|packages)\//u.test(file) ||
    !/\.[cm]?[jt]sx?$/u.test(file) ||
    /(?:\.d\.ts$|\.(?:test|spec)\.|\/tests?\/|\/__tests__\/)/u.test(file)
  )
    return [];
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    /tsx$/u.test(file)
      ? ts.ScriptKind.TSX
      : /jsx$/u.test(file)
        ? ts.ScriptKind.JSX
        : ts.ScriptKind.TS,
  );
  const errors = [];
  const visit = (node) => {
    const variable =
      ts.isVariableDeclaration(node) &&
      node.initializer &&
      (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer));
    const property =
      ts.isPropertyDeclaration(node) &&
      node.initializer &&
      (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer));
    const named =
      (ts.isFunctionDeclaration(node) && node.body) ||
      ts.isClassDeclaration(node) ||
      ts.isMethodDeclaration(node) ||
      ts.isConstructorDeclaration(node) ||
      ts.isGetAccessorDeclaration(node) ||
      ts.isSetAccessorDeclaration(node) ||
      variable ||
      property;
    if (named) {
      let host = node;
      if (variable) host = node.parent.parent;
      const tags = ts.getJSDocTags(host);
      const byName = (name) => tags.filter((t) => t.tagName.text === name);
      const content = (t) =>
        typeof t.comment === 'string' ? t.comment : t.comment?.map((x) => x.text).join('') || '';
      const why = [];
      for (const name of ['created', 'description', 'param', 'returns'])
        if (
          !byName(name).length ||
          byName(name).every((t) => !content(t).trim() && !(name === 'param' && t.name))
        )
          why.push(`@${name}`);
      const created = byName('created')[0];
      if (created && !/^(?:\d{4}-\d{2}-\d{2}|unknown\s*[-–])/u.test(content(created).trim()))
        why.push('created date');
      const callable = variable || property ? node.initializer : node;
      const params = ts.isClassDeclaration(node)
        ? node.members.find(ts.isConstructorDeclaration)?.parameters || []
        : callable.parameters || [];
      for (const param of params)
        if (
          ts.isIdentifier(param.name) &&
          !byName('param').some(
            (t) => t.name?.getText(source) === param.name.text && content(t).trim(),
          )
        )
          why.push(`@param ${param.name.text}`);
      if (why.length)
        errors.push(
          `${file}:${source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1} missing ${[...new Set(why)].join(', ')}`,
        );
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return errors;
}
