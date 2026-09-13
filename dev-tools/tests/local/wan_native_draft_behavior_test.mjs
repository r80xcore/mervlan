// Behavioral regression test for the WAN Native node popup draft model.
// Run with: node dev-tools/tests/local/wan_native_draft_behavior_test.mjs
// This evaluates the production popup functions with a small DOM fixture; it
// does not contact a router or load a browser.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const html = await readFile(path.join(root, 'www/index.html'), 'utf8');
const start = html.indexOf('        let WAN_NATIVE_POPUP_STATE = null;');
const end = html.indexOf('\n\n  function pollOnce(){', start);
assert.ok(start >= 0 && end > start, 'could not locate production WAN Native popup functions');
const productionPopup = html.slice(start, end);

function validIp(value) {
  const parts = String(value || '').split('.');
  return parts.length === 4 && parts.every(part => /^\d+$/.test(part) && +part >= 0 && +part <= 255);
}

function createHarness(cache, target = 'NODE1') {
  const elements = new Map();
  const roleControls = new Map();
  const edited = [];
  let conflict = false;
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', disabled: false, textContent: '', hidden: false,
      style: { display: '' }
    });
    return elements.get(id);
  };
  for (const id of [
    'wanNativeConfigPopup', 'wanNativePopupTitle', 'wanNativePopupTarget',
    'wanNativePopupRequirement', 'wanNativePopupVlan', 'wanNativePopupRole',
    'wanNativePopupNativeIp', 'wanNativePopupAsusIp', 'wanNativePopupNodeIp',
    'wanNativePopupError', 'wanNativePopupNativeIpRow', 'wanNativePopupAsusIpRow',
    'wanNativePopupNodeIpRow', 'wanNativePopupRoleRow', 'wanNativePopupNodeAsusRow',
    'wanNativePopupNodeAsusIp'
  ]) element(id);
  const document = {
    getElementById: element,
    querySelector(selector) {
      const nodeInput = selector.match(/^input\[name="(NODE\d+)"\]$/);
      if (nodeInput) return { value: cache[nodeInput[1]] || '' };
      const label = selector.match(/^\.node-label\[data-node-index="(\d+)"\]$/);
      if (label) return { textContent: `Node ${label[1]}` };
      return null;
    },
    querySelectorAll(selector) {
      const role = selector.match(/^\[data-node-role="(\d+)"\]$/);
      if (!role) return [];
      const slot = role[1];
      if (!roleControls.has(slot)) roleControls.set(slot, { value: '' });
      return [roleControls.get(slot)];
    }
  };
  const context = vm.createContext({
    document,
    CURRENT_SETTINGS_CACHE: cache,
    CURRENT_LAN_TARGET: target,
    console,
    String,
    Number,
    normalizeNodeRole: (value, fallback = 'standalone') => {
      const role = String(value || '').trim().toLowerCase();
      return role === 'aimesh' || role === 'standalone' ? role : fallback;
    },
    statusNodeIpIsValid: validIp,
    managedVlanNumber: value => {
      const raw = String(value || '').trim();
      return /^\d+$/.test(raw) && +raw >= 2 && +raw <= 4094 ? +raw : null;
    },
    getWanNativeFlatKey: value => value === 'main' ? 'WAN_NATIVE_MAIN' : `WAN_NATIVE_${value}`,
    wanNativeConflictsWithTarget: () => conflict,
    sanitizeNodeAlias: (_value, slot) => `Node ${slot}`,
    syncLanFieldsToCache: () => {},
    updateWanNativeSummary: () => {},
    markEdited: key => edited.push(key),
    refreshFormStatuses: () => {},
    syncInfoLatchVisibility: () => {},
    anchorModalToForm: () => {},
    releaseAnchoredModal: () => {}
  });
  vm.runInContext(`${productionPopup}\nglobalThis.__wanPopup = { openWanNativeConfigPopup, handleWanNativePopupRoleChange, handleWanNativePopupVlanInput, saveWanNativeConfig, cancelWanNativeConfig, state: () => WAN_NATIVE_POPUP_STATE };`, context);
  return {
    cache,
    element,
    edited,
    open: () => context.__wanPopup.openWanNativeConfigPopup(),
    role: value => { element('wanNativePopupRole').value = value; context.__wanPopup.handleWanNativePopupRoleChange(); },
    vlan: value => { element('wanNativePopupVlan').value = value; context.__wanPopup.handleWanNativePopupVlanInput(); },
    save: () => context.__wanPopup.saveWanNativeConfig(),
    cancel: () => context.__wanPopup.cancelWanNativeConfig(),
    setConflict: value => { conflict = value; },
    state: () => context.__wanPopup.state(),
    roleControl: slot => roleControls.get(String(slot))
  };
}

