#!/bin/sh
# Focused contract test for observation blocker and resume diagnostics.
set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_ROOT="${TMPDIR:-/tmp}/mervlan_tmp/selftest.observation-blocker.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  _acl_needle=$1
  _acl_file=$2
  grep -F "$_acl_needle" "$_acl_file" >/dev/null 2>&1 ||
    fail "expected '$_acl_needle' in $_acl_file"
}

assert_not_contains() {
  _acn_needle=$1
  _acn_file=$2
  if grep -F "$_acn_needle" "$_acn_file" >/dev/null 2>&1; then
    fail "did not expect '$_acn_needle' in $_acn_file"
  fi
}

line_number() {
  _aln_needle=$1
  _aln_file=$2
  grep -n -F "$_aln_needle" "$_aln_file" 2>/dev/null |
    head -n 1 | cut -d: -f1
}

setup_case() {
  _sc_name=$1
  _sc_root="$TEST_ROOT/$_sc_name"
  mkdir -p "$_sc_root/settings" "$_sc_root/functions" \
    "$_sc_root/tmp" "$_sc_root/locks" "$_sc_root/results" \
    "$_sc_root/config-locks" "$_sc_root/dhcp/owners" ||
    fail "unable to create fixture $_sc_name"

  cp "$BASE_DIR/functions/post_apply_worker.sh" \
    "$_sc_root/functions/post_apply_worker.sh" ||
    fail "unable to copy observation worker for $_sc_name"
  chmod 700 "$_sc_root/functions/post_apply_worker.sh" ||
    fail "unable to mark observation worker executable for $_sc_name"

  cat >"$_sc_root/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
LOG_SETTINGS_LOADED=1
LIB_JSON_LOADED=1
LIB_ACTION_ACK_LOADED=1
LIB_IDENTITY_LOADED=1
LIB_OWNER_LOCK_LOADED=1
LIB_MERVQT_LOADED=1
LIB_UPDATE_STATE_LOADED=1
LIB_SSID_FILTER_LOADED=1
LIB_MAC_SHIELD_SNAPSHOT_LOADED=1
LIB_PROGRESS_LOADED=1

: "${MERV_TEST_ROOT:?}"
TMPDIR="$MERV_TEST_ROOT/tmp"
LOCKDIR="$MERV_TEST_ROOT/locks"
RESULTDIR="$MERV_TEST_ROOT/results"
MERV_OBSERVATION_ROOT="$MERV_TEST_ROOT/observation"
MERV_OBSERVATION_CONFIG_LOCKDIR="$MERV_TEST_ROOT/config-locks"
MERV_DHCP_HOLD_TEST_MODE=1
MERV_DHCP_HOLD_TEST_ROOT="$MERV_TEST_ROOT"
MERV_DHCP_HOLD_STATE_ROOT="$MERV_TEST_ROOT/dhcp"
SETTINGS_FILE="$MERV_TEST_ROOT/settings/settings.json"
HW_SETTINGS_FILE="$MERV_TEST_ROOT/settings/hw.json"
MAX_SSIDS=1
MERV_NODE_ID=main
MERV_PROGRESS_TOKEN=""
export TMPDIR LOCKDIR RESULTDIR MERV_OBSERVATION_ROOT
export MERV_OBSERVATION_CONFIG_LOCKDIR MERV_DHCP_HOLD_TEST_MODE
export MERV_DHCP_HOLD_TEST_ROOT MERV_DHCP_HOLD_STATE_ROOT
export SETTINGS_FILE HW_SETTINGS_FILE MAX_SSIDS MERV_NODE_ID
export MERV_PROGRESS_TOKEN

info() {
  if [ "${1:-}" = '-c' ]; then
    shift 2
  fi
  printf '[INFO] %s\n' "$*" >>"$MERV_TEST_ROOT/observation.log"
  printf '%s\n' "$*" >>"$MERV_TEST_ROOT/timeline"
}
warn() { :; }
error() { :; }

merv_cap_ssids() { printf '%s\n' "$1"; }
ssid_filter_init() { :; }
merv_update_mutation_blocked() { return 1; }
merv_identity_nonce_next() {
  MERV_IDENTITY_NONCE="fixture.$$"
  return 0
}
merv_dhcp_hold_test_root_valid() { return 0; }

merv_lock_state() {
  if [ -d "$1" ]; then
    printf '%s\n' active
  else
    printf '%s\n' idle
  fi
}

merv_owner_lock_acquire() {
  _mola_lock=$1
  if [ "$_mola_lock" = "$MERV_TEST_ROOT/observation/worker.lock" ] &&
     [ -f "$MERV_TEST_ROOT/worker-busy" ]; then
    return 1
  fi
  mkdir -p "$_mola_lock" || return 1
  MERV_LOCK_NONCE=fixture
  MERV_LOCK_START=1
  return 0
}

merv_owner_lock_release() {
  rmdir "$1" 2>/dev/null || return 1
  return 0
}

sleep() {
  if [ "${MERV_TEST_SLEEP_SCENARIO:-}" = clear-blocker-after-defer ] &&
     [ ! -f "$MERV_TEST_ROOT/sleep-fired" ]; then
    : >"$MERV_TEST_ROOT/sleep-fired"
    rmdir "$MERV_TEST_ROOT/config-locks/mervlan_manager.lock" 2>/dev/null || :
  elif [ "${MERV_TEST_SLEEP_SCENARIO:-}" = complete-before-retry ] &&
       [ ! -f "$MERV_TEST_ROOT/sleep-fired" ]; then
    : >"$MERV_TEST_ROOT/sleep-fired"
    {
      printf 'snapshot_requested_generation=1\n'
      printf 'snapshot_completed_generation=1\n'
      printf 'collection_requested_generation=0\n'
      printf 'collection_completed_generation=0\n'
    } >"$MERV_TEST_ROOT/observation/request.state"
  fi
  command sleep "$@"
}
EOF

  cat >"$_sc_root/snapshot_cmd" <<'EOF'
#!/bin/sh
printf '%s\n' snapshot-action >>"$MERV_TEST_ROOT/timeline"
exit 0
EOF
  cat >"$_sc_root/collection_cmd" <<'EOF'
#!/bin/sh
printf '%s\n' collection-action >>"$MERV_TEST_ROOT/timeline"
exit 0
EOF
  chmod 700 "$_sc_root/snapshot_cmd" "$_sc_root/collection_cmd" ||
    fail "unable to mark observation fixtures executable for $_sc_name"
}

