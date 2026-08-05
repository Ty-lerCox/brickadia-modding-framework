#!/usr/bin/env node

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const fengari = require('fengari');
const fengariPackage = require('fengari/package.json');
const luaparse = require('luaparse');
const parserPackage = require('luaparse/package.json');

const { lua, lauxlib, to_jsstring: toJsString, to_luastring: toLuaString } =
  fengari;

const forbiddenSchedulerPrimitives = Object.freeze([
  'ExecuteWithDelay',
  'ExecuteAsync',
  'LoopAsync',
  'ClearAllDelayedActions',
]);
const forbiddenSchedulerSet = new Set(forbiddenSchedulerPrimitives);

function nodeLine(node) {
  return node?.loc?.start?.line || 1;
}

function nodeColumn(node) {
  return node?.loc?.start?.column ?? 0;
}

function indexString(node) {
  if (!node || node.type !== 'StringLiteral') return null;
  if (typeof node.value === 'string') return node.value;
  const rawMatch = node.raw?.match(/^(['"])([A-Za-z_][A-Za-z0-9_]*)\1$/);
  return rawMatch ? rawMatch[2] : null;
}

function compileLua53(source, sourceName) {
  const state = lauxlib.luaL_newstate();
  if (!state) {
    return { passed: false, error: 'Fengari could not allocate a Lua state.' };
  }

  try {
    const buffer = toLuaString(source);
    const chunkName = toLuaString(`@${sourceName}`);
    const status = lauxlib.luaL_loadbuffer(
      state,
      buffer,
      buffer.length,
      chunkName,
    );
    if (status === lua.LUA_OK) return { passed: true, error: null };
    const luaError = lua.lua_tostring(state, -1);
    return {
      passed: false,
      error: luaError ? toJsString(luaError) : `Lua compiler status ${status}`,
    };
  } finally {
    lua.lua_close(state);
  }
}

function directSchedulerReference(node, aliases = new Map()) {
  if (!node || typeof node !== 'object') return null;

  if (node.type === 'Identifier') {
    if (forbiddenSchedulerSet.has(node.name)) return node.name;
    return aliases.get(node.name) || null;
  }

  if (node.type === 'MemberExpression') {
    const name = node.identifier?.name;
    return forbiddenSchedulerSet.has(name) ? name : null;
  }

  if (node.type === 'IndexExpression') {
    const name = indexString(node.index);
    return forbiddenSchedulerSet.has(name) ? name : null;
  }

  return null;
}

function walk(node, visitor, parent = null) {
  if (!node || typeof node !== 'object') return;
  if (typeof node.type === 'string') visitor(node, parent);

  for (const [key, value] of Object.entries(node)) {
    if (key === 'loc' || key === 'range') continue;
    if (Array.isArray(value)) {
      for (const child of value) {
        if (child && typeof child === 'object' && child.type) {
          walk(child, visitor, node);
        }
      }
    } else if (value && typeof value === 'object' && value.type) {
      walk(value, visitor, node);
    }
  }
}

function schedulerFindings(ast) {
  const assignments = [];
  const aliases = new Map();
  const findings = [];
  const seen = new Set();

  const addFinding = (primitive, invocation, node) => {
    const line = nodeLine(node);
    const column = nodeColumn(node);
    const key = `${primitive}:${invocation}:${line}:${column}`;
    if (seen.has(key)) return;
    seen.add(key);
    findings.push({ primitive, invocation, line, column });
  };

  walk(ast, node => {
    if (
      node.type !== 'LocalStatement' &&
      node.type !== 'AssignmentStatement'
    ) {
      return;
    }

    const variables = node.variables || [];
    const initializers = node.init || [];
    for (let index = 0; index < initializers.length; index += 1) {
      assignments.push({
        variable: variables[index] || null,
        initializer: initializers[index],
      });
    }
  });

  // Resolve simple and transitive aliases before looking for calls. This catches
  // both `local run = ExecuteAsync` and `local run = _G["ExecuteAsync"]`.
  let changed = true;
  while (changed) {
    changed = false;
    for (const assignment of assignments) {
      if (assignment.variable?.type !== 'Identifier') continue;
      const primitive = directSchedulerReference(assignment.initializer, aliases);
      if (!primitive || aliases.get(assignment.variable.name) === primitive) {
        continue;
      }
      aliases.set(assignment.variable.name, primitive);
      changed = true;
    }
  }

  for (const assignment of assignments) {
    const primitive = directSchedulerReference(assignment.initializer, aliases);
    if (primitive) {
      addFinding(primitive, 'alias-reference', assignment.initializer);
    }
  }

  walk(ast, node => {
    if (node.type === 'IndexExpression') {
      const primitive = indexString(node.index);
      if (
        node.base?.type === 'Identifier' &&
        node.base.name === '_G' &&
        forbiddenSchedulerSet.has(primitive)
      ) {
        addFinding(primitive, '_G-index-reference', node);
      }
      return;
    }

    if (
      node.type !== 'CallExpression' &&
      node.type !== 'TableCallExpression' &&
      node.type !== 'StringCallExpression'
    ) {
      return;
    }

    if (node.base?.type === 'Identifier' && node.base.name === 'pcall') {
      const primitive = directSchedulerReference(node.arguments?.[0], aliases);
      if (primitive) addFinding(primitive, 'pcall', node.arguments[0]);
      return;
    }

    const primitive = directSchedulerReference(node.base, aliases);
    if (!primitive) return;
    const invocation =
      node.base.type === 'Identifier' && aliases.has(node.base.name)
        ? 'alias-call'
        : 'direct';
    addFinding(primitive, invocation, node.base);
  });

  return findings.sort((left, right) => {
    return left.line - right.line || left.column - right.column;
  });
}

function validateLuaSource(source, sourceName = '<memory>') {
  const compilation = compileLua53(source, sourceName);
  let ast;
  let astError = null;
  try {
    ast = luaparse.parse(source, {
      comments: false,
      locations: true,
      luaVersion: '5.3',
    });
  } catch (error) {
    astError = error.message;
  }

  const syntaxPassed = compilation.passed && !astError;
  const syntaxErrors = [];
  if (!compilation.passed) syntaxErrors.push(compilation.error);
  if (astError) syntaxErrors.push(`luaparse AST: ${astError}`);
  return {
    source: sourceName,
    syntaxPassed,
    syntaxError: syntaxErrors.length > 0 ? syntaxErrors.join('; ') : null,
    compilerPassed: compilation.passed,
    compilerError: compilation.error,
    astPassed: !astError,
    astError,
    unsafeSchedulerFindings: ast ? schedulerFindings(ast) : [],
  };
}

function validateLuaFile(filepath) {
  const absolutePath = path.resolve(filepath);
  return validateLuaSource(fs.readFileSync(absolutePath, 'utf8'), absolutePath);
}

function main(argv) {
  const paths = argv.filter(argument => argument !== '--');
  if (paths.length === 0) {
    process.stderr.write('Usage: validate-lua-runtime.js <lua-file> [...lua-file]\n');
    process.exitCode = 2;
    return;
  }

  const files = paths.map(validateLuaFile);
  const failed = files.some(file => {
    return !file.syntaxPassed || file.unsafeSchedulerFindings.length > 0;
  });
  const result = {
    status: failed ? 'failed' : 'passed',
    luaVersion: '5.3',
    compiler: `fengari@${fengariPackage.version}`,
    parser: `luaparse@${parserPackage.version}`,
    forbiddenSchedulerPrimitives,
    files,
  };
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (failed) process.exitCode = 1;
}

module.exports = {
  forbiddenSchedulerPrimitives,
  validateLuaFile,
  validateLuaSource,
};

if (require.main === module) {
  main(process.argv.slice(2));
}
