#!/bin/sh
# Execute source-derived event, Heal admission, and five-minute cron branches
# against private fixture state. No installed paths or router commands run.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
HANDLER="$BASE_DIR/functions/service-event-handler.sh"
HEAL="$BASE_DIR/functions/heal_event.sh"
BOOT="$BASE_DIR/functions/mervlan_boot.sh"
TEST_ROOT=""
umask 077
TEST_PARENT="${TMPDIR:-/tmp}/mervlan_tmp"
mkdir -p "$TEST_PARENT" || exit 1
_test_slot=0
while [ "$_test_slot" -lt 8 ]; do
  _test_candidate="$TEST_PARENT/selftest.heal-deferred.$$.$_test_slot"
  if mkdir "$_test_candidate" 2>/dev/null; then
    TEST_ROOT=$_test_candidate
    break
  fi
  _test_slot=$((_test_slot + 1))
done
[ -n "$TEST_ROOT" ] || { printf '%s\n' 'FAIL: could not allocate unique fixture root' >&2; exit 1; }
mkdir "$TEST_ROOT/locks" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ ! -f "$TEST_ROOT/trace.log" ] || cat "$TEST_ROOT/trace.log" >&2
  exit 1
}
pass() { printf 'PASS: %s\n' "$*"; }

awk '
  $0 == "    # Handler-level debounce for system events (prevents heal storms from rc event floods)" { copying=1 }
  copying && $0 == "  *)" { exit }
  copying { print }
' "$HANDLER" >"$TEST_ROOT/event.branch.raw" || fail 'could not extract production event branch'
[ -s "$TEST_ROOT/event.branch.raw" ] || fail 'production event branch is empty'
sed '$d' "$TEST_ROOT/event.branch.raw" |
  sed 's|/jffs/addons/mervlan/functions/heal_event.sh|"$MERV_TEST_HEAL_ENDPOINT"|' \
  >"$TEST_ROOT/event.branch" || fail 'could not prepare fixture-only event branch'

awk '
  $0 == "if ! type merv_update_mutation_blocked >/dev/null 2>&1; then" { copying=1 }
  copying && index($0, "# Every event and health-cron entry reconciles interrupted token owners") { exit }
  copying { print }
' "$HEAL" >"$TEST_ROOT/admission.branch" || fail 'could not extract production Heal admission gate'
[ -s "$TEST_ROOT/admission.branch" ] || fail 'production Heal admission gate is empty'

awk '
  $0 == "if [ \"$EVENT\" = \"cron\" ]; then" { copying=1 }
  copying && index($0, "#                         SERVICE MONITORING (UNUSED)") { exit }
  copying { print }
' "$HEAL" >"$TEST_ROOT/cron.branch" || fail 'could not extract production cron reconciliation branch'
[ -s "$TEST_ROOT/cron.branch" ] || fail 'production cron reconciliation branch is empty'
grep -Fq '*/5 * * * * $INJ_BASE/functions/heal_event.sh cron' "$BOOT" ||
  fail 'existing five-minute Heal check is not scheduled by boot'
grep -Fq 'check_wl_iface_placements' "$TEST_ROOT/cron.branch" ||
  fail 'cron branch no longer checks wireless interface placement'
grep -Fq '"$VLAN_MANAGER" >/dev/null 2>&1 &' "$TEST_ROOT/cron.branch" ||
  fail 'cron branch no longer launches the existing Manager for repair'

