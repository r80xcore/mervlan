#!/bin/sh
# Structural contract for Execute Nodes' no-node/full manager lifecycle.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/execute_nodes.sh"
_fail=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _fail=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Inspect only the no-node branch (from its elif through the parallel-path
# else). It must launch a direct background manager and publish PID/start
# identity before supervision; a foreground shell invocation is unsafe.
_branch=$(awk '
  /elif \[ -z "\$READY_NODES" \]/ { in_branch=1 }
  in_branch { print }
  in_branch && /^else$/ { exit }
' "$SOURCE")
printf '%s\n' "$_branch" | grep -Fq 'sh "$local_script" --no-collect' ||
  fail 'no-node branch does not invoke the manager'
printf '%s\n' "$_branch" | grep -Fq 'main_pid=$!' ||
  fail 'no-node branch does not track manager PID'
printf '%s\n' "$_branch" | grep -Fq 'main_start=$(merv_proc_start_time' ||
  fail 'no-node branch does not publish manager start identity'
printf '%s\n' "$_branch" | grep -Fq 'execute_supervise_local_manager' ||
  fail 'no-node branch does not supervise the tracked manager'
printf '%s\n' "$_branch" | grep -Fq '>>"$CLI_LOG" 2>&1 &' ||
  fail 'no-node manager is not a direct background child'
printf '%s\n' "$_branch" | grep -Fq 'kill "$main_pid"' &&
  fail 'no-node identity failure uses unauthenticated PID kill'

if [ "$_fail" -eq 0 ]; then
  printf 'EXECUTE_NODES_NO_NODE_LIFECYCLE_CONTRACT_OK\n'
  exit 0
fi
printf 'EXECUTE_NODES_NO_NODE_LIFECYCLE_CONTRACT_FAILED\n' >&2
exit 1
