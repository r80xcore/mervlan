#!/bin/sh
# Behavioral state-transition coverage for durable MAIN-to-node convergence.
# This uses only the protected marker library and private files; it never
# starts Sync Nodes, SSH, or a router action.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
ROOT="${TMPDIR:-/tmp}/mervlan-settings-convergence.$$"
cleanup() {
    if [ -n "${RUNNER_HOLDER_PID:-}" ]; then
        kill "$RUNNER_HOLDER_PID" 2>/dev/null || :
        wait "$RUNNER_HOLDER_PID" 2>/dev/null || :
    fi
    rm -rf "$ROOT"
}
trap cleanup 0 1 2 3 15
mkdir -p "$ROOT/state" || exit 1

export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$ROOT/state"
export MERV_SETTINGS_RECONCILE_FILE="$MERV_STATE_ROOT/settings_reconcile.state"

. "$BASE_DIR/settings/var_settings.sh"
. "$BASE_DIR/settings/lib_settings_reconcile.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
publish() { merv_settings_reconcile_publish "$1" "$2" pending 0 0; }

# Extract the production capture/terminal helper exactly as Sync Nodes runs it.
# The digest functions are controlled only for this private behavioral seam.
SYNC_HELPERS="$ROOT/sync_helpers.sh"
sed -n '/^sync_settings_reconcile_capture() {/,/^}/p' \
    "$BASE_DIR/functions/sync_nodes.sh" > "$SYNC_HELPERS"
sed -n '/^sync_settings_reconcile_finish() {/,/^}/p' \
    "$BASE_DIR/functions/sync_nodes.sh" >> "$SYNC_HELPERS"
[ -s "$SYNC_HELPERS" ] || fail production-helper-extraction
warn() { :; }
TEST_SETTINGS_DIGEST=md5:save-a
TEST_NODE_DIGEST=cksum:nodes-a
MERV_SSH_TRUST_LAST_REASON=
MERV_SSH_LAST_REASON=
merv_settings_node_sync_digest() { printf '%s\n' "$TEST_SETTINGS_DIGEST"; }
merv_node_list_digest() { printf '%s\n' "$TEST_NODE_DIGEST"; }
DRY_RUN=no
# The terminal-helper cases below deliberately isolate terminal result mapping;
# topology normalization has dedicated real-settings cases later in this test.
merv_settings_reconcile_normalize_current() { return 0; }
. "$SYNC_HELPERS"

# A/B: browser loss cannot remove a Save-published obligation.
publish md5:save-a cksum:nodes-a || fail browser-save-publish
merv_settings_reconcile_read || fail browser-save-read
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 1 ] || fail browser-generation
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail browser-pending
pass browser-loss-retains-pending

# C/F/G: a busy action, failed verification, and offline node retain the same
# generation; a retry state has a bounded due time and can later verify.
merv_settings_reconcile_update 1 md5:save-a cksum:nodes-a retry 1 30 || fail busy-retry-update
merv_settings_reconcile_read || fail busy-retry-read
[ "$MERV_SETTINGS_RECONCILE_STATUS" = retry ] || fail busy-status
[ "$MERV_SETTINGS_RECONCILE_ATTEMPT" = 1 ] || fail busy-attempt
merv_settings_reconcile_update 1 md5:save-a cksum:nodes-a retry 2 60 || fail offline-retry-update
merv_settings_reconcile_read || fail offline-retry-read
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 1 ] || fail offline-generation-lost
pass busy-failure-offline-retain-generation

# D: an older worker cannot clear a newer Save generation.
publish md5:save-b cksum:nodes-b || fail newer-save-publish
if merv_settings_reconcile_clear 1; then
    fail stale-worker-cleared-newer-save
