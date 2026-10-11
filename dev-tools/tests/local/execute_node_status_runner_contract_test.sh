#!/bin/sh
# Execute must accept both the legacy and the current strict node-run records.

set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/execute_nodes.sh"
eval "$(sed -n '/^execute_status_valid()/,/^fetch_node_runner_logs()/p' "$SOURCE" | sed '$d')"
APPLY_RUN_ID=77-4

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

_legacy='format_version=1
run_id=77-4
node_id=2
state=complete
pid=101
proc_start_time=200
started_epoch=100
completed_epoch=101
exit_code=0
reason=manager-complete'
execute_status_valid "$_legacy" 2 || fail legacy-format
pass 'legacy node-run terminal records remain accepted'

_started='format_version=2
run_id=77-4
node_id=2
state=started
pid=101
proc_start_time=200
parent_pid=90
parent_proc_start_time=180
manager_pid=none
manager_proc_start_time=none
started_epoch=100
completed_epoch=0
exit_code=
reason=runner-started'
execute_status_valid "$_started" 2 || fail current-started-format
pass 'current pending-to-started runner record is accepted'

_complete='format_version=2
run_id=77-4
node_id=2
state=complete
pid=101
proc_start_time=200
parent_pid=90
parent_proc_start_time=180
manager_pid=102
manager_proc_start_time=201
started_epoch=100
completed_epoch=101
exit_code=0
reason=manager-complete'
execute_status_valid "$_complete" 2 || fail current-terminal-format
pass 'current terminal runner record is accepted'

if execute_status_valid "$(printf '%s\n' "$_complete" | sed 's/manager_proc_start_time=201/manager_proc_start_time=none/')" 2; then
  fail incomplete-manager-identity
fi
if execute_status_valid "$(printf '%s\n' "$_complete" | sed '$a exit_code=0')" 2; then
  fail duplicate-field
fi
if execute_status_valid "$(printf '%s\n' "$_complete" | sed '/^parent_pid=/d')" 2; then
  fail missing-required-field
fi
printf '%s\n' 'EXECUTE_NODE_STATUS_RUNNER_CONTRACT_OK'
