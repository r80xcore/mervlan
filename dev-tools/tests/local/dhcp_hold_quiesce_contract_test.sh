#!/bin/sh
# Producer-compatible DHCP Hold inventory and terminal-state contract.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
mkdir -p /tmp/mervlan_tmp || exit 1
TEST_ROOT=$(mktemp -d /tmp/mervlan_tmp/selftest.dhcpq.XXXXXX) || exit 1
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/state" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" "$TEST_ROOT/state" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

export MERV_BASE="$BASE_DIR"
. "$BASE_DIR/settings/lib_selftest_context.sh" || fail context-library
merv_selftest_context_create "$TEST_ROOT" || fail context-create
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
MERV_QUIESCE_LOCK_ROOT="$TEST_ROOT/locks"
MERV_QUIESCE_RUNTIME_ROOT="$TEST_ROOT"
MERV_QUIESCE_STATE_ROOT="$TEST_ROOT/state"
MERV_QUIESCE_SETTINGS_RECONCILE="$TEST_ROOT/state/settings_reconcile.state"
MERV_QUIESCE_NODE_RECONCILE="$TEST_ROOT/state/node_reconcile.pending"
MERV_QUIESCE_TRUST_LOCK="$TEST_ROOT/state/ssh_trust/state.lock"
MERV_QUIESCE_DHCP_ROOT="$TEST_ROOT/locks/dhcp_hold"
MERV_QUIESCE_DHCP_LEGACY="$TEST_ROOT/locks/merv_dhcp_hold.active"
MERV_QUIESCE_OBSERVATION="$TEST_ROOT/locks/observation"
MERV_QUIESCE_NODE_JOBS="$TEST_ROOT/node_jobs"
MERV_QUIESCE_NODE_RUNS="$TEST_ROOT/results/node_runs"
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_DHCP_HOLD_TEST_MODE=1
MERV_DHCP_HOLD_TEST_ROOT="$TEST_ROOT"
MERV_DHCP_HOLD_STATE_ROOT="$MERV_QUIESCE_DHCP_ROOT"
MERV_DHCP_HOLD_LEGACY_MARKER="$MERV_QUIESCE_DHCP_LEGACY"
MERV_DHCP_HOLD_PROC_ROOT=/proc
export MERV_CONTINUATION_ROOT MERV_QUIESCE_LOCK_ROOT MERV_QUIESCE_RUNTIME_ROOT
export MERV_QUIESCE_STATE_ROOT MERV_QUIESCE_SETTINGS_RECONCILE MERV_QUIESCE_NODE_RECONCILE
export MERV_QUIESCE_TRUST_LOCK MERV_QUIESCE_DHCP_ROOT MERV_QUIESCE_DHCP_LEGACY
export MERV_QUIESCE_OBSERVATION MERV_QUIESCE_NODE_JOBS MERV_QUIESCE_NODE_RUNS
export MERV_OWNER_LOCK_PROC_ROOT MERV_DHCP_HOLD_TEST_MODE MERV_DHCP_HOLD_TEST_ROOT
export MERV_DHCP_HOLD_STATE_ROOT MERV_DHCP_HOLD_LEGACY_MARKER MERV_DHCP_HOLD_PROC_ROOT
. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || fail quiesce-library

TEST_HOLD_REQUIRED=0
TEST_RULES_ABSENT=1
merv_dhcp_hold_required() { [ "$TEST_HOLD_REQUIRED" = 1 ]; }
merv_dhcp_hold_rules_absent() { [ "$TEST_RULES_ABSENT" = 1 ]; }
merv_full_fence_classify() { printf absent; }

reset_root() {
  rm -rf "$MERV_QUIESCE_DHCP_ROOT"
  mkdir -p "$MERV_QUIESCE_DHCP_ROOT"
}
expect() {
  _expect=$1
  _got=$(merv_maintenance_quiesce_classify)
  [ "$_got" = "$_expect" ] || fail "expected-$_expect-got-$_got"
}
expect_reason() {
  _expect_status=$1 _expect_reason=$2
  merv_maintenance_quiesce_classify > "$TEST_ROOT/classification"
  _got=$(cat "$TEST_ROOT/classification")
  [ "$_got" = "$_expect_status" ] || fail "expected-$_expect_status-got-$_got"
  [ "$MERV_QUIESCE_REASON" = "$_expect_reason" ] ||
    fail "expected-reason-$_expect_reason-got-$MERV_QUIESCE_REASON"
}
write_field() { printf '%s\n' "$2" > "$1/$3"; }

