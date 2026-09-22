#!/bin/sh
# Source contract for browser-owned persisted/working row status semantics.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require() {
  grep -Fq "$1" "$UI_FILE" || fail "$2"
}

require 'let PERSISTED_SETTINGS_FLAT_BASELINE = null;' 'separate persisted baseline missing'
require 'function updatePersistedSettingsBaseline(source)' 'baseline update helper missing'
require 'updatePersistedSettingsBaseline(CURRENT_SETTINGS_CACHE);' 'successful settings load does not refresh baseline'
require 'function refreshSsidStatus(index)' 'SSID status calculator missing'
require 'function refreshNodeStatus(index)' 'Node status calculator missing'
require 'function refreshLanStatus(index)' 'LAN status calculator missing'
require 'function refreshFormStatuses()' 'full status refresh missing'
grep -Eq 'function[[:space:]]+markEdited[[:space:]]*\([[:space:]]*index[[:space:]]*\)[[:space:]]*\{[[:space:]]*refreshFormStatuses\([[:space:]]*\);[[:space:]]*\}' "$UI_FILE" || fail 'markEdited does not derive current status'
require 'savedConfigured ? STATUS_SYMBOLS.changed : STATUS_SYMBOLS.empty' 'pending deletion/unconfigured distinction missing'
require 'STATUS_SYMBOLS.invalid' 'invalid row state missing'
require 'statusSnapshotEqual(current, saved) ? STATUS_SYMBOLS.saved : STATUS_SYMBOLS.changed' 'saved/reverted comparison missing'
require 'alias: normalizeStatusAlias' 'node alias is absent from status snapshot'
require 'const values = collectTrunkValues(index);' 'trunk state is absent from LAN snapshot'
require 'const key = getLanFlatKey(CURRENT_LAN_TARGET, index);' 'LAN status ignores the active target baseline'
require 'syncLanFieldsToCache(CURRENT_LAN_TARGET);' 'LAN target switch does not preserve working values'
require 'loadLanFieldsFromCache(CURRENT_LAN_TARGET);' 'LAN target switch does not restore working values'

clear_block=$(sed -n '/function[[:space:]]*clearFields[[:space:]]*()/,/const CLI_WELCOME_HTML/p' "$UI_FILE")
printf '%s\n' "$clear_block" | grep -Fq 'refreshFormStatuses();' || fail 'Clear does not recompute statuses'
! printf '%s\n' "$clear_block" | grep -Fq 'PERSISTED_SETTINGS_FLAT_BASELINE =' || fail 'Clear overwrites persisted baseline'
! printf '%s\n' "$clear_block" | grep -Fq 'textContent="❌"' || fail 'Clear still assigns blanket Missing status'

lan_load_block=$(sed -n '/function[[:space:]]*loadLanFieldsFromCache[[:space:]]*(/,/function[[:space:]]*updateLanTargetButtons/p' "$UI_FILE")
printf '%s\n' "$lan_load_block" | grep -Fq 'refreshFormStatuses();' || fail 'LAN cache load does not recalculate pending state'

fill_block=$(sed -n '/function[[:space:]]*fillFormFromSettings[[:space:]]*(/,/function[[:space:]]*deepEqualObjects/p' "$UI_FILE")
printf '%s\n' "$fill_block" | grep -Fq 'rebuildTrunkVlanOptionsFromSettings(flat);' || fail 'form load does not rebuild trunk state'
printf '%s\n' "$fill_block" | grep -Fq 'refreshFormStatuses();' || fail 'form load does not recalculate final statuses'

ssid_status_block=$(sed -n '/function[[:space:]]*refreshSsidStatus[[:space:]]*(/,/function[[:space:]]*refreshNodeStatus/p' "$UI_FILE")
lan_status_block=$(sed -n '/function[[:space:]]*refreshLanStatus[[:space:]]*(/,/function[[:space:]]*refreshWanNativeStatus/p' "$UI_FILE")
! printf '%s\n' "$ssid_status_block" | grep -Fq 'classList.contains("duplicate")' || fail 'SSID duplicate overrides normal row status'
! printf '%s\n' "$lan_status_block" | grep -Fq 'classList.contains("duplicate")' || fail 'LAN duplicate overrides normal row status'

printf 'VLAN_STATUS_CONTRACT_OK\n'
