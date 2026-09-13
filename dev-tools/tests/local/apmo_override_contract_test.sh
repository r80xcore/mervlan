#!/bin/sh
#
# Focused APMO / Hardware_Override contract test.
#
# Verifies the nested JSON reader with both the host awk and BusyBox awk when
# available. The fixture deliberately enables distinct MAIN and NODE1 maps so
# a target-selection regression cannot pass by reading the wrong subsection.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

TEST_ROOT="${TMPDIR:-/tmp}/mervlan-apmo-override.$(date +%s).$$"
FIXTURE="$TEST_ROOT/settings.json"
SET_FIXTURE="$TEST_ROOT/settings-set.json"
BB_BIN="$TEST_ROOT/busybox-bin"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    _expected="$1"
    _actual="$2"
    _label="$3"
    [ "$_actual" = "$_expected" ] || fail "$_label: expected '$_expected', got '$_actual'"
}

mkdir -p "$TEST_ROOT"
printf '%s\n' \
    '{' \
    '  "General": {' \
    '    "IS_NODE": "0",' \
    '    "NODE_ID": "none"' \
    '  },' \
    '  "Hardware_Override": {' \
    '    "MAIN": {' \
    '      "MAP_OVERRIDE": "1",' \
    '      "OVERRIDE_WAN": "eth5",' \
    '      "OVERRIDE_MAX_ETH_PORTS": "6",' \
    '      "OVERRIDE_LAN1": "eth1",' \
    '      "OVERRIDE_LAN2": "eth2",' \
    '      "OVERRIDE_LAN3": "eth3",' \
    '      "OVERRIDE_LAN4": "eth4",' \
    '      "OVERRIDE_LAN5": "eth0",' \
    '      "OVERRIDE_LAN6": "eth6"' \
    '    },' \
    '    "NODE1": {' \
    '      "MAP_OVERRIDE": "1",' \
    '      "OVERRIDE_WAN": "eth6",' \
    '      "OVERRIDE_MAX_ETH_PORTS": "2",' \
    '      "OVERRIDE_LAN1": "eth1",' \
    '      "OVERRIDE_LAN2": "eth2"' \
    '    }' \
    '  }' \
    '}' > "$FIXTURE"

LIB_JSON_LOADED=
. "$MERV_BASE/settings/lib_json.sh"

assert_eq "1" "$(json_get_section2_value Hardware_Override MAIN MAP_OVERRIDE "$FIXTURE")" \
    "host awk MAIN MAP_OVERRIDE"
assert_eq "eth5" "$(json_get_section2_value Hardware_Override MAIN OVERRIDE_WAN "$FIXTURE")" \
    "host awk MAIN WAN"
assert_eq "1" "$(json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$FIXTURE")" \
    "host awk NODE1 MAP_OVERRIDE"
assert_eq "eth6" "$(json_get_section2_value Hardware_Override NODE1 OVERRIDE_WAN "$FIXTURE")" \
    "host awk NODE1 WAN"

BUSYBOX=$(command -v busybox 2>/dev/null || true)
if [ -n "$BUSYBOX" ]; then
    mkdir -p "$BB_BIN"
    ln -s "$BUSYBOX" "$BB_BIN/awk" || fail "cannot create BusyBox awk shim"

    assert_eq "1" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override MAIN MAP_OVERRIDE "$FIXTURE")" \
        "BusyBox awk MAIN MAP_OVERRIDE"
    assert_eq "eth5" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override MAIN OVERRIDE_WAN "$FIXTURE")" \
        "BusyBox awk MAIN WAN"
    assert_eq "1" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$FIXTURE")" \
        "BusyBox awk NODE1 MAP_OVERRIDE"

    cp "$FIXTURE" "$SET_FIXTURE"
    PATH="$BB_BIN:$PATH" json_set_section2_value Hardware_Override NODE1 MAP_OVERRIDE 0 "$SET_FIXTURE" || \
        fail "BusyBox awk nested setter"
    assert_eq "0" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$SET_FIXTURE")" \
        "BusyBox awk setter/getter round trip"
else
    printf 'WARN: BusyBox awk unavailable; router-side compatibility portion skipped\n'
fi

# The modal must serialize per-device targets and reject duplicate interfaces
# before saving. These are source contracts for the browser-only validation.
grep -q 'function validateAdvancedOverrideDuplicates' "$MERV_BASE/www/index.html" || \
    fail "APMO duplicate validator missing"
grep -q 'Duplicate interface:' "$MERV_BASE/www/index.html" || \
    fail "APMO duplicate error missing"
grep -q 'if (!validateAdvancedOverrideDuplicates()) return;' "$MERV_BASE/www/index.html" || \
    fail "APMO apply does not enforce duplicate validation"
grep -q 'vlanmgr_OVERRIDE_${t}_MAP_OVERRIDE' "$MERV_BASE/www/index.html" || \
    fail "APMO per-device target serialization missing"
grep -Fq 'onclick="applyAdvancedOverride(false)"' "$MERV_BASE/www/index.html" || \
    fail "APMO explicit Save button missing"
