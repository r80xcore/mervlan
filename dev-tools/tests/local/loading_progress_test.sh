#!/bin/sh
# Isolated tests for settings/lib_progress.sh. This test writes only beneath
# /tmp/mervlan_tmp/selftest.loading-progress.<pid>.

set -u
TEST_ROOT="/tmp/mervlan_tmp/selftest.loading-progress.$$"
TEST_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || exit 2
: "${MERV_BASE:=$(CDPATH= cd -- "$TEST_SCRIPT_DIR/../../.." 2>/dev/null && pwd)}"
export MERV_BASE
export MERV_PROGRESS_ROOT="$TEST_ROOT/progress"
mkdir -p "$TEST_ROOT" || exit 2

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

. "$MERV_BASE/settings/var_settings.sh" || exit 2
. "$MERV_BASE/settings/lib_progress.sh" || exit 2

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

TOKEN="20260726-test.$$"
ACTION="sync_vlanmgr"
LABEL="Sync Nodes"
PATH_JSON="$MERV_PROGRESS_ROOT/$TOKEN.json"

merv_progress_start "$TOKEN" "$ACTION" "$LABEL" indeterminate "Starting synchronization..." || fail 'start publishes'
[ -s "$PATH_JSON" ] || fail 'start status exists'
grep -Fq '"state":"starting"' "$PATH_JSON" || fail 'start state'
grep -Fq '"percent":null' "$PATH_JSON" || fail 'indeterminate percent is null'
pass 'start publication'

merv_progress_item "$TOKEN" "$ACTION" "$LABEL" nodes 2 4 'Node 2 of 4 synchronized' || fail 'item publishes'
grep -Fq '"state":"running"' "$PATH_JSON" || fail 'item state'
grep -Fq '"percent":50' "$PATH_JSON" || fail 'item percentage'
grep -Fq 'Node 2 of 4 synchronized' "$PATH_JSON" || fail 'message publication'
pass 'determinate item publication'

merv_progress_update "$TOKEN" "$ACTION" "$LABEL" running determinate nodes 4 4 999 'All nodes synchronized' '' || fail 'percent clamp publishes'
grep -Fq '"percent":100' "$PATH_JSON" || fail 'percent clamp'
pass 'percentage clamping'

merv_progress_fail "$TOKEN" "$ACTION" "$LABEL" determinate 'A node failed' 'SSH failure' || fail 'failure publishes'
grep -Fq '"state":"failed"' "$PATH_JSON" || fail 'failure state'
grep -Fq '"error":"SSH failure"' "$PATH_JSON" || fail 'failure message'
pass 'failure publication'

if merv_progress_start '../unsafe' "$ACTION" "$LABEL" indeterminate 'must reject'; then
    fail 'unsafe token rejected'
fi
pass 'token validation'

merv_progress_remove "$TOKEN" || fail 'status removal'
[ ! -e "$PATH_JSON" ] || fail 'status removed'
pass 'status removal'

printf 'loading progress tests: PASS\n'