fi
merv_settings_reconcile_read || fail newer-save-read
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 2 ] || fail newer-save-generation
[ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" = md5:save-b ] || fail newer-save-digest
pass newer-save-coalesces-old-worker

# H: trust is fail-closed and remains a user-visible blocked obligation.
MERV_SSH_TRUST_LAST_REASON=trust-expired
SYNC_RECONCILE_ACTIVE=0
SYNC_RECONCILE_VERIFIED=0
TEST_SETTINGS_DIGEST=md5:save-b
TEST_NODE_DIGEST=cksum:nodes-b
sync_settings_reconcile_capture || fail trust-capture
sync_settings_reconcile_finish || fail trust-block-update
merv_settings_reconcile_read || fail trust-block-read
[ "$MERV_SETTINGS_RECONCILE_STATUS" = blocked ] || fail trust-not-blocked
[ "$MERV_SETTINGS_RECONCILE_NEXT_EPOCH" = 0 ] || fail trust-bypass-scheduled
pass trust-required-does-not-bypass

# I: a fresh process can parse the persisted record after the original shell
# has discarded all state variables.
unset MERV_SETTINGS_RECONCILE_GENERATION MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST \
  MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST MERV_SETTINGS_RECONCILE_STATUS \
  MERV_SETTINGS_RECONCILE_ATTEMPT MERV_SETTINGS_RECONCILE_NEXT_EPOCH \
  MERV_SETTINGS_RECONCILE_UPDATED_EPOCH
merv_settings_reconcile_read || fail reboot-reload
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 2 ] || fail reboot-generation
pass reboot-reloads-pending-generation

# J/L: the production Sync terminal helper uses the current configured set,
# not the Save-time list digest. An empty current set therefore clears only a
# matching current generation after its vacuous exact verification.
merv_settings_reconcile_clear 2 || fail manual-full-clear
if merv_settings_reconcile_read; then
    fail manual-full-left-marker
fi
publish md5:save-a cksum:old-nodes || fail no-nodes-publish
TEST_SETTINGS_DIGEST=md5:save-a
TEST_NODE_DIGEST=cksum:empty
SYNC_RECONCILE_ACTIVE=0
SYNC_RECONCILE_VERIFIED=0
sync_settings_reconcile_capture || fail no-nodes-capture
[ "$SYNC_RECONCILE_ACTIVE" = 1 ] || fail no-nodes-current-set-not-captured
[ "$SYNC_RECONCILE_CURRENT_NODE_LIST_DIGEST" = cksum:empty ] || fail no-nodes-current-set-not-snapshotted
SYNC_RECONCILE_VERIFIED=1
sync_settings_reconcile_finish || fail no-nodes-terminal-helper
[ ! -e "$MERV_SETTINGS_RECONCILE_FILE" ] || fail no-nodes-stale-target
pass manual-full-and-no-nodes-clear-current-only

# K: exercise the production due entry point in a private fake addon tree.
# The fake Sync Nodes child is only an observable handoff; every decision
# before that handoff is made by the real settings_reconcile.sh and libraries.
publish md5:auto-off cksum:nodes-c || fail auto-off-publish
merv_settings_reconcile_read || fail auto-off-read
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail auto-off-forgot-state
RUNNER_BASE="$ROOT/runner-base"
RUNNER_STATE="$RUNNER_BASE/state"
RUNNER_CALLED="$RUNNER_BASE/sync-called"
RUNNER_ACTION_LOCK="$RUNNER_STATE/mervlan_action.lock"
RUNNER_QUIESCE="$RUNNER_STATE/update.quiesce"
RUNNER_HOLDER_PID=
mkdir -p "$RUNNER_BASE/functions" "$RUNNER_BASE/settings" "$RUNNER_STATE" || fail runner-root
cp -R "$BASE_DIR/settings/." "$RUNNER_BASE/settings/" || fail runner-libraries
cp "$BASE_DIR/functions/settings_reconcile.sh" "$RUNNER_BASE/functions/settings_reconcile.sh" || fail runner-copy
cat > "$RUNNER_BASE/functions/sync_nodes.sh" <<EOF
#!/bin/sh
printf '%s\n' called > "$RUNNER_CALLED"
EOF
chmod 755 "$RUNNER_BASE/functions/settings_reconcile.sh" "$RUNNER_BASE/functions/sync_nodes.sh" || fail runner-mode