make_base_handoff() {
  _mbh_id=$1
  _mbh_state=$2
  _mbh_dir="$MERV_QUIESCE_DHCP_ROOT/handoffs/$_mbh_id"
  mkdir -p "$_mbh_dir"
  write_field "$_mbh_dir" "$_mbh_id" handoff_id
  write_field "$_mbh_dir" heal parent_owner_type
  write_field "$_mbh_dir" parent-run-1 parent_run_id
  write_field "$_mbh_dir" parent-ref-1 parent_token_reference
  write_field "$_mbh_dir" manager child_owner_type
  write_field "$_mbh_dir" 1790000001 requested_epoch
  write_field "$_mbh_dir" "$_mbh_state" handoff_state
  write_field "$_mbh_dir" 1 ready
}
make_ack_fields() {
  _maf_dir=$1
  write_field "$_maf_dir" child-run-1 ack_child_run_id
  write_field "$_maf_dir" child-ref-1 ack_child_token_reference
  write_field "$_maf_dir" 1790000002 ack_epoch
}
make_terminal_handoff() {
  _mth_id=$1
  make_base_handoff "$_mth_id" completed
  _mth_dir="$MERV_QUIESCE_DHCP_ROOT/handoffs/$_mth_id"
  make_ack_fields "$_mth_dir"
  write_field "$_mth_dir" verify-1 verification_id
  write_field "$_mth_dir" 1790000003 completed_epoch
  write_field "$_mth_dir" 1790000004 parent_retired_epoch
}

reset_root
expect IDLE
pass 'empty DHCP state is idle'

rm -rf "$MERV_QUIESCE_DHCP_ROOT"
TEST_RULES_ABSENT=1
TEST_HOLD_REQUIRED=0
expect_reason IDLE idle
pass 'absent DHCP state root with absent legacy marker and clear external state is idle'

TEST_RULES_ABSENT=0
expect_reason BLOCKING dhcp-rules-unresolved
TEST_RULES_ABSENT=1
pass 'absent DHCP state root still checks unresolved DHCP Hold rules'

TEST_HOLD_REQUIRED=1
expect_reason BLOCKING dhcp-hold-required
TEST_HOLD_REQUIRED=0
pass 'absent DHCP state root still checks required DHCP Hold ownership'

(
  unset -f merv_dhcp_hold_rules_absent
  merv_maintenance_quiesce_classify > "$TEST_ROOT/classifier-missing"
  [ "$(cat "$TEST_ROOT/classifier-missing")" = BLOCKING ] &&
    [ "$MERV_QUIESCE_REASON" = dhcp-rule-classifier-missing ]
) || fail 'absent DHCP root did not fail closed when the rule classifier is unavailable'
pass 'absent DHCP state root blocks when external rule classifier is unavailable'

rm -rf "$MERV_QUIESCE_DHCP_ROOT"
printf 'obstruction\n' > "$MERV_QUIESCE_DHCP_ROOT"
expect BLOCKING
rm -f "$MERV_QUIESCE_DHCP_ROOT"
ln -s "$TEST_ROOT/state" "$MERV_QUIESCE_DHCP_ROOT"
expect BLOCKING
reset_root
pass 'DHCP state root obstruction and symlink remain blocking'

for category in faults intents owners failsafe; do
  reset_root
  mkdir -p "$MERV_QUIESCE_DHCP_ROOT/$category/entry"
  expect BLOCKING
done
pass 'faults, intents, owners, and failsafes remain blocking'

reset_root
make_base_handoff requested-handoff requested
expect BLOCKING
pass 'requested handoff remains blocking'
reset_root
make_base_handoff acknowledged-handoff acknowledged
make_ack_fields "$MERV_QUIESCE_DHCP_ROOT/handoffs/acknowledged-handoff"
expect BLOCKING
pass 'acknowledged handoff remains blocking'
reset_root
make_base_handoff failed-handoff failed
make_ack_fields "$MERV_QUIESCE_DHCP_ROOT/handoffs/failed-handoff"
write_field "$MERV_QUIESCE_DHCP_ROOT/handoffs/failed-handoff" 1790000003 failed_epoch
write_field "$MERV_QUIESCE_DHCP_ROOT/handoffs/failed-handoff" successor-died failure_reason
expect BLOCKING
pass 'failed handoff remains blocking'

reset_root
make_terminal_handoff completed-handoff
expect IDLE
pass 'exact completed retired handoff is accepted as terminal history'

for malformed in epoch missing-field; do
  reset_root
  make_terminal_handoff malformed-handoff
  _record="$MERV_QUIESCE_DHCP_ROOT/handoffs/malformed-handoff"
  case "$malformed" in
    epoch) write_field "$_record" 01 requested_epoch ;;
    missing-field) rm "$_record/parent_retired_epoch" ;;
  esac
  expect BLOCKING