grep -Fq 'onclick="applyAdvancedOverride(true)"' "$MERV_BASE/www/index.html" || \
    fail "APMO explicit Save & Refresh Hardware button missing"
grep -Fq 'function applyAdvancedOverride(refreshHardware)' "$MERV_BASE/www/index.html" || \
    fail "APMO explicit hardware-refresh action selector missing"
grep -Fq 'const wantHwProbe = refreshHardware === true;' "$MERV_BASE/www/index.html" || \
    fail "APMO hardware refresh no longer follows its explicit action"
if grep -Fq 'advOverrideAutoRefreshHw' "$MERV_BASE/www/index.html" || \
   grep -Fq 'toggleOverrideBtnText' "$MERV_BASE/www/index.html"; then
    fail "APMO retains obsolete transient auto-refresh controls"
fi
grep -Fq 'If it is disabled, run <strong>Sync Nodes</strong> manually after saving.' "$MERV_BASE/www/index.html" || \
    fail "APMO does not explain manual Sync Nodes when automatic sync is disabled"

# APMO actions retain the editor inside the addon form. The shared loading
# backdrop remains addon-local but positions its progress panel over APMO. The
# router acknowledgement is authoritative for the scoped Save; a delayed public
# fetch must not suppress the required follow-up.
REFRESH_FN=$(sed -n '/async function refreshHwProfile/,/async function checkForUpdates/p' "$MERV_BASE/www/index.html")
printf '%s\n' "$REFRESH_FN" | grep -q 'prepareAdvancedOverrideLoadingLayer();' || \
    fail "HW profile refresh does not align its APMO loading layer"
printf '%s\n' "$REFRESH_FN" | awk '/await loadSettings\(\);/ { loaded = NR } /refreshOpenAdvancedOverrideModalFromCache\(\);/ { refreshed = NR } END { exit !(loaded && refreshed && loaded < refreshed) }' || \
    fail "HW profile refresh does not rehydrate the open APMO editor"
if printf '%s\n' "$REFRESH_FN" | grep -q 'hideAdvancedOverrideModal();'; then
    fail "HW profile refresh incorrectly closes the APMO modal"
fi
APMO_MODAL_FN=$(sed -n '/function showAdvancedOverrideModal/,/function hideAdvancedOverrideModal/p' "$MERV_BASE/www/index.html")
printf '%s\n' "$APMO_MODAL_FN" | grep -Fq "try { formPane.appendChild(modal); } catch (e) { /* ignore */ }" || \
    fail "APMO does not share the addon form stacking context"
grep -Fq 'function prepareAdvancedOverrideLoadingLayer()' "$MERV_BASE/www/index.html" || \
    fail "APMO loading alignment helper missing"
grep -Fq 'function clearAdvancedOverrideLoadingPresentation()' "$MERV_BASE/www/index.html" || \
    fail "APMO loading presentation cleanup helper missing"
AUTO_SYNC_FN=$(sed -n '/async function autoSyncAdvancedOverrideNodes/,/async function applyOverrideWithHwProbe/p' "$MERV_BASE/www/index.html")
printf '%s\n' "$AUTO_SYNC_FN" | grep -q 'prepareAdvancedOverrideLoadingLayer();' || \
    fail "APMO automatic node sync does not align its loading layer"
if grep -Fq 'document.body.appendChild(backdrop)' "$MERV_BASE/www/index.html" || \
   grep -Fq 'body > .mervlan-loading-backdrop.mervlan-loading-backdrop--apmo' "$MERV_BASE/www/vlan_index_style.css"; then
    fail "APMO loading layer escapes addon-local ownership"
fi
grep -Fq '.mervlan-loading-backdrop.mervlan-loading-backdrop--apmo .mervlan-loading-panel' "$MERV_BASE/www/vlan_index_style.css" || \
    fail "APMO loader panel is not positioned over its modal"
grep -Fq 'left:var(--apmo-loader-center-x, 50%);' "$MERV_BASE/www/vlan_index_style.css" || \
    fail "APMO loader panel does not use the modal-relative horizontal center"
grep -Fq 'top:var(--apmo-loader-center-y, 50%);' "$MERV_BASE/www/vlan_index_style.css" || \
    fail "APMO loader panel does not use the modal-relative vertical center"
grep -Fq 'const modalIsInForm = modal.parentElement === form;' "$MERV_BASE/www/index.html" || \
    fail "form-owned APMO modal lacks form-relative anchoring"
grep -Fq 'function refreshOpenAdvancedOverrideModalFromCache(confirmedOverrides = null)' "$MERV_BASE/www/index.html" || \
    fail "APMO lacks post-action modal rehydration"
grep -Fq 'Object.prototype.hasOwnProperty.call(confirmedOverrides, key)' "$MERV_BASE/www/index.html" || \
    fail "APMO does not retain only acknowledged override keys during public-artifact lag"
grep -Fq 'function autoSyncAdvancedOverrideNodesEnabled()' "$MERV_BASE/www/index.html" || \
    fail "APMO lacks an authoritative post-reload automatic-sync check"
grep -Fq 'function configuredAdvancedOverrideTargets()' "$MERV_BASE/www/index.html" || \
    fail "APMO lacks configured-target payload selection"
