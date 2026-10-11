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

// Boot and runtime values are translated only at the display boundary. The
// backend report keys and values remain unchanged.
function statusElement() {
  return {
    textContent: '', innerHTML: '', className: '', disabled: false,
    style: {},
    classList: {
      add() {}, remove() {}, toggle() {}
    }
  };
}

function makeStatusUi(options = {}) {
  const elements = {
    svcBootPreferenceLine: statusElement(),
    svcBootStatusLine: statusElement(),
    svcStatusRefreshMessage: statusElement(),
    svcStatusRefreshBtn: statusElement(),
    svcStatusDetail: statusElement()
  };
  const context = vm.createContext({
    console,
    Date,
    Promise,
    Array,
    Object,
    String,
    Number,
    CURRENT_SETTINGS_CACHE: { BOOT_ENABLED: options.bootPreference ?? '1' },
    PATHS: { SERVICE_STATUS: '/status.json' },
    _svcStatusRequestSequence: 0,
    _svcStatusRefreshActive: false,
    _svcSettingsLoadState: 'ready',
    _svcTransactionActive: false,
    _svcLastStatusData: null,
    document: { getElementById(id) { return elements[id] || null; } },
    appendCliText() {},
    triggerAction: options.triggerAction || (async () => false),
    fetch: options.fetch || (async () => { throw new Error('status endpoint unavailable'); }),
    setTimeout(callback) { callback(); return 1; },
    clearTimeout() {}
  });
  ['setServiceStatusRefreshMessage', 'updateBootStatusLineFromCache', 'renderServiceStatusHtml']
    .forEach(name => vm.runInContext(extractFunction(name), context));
  vm.runInContext('async ' + extractFunction('refreshServiceStatus'), context);
  return { context, elements };
}

const { context: uiContext, elements: ui } = makeStatusUi();
uiContext.updateBootStatusLineFromCache({ pending: true });
equal(ui.svcBootPreferenceLine.textContent, 'Apply on Boot: Enabled', "summary names the user's Apply on Boot preference");
equal(ui.svcBootStatusLine.textContent, '○ Boot startup: Checking…', 'initial status is neutral while verification is pending');
expect(ui.svcBootStatusLine.className.includes('svc-status-neutral'), 'pending startup has no healthy styling');
expect(source.includes('void refreshServiceStatus(refreshBtn, { initial: true });'), 'first modal load starts the initial read-only status refresh');
expect(source.includes("setServiceSettingsLoadState('ready', '');"), 'Settings JSON completion does not leave a stale success message during status refresh');
pass('initial boot status remains Checking until verification completes');

const mainHealthyHtml = uiContext.renderServiceStatusHtml({
  ts: '12:00:00',
  main: { hw: 'RT-AX88U', boot: 'enabled', manager_hook: 'present', addon: 'active', event: 'active', cron: 'present', mac: 'on(12)' }
});
for (const label of [
  'Apply on Boot: Enabled', 'Boot startup: Ready', 'Event handler: Active',
  'Health check: Active', 'MAC Shield: On (12)', 'Runtime integration: Active'
]) expect(mainHealthyHtml.includes(label), `MAIN healthy status renders ${label}`);
for (const raw of ['manager_hook', 'present', 'addon: active', 'event: active', 'cron: present', 'mac on(12)']) {
  expect(!mainHealthyHtml.includes(raw), `MAIN display does not leak raw status token ${raw}`);
}
pass('MAIN boot and runtime values render as readable labels');

const nodeHealthyHtml = uiContext.renderServiceStatusHtml({
  main: { boot: 'enabled', manager_hook: 'present', addon: 'active', event: 'active', cron: 'present', mac: 'off' },
  nodes: [{ ip: '192.0.2.11', boot: 'enabled', manager_hook: 'present', addon: 'node-on', event: 'active', cron: 'present', mac: 'off' }]
});
for (const label of ['Apply on Boot: Enabled', 'Boot startup: Ready', 'Node integration: Active', 'Health check: Active']) {
  expect(nodeHealthyHtml.includes(label), `NODE healthy status renders ${label}`);
}
expect(!nodeHealthyHtml.includes('node-on'), 'node integration does not expose the backend enum');
pass('NODE integration and health states render as readable labels');

