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
MERV_UPDATE_OWNER=1
! merv_update_mutation_blocked || fail update-owner-bypass
unset MERV_UPDATE_OWNER
merv_update_quiesce_clear || fail quiesce-clear
! merv_update_quiesce_active || fail quiesce-still-active
pass quiesce-atomic-lifecycle

MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/maintenance.lock"
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

printf 'UPDATE_LIFECYCLE_CONTRACT_OK\n'
