#!/bin/sh
# Round 2 permanent contract: exact Ethernet placement is required for attach,
# correction, and final security success. Uses only a temporary virtual sysfs.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/ethernet-placement-contract.$$"
SYSROOT="$TEST_ROOT/sys/class/net"
umask 077
mkdir -p "$SYSROOT/eth_real" "$SYSROOT/br0/brif" "$SYSROOT/br189/brif" "$SYSROOT/br200/brif" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_rc() { _l="$1"; _e="$2"; shift 2; if "$@" >/dev/null 2>&1; then _a=0; else _a=$?; fi; [ "$_a" -eq "$_e" ] || fail "$_l rc=$_a expected=$_e"; }
extract_function() {
  awk -v n="$1" '
    { sub(/\r$/, "") }
    $0 ~ ("^" n "\\(\\)[[:space:]]*\\{") { on=1 }
    on { print }
    on && $0 == "}" { exit }
  ' "$2" > "$3" || return 1
  [ -s "$3" ]
}

MERV_BASE="$BASE_DIR"; export MERV_BASE
LIB_JSON_LOADED=
. "$BASE_DIR/settings/lib_json.sh" || fail 'load lib_json'
. "$BASE_DIR/settings/lib_br0_guard.sh" || fail 'load lib_br0_guard'
MERV_SYS_CLASS_NET_ROOT="$SYSROOT"; export MERV_SYS_CLASS_NET_ROOT

extract_function verify_interface_binding "$BASE_DIR/functions/mervlan_manager.sh" "$TEST_ROOT/verify.sh" || fail 'extract verifier'
extract_function attach_to_bridge "$BASE_DIR/functions/mervlan_manager.sh" "$TEST_ROOT/attach.sh" || fail 'extract attach'
extract_function merv_manager_final_security_check "$BASE_DIR/functions/mervlan_manager.sh" "$TEST_ROOT/final.sh" || fail 'extract final check'
extract_function member_of_bridge_brctl_fallback "$BASE_DIR/functions/mervlan_manager.sh" "$TEST_ROOT/member.sh" || fail 'extract bridge fallback'
. "$TEST_ROOT/verify.sh" || fail 'load verifier'
. "$TEST_ROOT/attach.sh" || fail 'load attach'
. "$TEST_ROOT/final.sh" || fail 'load final check'
. "$TEST_ROOT/member.sh" || fail 'load bridge fallback'

DEFAULT_BRIDGE=br0
DRY_RUN=no
SETTINGS_FILE="$TEST_ROOT/settings.json"
NODE_ID=none
BOUND_IFACES= WATCH_IFACES=
mkdir -p "$SYSROOT/br189/brif" || exit 1
iface_exists() { [ -d "$SYSROOT/$1" ]; }
validate_vlan_id() { return 0; }
is_internal_vap() { return 1; }
is_wl_iface() { return 1; }
is_native_radio() { return 1; }
ensure_vlan_bridge() { mkdir -p "$SYSROOT/br$1/brif"; }
remove_from_all_bridges() { rm -f "$SYSROOT"/br*/brif/"$1"; }
track_change() { :; }
info() { :; }
warn() { :; }
error() { :; }
sleep() { :; }
ebt_quarantine_release() { :; }
note_bound_iface() { :; }
queue_watch() { :; }
brctl() {
  case "$1" in
    addif) [ "${FAKE_ADDIF:-success}" = success ] && : > "$SYSROOT/$2/brif/$3"; return 0 ;;
    delif) rm -f "$SYSROOT/$2/brif/$3"; return 0 ;;
    show) printf '%s\n' "${FAKE_BRCTL_SHOW:-}"; return 0 ;;
  esac
  return 0
}

reset_membership() { rm -f "$SYSROOT"/br*/brif/eth_real; }
reset_membership
: > "$SYSROOT/br189/brif/eth_real"
assert_rc correct 0 verify_interface_binding eth_real 189
reset_membership
: > "$SYSROOT/br0/brif/eth_real"
assert_rc br0 1 verify_interface_binding eth_real 189
reset_membership
: > "$SYSROOT/br200/brif/eth_real"
assert_rc wrong 1 verify_interface_binding eth_real 189
reset_membership
: > "$SYSROOT/br0/brif/eth_real"
: > "$SYSROOT/br189/brif/eth_real"
assert_rc both 1 verify_interface_binding eth_real 189
reset_membership
assert_rc neither 1 verify_interface_binding eth_real 189

FAKE_BRCTL_SHOW=$(printf '%s\n' \
  'bridge name     bridge id               STP enabled     interfaces' \
  'br189           8000.000000000000       no              eth0' \
  '                                                        eth_real')
assert_rc 'manager brctl continuation membership is exact' 0 member_of_bridge_brctl_fallback br189 eth_real
FAKE_BRCTL_SHOW=$(printf '%s\n' \
  'bridge name     bridge id               STP enabled     interfaces' \
  'br189           8000.000000000000       no              eth_real' \
  '                                                        wl0.1' \
  'br200           8000.000000000001       no              eth_other' \
  '                                                        wl0.2')
assert_rc 'manager brctl first member and wireless continuation are exact' 0 member_of_bridge_brctl_fallback br189 eth_real
assert_rc 'manager brctl other bridge does not leak first member' 1 member_of_bridge_brctl_fallback br200 eth_real
FAKE_BRCTL_SHOW=$(printf '%s\n' \
  'bridge name     bridge id               STP enabled     interfaces' \
  'br189           8000.000000000000       no              eth_real_extra')
assert_rc 'manager brctl prefix member is rejected' 1 member_of_bridge_brctl_fallback br189 eth_real

FAKE_ADDIF=fail
assert_rc false_addif 1 attach_to_bridge eth_real 189 'Ethernet fixture'
assert_rc false_addif_postcheck 1 verify_interface_binding eth_real 189
FAKE_ADDIF=success
assert_rc successful_attach 0 attach_to_bridge eth_real 189 'Ethernet fixture'
assert_rc successful_attach_postcheck 0 verify_interface_binding eth_real 189

# Final success must not early-return for an empty managed-VAP state. It must
# still reject an absent/misplaced numeric managed Ethernet port.
merv_dhcp_hold_rules_present() { return 0; }
merv_l2_guard_verify_exact() { return 0; }
merv_iface_vid_list() { return 0; }
merv_managed_eth_iface_vid_list() { printf '%s %s\n' eth_real 189; }
reset_membership
: > "$SYSROOT/br0/brif/eth_real"
assert_rc final_rejects_br0_ethernet 1 merv_manager_final_security_check
reset_membership
: > "$SYSROOT/br189/brif/eth_real"
assert_rc final_accepts_exact_ethernet 0 merv_manager_final_security_check

printf 'ETHERNET_PLACEMENT_CONTRACT_OK\n'
