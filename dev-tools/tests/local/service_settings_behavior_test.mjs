#!/usr/bin/env node
// Behavioral Settings-modal transaction and convergence observer contract.
// Runs production pure helpers from www/index.html in a private VM only.

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');
const source = fs.readFileSync(path.join(root, 'www/index.html'), 'utf8');

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}
function pass(message) { console.log(`PASS: ${message}`); }
function expect(value, message) { if (!value) fail(message); }
function equal(actual, expected, message) { if (actual !== expected) fail(`${message}: expected ${expected}, got ${actual}`); }

function extractFunction(name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) fail(`production helper missing: ${name}`);
  const brace = source.indexOf('{', start);
  let depth = 0;
  for (let i = brace; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  fail(`production helper is unterminated: ${name}`);
}

const context = vm.createContext({
  console,
  Set,
  Number,
  String,
  Array,
  MAX_NODES: 10,
  sshTrustRegistryNeeds: [],
  CURRENT_SETTINGS_CACHE: {}
});
[
  'buildServiceSettingsTransaction',
  'serviceSettingsAutoSyncPrerequisites',
  'parseServiceConvergenceStatus',
  'adoptServiceConvergenceGeneration',
  'describeServiceConvergenceSettings',
  'describeServiceConvergence',
  'describeServiceSyncProgress',
  'describeServiceSaveResult',
  'unwrapVerifiedActionAcknowledgement',
  'normalizeSettingsSaveAcknowledgement'
].forEach(name => vm.runInContext(extractFunction(name), context));

const boot = { key: 'BOOT_ENABLED', desired: '1', definition: { kind: 'action', action: { order: 100 } } };
const nodeSetting = { key: 'DRY_RUN', desired: 'yes', definition: { kind: 'setting' } };
const localSetting = { key: 'HTML_CLIENT_REFRESH_MINUTES', desired: '15', definition: { kind: 'setting' } };
const tx = context.buildServiceSettingsTransaction([nodeSetting, localSetting, boot]);
equal(tx.length, 2, 'mixed Settings transaction remains two stages');
equal(tx[0].type, 'verified-action', 'Boot action precedes durable settings Save');
equal(tx[1].type, 'settings-save', 'ordinary settings are coalesced after actions');
equal(tx[1].changes.length, 2, 'ordinary Settings changes remain one scoped save');
pass('mixed Boot/node/local transaction is serialized without self-contention');

function verifiedWrapper(rawAck) {
  return {
    ok: rawAck.status === 'ok', status: rawAck.status, message: rawAck.message,
    warnings: rawAck.warnings || [], result: rawAck
  };
}

const pendingRawAck = {
  request_token: 't.settings-pending', action: 'save_vlanmgr', status: 'ok',
  message: 'Settings saved successfully; node settings synchronization is pending.', warnings: [],
  result: { local_saved: '1', node_sync: 'pending', node_sync_generation: '7' }
};
const pendingSave = context.normalizeSettingsSaveAcknowledgement(verifiedWrapper(pendingRawAck));
expect(pendingSave.ok, 'verified helper wrapper preserves an acknowledged pending Save');
equal(pendingSave.publicSettings, 'ok', 'normal Save publication state is preserved');
equal(pendingSave.nodeSyncStatus, 'pending', 'verified helper wrapper preserves pending node convergence');
equal(pendingSave.nodeSyncGeneration, 7, 'verified helper wrapper exposes the durable generation');

// Exercise the actual verified-helper -> Settings-normalizer boundary. The
// helper deliberately returns a wrapper whose `result` is the raw action ACK;
// this is the production shape that the prior fixture failed to model.
const helperContext = vm.createContext({
  AbortController: undefined,
  Date,
  Promise,
  String,
  Number,
  Object,
  encodeURIComponent,
  setTimeout(callback) { callback(); return 1; },
  clearTimeout() {},
  PATHS: { ACTION_RESULTS_DIR: '/token/', ACTION_RESULT: '/stable.json' }
});
vm.runInContext('async ' + extractFunction('waitForVerifiedActionResult'), helperContext);
['unwrapVerifiedActionAcknowledgement', 'normalizeSettingsSaveAcknowledgement']
  .forEach(name => vm.runInContext(extractFunction(name), helperContext));
