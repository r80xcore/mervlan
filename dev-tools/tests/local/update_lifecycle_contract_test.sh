#!/bin/sh
# Local contract test for the durable Update journal and bounded node retry
# marker. This test uses only isolated PC temporary state; it never contacts a
# router and never creates a router backup.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.update-lifecycle.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
export MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
export MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/maintenance.lock"
export MERV_NODE_RECONCILE_FILE="$MERV_STATE_ROOT/node_reconcile.pending"

. "$BASE_DIR/settings/var_settings.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/lib_node_reconcile.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

merv_update_journal_write run-1 extracting refs/heads/custom 1 1 1 0 0 partial-space || fail journal-write
merv_update_journal_active || fail journal-active
[ "$(merv_update_journal_get phase '')" = extracting ] || fail journal-phase
[ "$(merv_update_journal_get detail '')" = partial-space ] || fail journal-detail
merv_update_journal_requires_safe_boot || fail journal-safe-boot
pass journal-write-and-read

merv_update_quiesce_begin run-1 || fail quiesce-write
merv_update_quiesce_active || fail quiesce-active
unset MERV_UPDATE_OWNER
merv_update_mutation_blocked || fail mutation-blocked-during-quiesce
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 update-lifecycle || fail maintenance-owner-acquire
MERV_UPDATE_OWNER=1
MERV_UPDATE_OWNER_PID="$$"
MERV_UPDATE_OWNER_START="$MERV_LOCK_START"
MERV_UPDATE_OWNER_NONCE="$MERV_LOCK_NONCE"
! merv_update_mutation_blocked || fail authenticated-update-owner-bypass
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_LOCK_NONCE" || fail maintenance-owner-release
unset MERV_UPDATE_OWNER MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE
merv_update_quiesce_clear || fail quiesce-clear
! merv_update_quiesce_active || fail quiesce-still-active
pass quiesce-atomic-lifecycle

# Durable lifecycle state must reject symlinks before parsing, writing, or
# clearing. A dangling link is an obstruction even though `[ -e ]` is false.
_state_link_rc=0
(
  _state_link_dir="$TEST_ROOT/state-object-links"
  mkdir -p "$_state_link_dir" || exit 1
  _journal_link="$_state_link_dir/update.journal"
  _quiesce_link="$_state_link_dir/update.quiesce"
  _journal_target="$_state_link_dir/missing-journal-target"
  _quiesce_target="$_state_link_dir/missing-quiesce-target"
  MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_journal_target" "$_journal_link" 2>/dev/null || exit 2
  MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_quiesce_target" "$_quiesce_link" 2>/dev/null || exit 2
  [ -L "$_journal_link" ] && [ ! -e "$_journal_link" ] || exit 3
  [ -L "$_quiesce_link" ] && [ ! -e "$_quiesce_link" ] || exit 4

  MERV_UPDATE_JOURNAL="$_journal_link"
  merv_update_journal_state >/dev/null 2>&1
  _journal_state_rc=$?
  [ "$_journal_state_rc" -eq 2 ] || exit 10
  [ "${MERV_UPDATE_JOURNAL_STATE:-}" = malformed ] || exit 11
  merv_update_journal_write run-link extracting ref 0 0 0 0 0 detail >/dev/null 2>&1
  [ "$?" -ne 0 ] || exit 12
  merv_update_journal_clear >/dev/null 2>&1
  [ "$?" -ne 0 ] || exit 13
  [ -L "$_journal_link" ] || exit 14

  MERV_UPDATE_QUIESCE_FILE="$_quiesce_link"
  merv_update_quiesce_state >/dev/null 2>&1
  _quiesce_state_rc=$?
  [ "$_quiesce_state_rc" -eq 2 ] || exit 20
  [ "${MERV_UPDATE_QUIESCE_STATE:-}" = malformed ] || exit 21
  merv_update_quiesce_begin run-link >/dev/null 2>&1
  [ "$?" -ne 0 ] || exit 22
  merv_update_quiesce_clear >/dev/null 2>&1
  [ "$?" -ne 0 ] || exit 23
  [ -L "$_quiesce_link" ] || exit 24
)
_state_link_rc=$?
if [ "$_state_link_rc" -eq 0 ]; then
  pass dangling-state-symlinks-rejected-and-preserved