ACK_WAIT_FN=$(sed -n '/async function waitForVerifiedActionResult/,/async function executeVerifiedServiceAction/p' "$MERV_BASE/www/index.html")
printf '%s\n' "$ACK_WAIT_FN" | grep -Fq 'PATHS.ACTION_RESULTS_DIR + encodeURIComponent(requestToken)' || \
    fail "correlated acknowledgement wait lacks the per-token result path"
printf '%s\n' "$ACK_WAIT_FN" | grep -Fq 'PATHS.ACTION_RESULT +' || \
    fail "correlated acknowledgement wait lacks the stable-result fallback"
printf '%s\n' "$ACK_WAIT_FN" | grep -Fq 'parsed.request_token === requestToken && parsed.action === actionName' || \
    fail "correlated acknowledgement fallback does not require exact token/action identity"
OVERRIDE_PAYLOAD_FN=$(sed -n '/function buildOverridePayloadForMerlin/,/function buildClientMetaPayloadForMerlin/p' "$MERV_BASE/www/index.html")
printf '%s\n' "$OVERRIDE_PAYLOAD_FN" | grep -Fq 'configuredAdvancedOverrideTargets().forEach(t => {' || \
    fail "APMO override payload includes unconfigured node slots"
if printf '%s\n' "$OVERRIDE_PAYLOAD_FN" | grep -Fq 'nodeTokens(true).forEach(t => {'; then
    fail "APMO override payload still serializes every node slot"
fi
if sed -n '/function applyAdvancedOverride/,/async function queueAutomaticNodeSettingsSync/p' "$MERV_BASE/www/index.html" | grep -q 'const autoSyncVal ='; then
    fail "APMO still decides automatic sync from the pre-save browser cache"
fi

for fn in applyOverrideWithHwProbe applyOverrideSaveOnly; do
    case "$fn" in
        applyOverrideWithHwProbe)
            FN_BODY=$(sed -n '/async function applyOverrideWithHwProbe/,/function extractOverrideSaveExpected/p' "$MERV_BASE/www/index.html")
            ;;
        applyOverrideSaveOnly)
            FN_BODY=$(sed -n '/async function applyOverrideSaveOnly/,/async function refreshHwProfile/p' "$MERV_BASE/www/index.html")
            ;;
    esac
    printf '%s\n' "$FN_BODY" | grep -q 'prepareAdvancedOverrideLoadingLayer();' || \
        fail "$fn does not elevate the APMO loading layer"
    printf '%s\n' "$FN_BODY" | awk '/clearFields\(\);/ { cleared = NR } /await loadSettings\(\);/ { loaded = NR } /refreshOpenAdvancedOverrideModalFromCache\(expectedManaged\);/ { refreshed = NR } END { exit !(cleared && loaded && refreshed && cleared < loaded && loaded < refreshed) }' || \
        fail "$fn does not perform the normal Load after clearing and before rehydrating APMO"
    printf '%s\n' "$FN_BODY" | awk '/await loadSettings\(\);/ { loaded = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(loaded && auto && loaded < auto) }' || \
        fail "$fn does not decide APMO automatic sync after the authoritative reload"
    printf '%s\n' "$FN_BODY" | awk '/loadingTask\.completion/ { completed = NR } /MerVLANLoading\.close\(\);/ { released = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(completed && released && auto && completed < released && released < auto) }' || \
        fail "$fn does not release its completed loader before starting automatic node sync"
    printf '%s\n' "$FN_BODY" | awk '/waitForVerifiedActionResult\(saveRequestToken/ { ack = NR } /waitForSettingsToMatch\(expectedManaged/ { persist = NR } END { exit !(ack && persist && ack < persist) }' || \
        fail "$fn trusts a public fetch before the correlated router acknowledgement"
    printf '%s\n' "$FN_BODY" | grep -q 'public settings refresh is delayed. Continuing safely.' || \
        fail "$fn lacks delayed-publication continuation semantics"
done

for report in \
    'Hardware detection complete' \
    'Hardware model:' \
    'Hardware radios:' \
    'Hardware Ethernet:' \
    'Detected Ethernet interfaces:' \
    'Hardware profile stored in settings.json'; do
    grep -Fq "info -c vlan \"$report" "$MERV_BASE/functions/hw_probe.sh" || \
        fail "HW probe does not publish '$report' to the VLAN log"
done
grep -Fq 'info -c cli "Refreshing hardware profile for $_OVR_TARGET..."' "$MERV_BASE/functions/hw_probe.sh" || \
    fail "HW probe CLI start summary missing"
grep -Fq 'info -c cli "Hardware profile refreshed: $MODEL ($MAX_ETH_PORTS LAN ports; WAN $WAN_IF)"' "$MERV_BASE/functions/hw_probe.sh" || \
    fail "HW probe CLI completion summary missing"
if grep -Fq 'info -c cli,vlan' "$MERV_BASE/functions/hw_probe.sh"; then
    fail "HW probe duplicates its detailed report into the CLI log"
fi

printf 'APMO_OVERRIDE_CONTRACT_OK\n'
