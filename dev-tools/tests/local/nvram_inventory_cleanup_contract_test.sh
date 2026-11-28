#!/bin/sh
# Contract coverage for process-scoped NVRAM inventory exit cleanup and
# PID-reuse-safe bounded stale artifact pruning in /tmp/mervlan_tmp.

set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)

FAILURES=0
CASES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }
case_pass() {
  CASES=$((CASES + 1))
  [ "$FAILURES" -eq "$1" ] && pass "$2"
}

SNAPSHOT="$MERV_BASE/settings/mac_shield_snapshot.sh"
IDENTITY="$MERV_BASE/settings/lib_identity.sh"
HEAL="$MERV_BASE/functions/heal_event.sh"
WORKER="$MERV_BASE/functions/post_apply_worker.sh"
MANAGER="$MERV_BASE/functions/mervlan_manager.sh"

TEST_ROOT="/tmp/mervlan-nvram-cleanup-test.$$"
EXTRACTED="$TEST_ROOT/extracted"
INV_ROOT="$TEST_ROOT/inv"
PROC_ROOT="$TEST_ROOT/proc"
SYMLINK_TARGET="$TEST_ROOT/symlink-target"
umask 077
mkdir -p "$EXTRACTED" "$INV_ROOT" "$PROC_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

extract_fn() {
  _ef_src="$1" _ef_name="$2" _ef_dst="$3"
  awk -v wanted="$_ef_name" '
    $0 ~ ("^" wanted "\\(\\)[[:space:]]*\\{") { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_ef_src" > "$_ef_dst" || return 1
  [ -s "$_ef_dst" ]
}

for _fn in \
  merv_nvram_inventory_clear_state \
  merv_nvram_inventory_process_start \
  merv_nvram_inventory_path \
  merv_nvram_inventory_invalidate \
  merv_nvram_inventory_owner_confirmed_dead \
  merv_nvram_inventory_prune_stale \
  merv_iface_vid_cache_path \
  merv_iface_vid_cache_remove_files \
  merv_iface_vid_cache_disable; do
  extract_fn "$SNAPSHOT" "$_fn" "$EXTRACTED/$_fn.sh" || {
    printf 'FAIL: extract %s\n' "$_fn" >&2
    exit 1
  }
done

extract_fn "$HEAL" heal_cleanup_on_exit "$EXTRACTED/heal_cleanup_on_exit.sh"
extract_fn "$WORKER" obs_worker_cleanup "$EXTRACTED/obs_worker_cleanup.sh"
extract_fn "$MANAGER" cleanup_on_exit "$EXTRACTED/cleanup_on_exit.sh"

# Load production identity parser (merv_identity_proc_start) and only stub
# merv_identity_current_start so tests run deterministically on macOS & Linux.
. "$IDENTITY" || exit 1
MOCK_CURRENT_START=424242
merv_identity_current_start() {
  printf '%s\n' "$MOCK_CURRENT_START"
}

for _f in "$EXTRACTED"/merv_*.sh; do
  . "$_f"
done

# macOS hosts expose /tmp as a symlink to /private/tmp, which trips the Linux
# /tmp non-symlink invariant in merv_nvram_inventory_process_start.  Keep the
# extracted function on Linux and adapt only the /tmp root check on macOS.
if [ -L /tmp ]; then
  merv_nvram_inventory_process_start() {
    if [ -n "${1:-}" ]; then
      case "$1" in
        /tmp|/tmp/*) [ ! -L "$1" ] || return 1 ;;
        *) return 1 ;;
      esac
    fi
    merv_identity_current_start
  }
fi

MERV_NVRAM_INVENTORY_ROOT="$INV_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=pid
MERV_NVRAM_INVENTORY_PROC_ROOT="$PROC_ROOT"
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE MERV_NVRAM_INVENTORY_PROC_ROOT

# Case 1: prune_stale deletes confirmed dead & PID-reused artifacts, preserves
# live, unknown/malformed stat, $$, and symlinks.
_f=$FAILURES
_live_pid=1001;    [ "$_live_pid" != "$$" ]    || _live_pid=1002
_reused_pid=2001;  [ "$_reused_pid" != "$$" ]  || _reused_pid=2002
_dead_pid=3001;    [ "$_dead_pid" != "$$" ]    || _dead_pid=3002
_malformed_pid=4001; [ "$_malformed_pid" != "$$" ] || _malformed_pid=4002
_nostat_pid=5001;  [ "$_nostat_pid" != "$$" ]  || _nostat_pid=5002

mkdir -p "$PROC_ROOT/$_live_pid" "$PROC_ROOT/$_reused_pid" "$PROC_ROOT/$_malformed_pid" "$PROC_ROOT/$_nostat_pid"
printf '%s (sh) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 777777 0 0\n' "$_live_pid" > "$PROC_ROOT/$_live_pid/stat"
printf '%s (sh) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 999999 0 0\n' "$_reused_pid" > "$PROC_ROOT/$_reused_pid/stat"
printf 'malformed-stat-without-parens\n' > "$PROC_ROOT/$_malformed_pid/stat"

# Dead PID (no /proc/<pid> dir), including dotted scope + iface.state.tmp
: > "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.data"
: > "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.state"
: > "$INV_ROOT/nvram_inventory.my.scope.${_dead_pid}.111111.iface.state.tmp"
# PID-reused (stat has 999999, file has 888888)
: > "$INV_ROOT/nvram_inventory.pid.${_reused_pid}.888888.data"
: > "$INV_ROOT/nvram_inventory.pid.${_reused_pid}.888888.state"
# Live PID (stat matches 777777)
: > "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.data"
: > "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.state"
# Inconclusive PIDs (dir exists, stat malformed or missing) must be preserved
: > "$INV_ROOT/nvram_inventory.pid.${_malformed_pid}.555555.data"
: > "$INV_ROOT/nvram_inventory.pid.${_nostat_pid}.666666.data"
# Current process ($$)
: > "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.data"
: > "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.state"
# Symlink targeting outside file must never be removed or followed
printf 'keep-me\n' > "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.raw"

merv_nvram_inventory_prune_stale "$INV_ROOT" || fail 'prune_stale returned non-zero'

[ ! -e "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.data" ] || fail 'dead PID .data was not pruned'
[ ! -e "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.state" ] || fail 'dead PID .state was not pruned'
[ ! -e "$INV_ROOT/nvram_inventory.my.scope.${_dead_pid}.111111.iface.state.tmp" ] || fail 'dotted-scope dead PID .iface.state.tmp was not pruned'
[ ! -e "$INV_ROOT/nvram_inventory.pid.${_reused_pid}.888888.data" ] || fail 'PID-reused .data was not pruned'
[ ! -e "$INV_ROOT/nvram_inventory.pid.${_reused_pid}.888888.state" ] || fail 'PID-reused .state was not pruned'
[ -e "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.data" ] || fail 'live PID .data was incorrectly pruned'
[ -e "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.state" ] || fail 'live PID .state was incorrectly pruned'
[ -e "$INV_ROOT/nvram_inventory.pid.${_malformed_pid}.555555.data" ] || fail 'malformed-stat PID .data was pruned despite unknown identity'
[ -e "$INV_ROOT/nvram_inventory.pid.${_nostat_pid}.666666.data" ] || fail 'missing-stat PID .data was pruned despite existing /proc/<pid>'
[ -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.data" ] || fail 'current PID .data was incorrectly pruned'
[ -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.state" ] || fail 'current PID .state was incorrectly pruned'
[ -L "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.raw" ] || fail 'symlink artifact was deleted'
[ "$(cat "$SYMLINK_TARGET")" = "keep-me" ] || fail 'symlink target was modified'
rm -f "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.raw" \
  "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.data" \
  "$INV_ROOT/nvram_inventory.pid.${_live_pid}.777777.state" \
  "$INV_ROOT/nvram_inventory.pid.${_malformed_pid}.555555.data" \
  "$INV_ROOT/nvram_inventory.pid.${_nostat_pid}.666666.data"
case_pass "$_f" 'prune_stale reaps confirmed dead/reused artifacts and preserves live, unknown, $$, and symlinks'

# Case 2: prune_stale is a safe no-op when proc root is absent.
_f=$FAILURES
: > "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.data"
MERV_NVRAM_INVENTORY_PROC_ROOT="$TEST_ROOT/nonexistent-proc"
export MERV_NVRAM_INVENTORY_PROC_ROOT
merv_nvram_inventory_prune_stale "$INV_ROOT" || fail 'absent-proc prune failed'
[ -e "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.data" ] || fail 'absent-proc prune deleted file without proc proof'
rm -f "$INV_ROOT/nvram_inventory.pid.${_dead_pid}.111111.data"
MERV_NVRAM_INVENTORY_PROC_ROOT="$PROC_ROOT"
export MERV_NVRAM_INVENTORY_PROC_ROOT
case_pass "$_f" 'prune_stale safely no-ops when procfs is absent'

# Case 3: per-run prune limit bounds work and batched deletion clears >64 files.
_f=$FAILURES
_i=1
while [ "$_i" -le 70 ]; do
  _pid=$((6000 + _i))
  : > "$INV_ROOT/nvram_inventory.pid.${_pid}.111111.data"
  _i=$((_i + 1))
done
merv_nvram_inventory_prune_stale "$INV_ROOT" 4 || fail 'bounded prune failed'
_rem=$(find "$INV_ROOT" -maxdepth 1 -name 'nvram_inventory.pid.60*.data' | wc -l | tr -d ' ')
[ "$_rem" -eq 66 ] || fail "expected 66 remaining after limit=4, got $_rem"
merv_nvram_inventory_prune_stale "$INV_ROOT" 200 || fail 'batched prune failed'
_rem=$(find "$INV_ROOT" -maxdepth 1 -name 'nvram_inventory.pid.60*.data' | wc -l | tr -d ' ')
[ "$_rem" -eq 0 ] || fail "expected 0 remaining after batched prune, got $_rem"
case_pass "$_f" 'prune_stale respects per-run cap and batches deletions across >64 files'

# Case 4: heal_cleanup_on_exit invalidates uncached/cron inventory and preserves exit code.
_f=$FAILURES
. "$EXTRACTED/heal_cleanup_on_exit.sh"
HEAL_IFACE_VID_CACHE_ENABLED=0
HEAL_DHCP_TOKEN=""
HEAL_LOCK_ACQUIRED=0
error() { :; }
_rc=0
(exit 42) || heal_cleanup_on_exit || _rc=$?
[ "$_rc" -eq 42 ] || fail "heal_cleanup_on_exit altered exit code: $_rc"
[ ! -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.data" ] || fail 'heal_cleanup_on_exit left .data behind'
[ ! -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.state" ] || fail 'heal_cleanup_on_exit left .state behind'
case_pass "$_f" 'heal_cleanup_on_exit cleans uncached/cron inventory and preserves exit status'

# Case 5: obs_worker_cleanup invalidates observation inventory on exit.
_f=$FAILURES
: > "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.data"
: > "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.state"
. "$EXTRACTED/obs_worker_cleanup.sh"
obs_abort_active_pool() { return 0; }
obs_pool_state_clean() { return 0; }
obs_lock_release() { return 0; }
obs_log() { :; }
MNJ_POOL_ROOT=""
OBS_WORKER_LOCK="$TEST_ROOT/obs.lock"
_ow_nonce=""
_rc=0
obs_worker_cleanup || _rc=$?
[ "$_rc" -eq 0 ] || fail "obs_worker_cleanup returned $_rc"
[ ! -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.data" ] || fail 'obs_worker_cleanup left .data behind'
[ ! -e "$INV_ROOT/nvram_inventory.pid.$$.${MOCK_CURRENT_START}.state" ] || fail 'obs_worker_cleanup left .state behind'
case_pass "$_f" 'obs_worker_cleanup cleans observation worker inventory artifacts'

# Case 6: mervlan_manager cleanup_on_exit cleans inventory + derived cache on early/dry-run exit.
_f=$FAILURES
_cur_path=$(merv_nvram_inventory_path)
: > "${_cur_path}.data"
: > "${_cur_path}.state"
: > "${_cur_path}.iface.data"
: > "${_cur_path}.iface.state"
. "$EXTRACTED/cleanup_on_exit.sh"
MANAGER_DHCP_TOKEN=""
MANAGER_RUNTIME_OWNED=0
CHANGE_LOG="$TEST_ROOT/no-change.log"
MERV_ACTION_PROGRESS_ENABLED=0
MERV_ACTION_PROGRESS_FINAL=0
release_script_lock() { return 0; }
_rc=0
(exit 7) || cleanup_on_exit || _rc=$?
[ "$_rc" -eq 7 ] || fail "cleanup_on_exit altered exit code: $_rc"
[ ! -e "${_cur_path}.data" ] && [ ! -e "${_cur_path}.state" ] || fail 'manager cleanup_on_exit left inventory files'
[ ! -e "${_cur_path}.iface.data" ] && [ ! -e "${_cur_path}.iface.state" ] || fail 'manager cleanup_on_exit left derived iface files'
case_pass "$_f" 'mervlan_manager cleanup_on_exit cleans inventory and derived cache files'

if [ "$FAILURES" -ne 0 ]; then
  printf 'NVRAM_INVENTORY_CLEANUP_CONTRACT_FAILED (%s failures)\n' "$FAILURES" >&2
  exit 1
fi
printf 'NVRAM_INVENTORY_CLEANUP_CONTRACT_OK (%s cases)\n' "$CASES"
