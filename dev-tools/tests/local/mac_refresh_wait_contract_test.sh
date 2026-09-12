#!/bin/sh
# Focused contract test for the synchronous MAC refresh observation wait.
set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_ROOT="${TMPDIR:-/tmp}/mervlan_tmp/selftest.mac-refresh-wait.$$"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  _needle=$1
  _file=$2
  grep -F "$_needle" "$_file" >/dev/null 2>&1 || \
    fail "expected '$_needle' in $_file"
}

line_number() {
  _needle=$1
  _file=$2
  grep -n -F "$_needle" "$_file" | head -n 1 | cut -d: -f1
}

setup_case() {
  _case_name=$1
  _case_root="$TEST_ROOT/$_case_name"
  mkdir -p "$_case_root/settings" "$_case_root/functions" \
    "$_case_root/tmp" "$_case_root/locks" "$_case_root/results" \
    "$_case_root/progress" || fail "unable to create fixture $_case_name"

  cp "$BASE_DIR/functions/mac_refresh.sh" \
    "$_case_root/functions/mac_refresh.sh" || fail "unable to copy MAC refresh entrypoint"
  chmod 700 "$_case_root/functions/mac_refresh.sh" || fail "unable to mark entrypoint executable"

  cat >"$_case_root/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
MERV_TEST_ROOT="${MERV_TEST_ROOT:?}"
TMPDIR="$MERV_TEST_ROOT/tmp"
LOCKDIR="$MERV_TEST_ROOT/locks"
RESULTDIR="$MERV_TEST_ROOT/results"
MERV_PROGRESS_ROOT="$MERV_TEST_ROOT/progress"
SETTINGS_FILE="$MERV_TEST_ROOT/settings/mervlan.conf"
HW_SETTINGS_FILE="$MERV_TEST_ROOT/settings/hw.conf"
export TMPDIR LOCKDIR RESULTDIR MERV_PROGRESS_ROOT SETTINGS_FILE HW_SETTINGS_FILE
EOF

  cat >"$_case_root/settings/log_settings.sh" <<'EOF'
LOG_SETTINGS_LOADED=1
_merv_test_log() {
  printf '%s\n' "$*" >>"$MERV_TEST_ROOT/action.log"
}
info() { _merv_test_log "INFO $*"; }
warn() { _merv_test_log "WARN $*"; }
error() { _merv_test_log "ERROR $*"; }
EOF

  cat >"$_case_root/settings/lib_update_state.sh" <<'EOF'
LIB_UPDATE_STATE_LOADED=1
merv_update_mutation_blocked() { return 1; }
EOF

  cat >"$_case_root/settings/lib_action_progress.sh" <<'EOF'
LIB_ACTION_PROGRESS_LOADED=1
merv_action_progress_init() {
  printf 'progress-init\n' >>"$MERV_TEST_ROOT/timeline"
}
merv_action_progress_update() {
  printf 'progress-update %s\n' "$*" >>"$MERV_TEST_ROOT/timeline"
}
merv_action_progress_complete() {
  printf 'progress-complete\n' >>"$MERV_TEST_ROOT/timeline"
  printf 'success\n' >"$MERV_TEST_ROOT/progress-final"
}
merv_action_progress_fail() {
  printf 'progress-fail %s\n' "$*" >>"$MERV_TEST_ROOT/timeline"
  printf 'failure %s\n' "$*" >"$MERV_TEST_ROOT/progress-final"
}
EOF

  cat >"$_case_root/functions/post_apply_worker.sh" <<'EOF'
#!/bin/sh
set -u

_action=${1:-status}
_trace="$MERV_TEST_ROOT/worker.trace"
_attempt_file="$MERV_TEST_ROOT/attempts"

_run_attempt() {
  _attempt=0
  if [ -f "$_attempt_file" ]; then
    _attempt=$(cat "$_attempt_file")
  fi
  _attempt=$((_attempt + 1))
  printf '%s\n' "$_attempt" >"$_attempt_file"

  case "${MERV_WORKER_SCENARIO:-immediate}" in
    immediate)
      : >"$MERV_TEST_ROOT/snapshot.completed"
      printf 'snapshot-complete\n' >>"$_trace"
      : >"$MERV_TEST_ROOT/collection.completed"
      printf 'collection-complete\n' >>"$_trace"
      printf 'worker-complete\n' >>"$MERV_TEST_ROOT/timeline"
      printf 'run attempt=%s rc=0\n' "$_attempt" >>"$_trace"
      return 0
      ;;
    defer-success)
      if [ "$_attempt" -eq 1 ]; then
        printf 'run attempt=%s rc=75\n' "$_attempt" >>"$_trace"
        return 75
      fi
      : >"$MERV_TEST_ROOT/snapshot.completed"
      printf 'snapshot-complete\n' >>"$_trace"
      : >"$MERV_TEST_ROOT/collection.completed"
      printf 'collection-complete\n' >>"$_trace"
      printf 'worker-complete\n' >>"$MERV_TEST_ROOT/timeline"
      printf 'run attempt=%s rc=0\n' "$_attempt" >>"$_trace"
      return 0
      ;;
    timeout)
      printf 'run attempt=%s rc=75\n' "$_attempt" >>"$_trace"
      return 75
      ;;
    failure)
      printf 'run attempt=%s rc=1\n' "$_attempt" >>"$_trace"
      return 1
      ;;
    *)
      printf 'run attempt=%s rc=2\n' "$_attempt" >>"$_trace"
      return 2
      ;;
  esac
}