const helperPaths = [];
helperContext.fetch = async path => {
  helperPaths.push(path);
  return { ok: true, json: async () => pendingRawAck };
};
const verifiedFromHelper = await helperContext.waitForVerifiedActionResult(
  pendingRawAck.request_token, pendingRawAck.action, { local_saved: '1' }, 1000
);
const normalizedFromHelper = helperContext.normalizeSettingsSaveAcknowledgement(verifiedFromHelper);
expect(verifiedFromHelper.ok, 'verified helper accepts the correlated pending Save acknowledgement');
expect(helperPaths.length === 1, 'verified helper reads the correlated acknowledgement once');
expect(normalizedFromHelper.ok, 'verified helper wrapper reaches the Settings Save normalizer successfully');
equal(normalizedFromHelper.nodeSyncStatus, 'pending', 'verified-helper composition preserves pending node convergence');
equal(normalizedFromHelper.nodeSyncGeneration, 7, 'verified-helper composition preserves the durable generation');
pass('real verified-helper acknowledgement shape reaches Settings convergence');

const publicPartial = context.normalizeSettingsSaveAcknowledgement(verifiedWrapper({
  request_token: 't.public-partial', action: 'save_vlanmgr', status: 'partial', message: 'public copy unavailable', warnings: [],
  result: { local_saved: '1', public_settings: 'failed', node_sync: 'pending', node_sync_generation: '7' }
}));
expect(publicPartial.ok, 'public publication partial preserves authoritative MAIN save');
equal(publicPartial.publicSettings, 'failed', 'public failure remains distinct');
equal(publicPartial.nodeSyncStatus, 'pending', 'public failure does not become node failure');
equal(publicPartial.nodeSyncGeneration, 7, 'ack exposes only valid durable generation');
pass('structured public-save partial preserves durable node convergence');

const nodeFailure = context.normalizeSettingsSaveAcknowledgement(verifiedWrapper({
  request_token: 't.node-failure', action: 'save_vlanmgr', status: 'partial', message: 'node verification failed', warnings: [],
  result: { local_saved: '1', node_sync: 'failed', node_sync_generation: '8' }
}));
expect(nodeFailure.ok, 'authoritative MAIN save remains true when node convergence fails');
equal(nodeFailure.nodeSyncStatus, 'failed', 'authoritative node failure remains visible');
const localOnlyAck = context.normalizeSettingsSaveAcknowledgement(verifiedWrapper({
  request_token: 't.local-only', action: 'save_vlanmgr', status: 'ok', message: 'Settings saved.', warnings: [],
  result: { local_saved: '1', node_sync: 'skipped-local-only' }
}));
expect(localOnlyAck.ok && localOnlyAck.nodeSyncStatus === 'skipped-local-only', 'successful local-only Save remains a successful local Save');
const rejected = context.normalizeSettingsSaveAcknowledgement(verifiedWrapper({
  request_token: 't.no-main', action: 'save_vlanmgr', status: 'ok', message: 'save did not persist', warnings: [],
  result: { local_saved: '0' }
}));
expect(!rejected.ok, 'missing MAIN persistence is a real save failure');
expect(!context.normalizeSettingsSaveAcknowledgement(pendingRawAck).ok, 'raw acknowledgement is not accepted where the verified wrapper is required');
expect(!context.normalizeSettingsSaveAcknowledgement({ ok: true, status: 'ok', message: 'bad wrapper', result: { local_saved: '1' } }).ok,
  'malformed verified wrapper cannot impersonate an action payload');
expect(!context.normalizeSettingsSaveAcknowledgement({ ...verifiedWrapper(pendingRawAck), status: 'error' }).ok,
  'mismatched verified-wrapper and raw acknowledgement states cannot claim MAIN persistence');
pass('MAIN-save and node-failure semantics remain separate');

