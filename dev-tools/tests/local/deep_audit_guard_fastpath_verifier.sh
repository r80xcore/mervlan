#!/bin/sh
# Round 5 audit fixture: QT and MAC restorers fast-path on chain presence plus
# two parent jumps, while exact verification rejects empty/partial child rules.
# This harness uses a temporary fake ebtables command and extracted production
# functions only; it never changes runtime source or router/device state.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-guard-fastpath.$$"
umask 077
mkdir -p "$TEST_ROOT/bin" || exit 1
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

DUMP_FILE="$TEST_ROOT/ebtables.dump"
EBT_CALLS="$TEST_ROOT/ebtables.calls"
printf '%s\n' \
    'Bridge table: filter' \
    '' \
    'Bridge chain: FORWARD, entries: 2, policy: ACCEPT' \
    '-j MERV_QT' \
    '-j MERV_MAC' \
    'Bridge chain: INPUT, entries: 2, policy: ACCEPT' \
    '-j MERV_QT' \
    '-j MERV_MAC' \
    'Bridge chain: MERV_QT, entries: 0, policy: RETURN' \
    'Bridge chain: MERV_MAC, entries: 1, policy: RETURN' \
    '-s aa:bb:cc:dd:ee:ff --logical-in br0 -j ACCEPT' \
    > "$DUMP_FILE"

printf '%s\n' \
    '#!/bin/sh' \
    'for _arg in "$@"; do' \
    '    if [ "$_arg" = "-L" ]; then' \
    '        cat "$DUMP_FILE"' \
    '        exit 0' \
    '    fi' \
    'done' \
    'printf "%s\n" "$*" >> "$EBT_CALLS"' \
    'exit 1' \
    > "$TEST_ROOT/bin/ebtables"
chmod 700 "$TEST_ROOT/bin/ebtables" || exit 1
PATH="$TEST_ROOT/bin:$PATH"
export PATH DUMP_FILE EBT_CALLS

FUNCTIONS="$TEST_ROOT/guard_functions.sh"
: > "$FUNCTIONS"
for _entry in \
    '_merv_ebtables_get_dump _merv_ebtables_get_dump' \
    'merv_ebtables_chain_declared_exact merv_ebtables_chain_declared_exact' \
    'merv_ebtables_jump_count_exact merv_ebtables_jump_count_exact' \
    'merv_ebtables_rule_count_exact merv_ebtables_rule_count_exact' \
    'merv_ebtables_chain_rule_count merv_ebtables_chain_rule_count' \
    'merv_ebtables_verify_parent_jumps merv_ebtables_verify_parent_jumps' \
    'merv_mac_shield_verify_exact merv_mac_shield_verify_exact' \
    'merv_qt_verify_exact merv_qt_verify_exact' \
    'merv_l2_guard_verify_exact merv_l2_guard_verify_exact' \
    'restore_merv_mac_shield restore_merv_mac_shield' \
    'restore_merv_qt_shield restore_merv_qt_shield'; do
    _name=${_entry%% *}
    _file=${_entry#* }
    _part="$TEST_ROOT/$_file.part"
    extract_function "$_name" "$BASE_DIR/settings/lib_mervqt.sh" "$_part" || \
        fail "could not extract $_name"
    cat "$_part" >> "$FUNCTIONS" || exit 1
done

MERV_MAC_CHAIN=MERV_MAC
MERV_QT_CHAIN=MERV_QT
MERV_MAC_OVERRIDE_DB="$TEST_ROOT/override.db"
MERV_MAC_DB_ACTIVE="$TEST_ROOT/mac_shield.db"
DRY_RUN=no
TRACE="$TEST_ROOT/trace"
_MERV_QT_SHIELD_STATE=""
_MERV_MAC_SHIELD_STATE=""
printf '%s\n' '1234567890 aa:bb:cc:dd:ee:ff wl0.1 100' > "$MERV_MAC_DB_ACTIVE"
: > "$EBT_CALLS"
: > "$MERV_MAC_OVERRIDE_DB"
export MERV_MAC_CHAIN MERV_QT_CHAIN MERV_MAC_OVERRIDE_DB MERV_MAC_DB_ACTIVE DRY_RUN

mervqt_has_ebtables() { type ebtables >/dev/null 2>&1; }
mervqt_valid_mac() { case "$1" in [0-9a-f][0-9-a-f]:*) return 0 ;; *) return 1 ;; esac; }
mervqt_valid_wl_subif() { [ "$1" = wl0.1 ]; }
mervqt_valid_vid() { [ "$1" = 100 ]; }
mervqt_override_list_read() { printf ' '; }
mervqt_mac_is_overridden() { return 1; }
mervqt_mac_lower() { printf '%s\n' "$1"; }
merv_mac_best_db() { printf '%s\n' "$MERV_MAC_DB_ACTIVE"; }
merv_mac_build_expected_iface_vid() { printf '%s\n' 'wl0.1 100'; }
info() { printf 'info: %s\n' "$*" >> "$TRACE"; }
warn() { printf 'warn: %s\n' "$*" >> "$TRACE"; }

