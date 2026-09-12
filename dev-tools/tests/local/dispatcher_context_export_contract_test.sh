#!/bin/sh
# Runtime M-06 contract: failed child-context export must launch no worker.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SERVICE="$BASE_DIR/functions/service-event-handler.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.dispatch-export.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

# Extract only the dispatch function; the event router itself is intentionally
# not sourced because production paths are fixed to /jffs on ASUSWRT.
awk '
  /^dispatch_if_executable\(\) \{/ { in_dispatch=1 }
  in_dispatch { print }
  in_dispatch && $0 == "}" { exit }
' "$SERVICE" > "$TEST_ROOT/dispatch_fn.sh" || exit 1
. "$TEST_ROOT/dispatch_fn.sh" || exit 1

WORKER="$TEST_ROOT/execute_nodes.sh"
MARKER="$TEST_ROOT/worker-ran"
RELEASES="$TEST_ROOT/releases"
PROGRESS="$TEST_ROOT/progress"
ACK="$TEST_ROOT/ack"
printf '#!/bin/sh\nprintf ran > "%s"\n' "$MARKER" > "$WORKER"
chmod 700 "$WORKER"

LOCKDIR="$TEST_ROOT/locks"
MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
RAW=apply_vlanmgr
TYPE=dispatch
EVENT=export_test
MERV_PROGRESS_TOKEN=''
export LOCKDIR MERV_ACTION_LOCK_PATH RAW TYPE EVENT MERV_PROGRESS_TOKEN

logger() { :; }
get_progress_request_token() { printf 'dispatch-test-token\n'; }
merv_action_progress_init() { printf 'init\n' >> "$PROGRESS"; }
merv_action_progress_fail() { printf 'fail:%s\n' "$1" >> "$PROGRESS"; }
action_ack_error() { printf 'ack:%s\n' "$1" >> "$ACK"; }
merv_action_lock_enter() {
  MERV_ACTION_LOCK_MODE=self
  MERV_ACTION_LOCK_NONCE=stub-nonce
  MERV_ACTION_LOCK_START=1
  return 0
}
merv_action_lock_leave() { printf '%s\n' "$1" >> "$RELEASES"; return 0; }
merv_action_lock_export_child_context() { return 1; }
merv_action_lock_clear_child_context() { return 0; }

dispatch_if_executable "$WORKER"
_dispatch_rc=$?
[ "$_dispatch_rc" -ne 0 ] || exit 1
[ ! -e "$MARKER" ] || exit 1
[ -s "$PROGRESS" ] || exit 1
[ -s "$ACK" ] || exit 1
[ "$(wc -l < "$RELEASES" 2>/dev/null)" -eq 2 ] || exit 1

# A normal dispatched worker must use the identity API loaded by
# lib_action_lock, rather than the unavailable lib_mervqt compatibility
# wrappers.  This is the same path a router service-event invocation takes.
merv_action_lock_export_child_context() { return 0; }
merv_identity_proc_start() { printf '1\n'; }
merv_identity_matches() { return 0; }
dispatch_if_executable "$WORKER"
_dispatch_rc=$?
[ "$_dispatch_rc" -eq 0 ] || exit 1
[ -e "$MARKER" ] || exit 1
[ "$(wc -l < "$RELEASES" 2>/dev/null)" -eq 4 ] || exit 1
printf 'DISPATCHER_CONTEXT_EXPORT_CONTRACT_OK\n'