runner_set_auto() {
    printf '{\n  "General": {\n    "AUTO_SYNC_SETTINGS": "%s"\n  }\n}\n' "$1" \
        > "$RUNNER_BASE/settings/settings.json" || fail runner-settings
}
runner_publish() {
    MERV_BASE="$RUNNER_BASE" MERV_STATE_ROOT="$RUNNER_STATE" \
    MERV_SETTINGS_RECONCILE_FILE="$RUNNER_STATE/settings_reconcile.state" sh -c '
  . "$MERV_BASE/settings/var_settings.sh" || exit 1
  . "$MERV_BASE/settings/lib_settings_reconcile.sh" || exit 1
  merv_settings_reconcile_publish "$@"
' sh "$@" || fail runner-state-publish
}
runner_due() {
    MERV_BASE="$RUNNER_BASE" MERV_STATE_ROOT="$RUNNER_STATE" \
    MERV_SETTINGS_RECONCILE_FILE="$RUNNER_STATE/settings_reconcile.state" \
    MERV_ACTION_LOCK_PATH="$RUNNER_ACTION_LOCK" \
    MERV_UPDATE_QUIESCE_FILE="$RUNNER_QUIESCE" \
    MERVLAN_MAINTENANCE_LOCK_OVERRIDE="$RUNNER_STATE/mervlan_maintenance.lock" \
    sh "$RUNNER_BASE/functions/settings_reconcile.sh" due
}
runner_clear_call() { rm -f "$RUNNER_CALLED"; }
runner_expect_no_child() {
    _runner_wait=0
    while [ ! -e "$RUNNER_CALLED" ] && [ "$_runner_wait" -lt 2 ]; do
        sleep 1
        _runner_wait=$((_runner_wait + 1))
    done
    [ ! -e "$RUNNER_CALLED" ] || fail "$1"
}
runner_wait_for_child() {
    _runner_wait=0
    while [ ! -e "$RUNNER_CALLED" ] && [ "$_runner_wait" -lt 10 ]; do
        sleep 1
        _runner_wait=$((_runner_wait + 1))
    done
    [ -e "$RUNNER_CALLED" ] || fail "$1"
}
runner_clear_action_lock() { rm -rf "$RUNNER_ACTION_LOCK"; }
runner_owner_state() {
    MERV_BASE="$RUNNER_BASE" MERV_STATE_ROOT="$RUNNER_STATE" \
    MERV_ACTION_LOCK_PATH="$RUNNER_ACTION_LOCK" sh -c '
      . "$MERV_BASE/settings/var_settings.sh" || exit 1
      . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 1
      merv_owner_lock_state "$MERV_ACTION_LOCK_PATH"
    '
}
runner_start_live_action_owner() {
    RUNNER_READY="$RUNNER_STATE/action-owner.ready"
    RUNNER_RELEASE="$RUNNER_STATE/action-owner.release"
    rm -f "$RUNNER_READY" "$RUNNER_RELEASE"
    MERV_BASE="$RUNNER_BASE" MERV_STATE_ROOT="$RUNNER_STATE" \
    MERV_ACTION_LOCK_PATH="$RUNNER_ACTION_LOCK" \
    RUNNER_READY="$RUNNER_READY" RUNNER_RELEASE="$RUNNER_RELEASE" \
    sh -c '
      . "$MERV_BASE/settings/var_settings.sh" || exit 1
      . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 1
      merv_owner_lock_acquire "$MERV_ACTION_LOCK_PATH" 0 0 due-test-owner || exit 11
      : > "$RUNNER_READY"
      _hold=0
      while [ ! -f "$RUNNER_RELEASE" ] && [ "$_hold" -lt 30 ]; do sleep 1; _hold=$((_hold + 1)); done
      merv_owner_lock_release "$MERV_ACTION_LOCK_PATH" || exit 12
    ' &
    RUNNER_HOLDER_PID=$!
    _runner_wait=0
    while [ ! -f "$RUNNER_READY" ] && [ "$_runner_wait" -lt 10 ]; do
        sleep 1
        _runner_wait=$((_runner_wait + 1))
    done
    [ -f "$RUNNER_READY" ] || fail live-action-owner-not-ready
}
runner_stop_live_action_owner() {
    : > "$RUNNER_RELEASE"
    wait "$RUNNER_HOLDER_PID" || fail live-action-owner-release
    RUNNER_HOLDER_PID=
}
runner_begin_real_update_gate() {
    MERV_BASE="$RUNNER_BASE" MERV_STATE_ROOT="$RUNNER_STATE" \
    MERV_UPDATE_QUIESCE_FILE="$RUNNER_QUIESCE" sh -c '
      . "$MERV_BASE/settings/var_settings.sh" || exit 1
      . "$MERV_BASE/settings/lib_update_state.sh" || exit 1
      merv_update_quiesce_begin due-test-update
    ' || fail real-update-gate-begin
}
runner_clear_update_gate() { rm -f "$RUNNER_QUIESCE"; }

# No marker is normal idle state and must not fork a child.
runner_set_auto 1
runner_clear_call
rm -f "$RUNNER_STATE/settings_reconcile.state"
runner_due || fail absent-due-runner
runner_expect_no_child absent-due-launched-sync
pass absent-state-is-normal-no-work

# A valid currently-due marker hands work to the independently-owned child.
runner_publish md5:due cksum:due pending 0 0
runner_clear_call
runner_due || fail valid-due-runner
runner_wait_for_child valid-due-did-not-launch
pass valid-pending-due-launches-worker