cat >"$TEST_ROOT/admission.sh" <<'EOF'
#!/bin/sh
set -u
info() { printf 'heal-info:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
error() { printf 'heal-error:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
merv_update_mutation_blocked() { [ -e "$MERV_TEST_MAINTENANCE" ]; }
EOF
cat "$TEST_ROOT/admission.branch" >>"$TEST_ROOT/admission.sh"
cat >>"$TEST_ROOT/admission.sh" <<'EOF'
printf '%s\n' 'heal-mutation-path-reached' >>"$MERV_TEST_TRACE"
EOF
chmod 700 "$TEST_ROOT/admission.sh"

cat >"$TEST_ROOT/heal-endpoint.sh" <<'EOF'
#!/bin/sh
printf 'event-arrived:%s\n' "$*" >>"$MERV_TEST_TRACE"
exec sh "$MERV_TEST_ADMISSION_SCRIPT" "$@"
EOF
chmod 700 "$TEST_ROOT/heal-endpoint.sh"

cat >"$TEST_ROOT/event-fixture.sh" <<'EOF'
#!/bin/sh
set -u
COMBINED_NORM=wireless_restart
LOCKDIR="$MERV_TEST_ROOT/locks"
HEAL_WINDOW=60
MERV_HEAL_DELAY=1
MERV_HEAL_EVENT_DEBOUNCE=60
logger() { printf 'handler-log:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
sleep() { :; }
ebtables() {
  printf 'ebtables:%s\n' "$*" >>"$MERV_TEST_TRACE"
  return 0
}
EOF
cat "$TEST_ROOT/event.branch" >>"$TEST_ROOT/event-fixture.sh"
cat >>"$TEST_ROOT/event-fixture.sh" <<'EOF'
exit 0
EOF
chmod 700 "$TEST_ROOT/event-fixture.sh"

cat >"$TEST_ROOT/manager.sh" <<'EOF'
#!/bin/sh
printf '%s\n' manager-reconciliation-ran >>"$MERV_TEST_TRACE"
rm -f "$MERV_TEST_MISMATCH"
: >"$MERV_TEST_RECONCILED"
EOF
chmod 700 "$TEST_ROOT/manager.sh"

cat >"$TEST_ROOT/cron-fixture.sh" <<'EOF'
#!/bin/sh
set -u
MERV_BASE="$MERV_TEST_ROOT/fixture-base"
mkdir -p "$MERV_BASE/functions"
EVENT=cron
LOCKDIR="$MERV_TEST_ROOT/locks"
VLAN_MANAGER="$MERV_TEST_MANAGER"
COOLDOWN_SEC=180
MERV_SETTINGS_RECONCILE_FILE="$MERV_TEST_ROOT/no-settings-reconcile"
MERV_STATE_ROOT="$MERV_TEST_ROOT/no-state"
info() { printf 'cron-info:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
warn() { printf 'cron-warn:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
error() { printf 'cron-error:%s\n' "$*" >>"$MERV_TEST_TRACE"; }
log_maintenance_due() { :; }
ebtables() { printf 'cron-ebtables:%s\n' "$*" >>"$MERV_TEST_TRACE"; return 0; }
restore_merv_qt_shield() { :; }
restore_merv_mac_shield() { :; }
check_vlan_config_fast() { return 0; }
log_health_ok_if_needed() { :; }
merv_mac_build_expected_iface_vid() { :; }
check_wl_iface_placements() {
  printf '%s\n' cron-placement-check >>"$MERV_TEST_TRACE"
  [ ! -e "$MERV_TEST_MISMATCH" ]
}
record_mismatch() { printf '%s\n' cron-mismatch-recorded >>"$MERV_TEST_TRACE"; }
heal_allowed() { return 0; }
mark_heal() { printf '%s\n' cron-heal-marked >>"$MERV_TEST_TRACE"; }
evict_wl_from_br0() { printf '%s\n' cron-evict-existing-wl-placement >>"$MERV_TEST_TRACE"; }
merv_update_mutation_blocked() { [ -e "$MERV_TEST_MAINTENANCE" ]; }
EOF
cat "$TEST_ROOT/admission.branch" >>"$TEST_ROOT/cron-fixture.sh"
cat "$TEST_ROOT/cron.branch" >>"$TEST_ROOT/cron-fixture.sh"
chmod 700 "$TEST_ROOT/cron-fixture.sh"

export MERV_TEST_ROOT="$TEST_ROOT"
export MERV_TEST_TRACE="$TEST_ROOT/trace.log"
export MERV_TEST_MAINTENANCE="$TEST_ROOT/maintenance.active"
export MERV_TEST_HEAL_ENDPOINT="$TEST_ROOT/heal-endpoint.sh"
export MERV_TEST_ADMISSION_SCRIPT="$TEST_ROOT/admission.sh"
export MERV_TEST_MANAGER="$TEST_ROOT/manager.sh"
export MERV_TEST_MISMATCH="$TEST_ROOT/wl-placement-mismatch"
export MERV_TEST_RECONCILED="$TEST_ROOT/reconciled"
: >"$MERV_TEST_TRACE"
: >"$MERV_TEST_MAINTENANCE"
: >"$MERV_TEST_MISMATCH"

sh "$TEST_ROOT/event-fixture.sh" || fail 'production event fixture failed'
_wait=0
while ! grep -Fq 'event-arrived:wireless_restart' "$MERV_TEST_TRACE"; do
  _wait=$((_wait + 1))
  [ "$_wait" -lt 200 ] || fail 'event handler did not launch deferred Heal'
  sleep 0.01
done
sh "$TEST_ROOT/event-fixture.sh" || fail 'debounced event fixture failed'
grep -Fq 'ebtables:-t filter -I FORWARD -j MERV_QT' "$MERV_TEST_TRACE" ||
  fail 'synchronous existing-chain shield relink did not run'
grep -Fq 'heal-info:-c vlan Heal deferred: Update/Repair maintenance is active' "$MERV_TEST_TRACE" ||
  fail 'actual Heal admission gate did not defer on maintenance'
grep -Fq 'event-arrived:wireless_restart' "$MERV_TEST_TRACE" || fail 'wireless event did not arrive'
! grep -Fq 'heal-mutation-path-reached' "$MERV_TEST_TRACE" || fail 'Heal continued into mutation while maintenance was active'
[ "$(grep -Fc 'event-arrived:wireless_restart' "$MERV_TEST_TRACE")" -eq 1 ] ||
  fail 'handler debounce failed to coalesce repeated wireless event'
[ -e "$MERV_TEST_MAINTENANCE" ] || fail 'maintenance fixture unexpectedly released early'

rm -f "$MERV_TEST_MAINTENANCE"
sh "$TEST_ROOT/cron-fixture.sh" || fail 'production cron fixture failed'
_wait=0
while [ ! -e "$MERV_TEST_RECONCILED" ]; do
  _wait=$((_wait + 1))
  [ "$_wait" -lt 200 ] || fail 'existing Heal check did not invoke Manager'
  sleep 0.01
done
grep -Fq 'cron-placement-check' "$MERV_TEST_TRACE" || fail 'cron omitted wireless placement inspection'
grep -Fq 'cron-mismatch-recorded' "$MERV_TEST_TRACE" || fail 'cron did not record the detected mismatch'
grep -Fq 'manager-reconciliation-ran' "$MERV_TEST_TRACE" || fail 'existing Manager did not reconcile placement'
[ ! -e "$MERV_TEST_MISMATCH" ] || fail 'wireless placement remained unreconciled'
[ ! -e "$MERV_TEST_MAINTENANCE" ] || fail 'maintenance was still active during cron reconciliation'

pass 'source-derived wireless event deferred by maintenance, shielded synchronously, debounced, then reconciled by the existing five-minute Heal check after release'
