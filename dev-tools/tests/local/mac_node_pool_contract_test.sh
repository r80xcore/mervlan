#!/bin/sh
# MAC Shield node observation and DB push use the shared bounded pool while
# trust preflight, validation, merge, and local enforcement stay parent-owned.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-node-pool.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/db" "$TEST_ROOT/tmp" "$TEST_ROOT/tmp/node_jobs" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export VAR_SETTINGS_LOADED=1
export TMPDIR="$TEST_ROOT/tmp"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export SETTINGS_FILE="$TEST_ROOT/settings.json"
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
export MERV_MAC_OVERRIDE_DB="$TEST_ROOT/db/override.db"
export MERV_MAC_MAX_AGE_SEC=86400
export MERV_MAC_NODE_SYNC=1
export MERV_MAC_HEAL_TRIGGER=0
export MERV_NODE_PARALLELISM=2
export SSH_KEY="$TEST_ROOT/db/ssh.key"
: > "$SETTINGS_FILE"
: > "$SSH_KEY"
: > "$MERV_MAC_OVERRIDE_DB"

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
merv_is_valid_node_id() {
  case "$1" in 1|2|3|4|5|6|7|8|9|10) return 0 ;; *) return 1 ;; esac
}
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

info() { :; }
warn() { :; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
merv_mac_snapshot_preconditions_ok() { return 0; }
merv_mac_is_main() { return 0; }
merv_mac_node_list() {
  _mnp_node=1
  while [ "$_mnp_node" -le "${NODE_COUNT:-2}" ]; do
    printf '%s 192.0.2.%s\n' "$_mnp_node" "$_mnp_node"
    _mnp_node=$((_mnp_node + 1))
  done
}
mnp_wait_for_width() {
  _mnp_wait_root="$1"
  _mnp_wait_target="${MERV_NODE_PARALLELISM:-1}"
  case "$_mnp_wait_target" in 1|2|3|4|5) ;; *) _mnp_wait_target=1 ;; esac
  _mnp_wait_ticks=0
  while :; do
    _mnp_wait_active=$(find "$_mnp_wait_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$_mnp_wait_active" -ge "$_mnp_wait_target" ] && break
    [ "$_mnp_wait_ticks" -ge 15 ] && break
    sleep 1
    _mnp_wait_ticks=$((_mnp_wait_ticks + 1))
  done
}
merv_ssh_preflight_node_lines() {
  printf 'preflight-start\n' >> "$TEST_TRACE"
  printf 'preflight-end\n' >> "$TEST_TRACE"
  return 0
}
ssh_keys_effectively_installed() { return 0; }
merv_has() { return 0; }
merv_node_list_digest() { printf '%s\n' stable-node-set; }
merv_node_resolve_endpoint() { printf '%s\n' "$2"; }
merv_ssh_precheck() {
  _mnp_nid="$1"
  mkdir "$PUSH_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || return 1
  mnp_wait_for_width "$PUSH_ACTIVE_ROOT"
  _mnp_active=$(find "$PUSH_ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'push:%s:precheck:%s:%s\n' "$_mnp_nid" "$_mnp_active" "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"
  sleep "${MERV_NODE_POOL_TEST_DELAY:-1}"
  return 0
}
merv_ssh_exec() {
  _mnp_nid="$1"
  case "$3" in
    mkdir*) _mnp_stage=mkdir ;;
    *ebt_mac_shield_init_and_apply*) _mnp_stage=reload ;;
    *) _mnp_stage=other ;;
  esac
  _mnp_active=$(find "$PUSH_ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'push:%s:%s:%s:%s\n' "$_mnp_nid" "$_mnp_stage" "$_mnp_active" "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"
  if [ "$_mnp_stage" = reload ]; then
    sleep "${MERV_NODE_POOL_TEST_DELAY:-1}"
    rmdir "$PUSH_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || :
  fi
  return 0
}
merv_ssh_stream_file() {
  _mnp_nid="$1"
  if [ "$4" = "$MERV_MAC_DB_ACTIVE" ]; then _mnp_stage=db; else _mnp_stage=override; fi
  _mnp_active=$(find "$PUSH_ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'push:%s:%s:%s:%s\n' "$_mnp_nid" "$_mnp_stage" "$_mnp_active" "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"
  return 0
}
ebt_mac_shield_init_and_apply() {
  printf 'main-apply\n' >> "$TEST_TRACE"
  return 0
}

SNAP_RECORD=''
merv_mac_build_snapshot() {
  printf 'local-start\n' >> "$TEST_TRACE"
  sleep 1
  if [ -n "$SNAP_RECORD" ]; then
    printf '%s\n' "$SNAP_RECORD" > "$1" || return 1
    printf '1\n'
  else
    : > "$1" || return 1
    printf '0\n'
  fi
  printf 'local-end\n' >> "$TEST_TRACE"
}
merv_mac_collect_from_node() {
  _mnp_nid="$1"
  mkdir "$COLLECT_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || return 1
  mnp_wait_for_width "$COLLECT_ACTIVE_ROOT"
  _mnp_active=$(find "$COLLECT_ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'collect:%s:start:%s:%s\n' "$_mnp_nid" "$_mnp_active" "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"
  sleep "${MERV_NODE_POOL_TEST_DELAY:-1}"
  case "$_mnp_nid" in
    1|2|3|4|5|6) printf '%s\n' "$(date +%s) aa:bb:cc:dd:ee:$(printf '%02d' "$((10 + _mnp_nid))") wl0.$_mnp_nid $((9 + _mnp_nid))" ;;
    *) rmdir "$COLLECT_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || :; return 1 ;;
  esac
  rmdir "$COLLECT_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || :
  printf 'collect:%s:end:%s:%s\n' "$_mnp_nid" "${MERV_NODE_JOB_DIR:-none}" "${MERV_MAC_PAYLOAD_COUNT:-unset}" >> "$TEST_TRACE"
}