# Future retry and explicit manual states never launch on a cron tick.
runner_publish md5:future cksum:future retry 1 2147483647
runner_clear_call
runner_due || fail future-due-runner
runner_expect_no_child future-retry-launched-sync
runner_publish md5:blocked cksum:blocked blocked 1 0
runner_clear_call
runner_due || fail blocked-due-runner
runner_expect_no_child blocked-due-launched-sync
runner_publish md5:paused cksum:paused paused 1 0
runner_clear_call
runner_due || fail paused-due-runner
runner_expect_no_child paused-due-launched-sync
pass future-blocked-and-paused-do-not-auto-run

# AUTO_SYNC_SETTINGS is checked before parsing; it preserves both valid intent
# and an untrusted marker without launching a repair worker.
runner_set_auto 0
runner_publish md5:auto-off cksum:nodes-c pending 0 0
runner_clear_call
runner_due || fail auto-off-pending-runner
runner_expect_no_child auto-off-pending-launched-sync
[ -f "$RUNNER_STATE/settings_reconcile.state" ] || fail auto-off-pending-cleared-intent
printf 'format=1\ngeneration=broken\n' > "$RUNNER_STATE/settings_reconcile.state"
runner_clear_call
runner_due || fail auto-off-malformed-runner
runner_expect_no_child auto-off-malformed-launched-sync
[ -f "$RUNNER_STATE/settings_reconcile.state" ] || fail auto-off-malformed-mutated-state
pass auto-sync-disabled-preserves-pending-and-malformed-state

# A malformed existing marker is not read by due, but with auto-sync enabled
# it is handed to the serialized worker for normalization from live settings.
runner_set_auto 1
runner_clear_action_lock
runner_clear_update_gate
printf 'format=1\ngeneration=broken\n' > "$RUNNER_STATE/settings_reconcile.state"
runner_clear_call
runner_due || fail malformed-due-runner
runner_wait_for_child malformed-existing-due-did-not-launch
pass malformed-existing-due-launches-worker

# An actual Update quiesce marker blocks even malformed-marker repair. This
# exercises the same mutation gate the production due process uses.
printf 'format=1\ngeneration=broken\n' > "$RUNNER_STATE/settings_reconcile.state"
runner_begin_real_update_gate
runner_clear_call
runner_due || fail malformed-update-gated-due
runner_expect_no_child malformed-update-gate-launched-sync
[ -f "$RUNNER_STATE/settings_reconcile.state" ] || fail malformed-update-gate-mutated-state
runner_clear_update_gate
pass malformed-state-respects-real-update-gate

# A real, live action owner prevents a second due child. A regular-file and a
# malformed owner directory are both fail-closed global action obstructions.
runner_publish md5:owner cksum:owner pending 0 0
runner_start_live_action_owner
[ "$(runner_owner_state)" = live ] || fail live-action-owner-not-live
runner_clear_call
runner_due || fail live-owner-due-runner
runner_expect_no_child live-owner-launched-sync
runner_stop_live_action_owner

printf 'obstruction\n' > "$RUNNER_ACTION_LOCK"
[ "$(runner_owner_state)" = unknown ] || fail unknown-action-owner-not-unknown
runner_clear_call
runner_due || fail unknown-owner-due-runner
runner_expect_no_child unknown-owner-launched-sync
runner_clear_action_lock

mkdir "$RUNNER_ACTION_LOCK" || fail malformed-action-owner-root
printf 'invalid\n' > "$RUNNER_ACTION_LOCK/owner"
[ "$(runner_owner_state)" = malformed ] || fail malformed-action-owner-not-malformed
runner_clear_call
runner_due || fail malformed-owner-due-runner
runner_expect_no_child malformed-owner-launched-sync
runner_clear_action_lock
pass global-action-owner-obstructions-fail-closed