const disabledHtml = uiContext.renderServiceStatusHtml({
  main: { boot: 'disabled', manager_hook: 'absent', addon: 'active', event: 'active', cron: 'absent', mac: 'off' }
});
expect(disabledHtml.includes('Apply on Boot: Disabled'), 'disabled setting is explicit');
expect(disabledHtml.includes('Boot startup: Disabled'), 'expected absent startup hook is presented as disabled');
expect(disabledHtml.includes('Health check: Disabled'), 'expected absent health check is presented as disabled');
expect(!disabledHtml.includes('svc-status-bad'), 'expected OFF state has no red failure styling');
pass('disabled boot state is not presented as an integrity failure');

const mismatchHtml = uiContext.renderServiceStatusHtml({
  main: { boot: 'enabled', manager_hook: 'absent', addon: 'active', event: 'active', cron: 'present', mac: 'off' }
});
expect(mismatchHtml.includes('Boot startup: Missing'), 'enabled preference with an absent hook is clear');
expect(mismatchHtml.includes('svc-status-bad'), 'enabled preference mismatch is visibly unhealthy');
const invalidHtml = uiContext.renderServiceStatusHtml({
  main: { boot: 'enabled', manager_hook: 'invalid', addon: 'active', event: 'active', cron: 'present', mac: 'off' }
});
expect(invalidHtml.includes('Boot startup: Invalid') && invalidHtml.includes('svc-status-bad'), 'invalid hook remains visibly unhealthy');
const unknownHtml = uiContext.renderServiceStatusHtml({
  main: { boot: 'enabled', manager_hook: 'unknown', addon: 'active', event: 'unknown', cron: 'unknown', mac: 'unknown' }
});
expect(unknownHtml.includes('Boot startup: Unknown'), 'unknown hook remains explicit');
expect(unknownHtml.includes('svc-status-warning'), 'unknown hook and runtime states use warning styling');
expect(!unknownHtml.includes('Boot startup: Ready'), 'unknown hook cannot appear healthy');
pass('mismatch, invalid, and unknown verification states retain unhealthy or warning styling');

const bootOffUi = makeStatusUi({ bootPreference: '0' });
bootOffUi.context.updateBootStatusLineFromCache({ verified: true, managerHook: 'absent' });
equal(bootOffUi.elements.svcBootPreferenceLine.textContent, 'Apply on Boot: Disabled', 'summary shows OFF preference');
equal(bootOffUi.elements.svcBootStatusLine.textContent, '○ Boot startup: Disabled', 'summary does not mark expected OFF as missing');
expect(bootOffUi.elements.svcBootStatusLine.className.includes('svc-status-neutral'), 'expected OFF summary is neutral');

let releaseBaseline;
let successfulFetchCount = 0;
const refreshSuccess = makeStatusUi({
  fetch: async () => {
    successfulFetchCount++;
    if (successfulFetchCount === 1) {
      return await new Promise(resolve => { releaseBaseline = resolve; });
    }
    return { ok: true, json: async () => ({
      ts: 'fresh', main: { boot: 'enabled', manager_hook: 'present', addon: 'active', event: 'active', cron: 'present', mac: 'off' }
    }) };
  },
  triggerAction: async name => name === 'checkservice_vlanmgr'
});
refreshSuccess.elements.svcStatusRefreshMessage.textContent = 'Status refreshed';
const successButton = refreshSuccess.elements.svcStatusRefreshBtn;
const successRequest = refreshSuccess.context.refreshServiceStatus(successButton);
equal(refreshSuccess.elements.svcStatusRefreshMessage.textContent, 'Refreshing status…', 'manual refresh immediately replaces prior success text');
expect(successButton.disabled, 'Refresh button is disabled throughout the pending request');
releaseBaseline({ ok: true, json: async () => ({ ts: 'old' }) });
expect(await successRequest, 'fresh runtime report completes successfully');
equal(refreshSuccess.elements.svcStatusRefreshMessage.textContent, 'Status refreshed', 'runtime report owns refresh success feedback');
expect(!successButton.disabled, 'Refresh button is re-enabled after success');
equal(refreshSuccess.elements.svcBootStatusLine.textContent, '● Boot startup: Ready', 'success replaces Checking with verified Ready');
pass('Refresh transitions Checking to refreshed and re-enables the button');