prepare_run() {
  _mnp_width="$1"
  RUN_ROOT="$TEST_ROOT/width-$_mnp_width"
  rm -rf "$RUN_ROOT"
  mkdir -p "$RUN_ROOT/locks" "$RUN_ROOT/db" "$RUN_ROOT/tmp/node_jobs" "$RUN_ROOT/collect-active" "$RUN_ROOT/push-active" || return 1
  TMPDIR="$RUN_ROOT/tmp"; LOCKDIR="$RUN_ROOT/locks"; MERV_STATE_ROOT="$RUN_ROOT/state"
  SETTINGS_FILE="$RUN_ROOT/settings.json"; MERV_MAC_DB_ACTIVE="$RUN_ROOT/db/active.db"
  MERV_MAC_DB_JFFS="$RUN_ROOT/db/jffs.db"; MERV_MAC_OVERRIDE_DB="$RUN_ROOT/db/override.db"
  SSH_KEY="$RUN_ROOT/db/ssh.key"; TEST_TRACE="$RUN_ROOT/trace"
  COLLECT_ACTIVE_ROOT="$RUN_ROOT/collect-active"; PUSH_ACTIVE_ROOT="$RUN_ROOT/push-active"
  export TMPDIR LOCKDIR MERV_STATE_ROOT SETTINGS_FILE MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS
  export MERV_MAC_OVERRIDE_DB SSH_KEY TEST_TRACE COLLECT_ACTIVE_ROOT PUSH_ACTIVE_ROOT
  : > "$SETTINGS_FILE"; : > "$SSH_KEY"; : > "$MERV_MAC_OVERRIDE_DB"
}

assert_before() {
  _mnp_before="$1"; _mnp_after="$2"; _mnp_label="$3"
  [ "$(awk -v pat="$_mnp_before" '$0 ~ pat { print NR; exit }' "$TEST_TRACE")" -lt \
    "$(awk -v pat="$_mnp_after" '$0 ~ pat { print NR; exit }' "$TEST_TRACE")" ] || fail "$_mnp_label"
}