done
reset_root
make_terminal_handoff unknown-field-handoff
write_field "$MERV_QUIESCE_DHCP_ROOT/handoffs/unknown-field-handoff" extra unexpected_field
expect BLOCKING
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/handoffs/.partial-handoff.pending.123"
expect BLOCKING
pass 'malformed, extended, and partial handoff publications block'

reset_root
make_terminal_handoff linked-handoff
printf 'reason=manager-active\nrequested_epoch=1790000005\nattached_handoff=linked-handoff\n' \
  > "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
expect IDLE
pass 'completed handoff plus exact linked heal note is terminal advisory state'

reset_root
make_base_handoff active-linked-handoff acknowledged
make_ack_fields "$MERV_QUIESCE_DHCP_ROOT/handoffs/active-linked-handoff"
printf 'reason=manager-active\nrequested_epoch=1790000005\nattached_handoff=active-linked-handoff\n' \
  > "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
expect BLOCKING
reset_root
printf 'reason=manager-active\nrequested_epoch=1790000005\n' > "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
expect BLOCKING
reset_root
make_terminal_handoff malformed-linked-handoff
printf 'reason=manager-active\nrequested_epoch=01\nattached_handoff=malformed-linked-handoff\n' \
  > "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
expect BLOCKING
reset_root
make_terminal_handoff missing-linked-handoff
printf 'reason=manager-active\nrequested_epoch=1790000005\nattached_handoff=absent-handoff\n' \
  > "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
expect BLOCKING
reset_root
make_terminal_handoff temporary-marker-handoff
: > "$MERV_QUIESCE_DHCP_ROOT/.heal.pending.tmp.123"
expect BLOCKING
pass 'active, orphaned, malformed, missing-link, and temporary heal notes block'

# Test producer publication itself in an isolated self-test root. A matching
# active handoff gets an exact attached marker; absence of a handoff leaves no
# ambiguous orphan marker behind.
reset_root
make_base_handoff producer-active acknowledged
make_ack_fields "$MERV_QUIESCE_DHCP_ROOT/handoffs/producer-active"
_producer_rc=0
merv_dhcp_handoff_coalesce heal manager manager-active || _producer_rc=$?
[ "$_producer_rc" = 0 ] || fail producer-attached-return
grep -q '^attached_handoff=producer-active$' "$MERV_QUIESCE_DHCP_ROOT/heal.pending" || fail producer-attached-field
for _tmp in "$MERV_QUIESCE_DHCP_ROOT"/.heal.pending.tmp.*; do
  [ -e "$_tmp" ] || [ -L "$_tmp" ] || continue
  fail producer-temporary-remains
done
rm -rf "$MERV_QUIESCE_DHCP_ROOT/handoffs" "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
_producer_rc=0
merv_dhcp_handoff_coalesce heal manager manager-active || _producer_rc=$?
[ "$_producer_rc" = 1 ] || fail producer-unattached-return
[ ! -e "$MERV_QUIESCE_DHCP_ROOT/heal.pending" ] || fail producer-created-orphan-note
pass 'coalescing producer publishes only notes attached to active handoffs'

# Symlinks, FIFOs, and directory substitutions never become accepted history.
reset_root
mkdir -p "$TEST_ROOT/target"
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/handoffs"
ln -s "$TEST_ROOT/target" "$MERV_QUIESCE_DHCP_ROOT/handoffs/link-handoff"
expect BLOCKING
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/handoffs"
mkfifo "$MERV_QUIESCE_DHCP_ROOT/handoffs/fifo-handoff"
expect BLOCKING
for substitution in symlink fifo directory; do
  reset_root
  make_terminal_handoff object-handoff
  rm "$MERV_QUIESCE_DHCP_ROOT/handoffs/object-handoff/ready"
  case "$substitution" in
    symlink) ln -s "$TEST_ROOT/target" "$MERV_QUIESCE_DHCP_ROOT/handoffs/object-handoff/ready" ;;
    fifo) mkfifo "$MERV_QUIESCE_DHCP_ROOT/handoffs/object-handoff/ready" ;;
    directory) mkdir "$MERV_QUIESCE_DHCP_ROOT/handoffs/object-handoff/ready" ;;
  esac
  expect BLOCKING
done
for substitution in symlink fifo directory; do
  reset_root
  make_terminal_handoff heal-object-handoff
  case "$substitution" in
    symlink)
      printf 'reason=manager-active\nrequested_epoch=1790000005\nattached_handoff=heal-object-handoff\n' > "$TEST_ROOT/marker"
      ln -s "$TEST_ROOT/marker" "$MERV_QUIESCE_DHCP_ROOT/heal.pending"
      ;;
    fifo) mkfifo "$MERV_QUIESCE_DHCP_ROOT/heal.pending" ;;
    directory) mkdir "$MERV_QUIESCE_DHCP_ROOT/heal.pending" ;;
  esac
  expect BLOCKING
