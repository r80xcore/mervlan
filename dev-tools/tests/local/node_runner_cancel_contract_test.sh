#!/bin/sh
# Focused local regression for authenticated detached-runner cancellation.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-runner-cancel.$$"
umask 077
mkdir -p "$TEST_ROOT/node_runs/1-1" || exit 1
trap 'kill "${_child_pid:-}" 2>/dev/null || :; rm -rf "$TEST_ROOT"' 0 1 2 3 15
. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1

mkdir -p "$TEST_ROOT/hostile/1-1" || exit 1
cat > "$TEST_ROOT/hostile/1-1/node_1.status" <<'EOF'
format_version=1
run_id=1-1
node_id=1
state=complete
pid=1
proc_start_time=1
started_epoch=1
completed_epoch=1
exit_code=0
reason=terminal
EOF
( unset MERVLAN_SELFTEST_CONTEXT
  MERV_BASE="$BASE_DIR" MERV_NODE_STATUS_ROOT="$TEST_ROOT/hostile" \
    sh "$BASE_DIR/functions/mervlan_node_runner.sh" status 1-1 1 >/dev/null 2>&1
) && { printf '%s\n' 'FAIL: production node-run root accepted an inherited alternate' >&2; exit 1; }

MERV_BASE="$BASE_DIR" MERV_NODE_STATUS_ROOT="$TEST_ROOT/hostile" \
  sh "$BASE_DIR/functions/mervlan_node_runner.sh" status 1-1 1 >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: authenticated self-test node-run root was rejected' >&2
    exit 1
  }

sleep 60 &
_child_pid=$!
_child_start=$(awk '{print $22}' "/proc/$_child_pid/stat" 2>/dev/null || printf '')
_started=$(date +%s 2>/dev/null || printf '')
case "$_child_pid:$_child_start:$_started" in *[!0-9:]*|:*|*::*) exit 1 ;; esac
cat > "$TEST_ROOT/node_runs/1-1/node_1.status" <<EOF
format_version=1
run_id=1-1
node_id=1
state=started
pid=$_child_pid
proc_start_time=$_child_start
started_epoch=$_started
completed_epoch=0
exit_code=
reason=started
EOF

MERV_BASE="$BASE_DIR" \
MERVLAN_SELFTEST_CONTEXT="$TEST_ROOT/.mervlan-selftest-context" \
MERV_NODE_STATUS_ROOT="$TEST_ROOT/node_runs" \
MERV_NODE_RUNNER_MANAGER="$BASE_DIR/functions/mervlan_manager.sh" \
  sh "$BASE_DIR/functions/mervlan_node_runner.sh" cancel 1-1 1 >/dev/null 2>&1 && exit 1

[ ! -e "/proc/$_child_pid" ] || exit 1
grep -q '^state=started$' "$TEST_ROOT/node_runs/1-1/node_1.status" || exit 1
printf 'NODE_RUNNER_CANCEL_CONTRACT_OK\n'
