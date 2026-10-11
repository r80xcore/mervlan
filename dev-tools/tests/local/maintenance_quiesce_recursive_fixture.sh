#!/bin/sh
# Deterministic Execute topology, reconstructed from the retained 2026-09-23
# MAIN node_jobs/1790089829-23820 hierarchy. No capture bytes or live devices.
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
umask 077
ROOT=$(mktemp -d /tmp/mervlan_tmp/selftest.q-recursion.XXXXXXXX)
trap 'rm -rf "$ROOT"' 0 1 2 3 15
export MERV_BASE="$BASE_DIR"
Q_SOURCE=${FIXTURE_Q_SOURCE:-$BASE_DIR/settings/lib_maintenance_quiesce.sh}
. "$BASE_DIR/settings/lib_selftest_context.sh"
merv_selftest_context_create "$ROOT"
MERV_QUIESCE_RUNTIME_ROOT="$ROOT/runtime"
MERV_QUIESCE_LOCK_ROOT="$ROOT/runtime/locks"
MERV_QUIESCE_STATE_ROOT="$ROOT/state"
MERV_QUIESCE_SETTINGS_RECONCILE="$ROOT/state/settings_reconcile.state"
MERV_QUIESCE_NODE_RECONCILE="$ROOT/state/node_reconcile.pending"
MERV_QUIESCE_TRUST_LOCK="$ROOT/state/ssh_trust/state.lock"
MERV_QUIESCE_DHCP_ROOT="$ROOT/runtime/locks/dhcp_hold"
MERV_QUIESCE_DHCP_LEGACY="$ROOT/runtime/locks/merv_dhcp_hold.active"
MERV_QUIESCE_OBSERVATION="$ROOT/runtime/locks/observation"
MERV_QUIESCE_NODE_JOBS="$ROOT/runtime/node_jobs"
MERV_QUIESCE_NODE_RUNS="$ROOT/runtime/results/node_runs"
MERV_CONTINUATION_ROOT="$ROOT/runtime/continuations"
mkdir -p "$MERV_QUIESCE_LOCK_ROOT" "$MERV_QUIESCE_STATE_ROOT"
. "$Q_SOURCE"
CHECKS=0
check() {
  CHECKS=$((CHECKS + 1))
  "$@" || { printf 'FAIL recursive check %s: %s\n' "$CHECKS" "$*" >&2; exit 1; }
}
# Instrument only the definition name; recursive calls still enter the wrapper.
# Production traversal and validation bodies are otherwise byte-for-byte.
sed 's/^merv_quiesce_node_jobs_walk() {/fixture_walk_body() {/' \
  "$Q_SOURCE" > "$ROOT/instrumented.sh"