done
pass 'DHCP handoff and heal records reject symlink, FIFO, and directory substitutions'

# The state.lock producer writes four direct fields, not the generic owner
# file used by lib_owner_lock. A valid live identity is BUSY; stale canonical
# claims and malformed publication remain blocking.
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/state.lock"
_current_start=$(merv_identity_current_start /proc) || fail state-lock-current-identity
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" "$$" pid
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" "$_current_start" proc_start_time
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" 1790000001 created_epoch
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" fixture.owner.1 owner_nonce
expect BUSY
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/state.lock"
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" 2147483647 pid
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" 1 proc_start_time
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" 1790000001 created_epoch
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock" fixture.owner.1 owner_nonce
expect BLOCKING
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/state.lock.stale.1790000002.fixture.quarantine"
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock.stale.1790000002.fixture.quarantine" 2147483647 pid
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock.stale.1790000002.fixture.quarantine" 1 proc_start_time
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock.stale.1790000002.fixture.quarantine" 1790000001 created_epoch
write_field "$MERV_QUIESCE_DHCP_ROOT/state.lock.stale.1790000002.fixture.quarantine" fixture.owner.1 owner_nonce
expect IDLE
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/state.lock.incomplete-stale.1790000002.fixture.quarantine"
expect IDLE
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/state.lock.incomplete.1790000002.fixture.quarantine"
expect BLOCKING
pass 'dedicated state.lock live, stale, and retained quarantine states are classified'

# Required protection can never be hidden by otherwise-terminal history.
reset_root
make_terminal_handoff held-handoff
TEST_HOLD_REQUIRED=1
expect BLOCKING
TEST_HOLD_REQUIRED=0
TEST_RULES_ABSENT=0
expect BLOCKING
TEST_RULES_ABSENT=1
pass 'DHCP Hold rules and required owner state never classify IDLE'

reset_root
TEST_RULES_ABSENT=0
expect_reason BLOCKING dhcp-rules-unresolved
TEST_RULES_ABSENT=1
pass 'present empty DHCP state root still checks unresolved DHCP Hold rules'

reset_root
: > "$MERV_QUIESCE_DHCP_ROOT/recovery.pending"
expect BLOCKING
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/owners/live-owner"
write_field "$MERV_QUIESCE_DHCP_ROOT/owners/live-owner" 1 ready
expect BLOCKING
reset_root
mkdir -p "$MERV_QUIESCE_DHCP_ROOT/failsafe/recovery-required"
expect BLOCKING
pass 'recovery, live owners, and failsafes never classify IDLE'

# Exercise the real merv_dhcp_hold_required and merv_dhcp_hold_rules_absent
# implementations with the library's guarded fake ebtables backend. This
# proves root absence reaches the actual external classifier path without
# invoking host ebtables or changing host networking state.
cat > "$TEST_ROOT/ebtables" <<'EOF'
#!/bin/sh
case "${4:-}" in
  MERV_DHCP_HOLD) exit 1 ;;
  FORWARD)
    if [ "${TEST_REAL_DHCP_RULES:-0}" = 1 ]; then
      printf '%s\n' '-A FORWARD -j MERV_DHCP_HOLD'
    fi
    exit 0
    ;;
  INPUT) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$TEST_ROOT/ebtables"
(
  unset -f merv_dhcp_hold_required merv_dhcp_hold_rules_absent
  unset LIB_MERVQT_LOADED
  MERV_DHCP_HOLD_EBTABLES="$TEST_ROOT/ebtables"
  export MERV_DHCP_HOLD_EBTABLES
  . "$BASE_DIR/settings/lib_mervqt.sh" || exit 90
  rm -rf "$MERV_QUIESCE_DHCP_ROOT"
  TEST_REAL_DHCP_RULES=0
  export TEST_REAL_DHCP_RULES
  merv_maintenance_quiesce_classify > "$TEST_ROOT/actual-clear"
  _actual_clear=$(cat "$TEST_ROOT/actual-clear")
  [ "$_actual_clear" = IDLE ] && [ "$MERV_QUIESCE_REASON" = idle ] || exit 91
  TEST_REAL_DHCP_RULES=1
  merv_maintenance_quiesce_classify > "$TEST_ROOT/actual-present"
  _actual_present=$(cat "$TEST_ROOT/actual-present")
  [ "$_actual_present" = BLOCKING ] &&
    [ "$MERV_QUIESCE_REASON" = dhcp-rules-unresolved ] || exit 92
) || fail 'real DHCP Hold rule classifier was not reached from absent root'
pass 'source-real DHCP Hold classifier distinguishes absent rules from lingering rules'
