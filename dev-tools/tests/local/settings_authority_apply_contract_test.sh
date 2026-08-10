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
require "Authoritative settings are unavailable; click Load to retry" 'Save/Apply authority gate message missing'
require "return getSettingsNodeState();" 'configured/none node state is explicit'
require "return 'unknown';" 'unknown node state is explicit'
require "Apply blocked: authoritative settings or node state is unknown" 'unknown Apply must block'
require "getSettingsNodeState() !== 'none'" 'local Apply lacks explicit none guard'
require "getSettingsNodeState() !== 'configured'" 'node-aware Apply lacks configured guard'
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

printf 'SETTINGS_AUTHORITY_APPLY_CONTRACT_OK\n'
