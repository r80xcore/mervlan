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
require "function classifyConfiguredNodes(settings)" 'tri-state node classifier missing'
require "return configured ? 'configured' : 'none';" 'empty/none node case does not remain explicit none'
require "A nonempty malformed node value is not equivalent to no nodes" 'malformed node case is not fail-closed'

classifier=$(sed -n '/^    function classifyConfiguredNodes(settings)/,/^    function hasConfiguredNodes/p' "$UI_FILE")
printf '%s\n' "$classifier" | grep -Fq "return 'unknown';" || fail 'malformed node fixture does not classify unknown'
printf '%s\n' "$classifier" | grep -Fq "typeof raw !== 'string'" || fail 'non-string node fixture is not rejected before coercion'
printf '%s\n' "$classifier" | grep -Fq "trimmed.toLowerCase() === \"none\"" || fail 'none node fixture is not recognized'
printf '%s\n' "$classifier" | grep -Fq 'configured = true' || fail 'valid IPv4 node fixture is not recognized'

loader=$(sed -n '/^    async function loadSettings(opts = {}){/,/^    function toNone/p' "$UI_FILE")
[ "$(printf '%s\n' "$loader" | grep -Fc 'if (!mayCommit()) return false;')" -ge 4 ] || fail 'load publication guards are incomplete'

apply_block=$(sed -n '/^async function handleApplyClick(button)/,/^\/\/ Run VLAN Manager locally only/p' "$UI_FILE")
printf '%s\n' "$apply_block" | grep -Fq "nodeState === 'unknown'" || fail 'Apply does not branch on unknown node state'
printf '%s\n' "$apply_block" | grep -Fq "nodeState === 'configured'" || fail 'Apply does not branch on configured node state'

local_apply=$(sed -n '/^async function runVlanManagerLocal(button)/,/^\/\/ Run VLAN Manager with nodes/p' "$UI_FILE")
printf '%s\n' "$local_apply" | grep -Fq "getSettingsNodeState() !== 'configured'" || fail 'Local Router Only does not require configured nodes'
printf '%s\n' "$local_apply" | grep -Fq 'runConfirmedVlanManagerRoute' || fail 'Local Router Only bypasses confirmation'

nodes_only_apply=$(sed -n '/^async function runVlanManagerOnlyNodes(button)/,/^async function runMacRefresh/p' "$UI_FILE")
printf '%s\n' "$nodes_only_apply" | grep -Fq "getSettingsNodeState() !== 'configured'" || fail 'Nodes Only does not require configured nodes'
printf '%s\n' "$nodes_only_apply" | grep -Fq 'runConfirmedVlanManagerRoute' || fail 'Nodes Only bypasses confirmation'

printf 'SETTINGS_AUTHORITY_APPLY_CONTRACT_OK\n'
