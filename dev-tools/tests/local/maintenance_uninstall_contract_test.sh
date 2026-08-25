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

# A v0.53.26 Update parent has no delegation-kind marker, but after the target
# tree is activated it still owns the live canonical record and the matching
# durable journal/quiesce state.  Only that narrow public-refresh handoff is
# accepted; the normal new-parent delegation remains unchanged.
unset MERV_MAINTENANCE_DELEGATION_KIND
merv_update_journal_write run-legacy activated refs/heads/test 0 0 1 1 0 legacy || fail legacy-journal-write
merv_update_quiesce_begin run-legacy || fail legacy-quiesce-write
merv_update_legacy_reinstall_context_valid || fail legacy-reinstall-context
MERV_MAINTENANCE_DELEGATION_KIND=update
merv_maintenance_delegation_valid || fail normal-update-delegation
unset MERV_MAINTENANCE_DELEGATION_KIND

# A stale/mismatched durable marker or forged owner tuple cannot bridge the
# handoff, even while the process that owns the lock is still alive.
merv_update_quiesce_begin stale-run || fail stale-quiesce-write
if merv_update_legacy_reinstall_context_valid; then fail stale-quiesce-accepted; fi
merv_update_quiesce_begin run-legacy || fail legacy-quiesce-restore
MERV_UPDATE_OWNER_NONCE=forged
if merv_update_legacy_reinstall_context_valid; then fail forged-legacy-context; fi
MERV_UPDATE_OWNER_NONCE="$MERV_LOCK_NONCE"
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_LOCK_NONCE" || fail update-owner-release
if merv_update_legacy_reinstall_context_valid; then fail stale-owner-accepted; fi
pass update-journal-and-quiesce-required

# The compatibility bridge is source-guarded to the public/runtime reinstall
# modes in both entry points; no full uninstall path may inherit it.
grep -Fq 'if [ "$MODE" = "reinstall" ]' "$BASE_DIR/install.sh" || fail install-reinstall-guard
grep -Fq 'if [ "$ACTION" = "reinstall" ]' "$BASE_DIR/uninstall.sh" || fail uninstall-reinstall-guard
pass legacy-bridge-reinstall-only

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

# Existing installations can have a configured node that predates persisted
# AUTO_NODE<n>_MAC.  Full uninstall must pass that explicit legacy `none`
# identity to the same strict endpoint-bound SSH preflight, not fail before
# the verifier gets a chance to authenticate it.
PREFLIGHT_HELPER="$TEST_ROOT/uninstall-preflight.sh"
sed -n '/^preflight_full_uninstall_nodes() {/,/^}/p' "$UNINSTALL" > "$PREFLIGHT_HELPER" || fail preflight-extract
[ -s "$PREFLIGHT_HELPER" ] || fail preflight-helper-empty
if TEST_ROOT="$TEST_ROOT" PREFLIGHT_HELPER="$PREFLIGHT_HELPER" sh -c '
  ACTION=full
  TMPDIR="$TEST_ROOT/tmp"
  SETTINGS_FILE="$TEST_ROOT/settings.json"
  LOGTAG=test
  mkdir -p "$TMPDIR" || exit 1
  merv_node_list() { printf "%s\\n" "1 192.0.2.10"; }
  json_get_flag() { printf "%s" ""; }
  get_node_ssh_port() { printf "%s\\n" 22; }
  logger() { :; }
  merv_ssh_preflight_node_set() { cat "$1" > "$TEST_ROOT/preflight.tsv"; return 0; }
  . "$PREFLIGHT_HELPER" || exit 2
  preflight_full_uninstall_nodes || exit 3
  [ "$(cat "$TEST_ROOT/preflight.tsv")" = "1 192.0.2.10 none" ]
'; then :; else fail full-uninstall-legacy-node-preflight; fi
pass full-uninstall-legacy-node-preflight

# Full node cleanup must leave no node-local MerVLAN control-plane directories,
# remove only MerVLAN metadata, and disable node hooks before its runtime is
# erased.  Capture the authenticated remote command through the real helper.
REMOTE_HELPER="$TEST_ROOT/remove-nodes.sh"
sed -n '/^remove_nodes_full_install() {/,/^}/p' "$UNINSTALL" > "$REMOTE_HELPER" || fail remove-nodes-extract
[ -s "$REMOTE_HELPER" ] || fail remove-nodes-helper-empty
if TEST_ROOT="$TEST_ROOT" REMOTE_HELPER="$REMOTE_HELPER" sh -c '
  SSH_KEY="$TEST_ROOT/router-node-key"
  FULL_DELETE_BACKUPS=1
  printf x > "$SSH_KEY" || exit 1
  merv_node_list() { printf "%s\\n" "1 192.0.2.10"; }
  logger() { :; }
  merv_ssh_exec() { printf "%s" "$3" > "$TEST_ROOT/remote-cleanup.sh"; return 0; }
  . "$REMOTE_HELPER" || exit 2
  remove_nodes_full_install || exit 3
'; then :; else fail full-uninstall-node-cleanup-command; fi
for cleanup_path in \
  '/jffs/addons/mervlan' \
  '/tmp/mervlan_tmp' \
  '/www/user/mervlan' \
  '/www/user/merlin_vlan_manager' \
  '/jffs/addons/mervlan_state' \
  '/jffs/addons/mervlan_backups'; do
  grep -Fq "$cleanup_path" "$TEST_ROOT/remote-cleanup.sh" || fail "node-cleanup-path-missing:$cleanup_path"
done
grep -Fq 'mervlan_boot.sh nodedisable' "$TEST_ROOT/remote-cleanup.sh" || fail node-hook-cleanup-missing
grep -Fq 'mervlan_version' "$TEST_ROOT/remote-cleanup.sh" || fail node-metadata-cleanup-missing
pass full-uninstall-node-cleanup-command

printf 'MAINTENANCE_UNINSTALL_CONTRACT_OK\n'