. "$FUNCTIONS" || fail 'could not load extracted guard functions'

if restore_merv_qt_shield "$(cat "$DUMP_FILE")"; then
    QT_FAST_RC=0
else
    QT_FAST_RC=$?
fi
if restore_merv_mac_shield "$(cat "$DUMP_FILE")"; then
    MAC_FAST_RC=0
else
    MAC_FAST_RC=$?
fi
[ "$QT_FAST_RC" -eq 0 ] || fail "QT restorer rejected intact-chain fixture (rc=$QT_FAST_RC)"
[ "$MAC_FAST_RC" -eq 0 ] || fail "MAC restorer rejected intact-chain fixture (rc=$MAC_FAST_RC)"
[ "${_MERV_QT_SHIELD_STATE:-}" = ok ] || fail 'QT restorer did not take stable fast path'
[ "${_MERV_MAC_SHIELD_STATE:-}" = ok ] || fail 'MAC restorer did not take stable fast path'
grep -q -- '-D FORWARD' "$EBT_CALLS" || fail 'QT fast path did not perform its expected stale-gate sweep'

if merv_qt_verify_exact; then
    QT_EXACT_RC=0
else
    QT_EXACT_RC=$?
fi
if merv_mac_shield_verify_exact; then
    MAC_EXACT_RC=0
else
    MAC_EXACT_RC=$?
fi
if merv_l2_guard_verify_exact; then
    L2_EXACT_RC=0
else
    L2_EXACT_RC=$?
fi
[ "$QT_EXACT_RC" -ne 0 ] || fail 'QT exact verifier accepted missing child DROP rule'
[ "$MAC_EXACT_RC" -ne 0 ] || fail 'MAC exact verifier accepted partial/wrong child rule'
[ "$L2_EXACT_RC" -ne 0 ] || fail 'combined exact verifier accepted incomplete child rules'

printf 'FIXTURE: MERV_QT and MERV_MAC chains present; FORWARD/INPUT each have one jump\n'
printf 'CHILD_RULES: QT empty; MAC has one wrong ACCEPT rule instead of expected DROP\n'
printf 'FAST_PATH: QT rc=%s, MAC rc=%s (both accepted)\n' "$QT_FAST_RC" "$MAC_FAST_RC"
printf 'EXACT_VERIFY: QT rc=%s, MAC rc=%s, combined L2 rc=%s (all rejected)\n' \
    "$QT_EXACT_RC" "$MAC_EXACT_RC" "$L2_EXACT_RC"
printf 'EVIDENCE: restorers test chain+jump presence only; exact verifiers test expected child-rule state\n'
printf 'DEEP_AUDIT_GUARD_FASTPATH_VERIFIER_OK\n'
