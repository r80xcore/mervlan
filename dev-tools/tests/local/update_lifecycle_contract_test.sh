#!/bin/sh
# Local contract test for the durable Update journal and bounded node retry
# marker. This test uses only isolated PC temporary state; it never contacts a
# router and never creates a router backup.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.update-lifecycle.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
export MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
export MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/maintenance.lock"
export MERV_NODE_RECONCILE_FILE="$MERV_STATE_ROOT/node_reconcile.pending"

. "$BASE_DIR/settings/var_settings.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_node_reconcile.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

merv_update_journal_write run-1 extracting refs/heads/custom 1 1 1 0 0 partial-space || fail journal-write
merv_update_journal_active || fail journal-active
[ "$(merv_update_journal_get phase '')" = extracting ] || fail journal-phase
[ "$(merv_update_journal_get detail '')" = partial-space ] || fail journal-detail
merv_update_journal_requires_safe_boot || fail journal-safe-boot
pass journal-write-and-read

merv_update_quiesce_begin run-1 || fail quiesce-write
merv_update_quiesce_active || fail quiesce-active
unset MERV_UPDATE_OWNER
merv_update_mutation_blocked || fail mutation-blocked-during-quiesce
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 update-lifecycle || fail maintenance-owner-acquire
MERV_UPDATE_OWNER=1
MERV_UPDATE_OWNER_PID="$$"
MERV_UPDATE_OWNER_START="$MERV_LOCK_START"
MERV_UPDATE_OWNER_NONCE="$MERV_LOCK_NONCE"
! merv_update_mutation_blocked || fail authenticated-update-owner-bypass
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_LOCK_NONCE" || fail maintenance-owner-release
unset MERV_UPDATE_OWNER MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE
merv_update_quiesce_clear || fail quiesce-clear
! merv_update_quiesce_active || fail quiesce-still-active
pass quiesce-atomic-lifecycle

mkdir -p "$MERV_UPDATE_MAINTENANCE_LOCK" || fail maintenance-marker-create
merv_update_mutation_blocked || fail malformed-maintenance-lock-blocked
rmdir "$MERV_UPDATE_MAINTENANCE_LOCK" || fail maintenance-marker-clear
pass mutation-gate-lifecycle

merv_node_reconcile_write nodeenable unreachable node-unavailable 0 1234 digest:abc || fail node-marker-write
merv_node_reconcile_active || fail node-marker-active
[ "$(merv_node_reconcile_get action '')" = nodeenable ] || fail node-marker-action
[ "$(merv_node_reconcile_get next_epoch '')" = 1234 ] || fail node-marker-due
merv_node_reconcile_clear || fail node-marker-clear
! merv_node_reconcile_active || fail node-marker-still-active
pass bounded-node-marker-lifecycle

merv_update_journal_clear || fail journal-clear
! merv_update_journal_active || fail journal-still-active
merv_update_journal_write 'bad=value' extracting ref 0 0 0 0 0 detail >/dev/null 2>&1 && fail unsafe-journal-value
merv_node_reconcile_write '../bad' unreachable detail 0 1 digest >/dev/null 2>&1 && fail unsafe-node-action
pass malformed-values-rejected

# The GUI transport is Merlin-owned, so the updater records a content
# fingerprint instead of changing the transport file. Extract the two helpers
# from the production source to exercise the exact implementation without
# invoking an Update lifecycle.
UPDATE_SCRIPT="$BASE_DIR/functions/update_mervlan.sh"
GUI_HELPERS="$TEST_ROOT/gui-update-ref-helpers.sh"
sed -n \
  -e '/^update_gui_ref_transport_digest() {/,/^}/p' \
  -e '/^consume_gui_update_ref() {/,/^}/p' \
  "$UPDATE_SCRIPT" > "$GUI_HELPERS" || fail gui-helper-extract
[ -s "$GUI_HELPERS" ] || fail gui-helper-empty
GUI_TRANSPORT_FILE="$TEST_ROOT/custom_settings.txt"
GUI_LEDGER_FILE="$MERV_STATE_ROOT/update_refs.consumed"
GUI_RESULT_FILE="$TEST_ROOT/gui-ref-result"
printf 'vlanmgr_update_ref=refs/heads/gui-portability\n' > "$GUI_TRANSPORT_FILE" || fail gui-transport-write
gui_consume() {
  env CUSTOM_SETTINGS_FILE="$GUI_TRANSPORT_FILE" MERV_STATE_ROOT="$MERV_STATE_ROOT" \
    MERV_UPDATE_CONSUMED_FILE="$GUI_LEDGER_FILE" GUI_HELPERS="$GUI_HELPERS" \
    GUI_RESULT_FILE="$GUI_RESULT_FILE" sh -c '
      . "$GUI_HELPERS" || exit 2
      consume_gui_update_ref
      _gui_test_rc=$?
      printf "%s|%s\n" "$_gui_test_rc" "${GUI_UPDATE_REF:-}" > "$GUI_RESULT_FILE" || exit 3
    ' || fail gui-helper-run
}
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/heads/gui-portability' ] || fail gui-ref-first-value
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '1|refs/heads/gui-portability' ] || fail gui-ref-unchanged-reconsume
printf 'transport_generation=2\n' >> "$GUI_TRANSPORT_FILE" || fail gui-transport-change
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/heads/gui-portability' ] || fail gui-ref-transport-change-value
printf 'vlanmgr_update_ref=refs/tags/v6.0\n' >> "$GUI_TRANSPORT_FILE" || fail gui-ref-new-value-write
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/tags/v6.0' ] || fail gui-ref-canonical-value
grep -Eq '^(md5:[0-9A-Fa-f]{32}|cksum:[0-9]+:[0-9]+)\|refs/' "$GUI_LEDGER_FILE" || fail gui-ref-portable-ledger
pass gui-ref-content-ledger-lifecycle

printf 'UPDATE_LIFECYCLE_CONTRACT_OK\n'