unset LIB_MAINTENANCE_QUIESCE_LOADED
. "$ROOT/instrumented.sh"
# Host has no ASUSWRT ebtables; stub only its device observation boundary.
merv_dhcp_hold_required() { return 1; }
merv_dhcp_hold_rules_absent() { return 0; }
merv_full_fence_classify() { printf absent; }
merv_quiesce_node_jobs_walk() {
  local fixture_rc
  printf '%s %s\n' "${1#"$MERV_QUIESCE_NODE_JOBS"}" "$2" >> "$ROOT/trace"
  fixture_rc=0
  fixture_walk_body "$@" || fixture_rc=$?
  return "$fixture_rc"
}
make_pool() {
  mkdir -p "$1/node_1/ssh"
  printf '1 192.0.2.1\n' > "$1/.nodes.23820"
  cat > "$1/node_1/result" <<RESULT
format_version=2
state=ok
node_id=1
phase=$2
started_epoch=100
completed_epoch=101
reason=worker-ok
owner_pid=2147483647
owner_start=1
owner_nonce=fixture.2147483647.1
RESULT
  printf '2147483647\n' > "$1/node_1/wrapper.pid"
  printf '1\n' > "$1/node_1/wrapper.proc_start_time"
  printf '2147483647\n' > "$1/node_1/child.pid"
  printf '1\n' > "$1/node_1/child.proc_start_time"
  for f in stdout.log cli.log vlan.log; do : > "$1/node_1/$f"; done
  [ "$2" != prepare ] || : > "$1/node_1/settings.expected"
}
make_forensic_record() {
  _forensic_dir="$1/ssh_forensics"
  _forensic_phase="$2"
  mkdir -m 700 -p "$_forensic_dir"
  cat > "$_forensic_dir/attempt.2147483647.1.log" <<RECORD
format=1
phase=execute-$_forensic_phase
status=failure
return_code=255
node=1
canonical_endpoint=fixture-endpoint
selected_endpoint=fixture-endpoint
ssh_user=fixture
ssh_port=22
ssh_settings_path=/tmp/mervlan-fixture/settings.json
ssh_key_path=/tmp/mervlan-fixture/id_ed25519
ssh_key_type=unknown
ssh_key_mode=unknown
ssh_key_uid=unknown
ssh_key_size=unknown
ssh_key_fingerprint=fixture
trust_path=/tmp/mervlan-fixture/ssh_trust
trust_record_fingerprint=fixture
dbclient_binary=dbclient
dbclient_options=BatchMode=yes,PasswordAuthentication=no
maintenance_sync=0
maintenance_delegation=none
action_lock_mode=none
tmpdir=/tmp/mervlan_tmp
ssh_tmpdir=/tmp/mervlan_tmp/node_jobs/fixture/node_1/ssh
worker_dir=/tmp/mervlan_tmp/node_jobs/fixture/node_1
working_directory=/tmp/mervlan-fixture
umask=77
classification=publickey-rejected
sanitized_stderr=synthetic deterministic diagnostic
RECORD
  chmod 600 "$_forensic_dir/attempt.2147483647.1.log"
}
make_run() {
  mkdir -p "$1"
  printf '1 192.0.2.1\n' > "$1/ready"
  make_pool "$1/launch" launch
  printf '1 192.0.2.1\n' > "$1/launched"
  [ "$2" != retained ] || make_pool "$1/prepare" prepare
  make_pool "$1/status" status
  case "${3:-none}" in
    all)
      make_forensic_record "$1/launch/node_1" launch
      [ "$2" != retained ] || make_forensic_record "$1/prepare/node_1" prepare
      make_forensic_record "$1/status/node_1" status
      ;;
    prepare)
      [ "$2" != retained ] || make_forensic_record "$1/prepare/node_1" prepare
      ;;
  esac
}
reset_tree() {
  rm -rf "$MERV_QUIESCE_NODE_JOBS"
  mkdir "$MERV_QUIESCE_NODE_JOBS"
  make_run "$MERV_QUIESCE_NODE_JOBS/1790089829-23820" retained all
  : > "$ROOT/trace"
}
reset_prepare_forensics_tree() {
  rm -rf "$MERV_QUIESCE_NODE_JOBS"
  mkdir "$MERV_QUIESCE_NODE_JOBS"
  make_run "$MERV_QUIESCE_NODE_JOBS/1790089829-23820" retained prepare
  : > "$ROOT/trace"
}
scan() {
  MERV_QUIESCE_STATUS=IDLE
  MERV_QUIESCE_REASON=none
  SCAN_RC=0
  merv_quiesce_node_jobs_state || SCAN_RC=$?
}
expect() {
  scan
  check test "$MERV_QUIESCE_STATUS" = "$1"
  if [ "$1" = IDLE ]; then check test "$SCAN_RC" = 0
  else check test "$SCAN_RC" = 1; fi
  [ "$#" -lt 2 ] || check test "$MERV_QUIESCE_REASON" = "$2"
}
# Exercise the authoritative observer, including a reused current PID.
check test "$(merv_continuation_process_state 2147483647 1)" = dead
CURRENT_START=$(merv_identity_current_start /proc)
check test "$CURRENT_START" != 1
check test "$(merv_continuation_process_state "$$" 1)" = reused
reset_tree
for phase in launch prepare status; do
  check test -d "$MERV_QUIESCE_NODE_JOBS/1790089829-23820/$phase/node_1/ssh_forensics"
  check test -f "$MERV_QUIESCE_NODE_JOBS/1790089829-23820/$phase/node_1/ssh_forensics/attempt.2147483647.1.log"
done
expect IDLE
check test "$MERV_QUIESCE_READY_MANIFEST_COUNT:$MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT" = 1:1
# Real saved hierarchy includes three recursive sibling pools and optional files.
cat > "$ROOT/expected" <<'TRACE'
 0
/1790089829-23820 1
/1790089829-23820/launch 2
/1790089829-23820/prepare 2
/1790089829-23820/status 2
TRACE
check cmp "$ROOT/expected" "$ROOT/trace"
check test "$(merv_maintenance_quiesce_classify)" = IDLE
# A second completed Execute-style root matches the retained MAIN tree too.
# Cumulative counters survive and every recursive frame variable returns.
make_run "$MERV_QUIESCE_NODE_JOBS/2790089829-23820" retained all
for phase in launch prepare status; do
  check test -d "$MERV_QUIESCE_NODE_JOBS/2790089829-23820/$phase/node_1/ssh_forensics"
  check test -f "$MERV_QUIESCE_NODE_JOBS/2790089829-23820/$phase/node_1/ssh_forensics/attempt.2147483647.1.log"
