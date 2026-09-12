#!/bin/sh
# Round 2 audit fixture: deterministic Ethernet placement matrix for the
# current manager bridge verifier and attach path.  No runtime source or
# router/device state is changed; manager functions are extracted into a
# virtual sysfs and all bridge commands are faked.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-eth-matrix.$$"
AUDIT_SYSFS="$TEST_ROOT/sysfs"
umask 077
mkdir -p "$AUDIT_SYSFS/class/net/br0/brif" "$AUDIT_SYSFS/class/net/br100/brif" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    _name="$1"; _source="$2"; _destination="$3"; _occurrence="${4:-1}"
    awk -v function_name="$_name" -v wanted="$_occurrence" '
        { sub(/\r$/, "") }
        $0 ~ ("^" function_name "\\()[[:space:]]*\\{") {
            candidate++
            if (candidate == wanted) active=1
        }
        active { print }
        active && $0 == "}" { exit }
    ' "$_source" > "$_destination" || return 1
    [ -s "$_destination" ]
}

FUNCTIONS="$TEST_ROOT/manager_bridge_functions.sh"
for _fn in member_of_bridge_brctl_fallback member_of_bridge_sysfs member_of_bridge verify_interface_binding attach_to_bridge; do
    extract_function "$_fn" "$BASE_DIR/functions/mervlan_manager.sh" "$TEST_ROOT/$_fn.sh" || \
        fail "could not extract $_fn"
    # The extracted member helpers must inspect only the virtual sysfs tree.
    sed 's#/sys/class/net#${AUDIT_SYSFS}/class/net#g' "$TEST_ROOT/$_fn.sh" >> "$FUNCTIONS" || exit 1
done
. "$FUNCTIONS" || fail 'could not load extracted manager bridge functions'

AUDIT_SYSFS="$AUDIT_SYSFS"
export AUDIT_SYSFS
DEFAULT_BRIDGE=br0
DRY_RUN=no
BOUND_IFACES=""
WATCH_IFACES=""
export DEFAULT_BRIDGE DRY_RUN

# Dependencies used by attach_to_bridge are deterministic no-ops.  brctl addif
# reports success but intentionally does not create a membership entry for the
# false-success case.
brctl() {
    case "${1:-}" in
        show) printf 'bridge name\tbridge id\tSTP enabled\tinterfaces\n' ;;
        addif|delif) : ;;
        *) : ;;
    esac
    return 0
}
sleep() { :; }
iface_exists() { [ -d "$AUDIT_SYSFS/class/net/$1" ]; }
validate_vlan_id() { return 0; }
is_internal_vap() { return 1; }
is_wl_iface() { return 1; }
remove_from_all_bridges() { :; }
ensure_vlan_bridge() { return 0; }
track_change() { :; }
info() { :; }
warn() { :; }
error() { :; }
ebt_quarantine_release() { :; }
note_bound_iface() { :; }
queue_watch() { :; }

reset_membership() {
    rm -f "$AUDIT_SYSFS/class/net/br0/brif/eth1" \
        "$AUDIT_SYSFS/class/net/br100/brif/eth1" \
        "$AUDIT_SYSFS/class/net/eth1" 2>/dev/null || exit 1
}

assert_rc() {
    _label="$1"; _expected="$2"; shift 2
    if "$@"; then _rc=0; else _rc=$?; fi
    [ "$_rc" -eq "$_expected" ] || fail "$_label returned rc=$_rc expected=$_expected"
}

# correct: expected VLAN bridge membership is present.
reset_membership
: > "$AUDIT_SYSFS/class/net/br100/brif/eth1"
assert_rc correct 0 verify_interface_binding eth1 100

# br0: the managed Ethernet port is on the native bridge, not its VLAN bridge.
reset_membership
: > "$AUDIT_SYSFS/class/net/br0/brif/eth1"
assert_rc br0 1 verify_interface_binding eth1 100

# neither: no bridge membership is present.
reset_membership
assert_rc neither 1 verify_interface_binding eth1 100

# both: current manager verification is satisfied by expected-bridge presence;
# it does not reject simultaneous br0 membership.
reset_membership
: > "$AUDIT_SYSFS/class/net/br0/brif/eth1"
: > "$AUDIT_SYSFS/class/net/br100/brif/eth1"
assert_rc both 0 verify_interface_binding eth1 100

# absent: the interface itself is not present and therefore cannot verify.
reset_membership
assert_rc absent 1 verify_interface_binding eth1 100
assert_rc absent-attach 0 attach_to_bridge eth1 100 'ETH1 absent fixture'

# false bridge success: brctl addif succeeds but the kernel membership remains
# absent; attach_to_bridge retries verification, ignores the second failure,
# and still returns success through note_bound_iface/queue_watch.
reset_membership
: > "$AUDIT_SYSFS/class/net/eth1"
assert_rc false-bridge-success 0 attach_to_bridge eth1 100 'ETH1 fixture'
assert_rc false-bridge-postcheck 1 verify_interface_binding eth1 100

printf 'MATRIX: correct=verify0 br0=verify1 neither=verify1 both=verify0 absent=verify1/attach0\n'
printf 'FALSE_SUCCESS: attach_to_bridge rc=0 while postcheck rc=1 after fake brctl success\n'
printf 'EVIDENCE: expected-bridge-only verification accepts both; attach ignores failed retry verification\n'
printf 'DEEP_AUDIT_ETHERNET_PLACEMENT_MATRIX_OK\n'
