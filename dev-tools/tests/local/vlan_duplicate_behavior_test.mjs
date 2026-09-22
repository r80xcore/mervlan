// Focused browser-logic regression coverage for VLAN duplicate detection and
// row-status behavior. This uses the functions from index.html with a minimal
// DOM model, so it requires no browser or added dependency.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const html = await readFile(path.join(root, 'www/index.html'), 'utf8');

function sourceFunction(name) {
  const start = html.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} is missing`);
  const bodyStart = html.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < html.length; index += 1) {
    if (html[index] === '{') depth += 1;
    if (html[index] === '}' && --depth === 0) return html.slice(start, index + 1);
  }
  throw new Error(`${name} has an unterminated body`);
}

function field(name, value) {
  const classes = new Set();
  return {
    name,
    value,
    title: '',
    classList: {
      add: (...values) => values.forEach(value => classes.add(value)),
      remove: (...values) => values.forEach(value => classes.delete(value)),
      contains: value => classes.has(value)
    }
  };
}

function validatorEnvironment({ fields, cache = {}, tagged = [], untagged = [] }) {
  const document = {
    querySelectorAll(selector) {
      if (selector === 'input[name*="VLAN"], input[name*="_ETH"][name*="_VLAN"]') return fields;
      if (selector === 'select[name^="TAGGED_TRUNK"]') return tagged;
      if (selector === 'select[name^="UNTAGGED_TRUNK"]') return untagged;
      throw new Error(`unexpected selector: ${selector}`);
    },
    querySelector(selector) {
      if (selector === 'input[name*="_ETH"][name*="_VLAN"]') return fields.find(item => /^(?:NODE\d+_)?ETH\d+_VLAN$/.test(item.name)) || null;
      throw new Error(`unexpected selector: ${selector}`);
    }
  };
  const context = {
    document,
    CURRENT_SETTINGS_CACHE: cache,
    TOOLTIP: { VLAN: 'Enter VLAN ID (2–4094).' },
    CUSTOM_VLAN_OPTION_VALUE: '__custom__',
    managedVlanNumber(value) {
      const text = String(value).trim();
      return /^\d+$/.test(text) && Number(text) >= 2 && Number(text) <= 4094 ? Number(text) : null;
    },
    duplicateVlanTooltip: () => 'Duplicate VLAN ID; reuse is allowed when intentional.',
    refreshFormStatuses: () => {}
  };
  vm.createContext(context);
  vm.runInContext(sourceFunction('validateAllVlans'), context);
  return context;
}

function validate(options) {
  const context = validatorEnvironment(options);
  context.validateAllVlans();
  return options.fields;
}

// Unrelated current/future numeric settings never become cached VLAN candidates.
let fields = [field('VLAN_01', '30')];
validate({ fields, cache: { HTML_CLIENT_REFRESH_MINUTES: '30' } });
assert.equal(fields[0].classList.contains('duplicate'), false, 'refresh interval must not duplicate VLAN 30');

fields = [field('VLAN_01', '2')];
validate({ fields, cache: { NODE_PARALLELISM: '2' } });
assert.equal(fields[0].classList.contains('duplicate'), false, 'node parallelism must not duplicate VLAN 2');

// Visible SSID/LAN, cached inactive LAN, and both trunk types remain sources.
fields = [field('VLAN_01', '30'), field('ETH1_VLAN', '30')];
validate({ fields });
assert.ok(fields.every(item => item.classList.contains('duplicate')), 'visible SSID/LAN duplicate must be marked');

fields = [field('ETH1_VLAN', '30')];
validate({ fields, cache: { NODE1_ETH1_VLAN: '30' } });
assert.ok(fields[0].classList.contains('duplicate'), 'inactive node LAN VLAN must be considered');

fields = [field('ETH1_VLAN', '30')];
validate({ fields, tagged: [{ options: [{ selected: true, value: '30' }] }] });
assert.ok(fields[0].classList.contains('duplicate'), 'tagged trunk VLAN must be considered');

fields = [field('ETH1_VLAN', '30')];
validate({ fields, untagged: [{ value: '30' }] });
assert.ok(fields[0].classList.contains('duplicate'), 'untagged trunk VLAN must be considered');

fields = [field('ETH1_VLAN', '30')];
validate({ fields, cache: { NODE1_ETH1_VLAN: '30' } });
assert.ok(fields[0].classList.contains('duplicate'));
validate({ fields, cache: {} });
assert.equal(fields[0].classList.contains('duplicate'), false, 'removing a duplicate must clear the field marker');
assert.equal(fields[0].title, 'Enter VLAN ID (2–4094).', 'removing a duplicate must restore the standard field tooltip');

function statusEnvironment(currentSsid, savedSsid, currentLan, savedLan) {
  const statuses = {};
  const context = {
    STATUS_SYMBOLS: { saved: '✅', empty: '❎', changed: '🟩', invalid: '❌' },
    currentSsidStatusSnapshot: () => currentSsid,
    persistedSsidStatusSnapshot: () => savedSsid,
    currentLanStatusSnapshot: () => currentLan,
    persistedLanStatusSnapshot: () => savedLan,
    managedVlanNumber(value) {
      const text = String(value).trim();
      return /^\d+$/.test(text) && Number(text) >= 2 && Number(text) <= 4094 ? Number(text) : null;
    },
    statusTrunkListIsValid: () => true,
    statusSnapshotEqual: (left, right) => JSON.stringify(left) === JSON.stringify(right),
    setStatusSymbol: (id, symbol) => { statuses[id] = symbol; }
  };
  vm.createContext(context);
  vm.runInContext(sourceFunction('refreshSsidStatus'), context);
  vm.runInContext(sourceFunction('refreshLanStatus'), context);
  return { context, statuses };
}

const savedSsid = { ssid: 'Guest', vlan: '30', apiso: '0', assignments: 'none' };
const savedLan = { vlan: '30', trunk: { enabled: '0', tagged: 'none', untagged: 'none' } };
let status = statusEnvironment(savedSsid, savedSsid, savedLan, savedLan);
status.context.refreshSsidStatus(1);
status.context.refreshLanStatus(1);
assert.equal(status.statuses.status1, '✅', 'saved duplicate SSID keeps saved row status');
assert.equal(status.statuses.statusLAN1, '✅', 'saved duplicate LAN keeps saved row status');

status = statusEnvironment({ ...savedSsid, vlan: '30' }, { ...savedSsid, vlan: '20' }, savedLan, { ...savedLan, vlan: '20' });
status.context.refreshSsidStatus(1);
status.context.refreshLanStatus(1);
assert.equal(status.statuses.status1, '🟩', 'unsaved duplicate SSID remains pending');
assert.equal(status.statuses.statusLAN1, '🟩', 'unsaved duplicate LAN remains pending');

status = statusEnvironment({ ...savedSsid, vlan: 'invalid' }, savedSsid, { ...savedLan, vlan: 'invalid' }, savedLan);
status.context.refreshSsidStatus(1);
status.context.refreshLanStatus(1);
assert.equal(status.statuses.status1, '❌', 'invalid SSID VLAN keeps error status priority');
assert.equal(status.statuses.statusLAN1, '❌', 'invalid LAN VLAN keeps error status priority');

console.log('VLAN_DUPLICATE_BEHAVIOR_OK');