done
mkdir -p "$MERV_QUIESCE_NODE_JOBS/aaa/x/y/z" "$MERV_QUIESCE_NODE_JOBS/zzz/x/y/z"
for variable in dir depth entry name pid ready node ip extra status next; do
  eval "_mqnjw_$variable=sentinel_$variable"
done
: > "$ROOT/trace"
expect IDLE
check test "$MERV_QUIESCE_READY_MANIFEST_COUNT:$MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT" = 2:2
for variable in dir depth entry name pid ready node ip extra status next; do
  eval "check test \"\$_mqnjw_$variable\" = sentinel_$variable"
done
check test "$(awk '$1 ~ /\/z$/ { print $2 }' "$ROOT/trace" | tr '\n' ':')" = 4:4:
check test "$(awk '$1 ~ /\/(launch|prepare|status)$/ { print $2 }' "$ROOT/trace" | tr '\n' ':')" = 2:2:2:2:2:2:
[ "${FIXTURE_FRAMES_ONLY:-0}" != 1 ] || {
  printf 'QUIESCE_RECURSIVE_FRAMES_OK checks=%s\n' "$CHECKS"
  exit 0
}
# Recreate the immediately preceding consumer allowlist by removing only the
# ssh_forensics case. With a producer-compatible record in prepare, that
# pre-correction Q must reproduce the live signature before corrected Q scans
# the same tree to IDLE. The source-to-fixture assertions above prevent a
# report from claiming a namespace that the fixture did not actually build.
reset_prepare_forensics_tree
RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"
check test -d "$RUN/prepare/node_1/ssh_forensics"
check test -f "$RUN/prepare/node_1/ssh_forensics/attempt.2147483647.1.log"
awk '
  /^[[:space:]]*ssh_forensics\)[[:space:]]*$/ { skipping = 1; removed++; next }
  skipping && /^[[:space:]]*;;[[:space:]]*$/ { skipping = 0; next }
  !skipping { print }
  END { if (removed != 1 || skipping) exit 2 }
' "$Q_SOURCE" > "$ROOT/pre-correction-q.sh" || fail pre-correction-q-mutant-build
legacy_result=$(
  (
    unset LIB_MAINTENANCE_QUIESCE_LOADED
    . "$ROOT/pre-correction-q.sh"
    MERV_QUIESCE_STATUS=IDLE
    MERV_QUIESCE_REASON=none
    merv_quiesce_node_jobs_state || :
    printf '%s|%s|%s|%s\n' "$MERV_QUIESCE_STATUS" "$MERV_QUIESCE_REASON" \
      "$MERV_QUIESCE_READY_MANIFEST_COUNT" "$MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT"
  )
)
check test "$legacy_result" = 'BLOCKING|unknown-node-job-entry|0|1'
expect IDLE
check test "$MERV_QUIESCE_READY_MANIFEST_COUNT:$MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT" = 1:1

# Exact producer namespace validation: only direct, private attempt records
# with the final producer grammar qualify. Dot scratch is an unfinished
# publication and therefore keeps the whole node-job inventory blocked.
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
rm -rf "$_forensic_dir"; ln -s "$ROOT/absent" "$_forensic_dir"
expect BLOCKING node-job-ssh-forensics-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
rm -rf "$_forensic_dir"; : > "$_forensic_dir"
expect BLOCKING node-job-ssh-forensics-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
chmod 755 "$_forensic_dir"
expect BLOCKING node-job-ssh-forensics-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
rm "$_forensic_dir/attempt.2147483647.1.log"; ln -s "$ROOT/absent" "$_forensic_dir/attempt.2147483647.1.log"
expect BLOCKING node-job-ssh-forensics-record-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
rm "$_forensic_dir/attempt.2147483647.1.log"; mkfifo "$_forensic_dir/attempt.2147483647.1.log"
expect BLOCKING node-job-ssh-forensics-record-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
rm "$_forensic_dir/attempt.2147483647.1.log"; mkdir "$_forensic_dir/attempt.2147483647.1.log"
expect BLOCKING node-job-ssh-forensics-record-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
: > "$_forensic_dir/unknown.log"
expect BLOCKING unknown-node-job-entry
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
mkdir "$_forensic_dir/unknown-nested"
expect BLOCKING unknown-node-job-entry
for bad_name in \
  attempt.bad.1.log \
  attempt..1.log \
  attempt.pid.1.log \
  attempt.123..log \
  attempt.123.seq.log \
  attempt.123.1.log.extra \
  attempt.123.1.txt; do
  reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
  : > "$_forensic_dir/$bad_name"
  expect BLOCKING node-job-ssh-forensics-name-malformed
