#!/bin/sh
# Read-only Q classification: authoritative idle, waitable work, and blockers.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT=$(mktemp -d /tmp/mervlan-q-inventory.XXXXXX) || exit 1
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
export MERV_CONTINUATION_ROOT MERV_QUIESCE_LOCK_ROOT MERV_QUIESCE_RUNTIME_ROOT
export MERV_QUIESCE_STATE_ROOT MERV_QUIESCE_SETTINGS_RECONCILE MERV_QUIESCE_NODE_RECONCILE
export MERV_QUIESCE_TRUST_LOCK
export MERV_QUIESCE_DHCP_ROOT MERV_QUIESCE_DHCP_LEGACY MERV_QUIESCE_OBSERVATION
export MERV_QUIESCE_NODE_JOBS MERV_QUIESCE_NODE_RUNS MERV_OWNER_LOCK_PROC_ROOT
. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || fail quiesce-library

# Host tests have no ASUSWRT ebtables table. Stub only the read-only device
# observation result after loading the production classifier.
merv_dhcp_hold_required() { return 1; }
merv_dhcp_hold_rules_absent() { return 0; }
for name in heal_event.last vlan_event.last vlan_heal.last vlan_health_ok.last vlan_last_mismatch.last mac_precondition_heal.last self_restart.marker; do
  object="$TEST_ROOT/locks/$name"
  for value in 0 1790000000 1790000045; do
    printf '%s\n' "$value" > "$object"
    [ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail "$name-valid"
  done
  for value in '' bad 01 '-1' '1 2'; do
    printf '%s\n' "$value" > "$object"
    [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-malformed"
  done
  for attack in truncated multiple nul oversized; do
    case "$attack" in
      truncated) printf 123 > "$object" ;;
      multiple) printf '1\n2\n' > "$object" ;;
      nul) printf '1\0002\n' > "$object" ;;
      oversized) printf '123456789012345678901234567890\n' > "$object" ;;
    esac
    [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-$attack"
  done
  rm "$object"
  printf '1790000000\n' > "$TEST_ROOT/target"
  ln -s "$TEST_ROOT/target" "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-symlink"
  rm "$object"; mkdir "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-directory"
  rmdir "$object"; mkfifo "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-fifo"
  rm "$object"
  pass "$name explicit epoch grammar and object attack matrix"
done
for name in merv_boot_shield.active merv_boot_shield.ready merv_boot_shield.handoff merv_boot_shield.pid merv_boot_shield.pid.start merv_dhcp_hold.active native_auth.snapshot.123 unknown.last ..unknown; do
  printf '1790000000\n' > "$TEST_ROOT/locks/$name"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-blocking"
  rm "$TEST_ROOT/locks/$name"
done
pass 'active boot, temporary native-auth and unknown objects block'

# Enumerate ordinary producer owner families, including dispatcher actions.
for name in mervlan_maintenance.lock mervlan_action.lock mervlan_manager.lock vlan_event.lock execute_nodes.lock client_collect.lock sync_nodes.lock mac_client_meta.lock mac_snapshot.lock merv_boot_shield.transient.lock save_vlanmgr.lock; do
  object="$TEST_ROOT/locks/$name"
  merv_owner_lock_acquire "$object" 0 0 inventory-owner || fail "$name-acquire"
  nonce=$MERV_LOCK_NONCE
  [ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail "$name-owner-active"
  merv_owner_lock_release "$object" "$nonce" || fail "$name-release"
  mkdir "$object"; printf bad > "$object/owner"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-owner-malformed"
  rm -rf "$object"
  ln -s "$TEST_ROOT/locks" "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-owner-symlink"
  rm "$object"; printf bad > "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-owner-file"
  rm "$object"; mkfifo "$object"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-owner-fifo"
  rm "$object"
  pass "$name authoritative owner and malformed/object matrix"
done
for name in dhcp_hold observation; do
  object="$TEST_ROOT/locks/$name"
  mkdir "$object"
  [ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail "$name-empty-valid"
  printf bad > "$object/unknown"
  [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-unknown-child"
  rm "$object/unknown"; rmdir "$object"
  for attack in file fifo symlink; do
    case "$attack" in file) printf bad > "$object" ;; fifo) mkfifo "$object" ;; symlink) ln -s "$TEST_ROOT/locks" "$object" ;; esac
    [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$name-$attack"
    rm "$object"
  done
  pass "$name directory/container object matrix"
done

mkdir -p "$TEST_ROOT/locks/observation/faults"
for kind in snapshot collection; do
  object="$TEST_ROOT/locks/observation/faults/$kind-1-1790000000-1"
  printf 'operation=%s\ngeneration=1\nepoch=1790000000\n' "$kind" > "$object"
  [ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail "$kind-diagnostic-valid"
  for attack in malformed oversized directory symlink fifo; do
    rm "$object"
    case "$attack" in
      malformed) printf 'operation=unknown\n' > "$object" ;;
      oversized) head -c 129 /dev/zero > "$object" ;;
      directory) mkdir "$object" ;;
      symlink) ln -s "$TEST_ROOT/target" "$object" ;;
      fifo) mkfifo "$object" ;;
    esac
    [ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail "$kind-diagnostic-$attack"
    if [ -d "$object" ]; then rmdir "$object"; else rm "$object"; fi
    printf 'operation=%s\ngeneration=1\nepoch=1790000000\n' "$kind" > "$object"
  done
  rm "$object"
  pass "$kind explicit historical diagnostic format and object matrix"
done
printf bad > "$TEST_ROOT/locks/observation/faults/unknown"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail diagnostic-unknown
rm "$TEST_ROOT/locks/observation/faults/unknown"
rmdir "$TEST_ROOT/locks/observation/faults" "$TEST_ROOT/locks/observation"

# Execute the actual heal owner/admission source boundary in a real delayed
# process. Logging is stubbed; authority and owner cleanup functions are real.
python3 - "$BASE_DIR" "$TEST_ROOT/worker.sh" <<'PYWORKER'
from pathlib import Path
import sys
source=(Path(sys.argv[1])/'functions/heal_event.sh').read_text()
body=source[source.index('# Ensure locks directory'):source.index('# Reconcile interrupted DHCP ownership')]
header='''#!/bin/sh
. "$MERV_BASE/settings/lib_mutation_admission.sh" || exit 2
info() { :; }; warn() { :; }; error() { printf '%s\n' "$*" >&2; }
: > "$TEST_ROOT/worker-pending"
while [ ! -f "$TEST_ROOT/wake" ]; do sleep 0.1; done
'''
Path(sys.argv[2]).write_text(header+body+'\n: > "$TEST_ROOT/MUTATION"\n')
PYWORKER
export TEST_ROOT
MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/locks/mervlan_maintenance.lock"
MERV_FULL_FENCE_PATH="$TEST_ROOT/full.lock"
export MERV_UPDATE_MAINTENANCE_LOCK MERV_FULL_FENCE_PATH
. "$BASE_DIR/settings/lib_mutation_admission.sh" || fail admission-library
for name in heal_event.last mac_precondition_heal.last vlan_event.last vlan_heal.last vlan_health_ok.last vlan_last_mismatch.last self_restart.marker; do
  printf '1790000000\n' > "$TEST_ROOT/locks/$name"
  env LOCKDIR="$TEST_ROOT/locks" sh "$TEST_ROOT/worker.sh" > "$TEST_ROOT/worker.log" 2>&1 &
  worker=$!
  tries=0
  while [ ! -f "$TEST_ROOT/worker-pending" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -f "$TEST_ROOT/worker-pending" ] || fail worker-pending
  merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 0 0 full-main || fail M
  mn=$MERV_LOCK_NONCE; ms=$MERV_LOCK_START
  merv_full_fence_claim "$MERV_FULL_FENCE_PATH" || fail F
  fn=$MERV_FULL_FENCE_NONCE
  [ "$(merv_maintenance_quiesce_classify "$$" "$ms" "$mn" "$$" "$ms" "$fn")" = IDLE ] || fail "$name-Q-under-M-F"
  : > "$TEST_ROOT/wake"
  rc=0; wait "$worker" || rc=$?
  [ "$rc" = 75 ] || fail "$name-worker-refusal"
  [ ! -e "$TEST_ROOT/MUTATION" ] || fail mutation-slipped
  [ ! -e "$TEST_ROOT/locks/vlan_event.lock" ] || fail worker-owner-cleanup
  merv_full_fence_release "$MERV_FULL_FENCE_PATH" "$$" "$ms" "$fn" || fail release-F
  merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$mn" || fail release-M
  rm "$TEST_ROOT/wake" "$TEST_ROOT/worker-pending" "$TEST_ROOT/locks/$name"
  pass "$name real delayed worker refuses under Full M/F after owning R"
done
# Inline system-event re-link runs in the handler's own process identity.
python3 - "$BASE_DIR" "$TEST_ROOT/inline.sh" <<'PYINLINE'
from pathlib import Path
import sys
source=(Path(sys.argv[1])/'functions/service-event-handler.sh').read_text()
start=source.index('    _se_heal_lock="$LOCKDIR/vlan_event.lock"')
end=source.index('    logger -t "VLANMgr" "handler: queued heal_event',start)
header='''#!/bin/sh
. "$MERV_BASE/settings/lib_mutation_admission.sh" || exit 2
logger() { :; }
ebtables() {
  : > "$TEST_ROOT/inline-mutation"
  if [ -f "$TEST_ROOT/pause-inline" ]; then
    : > "$TEST_ROOT/inline-active"
    while [ ! -f "$TEST_ROOT/inline-continue" ]; do sleep 0.1; done
  fi
  return 1
}
MERV_HEAL_EVENT_DEBOUNCE=0
MERV_HEAL_DELAY=0
COMBINED_NORM=restart_lan
'''
Path(sys.argv[2]).write_text(header+source[start:end])
PYINLINE
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 0 0 full-main || fail inline-M
mn=$MERV_LOCK_NONCE; ms=$MERV_LOCK_START
merv_full_fence_claim "$MERV_FULL_FENCE_PATH" || fail inline-F
fn=$MERV_FULL_FENCE_NONCE
rc=0
env LOCKDIR="$TEST_ROOT/locks" sh "$TEST_ROOT/inline.sh" || rc=$?
[ "$rc" = 75 ] && [ ! -e "$TEST_ROOT/inline-mutation" ] && [ ! -e "$TEST_ROOT/locks/heal_event.last" ] || fail inline-admission
merv_full_fence_release "$MERV_FULL_FENCE_PATH" "$$" "$ms" "$fn" || fail inline-release-F
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$mn" || fail inline-release-M
pass 'actual inline handler refuses under F/M before timestamp and ebtables'
: > "$TEST_ROOT/pause-inline"
env LOCKDIR="$TEST_ROOT/locks" sh "$TEST_ROOT/inline.sh" &
worker=$!
tries=0
while [ ! -f "$TEST_ROOT/inline-active" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
[ -f "$TEST_ROOT/inline-active" ] || fail inline-active
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 0 0 full-main || fail inline-race-M
mn=$MERV_LOCK_NONCE; ms=$MERV_LOCK_START
merv_full_fence_claim "$MERV_FULL_FENCE_PATH" || fail inline-race-F
fn=$MERV_FULL_FENCE_NONCE
[ "$(merv_maintenance_quiesce_classify "$$" "$ms" "$mn" "$$" "$ms" "$fn")" = BUSY ] || fail inline-race-Q
: > "$TEST_ROOT/inline-continue"
wait "$worker" || fail inline-terminal
[ ! -e "$TEST_ROOT/locks/vlan_event.lock" ] || fail inline-owner-release
merv_full_fence_release "$MERV_FULL_FENCE_PATH" "$$" "$ms" "$fn" || fail inline-race-release-F
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$mn" || fail inline-race-release-M
pass 'actual inline handler already admitted remains visible to Q through its R'

# Keep node-job inventory tied to the retained Execute producer topology. The
# fixture asserts the synthetic ssh_forensics directories and completed files
# exist before exercising Q, then checks the legacy defect signature and the
# corrected IDLE result with hostile entries.
sh "$TEST_DIR/maintenance_quiesce_recursive_fixture.sh" || fail node-job-ssh-forensics-producer-inventory
pass 'product inventory accepts only producer-compatible node-job SSH forensic output'
