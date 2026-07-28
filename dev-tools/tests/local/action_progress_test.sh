#!/bin/sh
# Isolated tests for settings/lib_action_progress.sh. This test writes only
# beneath /tmp/mervlan_tmp/selftest.action-progress.<pid>.

set -u
TEST_ROOT="/tmp/mervlan_tmp/selftest.action-progress.$$"
TEST_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || exit 2
: "${MERV_BASE:=$(CDPATH= cd -- "$TEST_SCRIPT_DIR/../../.." 2>/dev/null && pwd)}"
export MERV_BASE
export MERV_PROGRESS_ROOT="$TEST_ROOT/progress"
mkdir -p "$TEST_ROOT" || exit 2

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

. "$MERV_BASE/settings/lib_action_progress.sh" || exit 2

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

TOKEN="action-test.$$"
merv_action_progress_init "$TOKEN" sync_vlanmgr "Sync Nodes" "Preparing..." || fail 'initialization'
[ "${MERV_ACTION_PROGRESS_ENABLED:-0}" = 1 ] || fail 'initialization enables publication'
pass 'shared initialization'

merv_action_progress_update sync 1 2 50 'Halfway through synchronization' || fail 'update publication'
PATH_JSON="$MERV_PROGRESS_ROOT/$TOKEN.json"
grep -Fq '"state":"running"' "$PATH_JSON" || fail 'running state'
grep -Fq '"percent":50' "$PATH_JSON" || fail 'percentage publication'
pass 'shared update publication'

merv_action_progress_complete 'Synchronization complete' || fail 'completion publication'
grep -Fq '"state":"complete"' "$PATH_JSON" || fail 'complete state'
pass 'shared completion publication'

printf 'shared action progress tests: PASS\n'
