#!/bin/sh
# Source-level offline contract for R4 authoritative settings and fail-closed
# Apply routing.  Browser execution is intentionally separate: this project
# has no local JavaScript runtime in the supported test environment.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$BASE_DIR/www/index.html"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

. "$TEST_DIR/js_source_helpers.sh"

require() {
    grep -Fq "$1" "$UI_FILE" || fail "$2"
}

require "SETTINGS_AUTHORITY_STATE = 'unknown'" 'explicit unknown authority state missing'
require "SETTINGS_AUTHORITY_CACHE_GENERATION" 'authoritative cache generation missing'
require "function beginSettingsAuthorityLoad()" 'settings load generation helper missing'
require "function invalidateSettingsAuthority" 'failure/clear invalidation helper missing'
require "function commitSettingsAuthority" 'authoritative success commit helper missing'
require "loadGeneration !== SETTINGS_AUTHORITY_GENERATION" 'stale settings response guard missing'
require "settings.json is not valid JSON." 'malformed settings terminal failure missing'
require "settings.json did not contain a settings object." 'non-object settings failure missing'
require "visible values are not submittable" 'failed-load recovery guidance missing'
require "Settings are unavailable. Click Load to retry before" 'Save/Apply authority gate message missing'
require "Loading settings... Save and Apply are paused." 'settings loading wording missing'
require "Settings loaded. Nodes are configured." 'configured-node success wording missing'
require "Settings loaded. No nodes configured." 'no-node success wording missing'
require "Settings loaded, but the node configuration is invalid. Apply is unavailable." 'invalid-node success wording missing'
require "SETTINGS_AUTHORITY_STATUS_HIDE_TIMER" 'success status hide timer missing'
require "SETTINGS_AUTHORITY_STATUS_GENERATION" 'success status generation guard missing'
require "status.classList.add('is-fading')" 'success status fade missing'
require "const SETTINGS_STATUS_SUCCESS_HOLD_MS = 4000;" 'named success status hold constant missing'
require "const SETTINGS_STATUS_FADE_OUT_MS = 400;" 'named success status fade constant missing'
require "const successDelay = SETTINGS_STATUS_SUCCESS_HOLD_MS + SETTINGS_STATUS_FADE_IN_MS" 'success status delay does not derive from named constants'
require "}, SETTINGS_STATUS_FADE_OUT_MS);" 'success status fade duration does not use named constant'
require "return getSettingsNodeState();" 'configured/none node state is explicit'
require "return 'unknown';" 'unknown node state is explicit'
require "Apply blocked: authoritative settings or node state is unknown" 'unknown Apply must block'
require "getSettingsNodeState() !== 'configured'" 'node-aware Apply lacks configured guard'
require "function runConfirmedVlanManagerRoute" 'confirmed VLAN route helper missing'
require "showMaintenanceConfirmation(confirmationOptions)" 'VLAN route confirmation is not using the shared confirmation dialog'
require 'function confirmRecentMainApply()' 'MAIN Apply recent-run advisory is missing'
require 'MAIN_APPLY_ADVISORY: "tmp/results/main_apply_advisory.json"' 'MAIN Apply advisory path is missing'
require "confirmLabel: 'Apply Anyway'" 'recent MAIN Apply advisory is not an explicit override'
require "function classifyConfiguredNodes(settings)" 'tri-state node classifier missing'
require "return configured ? 'configured' : 'none';" 'empty/none node case does not remain explicit none'
require "A nonempty malformed node value is not equivalent to no nodes" 'malformed node case is not fail-closed'

if command -v node >/dev/null 2>&1; then
    node - "$UI_FILE" <<'NODE' || fail 'settings authority classifier behavior regression'
const fs = require('fs');
const vm = require('vm');
const file = process.argv[2];
const html = fs.readFileSync(file, 'utf8');

function extractFunction(name) {
    const declaration = new RegExp('(?:^|\\n)[\\t ]*function[\\t ]+' + name + '[\\t ]*\\(').exec(html);
    if (!declaration) throw new Error(name + ' declaration is missing');
    const start = declaration.index + declaration[0].indexOf('function');
    const open = html.indexOf('{', start);
    if (open < 0) throw new Error(name + ' body is missing');
    let depth = 0;
    let quote = null;
    let lineComment = false;
    let blockComment = false;
    for (let index = open; index < html.length; index += 1) {
        const ch = html[index];
        const next = html[index + 1];
        if (lineComment) {
            if (ch === '\n') lineComment = false;
            continue;
        }
        if (blockComment) {
            if (ch === '*' && next === '/') { blockComment = false; index += 1; }
            continue;
        }
        if (quote) {
            if (ch === '\\') { index += 1; continue; }
            if (ch === quote) quote = null;
            continue;
        }
        if (ch === '/' && next === '/') { lineComment = true; index += 1; continue; }
        if (ch === '/' && next === '*') { blockComment = true; index += 1; continue; }
        if (ch === '"' || ch === "'" || ch === String.fromCharCode(96)) { quote = ch; continue; }
        if (ch === '{') depth += 1;
        if (ch === '}' && --depth === 0) return html.slice(start, index + 1);
    }
    throw new Error(name + ' has an unterminated body');
}