run_worker() {
  _rw_root=$1
  shift
  MERV_BASE="$_rw_root" \
  MERV_TEST_ROOT="$_rw_root" \
  MERV_TEST_SLEEP_SCENARIO="${MERV_TEST_SLEEP_SCENARIO:-}" \
  MERV_OBS_NO_AUTOSTART=1 \
  MERV_OBS_SNAPSHOT_CMD="$_rw_root/snapshot_cmd" \
  MERV_OBS_COLLECTION_CMD="$_rw_root/collection_cmd" \
    sh "$_rw_root/functions/post_apply_worker.sh" "$@"
}

run_rc() {
  _rr_expected=$1
  _rr_root=$2
  shift 2
  _rr_actual=0
  run_worker "$_rr_root" "$@" >"$_rr_root/worker.output" 2>&1 ||
    _rr_actual=$?
  [ "$_rr_actual" -eq "$_rr_expected" ] ||
    fail "$_rr_root $* returned $_rr_actual, expected $_rr_expected"
}

# Case 1: manager lock blocks both pending operations.
setup_case vlan-manager
_root="$TEST_ROOT/vlan-manager"
run_worker "$_root" request snapshot collect >/dev/null 2>&1 ||
  fail 'manager fixture request failed'
mkdir -p "$_root/config-locks/mervlan_manager.lock" || fail 'manager lock fixture failed'
run_rc 75 "$_root" run
assert_contains \
  'Observation: queued: MAC snapshot + client collection pending; blocked by VLAN manager' \
  "$_root/observation.log"
assert_not_contains 'configuration mutation active; generations remain pending' \
  "$_root/observation.log"
printf '%s\n' 'PASS: VLAN manager blocker diagnostic and rc=75'

# Case 2: event lock blocks only a pending collection.
setup_case vlan-event
_root="$TEST_ROOT/vlan-event"
run_worker "$_root" request collect >/dev/null 2>&1 ||
  fail 'event fixture request failed'
mkdir -p "$_root/config-locks/vlan_event.lock" || fail 'event lock fixture failed'
run_rc 75 "$_root" run
assert_contains \
  'Observation: queued: client collection pending; blocked by VLAN event' \
  "$_root/observation.log"
printf '%s\n' 'PASS: VLAN event blocker diagnostic and rc=75'

# Case 3: a ready mutating DHCP owner is reported with its existing owner type.
setup_case dhcp-mutating
_root="$TEST_ROOT/dhcp-mutating"
mkdir -p "$_root/dhcp/owners/manager-owner" || fail 'mutating owner fixture failed'
printf '%s\n' 1 >"$_root/dhcp/owners/manager-owner/ready"
printf '%s\n' manager >"$_root/dhcp/owners/manager-owner/owner_type"
printf '%s\n' mutating >"$_root/dhcp/owners/manager-owner/phase"
run_worker "$_root" request snapshot >/dev/null 2>&1 ||
  fail 'mutating owner request failed'
run_rc 75 "$_root" run
assert_contains \
  'Observation: queued: MAC snapshot pending; blocked by DHCP owner: manager (mutating)' \
  "$_root/observation.log"
printf '%s\n' 'PASS: DHCP mutating owner diagnostic'