const refreshFailure = makeStatusUi({
  fetch: async () => ({ ok: true, json: async () => ({ ts: 'old' }) }),
  triggerAction: async () => false
});
const failureButton = refreshFailure.elements.svcStatusRefreshBtn;
expect(!await refreshFailure.context.refreshServiceStatus(failureButton), 'rejected runtime check reports failure');
equal(refreshFailure.elements.svcStatusRefreshMessage.textContent, 'Status refresh failed', 'runtime action failure has explicit failure feedback');
expect(!failureButton.disabled, 'Refresh button is re-enabled after failure');
equal(refreshFailure.elements.svcBootStatusLine.textContent, '● Boot startup: Unknown', 'failed refresh does not retain a previous green state');
equal(refreshFailure.context._svcLastStatusData, null, 'failed refresh clears stale detail for later modal opens');
pass('failed Refresh clears stale success and re-enables the button');

// Keep the Settings modal pinned to the visible addon area while its content
// grows. Only the body scrolls; native scroll chaining remains available.
const settingsLayoutCss = source.slice(source.indexOf('/* ---- modal rows ---- */'), source.indexOf('/* ---- status bar and detail panel ---- */'));
const modalCss = settingsLayoutCss.slice(settingsLayoutCss.indexOf('#serviceSettingsModal {'));
expect(modalCss.includes('height: 100vh') && modalCss.includes('max-height: 100vh'), 'Settings modal has a full-height viewport fallback');
expect(modalCss.includes('height: 100dvh') && modalCss.includes('max-height: 100dvh'),
  'Settings modal uses the full dynamic mobile viewport when available');
expect(modalCss.includes('flex: 1 1 auto') && modalCss.includes('min-height: 0') && modalCss.includes('overflow-y: auto'),
  'expanded Settings content is the modal scroll area');
expect(modalCss.includes('flex: 0 0 auto'), 'modal header and footer retain their height while content scrolls');
expect(!modalCss.includes('overscroll-behavior'), 'modal body leaves native scroll chaining enabled at its boundaries');
const clientWheelHandler = extractFunction('setupClientsWheelScroll');
expect(clientWheelHandler.includes("document.querySelector('.clients-body')") && !clientWheelHandler.includes('serviceSettingsModal'),
  'existing custom wheel handling remains limited to the client list');
const modalMarkup = source.slice(source.indexOf('<div id="serviceSettingsModal"'), source.indexOf('<!-- ======== Development-only Developer Tools Modal ========'));
const headerIndex = modalMarkup.indexOf('class="modal__header"');
const bodyIndex = modalMarkup.indexOf('class="modal__body"');
const footerIndex = modalMarkup.indexOf('class="modal__actions"');
expect(headerIndex >= 0 && bodyIndex > headerIndex && footerIndex > bodyIndex, 'header, scrollable body, and action footer remain in that order');
expect(source.includes("modal.style.display = 'flex';"), 'Settings modal opens as a flex column');
expect(source.includes("const isServiceSettingsModal = modal.id === 'serviceSettingsModal';"), 'Settings modal uses its dedicated addon-area anchor sizing');
expect(source.includes('const settingsHeight = Math.max(0, Math.floor(visibleAreaHeight));') &&
  source.includes('modal.style.height = `${settingsHeight}px`;') && source.includes('visibleTop - formRect.top);'),
  'Settings modal height and top/bottom alignment use the visible addon area');
expect(source.includes("modal.style.height = '';"), 'closing an anchored modal clears its temporary fixed height');