_run_wait() {
  _max=${1:-120}
  case "$_max" in
    ''|*[!0-9]*) return 2 ;;
  esac
  printf 'run-wait %s\n' "$_max" >>"$_trace"
  _started=$(date +%s 2>/dev/null || printf '0')
  _deadline=$((_started + _max))
  while :; do
    _run_attempt
    _rc=$?
    case "$_rc" in
      0)
        [ -f "$MERV_TEST_ROOT/snapshot.completed" ] && \
          [ -f "$MERV_TEST_ROOT/collection.completed" ] && return 0
        ;;
      75) ;;
      *) return "$_rc" ;;
    esac
    _now=$(date +%s 2>/dev/null || printf '0')
    if [ "$_now" -ge "$_deadline" ]; then
      return 75
    fi
    sleep 1
  done
}

case "$_action" in
  request)
    [ "${2:-}" = snapshot-reset ] && [ "${3:-}" = collect ] || exit 2
    printf 'request %s %s\n' "$2" "$3" >>"$_trace"
    : >"$MERV_TEST_ROOT/snapshot.requested"
    : >"$MERV_TEST_ROOT/collection.requested"
    exit 0
    ;;
  run)
    _run_attempt
    exit $?
    ;;
  run-wait)
    _run_wait "${2:-120}"
    exit $?
    ;;
  status)
    _snapshot_complete=0
    _collection_complete=0
    [ -f "$MERV_TEST_ROOT/snapshot.completed" ] && _snapshot_complete=1
    [ -f "$MERV_TEST_ROOT/collection.completed" ] && _collection_complete=1
    printf 'snapshot requested=1 completed=%s; collection requested=1 completed=%s\n' \
      "$_snapshot_complete" "$_collection_complete"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
EOF
  chmod 700 "$_case_root/functions/post_apply_worker.sh" || \
    fail "unable to mark worker fixture executable"
}

run_case() {
  _case_name=$1
  _scenario=$2
  _expected_rc=$3
  setup_case "$_case_name"

  _rc=0
  MERV_BASE="$_case_root" \
    MERV_TEST_ROOT="$_case_root" \
    MERV_WORKER_SCENARIO="$_scenario" \
    MERV_OBS_AUTOSTART_WAIT_SEC=2 \
    sh "$_case_root/functions/mac_refresh.sh" >"$_case_root/output" 2>&1 || _rc=$?

  [ "$_rc" -eq "$_expected_rc" ] || \
    fail "$_scenario returned $_rc, expected $_expected_rc (see $_case_root/output)"
  assert_contains "request snapshot-reset collect" "$_case_root/worker.trace"
  [ -f "$_case_root/snapshot.requested" ] || fail "snapshot request was not published"
  [ -f "$_case_root/collection.requested" ] || fail "collection request was not published"
}

run_case immediate immediate 0
assert_contains 'success' "$TEST_ROOT/immediate/progress-final"
[ -f "$TEST_ROOT/immediate/snapshot.completed" ] || fail "immediate snapshot did not complete"
[ -f "$TEST_ROOT/immediate/collection.completed" ] || fail "immediate collection did not complete"

run_case defer_success defer-success 0
assert_contains 'success' "$TEST_ROOT/defer_success/progress-final"
assert_contains 'run-wait 2' "$TEST_ROOT/defer_success/worker.trace"
assert_contains 'run attempt=1 rc=75' "$TEST_ROOT/defer_success/worker.trace"
assert_contains 'run attempt=2 rc=0' "$TEST_ROOT/defer_success/worker.trace"
[ -f "$TEST_ROOT/defer_success/snapshot.completed" ] || fail "deferred snapshot did not complete"
[ -f "$TEST_ROOT/defer_success/collection.completed" ] || fail "deferred collection did not complete"
_worker_line=$(line_number 'worker-complete' "$TEST_ROOT/defer_success/timeline")
_progress_line=$(line_number 'progress-complete' "$TEST_ROOT/defer_success/timeline")
[ -n "$_worker_line" ] && [ -n "$_progress_line" ] || fail "missing completion timeline markers"
[ "$_worker_line" -lt "$_progress_line" ] || \
  fail "MAC refresh reported completion before worker completion"

run_case timeout timeout 75
assert_contains 'failure' "$TEST_ROOT/timeout/progress-final"
assert_contains 'run-wait 2' "$TEST_ROOT/timeout/worker.trace"
assert_contains 'deferred/failed (rc=75); pending generation retained' "$TEST_ROOT/timeout/action.log"
[ ! -f "$TEST_ROOT/timeout/snapshot.completed" ] || fail "timeout completed snapshot unexpectedly"
[ ! -f "$TEST_ROOT/timeout/collection.completed" ] || fail "timeout completed collection unexpectedly"

run_case genuine_failure failure 1
assert_contains 'failure' "$TEST_ROOT/genuine_failure/progress-final"
assert_contains 'run-wait 2' "$TEST_ROOT/genuine_failure/worker.trace"
assert_contains 'run attempt=1 rc=1' "$TEST_ROOT/genuine_failure/worker.trace"
[ ! -f "$TEST_ROOT/genuine_failure/snapshot.completed" ] || fail "failed run completed snapshot unexpectedly"

printf '%s\n' 'MAC_REFRESH_WAIT_CONTRACT_OK'