elif [ "$_state_link_rc" -eq 2 ]; then
  pass dangling-state-symlinks-unsupported-on-host
else
  fail "dangling-state-symlinks-fail-closed (rc=$_state_link_rc)"
fi

mkdir -p "$MERV_UPDATE_MAINTENANCE_LOCK" || fail maintenance-marker-create
merv_update_mutation_blocked || fail malformed-maintenance-lock-blocked
rmdir "$MERV_UPDATE_MAINTENANCE_LOCK" || fail maintenance-marker-clear
pass mutation-gate-lifecycle

# A dangling maintenance-lock symlink is an obstruction, not absence.  Clear
# the journal first so this assertion exercises the maintenance path itself,
# then require the real update mutation gate to remain blocked and preserve the
# exact link.
merv_update_journal_clear || fail mutation-gate-journal-clear
_caller_gate_failures=0
(
  _dangling_target="$TEST_ROOT/maintenance-target-does-not-exist"
  MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_dangling_target" "$MERV_UPDATE_MAINTENANCE_LOCK" 2>/dev/null || exit 2
  [ -L "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 3
  [ ! -e "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 4
  merv_update_mutation_blocked
  _dangling_mutation_rc=$?
  [ "$_dangling_mutation_rc" -eq 0 ] || exit 10
  [ -L "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 11
)
_dangling_gate_rc=$?
rm -f "$MERV_UPDATE_MAINTENANCE_LOCK" 2>/dev/null || :
if [ "$_dangling_gate_rc" -eq 0 ]; then
  pass dangling-maintenance-symlink-blocks-mutation
else
  printf 'FAIL: dangling-maintenance-symlink-mutation-block (rc=%s)\n' \
    "$_dangling_gate_rc" >&2
  _caller_gate_failures=1
fi

# Exercise the exact updater idle gate without starting an Update.  The
# extracted function is production text; only unrelated runtime classifiers
# are stubbed so a dangling maintenance obstruction is the sole busy signal.
UPDATE_SCRIPT="$BASE_DIR/functions/update_mervlan.sh"
IDLE_HELPER="$TEST_ROOT/update-idle-contract-helper.sh"
sed -n '/^update_wait_for_runtime_idle() {/,/^}/p' "$UPDATE_SCRIPT" > "$IDLE_HELPER" ||
  fail update-idle-helper-extract
[ -s "$IDLE_HELPER" ] || fail update-idle-helper-empty
(
  IDLE_CASE="$TEST_ROOT/update-idle-dangling"
  mkdir -p "$IDLE_CASE" || exit 1
  # var_settings.sh intentionally makes LOCKDIR readonly.  The idle fixture
  # leaves that isolated default runtime root untouched and overrides only the
  # maintenance path under test.
  MERV_UPDATE_MAINTENANCE_LOCK="$IDLE_CASE/mervlan_maintenance.lock"
  export MERV_UPDATE_MAINTENANCE_LOCK
  IDLE_TRACE="$IDLE_CASE/trace.log"
  IDLE_OUTPUT="$IDLE_CASE/output.log"
  : > "$IDLE_TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$IDLE_TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$IDLE_TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$IDLE_TRACE"; }
  merv_observation_wait_idle() { return 0; }
  merv_dhcp_hold_status() {
    printf 'desired=clear\nobserved=absent\n'
    return 0
  }
  merv_action_lock_parent_owned() { return 1; }
  _idle_target="$IDLE_CASE/absent-maintenance-target"
  MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_idle_target" "$MERV_UPDATE_MAINTENANCE_LOCK" 2>/dev/null || exit 2
  [ -L "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 3
  [ ! -e "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 4
  . "$IDLE_HELPER" || exit 5
  update_wait_for_runtime_idle 0 > "$IDLE_OUTPUT" 2>&1
  _idle_rc=$?
  [ "$_idle_rc" -ne 0 ] || exit 10
  [ -L "$MERV_UPDATE_MAINTENANCE_LOCK" ] || exit 11
)
_idle_gate_rc=$?
if [ "$_idle_gate_rc" -eq 0 ]; then
  pass dangling-maintenance-symlink-blocks-update-idle
else
  printf 'FAIL: dangling-maintenance-symlink-idle-gate (rc=%s)\n' \
    "$_idle_gate_rc" >&2
  _caller_gate_failures=1
fi

# The runtime idle gate must apply the same rule to the boot-shield marker:
# `[ -f ]` alone misses a dangling link and would allow Update teardown.
_idle_marker_link_rc=0
(
  IDLE_MARKER_CASE="$TEST_ROOT/update-idle-marker-dangling"
  env "IDLE_HELPER=$IDLE_HELPER" "IDLE_MARKER_CASE=$IDLE_MARKER_CASE" \
  "LOCKDIR=$IDLE_MARKER_CASE/locks" \
  "MERV_UPDATE_MAINTENANCE_LOCK=$IDLE_MARKER_CASE/maintenance.lock" \
  sh -c '
    set -u
    mkdir -p "$IDLE_MARKER_CASE/locks" || exit 1
    info() { printf "INFO:%s\n" "$*" >> "$IDLE_MARKER_CASE/trace.log"; }
    error() { printf "ERROR:%s\n" "$*" >> "$IDLE_MARKER_CASE/trace.log"; }
    warn() { printf "WARN:%s\n" "$*" >> "$IDLE_MARKER_CASE/trace.log"; }
    merv_owner_lock_state() { printf "absent"; return 0; }
    merv_update_maintenance_lock_state() { printf "absent"; return 0; }
    merv_observation_wait_idle() { return 0; }
    merv_dhcp_hold_status() { printf "desired=clear\nobserved=absent\n"; return 0; }
    merv_action_lock_parent_owned() { return 1; }
    _idle_marker_target="$IDLE_MARKER_CASE/absent-marker-target"
    _idle_marker_path="$LOCKDIR/merv_boot_shield.active"
    MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_idle_marker_target" "$_idle_marker_path" 2>/dev/null || exit 2
    [ -L "$_idle_marker_path" ] && [ ! -e "$_idle_marker_path" ] || exit 3
    . "$IDLE_HELPER" || exit 4
    update_wait_for_runtime_idle 0 > "$IDLE_MARKER_CASE/output.log" 2>&1
    _idle_marker_rc=$?
    [ "$_idle_marker_rc" -ne 0 ] || exit 10
    [ -L "$_idle_marker_path" ] || exit 11
  '
)
_idle_marker_link_rc=$?
if [ "$_idle_marker_link_rc" -eq 0 ]; then
  pass dangling-boot-marker-blocks-update-idle
elif [ "$_idle_marker_link_rc" -eq 2 ]; then
  pass dangling-boot-marker-idle-unsupported-on-host
else
  fail "dangling-boot-marker-idle-fail-closed (rc=$_idle_marker_link_rc)"
  _caller_gate_failures=1
fi

# The broad historical phase/GUI checks remain available by default, but this
# selector lets the CORR-DHCP caller gate run stop after its precise assertions
# instead of entering the known hanging phase path on this host.
if [ "${MERV_DHCP_CALLERS_FOCUSED:-0}" = "1" ]; then
  [ "${_caller_gate_failures:-1}" -eq 0 ] || {
    printf 'UPDATE_DHCP_CALLERS_FOCUSED_FAILED\n' >&2
    exit 1
  }
  printf 'UPDATE_DHCP_CALLERS_FOCUSED_OK\n'
  exit 0
fi

# A direct installer that owns the maintenance lock may delegate only an exact
# owner tuple to its hardware-profile child.  A forged tuple remains blocked.
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 direct-install || fail direct-install-owner-acquire
MERV_MAINTENANCE_ENTRY_OWNED=1
MERV_MAINTENANCE_ENTRY_START="$MERV_LOCK_START"
MERV_MAINTENANCE_ENTRY_NONCE="$MERV_LOCK_NONCE"
merv_maintenance_direct_export_install_context || fail direct-install-context-export
merv_maintenance_delegation_valid || fail direct-install-context-valid
! merv_update_mutation_blocked || fail direct-install-child-bypass
MERV_MAINTENANCE_OWNER_NONCE=forged
merv_update_mutation_blocked || fail forged-direct-install-context-blocked
MERV_MAINTENANCE_OWNER_NONCE="$MERV_MAINTENANCE_ENTRY_NONCE"
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_MAINTENANCE_ENTRY_NONCE" || fail direct-install-owner-release
unset MERV_MAINTENANCE_ENTRY_OWNED MERV_MAINTENANCE_ENTRY_START MERV_MAINTENANCE_ENTRY_NONCE \
  MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND MERV_INSTALL_DELEGATION \
  MERV_MAINTENANCE_OWNER_PID MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
pass direct-installer-child-lifecycle

# Standalone uninstall owns the same maintenance lock but gets a distinct,
# authenticated delegation kind for its boot-hook teardown children.
merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 direct-uninstall || fail direct-uninstall-owner-acquire
MERV_MAINTENANCE_ENTRY_OWNED=1
MERV_MAINTENANCE_ENTRY_START="$MERV_LOCK_START"
MERV_MAINTENANCE_ENTRY_NONCE="$MERV_LOCK_NONCE"
merv_maintenance_direct_export_uninstall_context || fail direct-uninstall-context-export
merv_maintenance_delegation_valid || fail direct-uninstall-context-valid
! merv_update_mutation_blocked || fail direct-uninstall-child-bypass
MERV_MAINTENANCE_OWNER_NONCE=forged
merv_update_mutation_blocked || fail forged-direct-uninstall-context-blocked
MERV_MAINTENANCE_OWNER_NONCE="$MERV_MAINTENANCE_ENTRY_NONCE"
merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$MERV_MAINTENANCE_ENTRY_NONCE" || fail direct-uninstall-owner-release
unset MERV_MAINTENANCE_ENTRY_OWNED MERV_MAINTENANCE_ENTRY_START MERV_MAINTENANCE_ENTRY_NONCE \
  MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND MERV_UNINSTALL_DELEGATION \
  MERV_MAINTENANCE_OWNER_PID MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
pass direct-uninstaller-child-lifecycle

merv_node_reconcile_write nodeenable unreachable node-unavailable 0 1234 digest:abc || fail node-marker-write
merv_node_reconcile_active || fail node-marker-active
[ "$(merv_node_reconcile_get action '')" = nodeenable ] || fail node-marker-action
[ "$(merv_node_reconcile_get next_epoch '')" = 1234 ] || fail node-marker-due
merv_node_reconcile_clear || fail node-marker-clear
! merv_node_reconcile_active || fail node-marker-still-active
pass bounded-node-marker-lifecycle

merv_update_journal_clear || fail journal-clear
! merv_update_journal_active || fail journal-still-active
merv_update_journal_write 'bad=value' extracting ref 0 0 0 0 0 detail >/dev/null 2>&1 && fail unsafe-journal-value
merv_node_reconcile_write '../bad' unreachable detail 0 1 digest >/dev/null 2>&1 && fail unsafe-node-action
pass malformed-values-rejected

# Keep the strict parser's allowlist synchronized with real production Update
# phase writers. Literal phases are derived from the current source; the one
# dynamic failure family is deliberately checked with a bounded representative.
UPDATE_PHASES=$(sed -n 's/^[[:space:]]*update_record_phase[[:space:]]\{1,\}"\{0,1\}\([A-Za-z0-9-][A-Za-z0-9-]*\).*/\1/p' \
  "$BASE_DIR/functions/update_mervlan.sh" | sort -u)
[ -n "$UPDATE_PHASES" ] || fail production-phase-discovery
for update_required_phase in workspace quiescing quiesced preflight downloading extracting staged durable-backup backup quiesced-guards-released activation-started activated public-refresh main-verified node-sync finalization-failed completed; do
  printf '%s\n' "$UPDATE_PHASES" | grep -qx "$update_required_phase" || fail "production-phase-missing-$update_required_phase"
done
grep -Fq 'update_record_phase "failed-$block"' "$BASE_DIR/functions/update_mervlan.sh" || fail production-failed-phase-discovery
for update_phase in $UPDATE_PHASES failed-synthetic; do
  merv_update_journal_write phase-test "$update_phase" ref 0 0 0 0 0 detail none none none none none none old new || fail "phase-write-$update_phase"
  merv_update_journal_state || fail "phase-parse-$update_phase"
done
merv_update_journal_write phase-test unknown-phase ref 0 0 0 0 0 detail none none none none none none old new || fail unknown-phase-write
if merv_update_journal_state; then fail unknown-phase-accepted; fi
merv_update_journal_clear || fail phase-journal-clear
pass production-phase-allowlist

# The GUI transport is Merlin-owned, so the updater records a content
# fingerprint instead of changing the transport file. Extract the two helpers
# from the production source to exercise the exact implementation without
# invoking an Update lifecycle.
UPDATE_SCRIPT="$BASE_DIR/functions/update_mervlan.sh"
GUI_HELPERS="$TEST_ROOT/gui-update-ref-helpers.sh"
sed -n \
  -e '/^update_gui_ref_transport_digest() {/,/^}/p' \
  -e '/^consume_gui_update_ref() {/,/^}/p' \
  "$UPDATE_SCRIPT" > "$GUI_HELPERS" || fail gui-helper-extract
[ -s "$GUI_HELPERS" ] || fail gui-helper-empty
GUI_TRANSPORT_FILE="$TEST_ROOT/custom_settings.txt"
GUI_LEDGER_FILE="$MERV_STATE_ROOT/update_refs.consumed"
GUI_RESULT_FILE="$TEST_ROOT/gui-ref-result"
printf 'vlanmgr_update_ref=refs/heads/gui-portability\n' > "$GUI_TRANSPORT_FILE" || fail gui-transport-write
gui_consume() {
  env CUSTOM_SETTINGS_FILE="$GUI_TRANSPORT_FILE" MERV_STATE_ROOT="$MERV_STATE_ROOT" \
    MERV_UPDATE_CONSUMED_FILE="$GUI_LEDGER_FILE" GUI_HELPERS="$GUI_HELPERS" \
    GUI_RESULT_FILE="$GUI_RESULT_FILE" sh -c '
      . "$GUI_HELPERS" || exit 2
      consume_gui_update_ref
      _gui_test_rc=$?
      printf "%s|%s\n" "$_gui_test_rc" "${GUI_UPDATE_REF:-}" > "$GUI_RESULT_FILE" || exit 3
    ' || fail gui-helper-run
}
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/heads/gui-portability' ] || fail gui-ref-first-value
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '1|refs/heads/gui-portability' ] || fail gui-ref-unchanged-reconsume
printf 'transport_generation=2\n' >> "$GUI_TRANSPORT_FILE" || fail gui-transport-change
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/heads/gui-portability' ] || fail gui-ref-transport-change-value
printf 'vlanmgr_update_ref=refs/tags/v6.0\n' >> "$GUI_TRANSPORT_FILE" || fail gui-ref-new-value-write
gui_consume
[ "$(cat "$GUI_RESULT_FILE")" = '0|refs/tags/v6.0' ] || fail gui-ref-canonical-value
grep -Eq '^(md5:[0-9A-Fa-f]{32}|cksum:[0-9]+:[0-9]+)\|refs/' "$GUI_LEDGER_FILE" || fail gui-ref-portable-ledger
pass gui-ref-content-ledger-lifecycle

printf 'UPDATE_LIFECYCLE_CONTRACT_OK\n'