const context = vm.createContext({ MAX_NODES: 10 });
vm.runInContext(extractFunction('classifyConfiguredNodes') +
    '\nglobalThis.classifyConfiguredNodes = classifyConfiguredNodes;', context);
const cases = [
    ['configured IPv4', { NODE1: '192.168.1.2' }, 'configured'],
    ['empty value', { NODE1: '' }, 'none'],
    ['none value', { NODE1: 'none' }, 'none'],
    ['malformed IPv4', { NODE1: '999.1.1.1' }, 'unknown'],
    ['unsupported hostname', { NODE1: 'router.local' }, 'unknown'],
    ['non-string value', { NODE1: 1234 }, 'unknown'],
    ['malformed settings object', [], 'unknown'],
    ['null settings object', null, 'unknown'],
    ['valid then malformed node', { NODE1: '192.168.1.2', NODE2: 'bad' }, 'unknown']
];
for (const item of cases) {
    const actual = context.classifyConfiguredNodes(item[1]);
    if (actual !== item[2]) throw new Error(item[0] + ': ' + actual + ' !== ' + item[2]);
}
console.log('SETTINGS_AUTHORITY_CLASSIFIER_BEHAVIOR_OK cases=9');
NODE
else
    classifier=$(extract_js_function classifyConfiguredNodes "$UI_FILE") || fail 'classifier function extraction failed'
    printf '%s\n' "$classifier" | grep -Fq "return 'unknown';" || fail 'malformed node fixture does not classify unknown'
    printf '%s\n' "$classifier" | grep -Fq "typeof raw !== 'string'" || fail 'non-string node fixture is not rejected before coercion'
    printf '%s\n' "$classifier" | grep -Fq "trimmed.toLowerCase() === \"none\"" || fail 'none node fixture is not recognized'
    printf '%s\n' "$classifier" | grep -Fq 'configured = true' || fail 'valid IPv4 node fixture is not recognized'
fi

loader=$(extract_js_function loadSettings "$UI_FILE") || fail 'settings loader function extraction failed'
[ "$(printf '%s\n' "$loader" | grep -Fc 'if (!mayCommit()) return false;')" -ge 4 ] || fail 'load publication guards are incomplete'

apply_block=$(extract_js_function handleApplyClick "$UI_FILE") || fail 'Apply handler extraction failed'
printf '%s\n' "$apply_block" | grep -Fq "nodeState === 'unknown'" || fail 'Apply does not branch on unknown node state'
printf '%s\n' "$apply_block" | grep -Fq "nodeState === 'configured'" || fail 'Apply does not branch on configured node state'

local_apply=$(extract_js_function runVlanManagerLocal "$UI_FILE") || fail 'Local Apply handler extraction failed'
printf '%s\n' "$local_apply" | grep -Fq "getSettingsNodeState() !== 'configured'" || fail 'Local Router Only does not require configured nodes'
printf '%s\n' "$local_apply" | grep -Fq 'runConfirmedVlanManagerRoute' || fail 'Local Router Only bypasses confirmation'
printf '%s\n' "$local_apply" | grep -Fq '}), true);' || fail 'Local Router Only does not request MAIN Apply advisory'

with_nodes_apply=$(extract_js_function runVlanManagerWithNodes "$UI_FILE") || fail 'Router + Nodes Apply handler extraction failed'
printf '%s\n' "$with_nodes_apply" | grep -Fq 'confirmRecentMainApply()' || fail 'Router + Nodes does not request MAIN Apply advisory'

nodes_only_apply=$(extract_js_function runVlanManagerOnlyNodes "$UI_FILE") || fail 'Nodes Only Apply handler extraction failed'
printf '%s\n' "$nodes_only_apply" | grep -Fq "getSettingsNodeState() !== 'configured'" || fail 'Nodes Only does not require configured nodes'
printf '%s\n' "$nodes_only_apply" | grep -Fq 'runConfirmedVlanManagerRoute' || fail 'Nodes Only bypasses confirmation'

printf 'SETTINGS_AUTHORITY_APPLY_CONTRACT_OK\n'
