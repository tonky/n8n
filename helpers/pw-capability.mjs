// Interpret only declarative capability values. Never execute a spec or its imports.
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, extname, resolve, sep } from 'node:path';
import { createRequire } from 'node:module';

export function capabilityReader(packageDir, callerEnvironment = process.env) {
  const environment = Object.freeze({...callerEnvironment});
  const root = realpathSync(resolve(packageDir, '../../../..'));
  const ts = createRequire(resolve(root, 'package.json'))('typescript');
  const modules = new Map();
  const active = new Set();
  function unwrap(node) {
    while (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isSatisfiesExpression(node) || ts.isNonNullExpression(node) || ts.isTypeAssertionExpression(node)) node = node.expression;
    return node;
  }
  function read(file) {
    file = realpathSync(file);
    if (file !== root && !file.startsWith(root + sep)) throw Error(`capability import escapes repository: ${file}`);
    if (modules.has(file)) return modules.get(file);
    const text = readFileSync(file, 'utf8');
    if (text.length > 1024 * 1024) throw Error(`capability module is too large: ${file}`);
    const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    if (source.parseDiagnostics.length) throw Error(`invalid TypeScript capability module: ${file}`);
    const module = { file, source, values: new Map(), imports: new Map(), exports: new Map() };
    modules.set(file, module);
    for (const statement of source.statements) {
      if (ts.isVariableStatement(statement)) {
        const constant = !!(statement.declarationList.flags & ts.NodeFlags.Const);
        for (const item of statement.declarationList.declarations) if (ts.isIdentifier(item.name)) {
          module.values.set(item.name.text, constant ? item.initializer : undefined);
        }
      } else if (ts.isImportDeclaration(statement) && statement.importClause && !statement.importClause.isTypeOnly) {
        const clause = statement.importClause;
        if (clause.name) module.imports.set(clause.name.text, [statement.moduleSpecifier.text, 'default']);
        if (clause.namedBindings && ts.isNamedImports(clause.namedBindings)) for (const binding of clause.namedBindings.elements) {
          if (!binding.isTypeOnly) module.imports.set(binding.name.text, [statement.moduleSpecifier.text, binding.propertyName?.text ?? binding.name.text]);
        }
      } else if (ts.isExportDeclaration(statement) && statement.exportClause && ts.isNamedExports(statement.exportClause)) {
        for (const binding of statement.exportClause.elements) module.exports.set(binding.name.text, [statement.moduleSpecifier?.text, binding.propertyName?.text ?? binding.name.text]);
      }
    }
    return module;
  }
  function imported(module, name) {
    if (!name.startsWith('.')) throw Error(`capability value requires a non-relative import: ${name}`);
    const path = resolve(dirname(module.file), name);
    const paths = extname(path) ? [path] : [path + '.ts', path + '.mts', path + '.mjs', resolve(path, 'index.ts')];
    const file = paths.find(existsSync);
    if (!file) throw Error(`capability import is missing: ${path}`);
    return read(file);
  }
  function symbol(module, name) {
    const key = `${module.file}#${name}`;
    if (active.has(key) || active.size >= 64) throw Error(`cyclic capability value: ${key}`);
    active.add(key);
    try {
      if (module.values.has(name)) {
        const node = module.values.get(name);
        if (!node) throw Error(`capability value is not a static const: ${key}`);
        return { module, node: unwrap(node) };
      }
      const binding = module.imports.get(name) ?? module.exports.get(name);
      if (binding) return symbol(binding[0] ? imported(module, binding[0]) : module, binding[1]);
      throw Error(`unresolved capability value: ${key}`);
    } finally { active.delete(key); }
  }
  function dereference(module, node) {
    node = unwrap(node);
    const seen = new Set();
    while (ts.isIdentifier(node)) {
      const key = `${module.file}#${node.text}`;
      if (seen.has(key) || seen.size >= 64) throw Error(`cyclic capability constant: ${key}`);
      seen.add(key);
      ({ module, node } = symbol(module, node.text));
    }
    return { module, node };
  }
  function property(module, node, name) {
    ({ module, node } = dereference(module, node));
    if (ts.isPropertyAccessExpression(node)) return propertyValue(module, node.expression, node.name.text, name);
    if (!ts.isObjectLiteralExpression(node)) throw Error(`capability option must be a static object in ${module.file}`);
    let result;
    for (const item of node.properties) {
      if (ts.isSpreadAssignment(item)) {
        const found = property(module, item.expression, name);
        if (found) result = found;
      } else {
        const key = item.name && (ts.isIdentifier(item.name) || ts.isStringLiteral(item.name)) ? item.name.text : undefined;
        if (key === undefined) throw Error(`unsupported capability property in ${module.file}`);
        if (key !== name) continue;
        if (ts.isPropertyAssignment(item)) result = {module, node:item.initializer};
        else if (ts.isShorthandPropertyAssignment(item)) result = {module, node:item.name};
        else throw Error(`capability ${name} must be a static value in ${module.file}`);
      }
    }
    return result;
  }
  function propertyValue(module, object, key, name) {
    const value = property(module, object, key);
    if (!value) throw Error(`missing capability constant property: ${key}`);
    return property(value.module, value.node, name);
  }
  function value(module, node, depth = 0) {
    if (depth > 64) throw Error('capability value is too deeply nested');
    ({module,node} = dereference(module,node));
    if (ts.isStringLiteralLike(node)) return node.text;
    if (ts.isNumericLiteral(node)) return Number(node.text);
    if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
    if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
    if (node.kind === ts.SyntaxKind.NullKeyword) return null;
    if (ts.isCallExpression(node) && node.arguments.length === 1 && ts.isPropertyAccessExpression(node.expression) && ts.isIdentifier(node.expression.expression) && node.expression.expression.text === 'JSON' && node.expression.name.text === 'stringify' && !module.values.has('JSON') && !module.imports.has('JSON')) {
      return JSON.stringify(value(module,node.arguments[0],depth+1));
    }
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken) {
      return value(module,node.left,depth+1) ?? value(module,node.right,depth+1);
    }
    if (ts.isPropertyAccessExpression(node)) {
      if (ts.isPropertyAccessExpression(node.expression) && ts.isIdentifier(node.expression.expression) && node.expression.expression.text === 'process' && node.expression.name.text === 'env' && !module.values.has('process') && !module.imports.has('process')) return environment[node.name.text];
      const found = property(module,node.expression,node.name.text);
      if (found) return value(found.module,found.node,depth+1);
    }
    if (ts.isArrayLiteralExpression(node)) return node.elements.flatMap(item => ts.isSpreadElement(item) ? value(module,item.expression,depth+1) : [value(module,item,depth+1)]);
    if (ts.isObjectLiteralExpression(node)) {
      const result = Object.create(null);
      for (const item of node.properties) {
        if (ts.isSpreadAssignment(item)) Object.assign(result, value(module,item.expression,depth+1));
        else {
          const key = item.name && (ts.isIdentifier(item.name) || ts.isStringLiteral(item.name)) ? item.name.text : undefined;
          if (key === undefined || (!ts.isPropertyAssignment(item) && !ts.isShorthandPropertyAssignment(item))) throw Error(`unsupported capability object in ${module.file}`);
          result[key] = value(module,ts.isPropertyAssignment(item) ? item.initializer : item.name,depth+1);
        }
      }
      return result;
    }
    throw Error(`unsupported dynamic capability expression in ${module.file}: ${node.getText(module.source)}`);
  }
  return function specCapability(file) {
    const module = read(resolve(packageDir,file));
    let capability;
    function visit(node) {
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === 'use' && ts.isIdentifier(node.expression.expression) && node.expression.expression.text === 'test') {
        if (node.arguments.length !== 1) throw Error(`unsupported test.use in ${file}`);
        const found = property(module,node.arguments[0],'capability');
        if (found) {
          let declaration = dereference(found.module,found.node);
          if (ts.isStringLiteralLike(declaration.node)) {
            const named = read(resolve(packageDir,'fixtures/capabilities.ts'));
            const exported = symbol(named,'CAPABILITIES');
            declaration = property(exported.module,exported.node,declaration.node.text);
            if (!declaration) throw Error(`unknown capability in ${file}`);
          }
          const envNode = property(declaration.module,declaration.node,'env');
          const servicesNode = property(declaration.module,declaration.node,'services');
          const env = envNode ? value(envNode.module,envNode.node) : {};
          const services = servicesNode ? value(servicesNode.module,servicesNode.node) : [];
          if (!env || Array.isArray(env) || typeof env !== 'object' || Object.values(env).some(v=>typeof v!=='string') || !Array.isArray(services) || services.some(v=>typeof v!=='string')) throw Error(`invalid declarative capability in ${file}`);
          const next = {env, services};
          if (capability && JSON.stringify(capability) !== JSON.stringify(next)) throw Error(`multiple backend capabilities in one spec: ${file}`);
          capability = next;
        }
      }
      ts.forEachChild(node,visit);
    }
    visit(module.source);
    return capability ?? {env:{},services:[]};
  };
}