const pending = { format: 1, active: true, generation: 7, status: 'pending', attempt: 0, next_epoch: 0, updated_epoch: 1 };
const running = { ...pending, status: 'running' };
const blocked = { ...pending, status: 'blocked' };
const retry = { ...pending, status: 'retry' };
const paused = { ...pending, status: 'paused' };
const verified = { ...pending, active: false, status: 'verified' };
equal(context.describeServiceConvergenceSettings(false).state, 'success', 'ordinary MAIN persistence remains green');
equal(context.describeServiceConvergenceSettings(true).state, 'warning', 'public publication failure remains a Settings warning');
expect(context.describeServiceConvergenceSettings(true).message.includes('publication'), 'public publication warning is explicit');
expect(context.describeServiceConvergence(null, 0).silent, 'modal reopen without an obligation keeps its ordinary loaded status');
expect(context.describeServiceConvergence(verified, 0).silent, 'old verified projection is not reused for an unrelated modal open');
equal(context.describeServiceConvergence(pending, 7).terminal, false, 'pending remains nonterminal');
expect(context.describeServiceConvergence(running, 7).message.includes('Synchronizing'), 'running is visible');
expect(context.describeServiceConvergence(blocked, 7).message.includes('trust'), 'trust block is visible');
expect(context.describeServiceConvergence(retry, 7).message.includes('retry'), 'retry is visible');
expect(context.describeServiceConvergence(paused, 7).message.includes('Disabled'), 'paused is visible');
equal(context.describeServiceConvergence(verified, 7).terminal, true, 'verified is terminal');
equal(context.describeServiceConvergence(pending, 7).state, 'info', 'pending is neutral information, not a warning');
equal(context.describeServiceConvergence(running, 7).state, 'info', 'running is neutral information, not a warning');
equal(context.describeServiceConvergence(verified, 7).state, 'success', 'verified is green terminal success');
equal(context.describeServiceConvergence(retry, 7).state, 'warning', 'retry remains a warning');
equal(context.describeServiceConvergence(blocked, 7).state, 'warning', 'trust block remains a warning');
equal(context.describeServiceConvergence(paused, 7).state, 'warning', 'paused convergence remains a warning');
equal(context.describeServiceConvergence({ ...pending, generation: 8 }, 7).generation, 8, 'newer generation supersedes stale modal observer');
equal(context.describeServiceConvergence({ ...pending, generation: 6 }, 7).terminal, false, 'stale completion cannot verify newer generation');
equal(context.parseServiceConvergenceStatus({ ...pending, settings_digest: 'secret' }), null, 'observer rejects an unexpected public field');
equal(context.parseServiceConvergenceStatus({ ...pending, generation: 0 }), null, 'invalid generation is rejected');
equal(context.parseServiceConvergenceStatus({ ...pending, status: 'bad' }), null, 'invalid status is rejected');
const adoptedOnReopen = context.adoptServiceConvergenceGeneration(0, running);
equal(adoptedOnReopen, 7, 'reopened observer adopts the live active generation');
equal(context.describeServiceConvergence(verified, adoptedOnReopen).state, 'success', 'adopted generation reaches green verified completion');
equal(context.adoptServiceConvergenceGeneration(0, verified), 0, 'old inactive verified state is not adopted on an unrelated modal open');
equal(context.adoptServiceConvergenceGeneration(8, running), 8, 'acknowledged newer generation is never replaced by an older active generation');
pass('generation-aware observer covers pending through verified safely');

const liveProgress = context.describeServiceSyncProgress({ state: 'running', message: 'Synchronizing NODE1…' });
expect(liveProgress && liveProgress.message === 'Synchronizing NODE1…', 'real loader progress is preserved for Settings display');
equal(liveProgress.state, 'info', 'real running loader progress is neutral information');
equal(context.describeServiceSyncProgress({ state: 'complete', message: 'Synchronization complete' }), null, 'loader completion cannot directly fabricate durable success');
equal(context.describeServiceSyncProgress({ state: 'failed', message: 'Synchronization failed' }), null, 'loader failure is left to durable reconciliation truth');
pass('loader progress is mirrored without becoming convergence authority');

const noNodes = context.serviceSettingsAutoSyncPrerequisites({ SSH_KEYS_INSTALLED: '1' });
expect(!noNodes.ready && noNodes.message.includes('No nodes'), 'no nodes preserves Auto-sync prerequisite');
const noKeys = context.serviceSettingsAutoSyncPrerequisites({ NODE1: '192.0.2.10' });
expect(!noKeys.ready && noKeys.message.includes('SSH keys'), 'missing keys preserve Auto-sync prerequisite');
const ready = context.serviceSettingsAutoSyncPrerequisites({ NODE1: '192.0.2.10', SSH_KEYS_INSTALLED: '1' });
expect(ready.ready, 'configured trusted node allows Auto-sync control');
pass('Auto-sync prerequisites survive modal control-state transitions');

const localOnly = context.describeServiceSaveResult({ nodeSyncStatus: 'skipped-local-only', publicSettings: 'ok' });
expect(!localOnly.observe && localOnly.message === 'Settings saved.', 'local-only save has no fabricated node stage');
const pausedSave = context.describeServiceSaveResult({ nodeSyncStatus: 'paused', nodeSyncGeneration: 9, publicSettings: 'ok' });
expect(pausedSave.observe && pausedSave.generation === 9, 'paused durable generation is observed, not called verified');
pass('local-only and paused Save outcomes remain truthful');

expect(!source.includes("transactionWarnings.length ? transactionWarnings.join(' ') : 'Settings Saved!'"), 'modal no longer overwrites convergence state with generic success');
expect(source.includes('stopServiceConvergenceObservation();'), 'modal close stops only its observer');
expect(source.includes('Browser auto-sync accelerator did not start; observing backend convergence.'), 'browser/boundary race is not reported as node failure');
console.log('SERVICE_SETTINGS_BEHAVIOR_OK');