function anchorSettingsModal(intrinsicHeight,
  formRect = { top: -20, bottom: 600, left: 20, right: 560, width: 540, height: 620 },
  viewportHeight = 500) {
  const form = {
    getBoundingClientRect() { return formRect; },
    classList: { contains() { return false; } },
    clientWidth: 540
  };
  const modal = {
    id: 'serviceSettingsModal',
    parentElement: form,
    offsetHeight: intrinsicHeight,
    style: {},
    classList: { add() {} },
    getBoundingClientRect() { return { height: intrinsicHeight }; }
  };
  const anchorContext = vm.createContext({
    MODAL_SAFE_MARGIN: 24,
    anchoredModal: null,
    observeAnchoredModal() {},
    requestAnimationFrame(callback) { callback(); },
    window: { innerHeight: viewportHeight, scrollX: 0, scrollY: 0 },
    document: {
      querySelector() { return form; },
      documentElement: { clientHeight: viewportHeight, scrollLeft: 0, scrollTop: 0 }
    }
  });
  vm.runInContext(extractFunction('anchorModalToForm'), anchorContext);
  anchorContext.anchorModalToForm(modal);
  return modal;
}

const compactModal = anchorSettingsModal(340);
const expandedModal = anchorSettingsModal(1100);
equal(compactModal.style.height, '500px', 'Settings modal fills the entire visible addon height');
equal(compactModal.style.maxHeight, '500px', 'Settings modal height is capped to the full visible addon area');
equal(compactModal.style.top, '20px', 'Settings modal top is latched to the visible addon boundary');
const anchoredTop = -20 + Number.parseFloat(compactModal.style.top);
const anchoredBottom = anchoredTop + Number.parseFloat(compactModal.style.height);
equal(anchoredTop, 0, 'Settings modal reaches the visible addon top without a gap');
equal(anchoredBottom, 500, 'Settings modal reaches the visible addon bottom without a gap');
equal(expandedModal.style.height, compactModal.style.height, 'expanded runtime status does not resize the modal');
equal(expandedModal.style.top, compactModal.style.top, 'expanded runtime status does not move the modal');
const addonBoundedModal = anchorSettingsModal(800,
  { top: 80, bottom: 430, left: 20, right: 560, width: 540, height: 350 }, 500);
equal(addonBoundedModal.style.height, '350px', 'shorter addon form bounds modal height below the viewport height');
equal(addonBoundedModal.style.top, '0px', 'modal starts at the addon form top when it is inside the viewport');
equal(80 + Number.parseFloat(addonBoundedModal.style.top), 80, 'modal reaches the addon top edge');
equal(80 + Number.parseFloat(addonBoundedModal.style.top) + Number.parseFloat(addonBoundedModal.style.height), 430,
  'modal reaches the addon bottom edge');
pass('Settings modal fills stable addon height edge-to-edge with reachable header and actions');

const settingsRowsCss = settingsLayoutCss.slice(settingsLayoutCss.indexOf('.svc-settings-row {'), settingsLayoutCss.indexOf('#serviceSettingsModal {'));
expect(settingsRowsCss.includes('gap: 12px') && settingsRowsCss.includes('flex: 1 1 auto') && settingsRowsCss.includes('min-width: 0'),
  'Settings descriptions can use more of the available row width');
expect(settingsLayoutCss.includes('padding: 16px;'), 'desktop Settings modal reduces horizontal inset while retaining readable padding');
expect(source.includes('padding: 14px 10px;'), 'narrow-screen Settings layout retains compact readable side padding');
expect(settingsRowsCss.includes('font-size: 0.81em') && settingsRowsCss.includes('font-weight: 400') &&
  settingsRowsCss.includes('color: #777') && settingsRowsCss.includes('line-height: 1.35'),
  'all Settings descriptions share the same typography');
const pauseSection = modalMarkup.slice(modalMarkup.indexOf('<!-- Pause Event Reactions -->'), modalMarkup.indexOf('<!-- Experimental Features -->'));
const pauseDescription = 'Temporarily pauses automatic MerVLAN event handling to prevent repeated rebuilds during ASUS setting changes. Resets on reboot. Sync Nodes afterward to apply it to nodes.';
expect(pauseSection.includes(`<span class="svc-settings-hint">${pauseDescription}</span>`), 'Pause event reactions uses the requested concise description');
expect(!pauseSection.includes('style=') && (pauseSection.match(/class="svc-settings-hint"/g) || []).length === 1,
  'Pause description uses the shared hint style without a special inline override');
expect(settingsRowsCss.includes('overflow-wrap: anywhere'), 'long descriptions wrap inside the widened settings column');
pass('Settings rows use more width and Pause event reactions matches shared description styling');

console.log('SERVICE_SETTINGS_BEHAVIOR_OK');
