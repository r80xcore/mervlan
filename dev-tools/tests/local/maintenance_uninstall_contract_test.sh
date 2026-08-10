#!/bin/sh
# Focused R5 maintenance admission and full-uninstall ordering contracts.
# Uses only an isolated owner record; no router, node, or live addon paths.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TEST_ROOT="/tmp/mervlan_tmp/selftest.maintenance.$$"
umask 077
mkdir -p "$TEST_ROOT/state" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
export MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
export MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/maintenance.lock"

. "$BASE_DIR/settings/var_settings.sh" || fail load-settings
. "$BASE_DIR/settings/lib_update_state.sh" || fail load-maintenance

merv_maintenance_direct_admit || fail standalone-admission
[ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || fail standalone-owner
merv_maintenance_direct_release || fail standalone-release
[ "$(merv_owner_lock_state "$MERV_UPDATE_MAINTENANCE_LOCK")" = "absent" ] || fail owner-leaked
pass standalone-admission-and-release

# A bare Boolean update hint cannot bypass a live owner.
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 maintenance-test || fail owner-acquire
MERV_UPDATE_OWNER=1
unset MERV_MAINTENANCE_DELEGATION_KIND MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE
if merv_maintenance_delegation_valid; then fail bare-update-bypass; fi
pass bare-update-bypass-rejected

# Exact backup delegation is accepted only while the canonical owner is live.
MERV_MAINTENANCE_DELEGATED=1
MERV_MAINTENANCE_DELEGATION_KIND=backup
MERV_BACKUP_DELEGATION=1
MERV_MAINTENANCE_OWNER_PID="$$"
MERV_MAINTENANCE_OWNER_START="$MERV_LOCK_START"
MERV_MAINTENANCE_OWNER_NONCE="$MERV_LOCK_NONCE"
export MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
  MERV_BACKUP_DELEGATION MERV_MAINTENANCE_OWNER_PID \
  MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
merv_maintenance_delegation_valid || fail exact-backup-delegation
sh -c '. "$MERV_BASE/settings/lib_update_state.sh"; merv_maintenance_delegation_valid' || fail delegated-child-context
MERV_MAINTENANCE_OWNER_NONCE=forged
if merv_maintenance_delegation_valid; then fail forged-delegation; fi
MERV_MAINTENANCE_OWNER_NONCE="$MERV_LOCK_NONCE"
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_LOCK_NONCE" || fail owner-release
if merv_maintenance_delegation_valid; then fail stale-delegation; fi
pass exact-live-delegation-and-forgery-rejection

# Update delegation requires both the authenticated owner and durable
# journal/quiesce state; the owner tuple alone is insufficient.
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 update-test || fail update-owner-acquire
MERV_UPDATE_OWNER=1
MERV_UPDATE_OWNER_PID="$$"
MERV_UPDATE_OWNER_START="$MERV_LOCK_START"
MERV_UPDATE_OWNER_NONCE="$MERV_LOCK_NONCE"
MERV_MAINTENANCE_DELEGATION_KIND=update
if merv_maintenance_delegation_valid; then fail update-without-quiesce; fi
merv_update_journal_write run-r5 extracting refs/heads/test 0 0 1 0 0 r5 || fail journal-write
merv_update_quiesce_begin run-r5 || fail quiesce-write
merv_maintenance_delegation_valid || fail update-delegation
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_LOCK_NONCE" || fail update-owner-release
pass update-journal-and-quiesce-required

# Static uninstall ordering: two complete preflights precede remote deletion,
# and local full-tree removal appears only after the remote operation.
UNINSTALL="$BASE_DIR/uninstall.sh"
preflight_count=$(grep -c 'preflight_full_uninstall_nodes' "$UNINSTALL")
[ "$preflight_count" -ge 3 ] || fail second-preflight-contract
remote_line=$(grep -n 'remove_nodes_full_install; then' "$UNINSTALL" | cut -d: -f1 | head -n 1)
local_line=$(grep -n 'rm -rf /jffs/addons/mervlan' "$UNINSTALL" | tail -n 1 | cut -d: -f1)
[ -n "$remote_line" ] && [ -n "$local_line" ] && [ "$remote_line" -lt "$local_line" ] || fail remote-before-local
grep -Fq 'local control plane, settings, and trust were retained' "$UNINSTALL" || fail partial-failure-message
pass full-uninstall-preflight-and-recovery-order

printf 'MAINTENANCE_UNINSTALL_CONTRACT_OK\n'