function nodeCache(slot = 1, { main = '190', own = '200', role = 'aimesh', nodeIp = '192.168.190.201' } = {}) {
  return {
    WAN_NATIVE_MAIN: main,
    [`WAN_NATIVE_NODE${slot}`]: own,
    [`NODE${slot}`]: `192.168.186.${200 + slot}`,
    [`NODE${slot}_ROLE`]: role,
    [`NODE${slot}_WAN_NATIVE_IP`]: nodeIp
  };
}

// 1–5: inherited display and retained Standalone draft across repeated role toggles.
{
  const h = createHarness(nodeCache());
  h.open();
  assert.equal(h.element('wanNativePopupVlan').value, '190');
  assert.equal(h.element('wanNativePopupVlan').disabled, true);
  h.role('standalone');
  assert.equal(h.element('wanNativePopupVlan').value, '200');
  assert.equal(h.element('wanNativePopupVlan').disabled, false);
  h.role('aimesh');
  assert.equal(h.element('wanNativePopupVlan').value, '190');
  assert.equal(h.element('wanNativePopupVlan').disabled, true);
  h.role('standalone');
  assert.equal(h.element('wanNativePopupVlan').value, '200');
  h.vlan('201');
  h.role('aimesh');
  h.role('standalone');
  assert.equal(h.element('wanNativePopupVlan').value, '201');
}

// 6: Cancel is draft-only and leaves authoritative cache unchanged.
{
  const cache = nodeCache();
  const before = JSON.stringify(cache);
  const h = createHarness(cache);
  h.open(); h.role('standalone'); h.vlan('201'); h.cancel();
  assert.equal(JSON.stringify(cache), before);
}

// 7–8 and 13–14: AiMesh Save retains dormant VID; Standalone Save writes only
// the draft, synchronizes the shared role control, and survives a reopen.
{
  const aimesh = nodeCache();
  const h = createHarness(aimesh);
  h.open(); h.save();
  assert.equal(aimesh.WAN_NATIVE_NODE1, '200');
  assert.ok(!h.edited.includes('WAN_NATIVE_NODE1'));

  const standalone = nodeCache();
  const s = createHarness(standalone);
  s.open(); s.role('standalone'); s.vlan('201'); s.save();
  assert.equal(standalone.WAN_NATIVE_MAIN, '190');
  assert.equal(standalone.WAN_NATIVE_NODE1, '201');
  assert.equal(standalone.NODE1_ROLE, 'standalone');
  assert.equal(s.roleControl(1).value, 'standalone');
  const reopened = createHarness(standalone);
  reopened.open();
  assert.equal(reopened.element('wanNativePopupVlan').value, '201');
}

// 9–11: ASUS/default inheritance, conflict rejection, and node-reservation validation.
{
  const asus = createHarness(nodeCache(1, { main: 'none' }));
  asus.open();
  assert.equal(asus.element('wanNativePopupVlan').value, '');
  assert.equal(asus.element('wanNativePopupVlan').disabled, true);

  const conflictCache = nodeCache();
  const conflict = createHarness(conflictCache);
  conflict.setConflict(true); conflict.open(); conflict.save();
  assert.match(conflict.element('wanNativePopupError').textContent, /Use a VLAN ID/);
  assert.equal(conflictCache.WAN_NATIVE_NODE1, '200');

  const invalidReservation = nodeCache(1, { nodeIp: 'none' });
  const reservation = createHarness(invalidReservation);
  reservation.open(); reservation.save();
  assert.match(reservation.element('wanNativePopupError').textContent, /WAN Native DHCP reservation/);
  assert.equal(invalidReservation.WAN_NATIVE_NODE1, '200');
}

// 12: the same draft model works for every supported node slot.
for (let slot = 1; slot <= 10; slot++) {
  const own = String(200 + slot);
  const h = createHarness(nodeCache(slot, { own }), `NODE${slot}`);
  h.open();
  assert.equal(h.element('wanNativePopupVlan').value, '190');
  h.role('standalone');
  assert.equal(h.element('wanNativePopupVlan').value, own);
}

console.log('WAN_NATIVE_DRAFT_BEHAVIOR_OK');