# Case 4: a ready handoff owner remains a blocker and is named compactly.
setup_case dhcp-handoff
_root="$TEST_ROOT/dhcp-handoff"
mkdir -p "$_root/dhcp/owners/manager-owner" || fail 'handoff owner fixture failed'
printf '%s\n' 1 >"$_root/dhcp/owners/manager-owner/ready"
printf '%s\n' manager >"$_root/dhcp/owners/manager-owner/owner_type"
printf '%s\n' handoff_wait >"$_root/dhcp/owners/manager-owner/phase"
run_worker "$_root" request snapshot collect >/dev/null 2>&1 ||
  fail 'handoff owner request failed'
run_rc 75 "$_root" run
assert_contains \
  'blocked by DHCP owner: manager (handoff_wait)' "$_root/observation.log"
printf '%s\n' 'PASS: DHCP handoff owner diagnostic'

# Case 5: a deferred run retries after the blocker clears and logs resume
# before either fixture action starts.
setup_case resume
_root="$TEST_ROOT/resume"
run_worker "$_root" request snapshot collect >/dev/null 2>&1 ||
  fail 'resume fixture request failed'
mkdir -p "$_root/config-locks/mervlan_manager.lock" || fail 'resume lock fixture failed'
MERV_TEST_SLEEP_SCENARIO=clear-blocker-after-defer
run_rc 0 "$_root" run-wait 3
unset MERV_TEST_SLEEP_SCENARIO
assert_contains \
  'Observation: queued: MAC snapshot + client collection pending; blocked by VLAN manager' \
  "$_root/timeline"
assert_contains 'Observation: blocker cleared; resuming queued work' "$_root/timeline"
_resume_count=$(grep -F -c 'Observation: blocker cleared; resuming queued work' \
  "$_root/observation.log")
[ "$_resume_count" -eq 1 ] || fail "resume log count=$_resume_count"
_queued_line=$(line_number \
  'Observation: queued: MAC snapshot + client collection pending; blocked by VLAN manager' \
  "$_root/timeline")
_resume_line=$(line_number 'Observation: blocker cleared; resuming queued work' "$_root/timeline")
_snapshot_line=$(line_number snapshot-action "$_root/timeline")
_collection_line=$(line_number collection-action "$_root/timeline")
[ -n "$_queued_line" ] && [ -n "$_resume_line" ] &&
  [ -n "$_snapshot_line" ] && [ -n "$_collection_line" ] ||
  fail 'resume ordering markers are incomplete'
[ "$_queued_line" -lt "$_resume_line" ] &&
  [ "$_resume_line" -lt "$_snapshot_line" ] &&
  [ "$_snapshot_line" -lt "$_collection_line" ] ||
  fail 'resume log did not precede queued fixture work'
printf '%s\n' 'PASS: resume diagnostic is emitted once before queued work'

# Case 6: repeated defer attempts may repeat the queued line but never claim
# that the blocker cleared.
setup_case still-blocked
_root="$TEST_ROOT/still-blocked"
run_worker "$_root" request snapshot >/dev/null 2>&1 ||
  fail 'still-blocked fixture request failed'
mkdir -p "$_root/config-locks/mervlan_manager.lock" || fail 'still-blocked lock fixture failed'
MERV_TEST_SLEEP_SCENARIO=none
run_rc 75 "$_root" run-wait 2
unset MERV_TEST_SLEEP_SCENARIO
_queued_count=$(grep -F -c 'Observation: queued: MAC snapshot pending; blocked by VLAN manager' \
  "$_root/observation.log")
[ "$_queued_count" -ge 2 ] || fail "expected repeated queued logs, count=$_queued_count"
assert_not_contains 'Observation: blocker cleared; resuming queued work' \
  "$_root/observation.log"
printf '%s\n' 'PASS: still-blocked retries repeat queued diagnostics without resume'

# Case 7: if another worker completes the target before retry ownership, the
# retry exits without claiming that it resumed work.
setup_case no-remaining-work
_root="$TEST_ROOT/no-remaining-work"
run_worker "$_root" request snapshot >/dev/null 2>&1 ||
  fail 'no-work fixture request failed'
mkdir -p "$_root/config-locks/mervlan_manager.lock" || fail 'no-work lock fixture failed'
MERV_TEST_SLEEP_SCENARIO=complete-before-retry
run_rc 0 "$_root" run-wait 3
unset MERV_TEST_SLEEP_SCENARIO
assert_contains 'Observation: queued: MAC snapshot pending; blocked by VLAN manager' \
  "$_root/observation.log"
assert_not_contains 'Observation: blocker cleared; resuming queued work' \
  "$_root/observation.log"
assert_not_contains snapshot-action "$_root/timeline"
printf '%s\n' 'PASS: no remaining work does not emit resume diagnostic'

printf '%s\n' 'OBSERVATION_BLOCKER_LOGGING_CONTRACT_OK'