run_width() {
  _mnp_width="$1"
  prepare_run "$_mnp_width" || fail "width $_mnp_width fixture setup"
  NODE_COUNT=6; MERV_NODE_PARALLELISM="$_mnp_width"; export NODE_COUNT MERV_NODE_PARALLELISM
  MERV_NODE_POOL_TEST_DELAY=1
  export MERV_NODE_POOL_TEST_DELAY
  SNAP_RECORD="$(date +%s) aa:bb:cc:dd:ee:01 wl0.1 10"
  export MERV_MAC_SNAPSHOT_RESET=0 MERV_MAC_SNAPSHOT_ALLOW_EMPTY=0 MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
  merv_mac_snapshot || fail "width $_mnp_width complete node-pool snapshot returned failure"
  [ "$MERV_MAC_LAST_NODES_TOTAL" -eq 6 ] || fail "width $_mnp_width node total=$MERV_MAC_LAST_NODES_TOTAL"
  [ "$MERV_MAC_LAST_NODES_OK" -eq 6 ] || fail "width $_mnp_width node ok=$MERV_MAC_LAST_NODES_OK"
  [ "$MERV_MAC_LAST_NODES_FAILED" -eq 0 ] || fail "width $_mnp_width node failed=$MERV_MAC_LAST_NODES_FAILED"
  [ "$MERV_MAC_LAST_NODE_COUNT" -eq 6 ] || fail "width $_mnp_width node records=$MERV_MAC_LAST_NODE_COUNT"
  [ "$MERV_MAC_LAST_PUSH_TOTAL" -eq 6 ] || fail "width $_mnp_width push total=$MERV_MAC_LAST_PUSH_TOTAL"
  [ "$MERV_MAC_LAST_PUSH_OK" -eq 6 ] || fail "width $_mnp_width push ok=$MERV_MAC_LAST_PUSH_OK"
  [ "$MERV_MAC_LAST_PUSH_FAILED" -eq 0 ] || fail "width $_mnp_width push failed=$MERV_MAC_LAST_PUSH_FAILED"
  [ "$(wc -l < "$MERV_MAC_DB_ACTIVE" | tr -d ' ')" = 7 ] || fail "width $_mnp_width merged database did not contain local and node records"

  _mnp_collect_max=$(awk -F: '$1 == "collect" && $3 == "start" && ($4 + 0) > max { max = $4 + 0 } END { print max + 0 }' "$TEST_TRACE")
  [ "$_mnp_collect_max" -eq "$_mnp_width" ] || fail "width $_mnp_width collection max=$_mnp_collect_max"
  _mnp_push_max=$(awk -F: '$1 == "push" && $3 == "precheck" && ($4 + 0) > max { max = $4 + 0 } END { print max + 0 }' "$TEST_TRACE")
  [ "$_mnp_push_max" -eq "$_mnp_width" ] || fail "width $_mnp_width push max=$_mnp_push_max"
  [ "$(grep -c '^preflight-start$' "$TEST_TRACE" 2>/dev/null || :)" -eq 1 ] || fail "width $_mnp_width trust preflight was not one serial gate"
  assert_before '^preflight-end$' '^local-start$' "width $_mnp_width local work started before trust preflight"
  assert_before '^local-end$' '^collect:[1-6]:start:' "width $_mnp_width node collection started before MAIN collection ended"
  _mnp_last_collect=$(grep -n '^collect:[1-6]:end:' "$TEST_TRACE" | tail -n 1 | cut -d: -f1)
  _mnp_first_push=$(grep -n '^push:[1-6]:precheck:' "$TEST_TRACE" | head -n 1 | cut -d: -f1)
  [ -n "$_mnp_last_collect" ] && [ -n "$_mnp_first_push" ] && [ "$_mnp_last_collect" -lt "$_mnp_first_push" ] || fail "width $_mnp_width push began before all collection workers ended"

  for _mnp_node in 1 2 3 4 5 6; do
    _mnp_collect_path=$(awk -F: -v n="$_mnp_node" '$1 == "collect" && $2 == n && $3 == "start" { print $5; exit }' "$TEST_TRACE")
    case "$_mnp_collect_path" in */node_$_mnp_node) ;; *) fail "width $_mnp_width collection worker $_mnp_node path=$_mnp_collect_path" ;; esac
    _mnp_push_path=$(awk -F: -v n="$_mnp_node" '$1 == "push" && $2 == n && $3 == "precheck" { print $5; exit }' "$TEST_TRACE")
    case "$_mnp_push_path" in */node_$_mnp_node) ;; *) fail "width $_mnp_width push worker $_mnp_node path=$_mnp_push_path" ;; esac
    _mnp_stages=$(awk -F: -v n="$_mnp_node" '$1 == "push" && $2 == n { print $3 }' "$TEST_TRACE" | tr '\n' ' ')
    [ "$_mnp_stages" = 'precheck mkdir db override reload ' ] || fail "width $_mnp_width node $_mnp_node push order=$_mnp_stages"
  done
  [ -z "$(find "$TMPDIR/node_jobs" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "width $_mnp_width node-pool workspace leaked after complete run"
  [ -z "$(find "$COLLECT_ACTIVE_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "width $_mnp_width collection active markers leaked"
  [ -z "$(find "$PUSH_ACTIVE_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "width $_mnp_width push active markers leaked"
  printf 'PASS width=%s collect-max=%s push-max=%s parent-merge-counters-isolated-ordering\n' "$_mnp_width" "$_mnp_collect_max" "$_mnp_push_max"
}

for _mnp_width in 1 2 3 4 5; do
  run_width "$_mnp_width"
done

# A complete empty reset is authoritative too: after MAIN enforcement, the
# empty active db must be streamed and reloaded on every configured node via
# the same bounded pool, with parent-owned terminal counters.
merv_mac_collect_empty_node() {
  _mnp_nid="$1"
  mkdir "$COLLECT_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || return 1
  mnp_wait_for_width "$COLLECT_ACTIVE_ROOT"
  _mnp_active=$(find "$COLLECT_ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'collect:%s:start:%s:%s\n' "$_mnp_nid" "$_mnp_active" "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"
  sleep "${MERV_NODE_POOL_TEST_DELAY:-1}"
  rmdir "$COLLECT_ACTIVE_ROOT/node_$_mnp_nid" 2>/dev/null || :
  printf 'collect:%s:end:%s:%s\n' "$_mnp_nid" "${MERV_NODE_JOB_DIR:-none}" "${MERV_MAC_PAYLOAD_COUNT:-unset}" >> "$TEST_TRACE"
}
merv_mac_collect_from_node() { merv_mac_collect_empty_node "$@"; }

run_empty_width() {
  _mnp_empty_width="$1"
  prepare_run "empty-$_mnp_empty_width" || fail "empty width $_mnp_empty_width fixture setup"
  NODE_COUNT="$_mnp_empty_width"; MERV_NODE_PARALLELISM="$_mnp_empty_width"; export NODE_COUNT MERV_NODE_PARALLELISM
  MERV_NODE_POOL_TEST_DELAY=1; export MERV_NODE_POOL_TEST_DELAY
  printf '%s aa:bb:cc:dd:ee:01 wl0.1 10\n' "$(date +%s)" > "$MERV_MAC_DB_ACTIVE"
  printf 'stale-checkpoint\n' > "$MERV_MAC_DB_JFFS"
  SNAP_RECORD=''
  export MERV_MAC_SNAPSHOT_RESET=1 MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1 MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
  merv_mac_snapshot || fail "empty width $_mnp_empty_width snapshot returned failure"
  [ "$MERV_MAC_LAST_STATUS" = empty ] || fail "empty width $_mnp_empty_width status=$MERV_MAC_LAST_STATUS"
  [ "$MERV_MAC_LAST_REASON" = reset_no_clients ] || fail "empty width $_mnp_empty_width reason=$MERV_MAC_LAST_REASON"
  [ "$MERV_MAC_LAST_NODES_TOTAL" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width node total=$MERV_MAC_LAST_NODES_TOTAL"
  [ "$MERV_MAC_LAST_NODES_OK" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width node ok=$MERV_MAC_LAST_NODES_OK"
  [ "$MERV_MAC_LAST_NODES_FAILED" -eq 0 ] || fail "empty width $_mnp_empty_width node failed=$MERV_MAC_LAST_NODES_FAILED"
  [ "$MERV_MAC_LAST_NODE_COUNT" -eq 0 ] || fail "empty width $_mnp_empty_width node records=$MERV_MAC_LAST_NODE_COUNT"
  [ "$MERV_MAC_LAST_PUSH_TOTAL" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width push total=$MERV_MAC_LAST_PUSH_TOTAL"
  [ "$MERV_MAC_LAST_PUSH_OK" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width push ok=$MERV_MAC_LAST_PUSH_OK"
  [ "$MERV_MAC_LAST_PUSH_FAILED" -eq 0 ] || fail "empty width $_mnp_empty_width push failed=$MERV_MAC_LAST_PUSH_FAILED"
  [ ! -s "$MERV_MAC_DB_ACTIVE" ] || fail "empty width $_mnp_empty_width active db was not cleared"
  [ ! -s "$MERV_MAC_DB_JFFS" ] || fail "empty width $_mnp_empty_width JFFS db was not cleared"

  _mnp_collect_max=$(awk -F: '$1 == "collect" && $3 == "start" && ($4 + 0) > max { max = $4 + 0 } END { print max + 0 }' "$TEST_TRACE")
  [ "$_mnp_collect_max" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width collection max=$_mnp_collect_max"
  _mnp_push_max=$(awk -F: '$1 == "push" && $3 == "precheck" && ($4 + 0) > max { max = $4 + 0 } END { print max + 0 }' "$TEST_TRACE")
  [ "$_mnp_push_max" -eq "$_mnp_empty_width" ] || fail "empty width $_mnp_empty_width push max=$_mnp_push_max"
  [ "$(grep -c '^preflight-start$' "$TEST_TRACE" 2>/dev/null || :)" -eq 1 ] || fail "empty width $_mnp_empty_width trust preflight was not one serial gate"
  assert_before '^preflight-end$' '^local-start$' "empty width $_mnp_empty_width local work started before trust preflight"
  assert_before '^local-end$' '^collect:[1-5]:start:' "empty width $_mnp_empty_width node collection started before MAIN collection ended"
  _mnp_last_collect=$(grep -n '^collect:[1-5]:end:' "$TEST_TRACE" | tail -n 1 | cut -d: -f1)
  _mnp_first_push=$(grep -n '^push:[1-5]:precheck:' "$TEST_TRACE" | head -n 1 | cut -d: -f1)
  [ -n "$_mnp_last_collect" ] && [ -n "$_mnp_first_push" ] && [ "$_mnp_last_collect" -lt "$_mnp_first_push" ] || fail "empty width $_mnp_empty_width push began before all collection workers ended"
  assert_before '^main-apply$' '^push:[1-5]:precheck:' "empty width $_mnp_empty_width push began before MAIN enforcement"
  [ -z "$(find "$TMPDIR/node_jobs" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "empty width $_mnp_empty_width node-pool workspace leaked after complete run"
  [ -z "$(find "$COLLECT_ACTIVE_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "empty width $_mnp_empty_width collection active markers leaked"
  [ -z "$(find "$PUSH_ACTIVE_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "empty width $_mnp_empty_width push active markers leaked"
  printf 'PASS empty-width=%s collect-max=%s push-max=%s empty-reset-counters-ordering\n' "$_mnp_empty_width" "$_mnp_collect_max" "$_mnp_push_max"
}

for _mnp_width in 2 5; do
  run_empty_width "$_mnp_width"
done

# A failed node observation must downgrade reset to non-destructive merge and
# preserve the prior database, even when the successful node is empty.
prepare_run failure || fail 'incomplete fixture setup'
NODE_COUNT=2; MERV_NODE_PARALLELISM=2; export NODE_COUNT MERV_NODE_PARALLELISM
printf '%s aa:bb:cc:dd:ee:01 wl0.1 10\n' "$(date +%s)" > "$MERV_MAC_DB_ACTIVE"
SNAP_RECORD=''
merv_mac_collect_from_node() {
  case "$1" in
    1) printf 'collect:1:start:0:%s\n' "${MERV_NODE_JOB_DIR:-none}" >> "$TEST_TRACE"; return 0 ;;
    2) return 1 ;;
  esac
}
export MERV_MAC_SNAPSHOT_RESET=1 MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1 MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
merv_mac_snapshot || fail 'incomplete reset returned failure'
[ "$MERV_MAC_LAST_REASON" = incomplete_node_observation ] || fail "incomplete reset reason=$MERV_MAC_LAST_REASON"
[ "$MERV_MAC_LAST_NODES_TOTAL" -eq 2 ] || fail "incomplete reset node total=$MERV_MAC_LAST_NODES_TOTAL"
[ "$MERV_MAC_LAST_NODES_OK" -eq 1 ] || fail "incomplete reset node ok=$MERV_MAC_LAST_NODES_OK"
[ "$MERV_MAC_LAST_NODES_FAILED" -eq 1 ] || fail "incomplete reset node failed=$MERV_MAC_LAST_NODES_FAILED"
[ "$MERV_MAC_LAST_PUSH_TOTAL" -eq 0 ] || fail 'incomplete reset unexpectedly pushed nodes'
[ "$(wc -l < "$MERV_MAC_DB_ACTIVE" | tr -d ' ')" = 1 ] || fail 'incomplete reset did not preserve prior database'
[ -z "$(find "$TMPDIR/node_jobs" -mindepth 1 -print -quit 2>/dev/null)" ] || fail 'node-pool workspace leaked after incomplete run'

printf 'MAC_NODE_POOL_CONTRACT_OK\n'
