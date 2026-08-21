#!/bin/sh
# Round 2 audit fixture: the final manager security gate validates managed VAP
# placement and guard chains, but does not validate managed Ethernet placement.
# This is audit-only: the production function is extracted into temporary state
# and /sys is virtualized; no router state or runtime source is changed.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-ethernet-gap.$$"
umask 077
mkdir -p "$TEST_ROOT/sysfs/br0/brif" "$TEST_ROOT/sysfs/br100/brif" || exit 1
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

RAW_FUNCTION="$TEST_ROOT/final_security.raw"
FUNCTION="$TEST_ROOT/final_security.sh"
extract_function merv_manager_final_security_check \
    "$BASE_DIR/functions/mervlan_manager.sh" "$RAW_FUNCTION" || \
    fail 'could not extract merv_manager_final_security_check'
# The production function uses absolute sysfs paths.  Rewrite only the
# temporary extracted copy so the fixture remains unprivileged and deterministic.
sed 's#/sys/class/net#${AUDIT_SYSFS}#g' "$RAW_FUNCTION" > "$FUNCTION" || exit 1

AUDIT_SYSFS="$TEST_ROOT/sysfs"
export AUDIT_SYSFS
: > "$AUDIT_SYSFS/br100/brif/wl0.1"
# Deliberately no br100/brif/eth1 entry: this is the security gap under test.

MAX_SSIDS=1
ETH_PORTS='eth1'
SETTINGS_FILE="$TEST_ROOT/settings.json"
TRACE="$TEST_ROOT/security.trace"
GUARD_TRACE="$TEST_ROOT/guards.trace"
export MAX_SSIDS ETH_PORTS SETTINGS_FILE

# Fixture configuration: one managed Ethernet port and one managed VAP share
# VLAN 100.  The final gate receives the Ethernet declaration only as context;
# its production body never enumerates ETH_PORTS or read_json.
printf '%s\n' '{"ETH1_VLAN":"100","SSID_01":"Guest","VLAN_01":"100"}' > "$SETTINGS_FILE"

get_ssid_slot_value() { printf '%s\n' Guest; }
get_vlan_slot_value() { printf '%s\n' 100; }
merv_mac_build_expected_iface_vid() { printf '%s\n' 'wl0.1 100'; }
merv_dhcp_hold_rules_present() { : > "$GUARD_TRACE.dhcp"; return 0; }
merv_l2_guard_verify_exact() { : > "$GUARD_TRACE.l2"; return 0; }
error() { printf 'error: %s\n' "$*" >> "$TRACE"; }

. "$FUNCTION" || fail 'could not load extracted final security function'

if merv_manager_final_security_check > "$TRACE" 2>&1; then
    FINAL_RC=0
else
    FINAL_RC=$?
fi
[ "$FINAL_RC" -eq 0 ] || fail "final security gate rejected the VAP/guard-clean fixture (rc=$FINAL_RC)"
[ -f "$GUARD_TRACE.dhcp" ] || fail 'DHCP guard fixture was not exercised'
[ -f "$GUARD_TRACE.l2" ] || fail 'L2 guard fixture was not exercised'
[ -e "$AUDIT_SYSFS/br100/brif/wl0.1" ] || fail 'VAP fixture was not placed in br100'
[ ! -e "$AUDIT_SYSFS/br100/brif/eth1" ] || fail 'Ethernet gap fixture unexpectedly contains eth1'

printf 'CONFIG: managed Ethernet eth1 -> br100 (fixture member absent)\n'
printf 'INPUT: managed VAP wl0.1 -> br100; DHCP and L2 guard verifiers pass\n'
printf 'RESULT: merv_manager_final_security_check rc=%s (accepted)\n' "$FINAL_RC"
printf 'EVIDENCE: final gate checks VAP pairs from merv_mac_build_expected_iface_vid; no Ethernet membership check ran\n'
printf 'DEEP_AUDIT_FINAL_SECURITY_ETHERNET_GAP_OK\n'
