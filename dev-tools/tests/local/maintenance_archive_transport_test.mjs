#!/usr/bin/env node
// Behavioral contract for the GUI maintenance archive-action transport.
// The frontend functions and the handler parser/decoder are loaded from the
// production sources; the final worker dispatch is a local recording stub.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const aspSource = readFileSync(path.join(root, 'mervlan.asp'), 'utf8');
const handlerLines = readFileSync(path.join(root, 'functions/service-event-handler.sh'), 'utf8').split('\n');

function extractJsFunction(source, name) {
  const match = new RegExp(`(^|\\n)[ \\t]*(?:async[ \\t]+)?function[ \\t]+${name}[ \\t]*\\(`).exec(source);
  assert.ok(match, `production frontend function is missing: ${name}`);
  const start = match.index + (match[1] ? match[1].length : 0);
  const open = source.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let lineComment = false;
  let blockComment = false;
  let seenOpen = false;
  for (let index = open; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === '*' && next === '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (character === '\\') index += 1;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === '/' && next === '/') {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === '/' && next === '*') {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'" || character === '`') {
      quote = character;
      continue;
    }
    if (character === '{') {
      depth += 1;
      seenOpen = true;
    } else if (character === '}') {
      depth -= 1;
      if (seenOpen && depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(`production frontend function is unterminated: ${name}`);
}

const frontendContext = vm.createContext({ console });
[
  'MVM_hexAscii',
  'MVM_maintenanceAction',
  'MVM_backupArchiveKey',
  'MVM_archiveMaintenanceAction',
  'MVM_listBackups',
  'MVM_createBackup',
  'MVM_deleteBackup',
  'MVM_restoreBackup'
].forEach((name) => vm.runInContext(extractJsFunction(aspSource, name), frontendContext));
vm.runInContext(
  'var capturedAction = "";\n' +
  'function MVM_exec(actionName) { capturedAction = actionName; return true; }',
  frontendContext
);

function findLine(predicate, start = 0) {
  const index = handlerLines.findIndex((line, lineIndex) => lineIndex >= start && predicate(line, lineIndex));
  assert.ok(index >= 0, 'expected production service-event marker is missing');
  return index;
}

const parserStart = findLine((line) => line.startsWith(': "${MERV_BASE:='));
const parserEnd = findLine((line) => line.includes('# NODE GUARD'), parserStart);
const parserSource = handlerLines.slice(parserStart, parserEnd).join('\n');

const decoderStart = findLine((line) => line.startsWith('decode_hex_ascii() {'));
const decoderEnd = findLine((line) => line.startsWith('json_get_flag() {'), decoderStart);
const decoderSource = handlerLines.slice(decoderStart, decoderEnd).join('\n');

const mainCaseStart = (() => {
  let result = -1;
  handlerLines.forEach((line, index) => {
    if (line === 'case "${TYPE}_${EVENT}" in') result = index;
  });
  assert.ok(result >= 0, 'main production dispatch case is missing');
  return result;
})();
const branchStart = findLine((line, index) => index > mainCaseStart && line.trim() === 'backupinventory_vlanmgr_*)');
const branchEnd = findLine((line, index) => index > branchStart && line.trim() === 'undorestore_vlanmgr_*)');
const maintenanceBranches = handlerLines.slice(branchStart, branchEnd).join('\n');

const serviceEventSeam = [
  'logger() { :; }',
  parserSource,
  decoderSource,
  'dispatch_if_executable() {',
  '  printf "DISPATCH"',
  '  for _seam_arg in "$@"; do printf "|%s" "$_seam_arg"; done',
  '  printf "\\n"',
  '}',
  'case "${TYPE}_${EVENT}" in',
  maintenanceBranches,
  'esac'
].join('\n');

function frontendCall(callback) {
  frontendContext.capturedAction = '';
  const accepted = Boolean(callback());
  return { accepted, action: frontendContext.capturedAction };
}

function normalizeLikeHandler(action) {
  const rawNorm = action.replaceAll('-', '_');
  assert.match(rawNorm, /^[A-Za-z0-9._-]+$/, 'test action unexpectedly falls outside the handler alphabet');
  const separator = rawNorm.indexOf('_');
  assert.ok(separator > 0, 'test action has no handler separator');
  const type = rawNorm.slice(0, separator);
  const event = rawNorm.slice(separator + 1);
  return `${type.toLowerCase().replaceAll('-', '_')}_${event.toLowerCase().replaceAll('-', '_')}`;
}

function runServiceEvent(action) {
  const result = spawnSync(
    '/bin/sh',
    ['-c', serviceEventSeam, 'mervlan-archive-transport-test', action],
    {
      encoding: 'utf8',
      env: {
        ...process.env,
        MERV_BASE: `/tmp/mervlan-archive-transport-${process.pid}`,
        LOCKDIR: `/tmp/mervlan-archive-transport-locks-${process.pid}`
      }
    }
  );
  const output = result.stdout.trimEnd();
  const fields = output.startsWith('DISPATCH|') ? output.slice('DISPATCH|'.length).split('|') : null;
  return { status: result.status, output, fields, stderr: result.stderr.trim() };
}

function hexAscii(value) {
  let result = '';
  for (const character of value) result += character.charCodeAt(0).toString(16).padStart(2, '0');
  return result;
}

const requestToken = 'tok.-_';
const tokenHex = hexAscii(requestToken);
const expectedWorker = '/jffs/addons/mervlan/functions/update_mervlan.sh';
const archives = [
  ['manual lowercase simple', 'mervlan.manual.backup.20260926-174516.test.tar.gz', 'm.20260926-174516.test'],
  ['manual hyphen tag', 'mervlan.manual.backup.20260926-174516.r80xcore-test.tar.gz', 'm.20260926-174516.r80xcore-test'],
  ['manual underscore tag', 'mervlan.manual.backup.20260926-174516.r80xcore_test.tar.gz', 'm.20260926-174516.r80xcore_test'],
  ['manual mixed-case tag', 'mervlan.manual.backup.20260926-174516.MyBackup.tar.gz', 'm.20260926-174516.MyBackup'],
  ['automatic backup', 'mervlan.backup.20260926-174516.tar.gz', 'a.20260926-174516'],
  ['automatic collision suffix', 'mervlan.backup.20260926-174516-2.tar.gz', 'a.20260926-174516-2']
];

for (const [label, archiveId, archiveKey] of archives) {
  assert.equal(frontendContext.MVM_backupArchiveKey(archiveId), archiveKey, `${label}: frontend archive key`);
  for (const [operation, functionName, dispatchVerb] of [
    ['Restore', 'MVM_restoreBackup', 'restore'],
    ['Delete', 'MVM_deleteBackup', 'delete']
  ]) {
    const frontend = frontendCall(() => frontendContext[functionName](requestToken, archiveId, {}));
    assert.equal(frontend.accepted, true, `${label}: frontend ${operation} accepted`);
    assert.equal(
      frontend.action,
      `${dispatchVerb}backup_vlanmgr_${tokenHex}_${archiveKey}`,
      `${label}: frontend ${operation} action`
    );
    const normalized = normalizeLikeHandler(frontend.action);
    assert.notEqual(normalized, frontend.action, `${label}: generic normalization must expose the transport-sensitive spelling`);
    const dispatched = runServiceEvent(frontend.action);
    const expectedDispatch = dispatchVerb === 'delete'
      ? [expectedWorker, 'backup', dispatchVerb, archiveId, 'yes', requestToken]
      : [expectedWorker, dispatchVerb, archiveId, 'yes', requestToken];
    assert.deepEqual(
      dispatched.fields,
      expectedDispatch,
      `${label}: ${operation} exact backend dispatch`
    );
    console.log(`PASS ${label}: ${operation} exact archive and token round-trip`);
  }
}

const inventory = frontendCall(() => frontendContext.MVM_listBackups(requestToken, {}));
assert.equal(inventory.accepted, true, 'backup inventory frontend action accepted');
assert.deepEqual(runServiceEvent(inventory.action).fields, [expectedWorker, 'inventory', requestToken], 'backup inventory dispatch');
console.log('PASS backup inventory control action remains correlated');

const createTag = 'Test-Backup_1';
const create = frontendCall(() => frontendContext.MVM_createBackup(requestToken, createTag, {}));
assert.equal(create.accepted, true, 'manual backup create frontend action accepted');
assert.deepEqual(
  runServiceEvent(create.action).fields,
  [expectedWorker, 'backup', 'create', createTag, 'yes', requestToken],
  'manual backup create preserves legal tag and token'
);
console.log('PASS manual backup create preserves legal tag and token');

const invalidArchiveIds = [
  ['path traversal', 'mervlan.manual.backup.20260926-174516.test/../x.tar.gz'],
  ['backslash', 'mervlan.manual.backup.20260926-174516.test\\escape.tar.gz'],
  ['dot traversal', 'mervlan.manual.backup.20260926-174516..test.tar.gz'],
  ['space', 'mervlan.manual.backup.20260926-174516.bad tag.tar.gz'],
  ['empty tag', 'mervlan.manual.backup.20260926-174516..tar.gz'],
  ['oversized tag', `mervlan.manual.backup.20260926-174516.${'a'.repeat(25)}.tar.gz`],
  ['bad timestamp', 'mervlan.manual.backup.20260926_174516.test.tar.gz'],
  ['malformed prefix', 'other.manual.backup.20260926-174516.test.tar.gz'],
  ['shell metacharacter', 'mervlan.manual.backup.20260926-174516.bad;$(id).tar.gz'],
  ['newline', 'mervlan.manual.backup.20260926-174516.bad\ntag.tar.gz'],
  ['control character', 'mervlan.manual.backup.20260926-174516.bad\u0001tag.tar.gz'],
  ['automatic nonnumeric suffix', 'mervlan.backup.20260926-174516-x.tar.gz']
];
for (const [label, archiveId] of invalidArchiveIds) {
  assert.equal(frontendContext.MVM_backupArchiveKey(archiveId), '', `${label}: frontend archive key rejected`);
  const frontend = frontendCall(() => frontendContext.MVM_restoreBackup(requestToken, archiveId, {}));
  assert.equal(frontend.accepted, false, `${label}: frontend Restore rejected`);
  assert.equal(frontend.action, '', `${label}: rejected archive did not dispatch`);
}
console.log(`PASS frontend rejects ${invalidArchiveIds.length} malformed archive IDs`);

const validArchiveKey = 'm.20260926-174516.test';
const malformedBackendKeys = [
  ['path traversal', 'm.20260926-174516.test/../x'],
  ['backslash', 'm.20260926-174516.test\\x'],
  ['dot traversal', 'm.20260926-174516..test'],
  ['space', 'm.20260926-174516.bad tag'],
  ['empty tag', 'm.20260926-174516.'],
  ['oversized tag', `m.20260926-174516.${'a'.repeat(25)}`],
  ['bad timestamp', 'm.2026092-174516.test'],
  ['malformed prefix', 'x.20260926-174516.test'],
  ['shell metacharacter', 'm.20260926-174516.bad;$(id)'],
  ['newline', 'm.20260926-174516.bad\ntag'],
  ['control character', 'm.20260926-174516.bad\u0001tag'],
  ['automatic bad suffix', 'a.20260926-174516-x'],
  ['automatic bad separator', 'a.20260926_174516'],
  ['empty token', '']
];
for (const [label, archiveKey] of malformedBackendKeys) {
  const action = `restorebackup_vlanmgr__${archiveKey}`;
  const dispatched = runServiceEvent(action);
  assert.equal(dispatched.fields, null, `backend rejects ${label}`);
}
for (const [label, tokenPart] of [
  ['malformed token', 'zz'],
  ['oversized token', 'a'.repeat(65)]
]) {
  const dispatched = runServiceEvent(`restorebackup_vlanmgr_${tokenPart}_${validArchiveKey}`);
  assert.equal(dispatched.fields, null, `backend rejects ${label}`);
}
assert.equal(runServiceEvent(`otheraction_${tokenHex}_${validArchiveKey}`).fields, null, 'backend rejects malformed action prefix');
console.log(`PASS backend rejects ${malformedBackendKeys.length + 2} malformed archive transports`);

console.log('MAINTENANCE_ARCHIVE_TRANSPORT_CONTRACT_OK');