done
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
: > "$_forensic_dir/.attempt.123.1.tmp"
expect BLOCKING node-job-partial-publication
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
: > "$_forensic_dir/.list.123"
expect BLOCKING node-job-partial-publication
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
awk 'BEGIN { for (i = 0; i < 14812; i++) printf "x"; printf "\n" }' > "$_forensic_dir/attempt.2147483647.2.log"
chmod 600 "$_forensic_dir/attempt.2147483647.2.log"
expect BLOCKING node-job-ssh-forensics-record-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
chmod 644 "$_forensic_dir/attempt.2147483647.1.log"
expect BLOCKING node-job-ssh-forensics-record-obstructed
reset_prepare_forensics_tree; RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"; _forensic_dir="$RUN/prepare/node_1/ssh_forensics"
if mknod "$_forensic_dir/attempt.2147483647.2.log" c 1 3 2>/dev/null; then
  expect BLOCKING node-job-ssh-forensics-record-obstructed
else
  printf 'SKIP forensic-device-mknod-unavailable\n'
fi

# A terminal result with a reused identity remains idle.
printf '%s\n' "$$" > "$MERV_QUIESCE_NODE_JOBS/1790089829-23820/launch/node_1/wrapper.pid"
expect IDLE
RUN="$MERV_QUIESCE_NODE_JOBS/1790089829-23820"
reset_tree; rm "$RUN/ready"
expect BLOCKING node-job-launched-or-ready-malformed
reset_tree; printf 'bad\n' > "$RUN/ready"
expect BLOCKING node-job-launched-or-ready-malformed
reset_tree; printf 'bad\n' > "$RUN/launched"
expect BLOCKING node-job-launched-or-ready-malformed
reset_tree; printf '2 192.0.2.2\n' > "$RUN/launched"
expect BLOCKING node-job-launched-not-ready
reset_tree; rm "$RUN/status/node_1/result"
expect BLOCKING node-job-result-missing-or-unreadable
reset_tree; printf 'state=ok\n' > "$RUN/status/node_1/result"
expect BLOCKING node-job-result-malformed
reset_tree; printf '%s\n' "$$" > "$RUN/launch/node_1/wrapper.pid"
printf '%s\n' "$CURRENT_START" > "$RUN/launch/node_1/wrapper.proc_start_time"
expect BUSY node-job-wrapper-live
reset_tree
# Deliberately unavailable observer, scoped so subsequent tests use production.
(
  merv_continuation_process_state() { printf 'unknown'; }
  expect BLOCKING node-job-result-owner-unobservable
  printf '%s\n' "$CHECKS" > "$ROOT/unknown-count"
)
CHECKS=$(cat "$ROOT/unknown-count")
reset_tree; : > "$RUN/launch/node_1/.result.tmp"
expect BLOCKING node-job-partial-publication
reset_tree; rm "$RUN/launched"
expect BLOCKING node-job-ready-without-terminal-launch-inventory
for target in ready launched status/node_1/result launch/node_1/wrapper.pid; do
  for attack in symlink fifo directory; do
    reset_tree
    rm "$RUN/$target"
    case "$attack" in
      symlink) ln -s "$ROOT/absent" "$RUN/$target" ;;
      fifo) mkfifo "$RUN/$target" ;;
      directory) mkdir "$RUN/$target" ;;
    esac
    expect BLOCKING
  done
done
reset_tree; : > "$RUN/unknown-file"
expect BLOCKING unknown-node-job-entry
reset_tree; mkdir "$RUN/bad directory"
expect BLOCKING unknown-node-job-dir
reset_tree; ln -s "$RUN/status" "$RUN/sibling-link"
expect BLOCKING unknown-node-job-entry
reset_tree; mkdir -p "$MERV_QUIESCE_NODE_JOBS/aaa/x/y/z/too-deep"
expect BLOCKING node-job-depth
printf 'QUIESCE_RECURSIVE_OK checks=%s shell=%s\n' "$CHECKS" "${FIXTURE_SHELL:-default}"