# Use the real digest and node-list helpers for lifecycle normalization.  This
# catches the topology cases that a stubbed digest cannot represent.
REAL_ROOT="$ROOT/real-current"
REAL_BASE="$REAL_ROOT/addon"
mkdir -p "$REAL_ROOT/state" "$REAL_BASE" || fail real-current-root
cp -R "$BASE_DIR/settings" "$REAL_BASE/settings" || fail real-current-libraries
cat > "$REAL_BASE/settings/settings.json" <<'EOF'
{
  "General": {
    "AUTO_SYNC_SETTINGS": "1"
  },
  "Nodes": {
    "NODE1": "192.0.2.10",
    "NODE1_ROLE": "aimesh"
  },
  "VLAN": {
    "VLAN_01": "10"
  }
}
EOF
MERV_BASE="$REAL_BASE" \
MERV_STATE_ROOT="$REAL_ROOT/state" MERV_SETTINGS_RECONCILE_FILE="$REAL_ROOT/state/settings_reconcile.state" \
sh -c '
  . "$MERV_BASE/settings/var_settings.sh" || exit 1
  . "$MERV_BASE/settings/lib_json.sh" || exit 1
  . "$MERV_BASE/settings/lib_settings_reconcile.sh" || exit 1
  merv_settings_reconcile_normalize_current publish || exit 11
  merv_settings_reconcile_read || exit 12
  first="$MERV_SETTINGS_RECONCILE_GENERATION"
  test "$MERV_SETTINGS_RECONCILE_STATUS" = pending || exit 13

  # Changing the real required set supersedes rather than retaining node A.
  sed "s/192.0.2.10/192.0.2.11/" "$SETTINGS_FILE" > "$SETTINGS_FILE.next" && mv "$SETTINGS_FILE.next" "$SETTINGS_FILE" || exit 14
  merv_settings_reconcile_normalize_current existing || exit 15
  merv_settings_reconcile_read || exit 16
  test "$MERV_SETTINGS_RECONCILE_GENERATION" -gt "$first" || exit 17
  second="$MERV_SETTINGS_RECONCILE_GENERATION"

  # AUTO_SYNC_SETTINGS is deliberately outside the settings digest, so these
  # transitions must still change the operational state explicitly.
  sed "s/\"AUTO_SYNC_SETTINGS\": \"1\"/\"AUTO_SYNC_SETTINGS\": \"0\"/" "$SETTINGS_FILE" > "$SETTINGS_FILE.next" && mv "$SETTINGS_FILE.next" "$SETTINGS_FILE" || exit 18
  merv_settings_reconcile_normalize_current existing || exit 19
  merv_settings_reconcile_read || exit 20
  test "$MERV_SETTINGS_RECONCILE_STATUS" = paused || exit 21
  sed "s/\"AUTO_SYNC_SETTINGS\": \"0\"/\"AUTO_SYNC_SETTINGS\": \"1\"/" "$SETTINGS_FILE" > "$SETTINGS_FILE.next" && mv "$SETTINGS_FILE.next" "$SETTINGS_FILE" || exit 22
  merv_settings_reconcile_normalize_current existing || exit 23
  merv_settings_reconcile_read || exit 24
  test "$MERV_SETTINGS_RECONCILE_STATUS" = pending || exit 25
  test "$MERV_SETTINGS_RECONCILE_GENERATION" = "$second" || exit 26

  # A malformed marker is never sourced. It is quarantined and rebuilt only
  # from current validated settings/node topology.
  printf "format=1\\ngeneration=bad\\n" > "$MERV_SETTINGS_RECONCILE_FILE" || exit 27
  merv_settings_reconcile_normalize_current existing || exit 28
  test -n "${MERV_SETTINGS_RECONCILE_QUARANTINED:-}" || exit 29
  test -f "$MERV_SETTINGS_RECONCILE_QUARANTINED" || exit 30
  merv_settings_reconcile_read || exit 31
  test "$MERV_SETTINGS_RECONCILE_STATUS" = pending || exit 32

  # Removing the final configured node makes the obligation vacuous and clears
  # the obsolete generation using the real settings/node digest path.
  sed "/\"NODE1\"/d; /\"NODE1_ROLE\"/d" "$SETTINGS_FILE" > "$SETTINGS_FILE.next" && mv "$SETTINGS_FILE.next" "$SETTINGS_FILE" || exit 33
  merv_settings_reconcile_normalize_current existing || exit 34
  test ! -e "$MERV_SETTINGS_RECONCILE_FILE" || exit 35
' || { _real_rc=$?; fail "real-topology-auto-malformed-lifecycle rc=$_real_rc"; }
pass real-topology-auto-and-malformed-lifecycle

# P: malformed records are rejected; no caller may treat a truncated marker as
# a successful synchronization result.
printf 'format=1\ngeneration=5\n' > "$MERV_SETTINGS_RECONCILE_FILE"
if merv_settings_reconcile_read; then
    fail malformed-marker-accepted
fi
pass malformed-state-fails-closed

printf 'SETTINGS_CONVERGENCE_CONTRACT_OK\n'
