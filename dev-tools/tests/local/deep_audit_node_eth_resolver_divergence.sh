#!/bin/sh
# Round 3 audit fixture: manager node overrides and heal's VLAN expectation
# resolver read different Ethernet pools for the same NODE1 settings.
# Production functions are extracted into temporary state; no runtime source
# or router/device state is changed.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-node-eth.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    _name="$1"
    _source="$2"
    _destination="$3"
    _occurrence="${4:-1}"
    awk -v function_name="$_name" -v wanted="$_occurrence" '
        { sub(/\r$/, "") }
        $0 ~ ("^" function_name "\\(\\)[[:space:]]*\\{") {
            candidate++
            if (candidate == wanted) active=1
        }
        active { print }
        active && $0 == "}" { exit }
    ' "$_source" > "$_destination" || return 1
    [ -s "$_destination" ]
}

SETTINGS_FILE="$TEST_ROOT/settings.json"
export SETTINGS_FILE
printf '%s\n' \
    '{' \
    '  "ETH1_VLAN": "100",' \
    '  "NODE1_ETH1_VLAN": "200",' \
    '  "VLAN": {' \
    '    "Ethernet_ports": {"ETH1_VLAN": "100"},' \
    '    "Pool": {"VLAN_01": "none"},' \
    '    "Trunks": {}' \
    '  }' \
    '}' > "$SETTINGS_FILE" || exit 1

MERV_BASE="$BASE_DIR"
export MERV_BASE
LIB_JSON_LOADED=
. "$BASE_DIR/settings/lib_json.sh" || fail 'could not load JSON fixture helpers'

MANAGER_FUNCTION="$TEST_ROOT/manager_read_json.sh"
HEAL_FUNCTION="$TEST_ROOT/heal_expected_vlans.sh"
extract_function read_json "$BASE_DIR/functions/mervlan_manager.sh" \
    "$MANAGER_FUNCTION" 2 || fail 'could not extract node-aware manager read_json'
extract_function expected_vlans_from_settings "$BASE_DIR/functions/heal_event.sh" \
    "$HEAL_FUNCTION" || fail 'could not extract heal expected_vlans_from_settings'

read_json_raw() { json_get_scalar "$1" "$2"; }
merv_is_valid_node_id() {
    case "$1" in
        1|2|3|4|5) return 0 ;;
        *) return 1 ;;
    esac
}
NODE_ID=1
export NODE_ID
. "$MANAGER_FUNCTION" || fail 'could not load manager resolver fixture'
MANAGER_VALUE=$(read_json ETH1_VLAN "$SETTINGS_FILE")

# Heal's resolver intentionally reads VLAN.Ethernet_ports through the MAIN
# nested JSON accessor; it does not call the manager's node-aware read_json.
MAX_SSIDS=1
ETH_PORTS='eth1'
SSID_FILTER_FATAL=0
get_vlan_slot_value() { printf '%s\n' none; }
trim_spaces() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}
error() { :; }
export MAX_SSIDS ETH_PORTS SSID_FILTER_FATAL

. "$HEAL_FUNCTION" || fail 'could not load heal resolver fixture'
set +u
HEAL_VALUE=$(expected_vlans_from_settings)
HEAL_RC=$?
set -u
[ "$HEAL_RC" -eq 0 ] || fail "heal resolver failed (rc=$HEAL_RC)"

[ "$MANAGER_VALUE" = 200 ] || fail "manager did not select NODE1 override (got '$MANAGER_VALUE')"
printf '%s\n' "$HEAL_VALUE" | grep -qx '100' || \
    fail "heal did not select MAIN Ethernet VLAN 100 (got '$HEAL_VALUE')"
printf '%s\n' "$HEAL_VALUE" | grep -qx '200' && \
    fail 'heal unexpectedly selected NODE1 override'

printf 'FIXTURE: MAIN ETH1_VLAN=100; NODE1_ETH1_VLAN=200; NODE_ID=1\n'
printf 'RESULT: manager read_json ETH1_VLAN -> %s (NODE1 override)\n' "$MANAGER_VALUE"
printf 'RESULT: heal expected_vlans_from_settings -> %s (MAIN Ethernet pool)\n' "$HEAL_VALUE"
printf 'EVIDENCE: manager and heal resolve the same node settings to different Ethernet VLANs\n'
printf 'DEEP_AUDIT_NODE_ETH_RESOLVER_DIVERGENCE_OK\n'
