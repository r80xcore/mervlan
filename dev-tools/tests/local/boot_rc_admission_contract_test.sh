#!/bin/sh
# Offline contract coverage for the deliberately small boot RC admission layer.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-boot-rc-admission.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected $2, got $1)"; }

MANAGER="$BASE_DIR/functions/mervlan_manager.sh"
SAVE="$BASE_DIR/functions/save_settings.sh"
UI="$BASE_DIR/www/index.html"

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { p=1 } p { print } p && /^}/ { exit }' "$MANAGER"
}

NORMALIZE=$(extract_function boot_rc_timeout_normalize)
MONOTONIC=$(extract_function boot_monotonic_now | sed 's@/proc/uptime@${TEST_UPTIME}@g')
WAIT=$(extract_function boot_wait_for_rc_quiet)
OBSERVE=$(extract_function boot_rc_observe | sed 's@/tmp/rc_service@${TEST_RC_SERVICE}@g')
SSID_WAIT=$(extract_function boot_wait_for_configured_ssids)
[ -n "$NORMALIZE" ] && [ -n "$MONOTONIC" ] && [ -n "$WAIT" ] && [ -n "$OBSERVE" ] && [ -n "$SSID_WAIT" ] || {
  fail 'could not extract production boot helpers'
  exit 1
}
eval "$NORMALIZE"

TEST_UPTIME="$TEST_ROOT/uptime"
printf '%s\n' '100.42 90.00' > "$TEST_UPTIME"
eval "$MONOTONIC"
assert_eq "$(boot_monotonic_now)" 100 'monotonic helper returns integer uptime seconds'
printf '%s\n' malformed > "$TEST_UPTIME"
if boot_monotonic_now; then
  fail 'malformed uptime incorrectly produced a timestamp'
else
  pass 'monotonic helper rejects malformed uptime'
fi

assert_eq "$(boot_rc_timeout_normalize '')" 45 'runtime normalization for missing value'
for pair in 'abc 45' '1 45' '4 45' '-1 45' '121 45' '0 0' '5 5' '45 45' '120 120'; do
  set -- $pair
  assert_eq "$(boot_rc_timeout_normalize "$1")" "$2" "runtime normalization for '$1'"
done
pass 'runtime BOOT_RC_TIMEOUT normalization'

run_wait_case() {
  _case="$1"; _times="$2"; _states="$3"; _timeout="$4"
  printf '%s' "$_times" | tr ',' '\n' > "$TEST_ROOT/times.$_case"
  printf '%s' "$_states" | tr ',' '\n' > "$TEST_ROOT/states.$_case"
  MERV_MANAGER_MODE=boot; BOOT_RC_TIMEOUT="$_timeout"; BOOT_RC_QUIET_SECONDS=5
  info() { :; }; error() { :; }
  boot_monotonic_now() {
    _v=$(sed -n '1p' "$TEST_ROOT/times.$_case")
    sed '1d' "$TEST_ROOT/times.$_case" > "$TEST_ROOT/times.$_case.next" && mv "$TEST_ROOT/times.$_case.next" "$TEST_ROOT/times.$_case"
    [ -n "$_v" ] || return 1; printf '%s\n' "$_v"
  }
  boot_rc_observe() {
    _v=$(sed -n '1p' "$TEST_ROOT/states.$_case")
    sed '1d' "$TEST_ROOT/states.$_case" > "$TEST_ROOT/states.$_case.next" && mv "$TEST_ROOT/states.$_case.next" "$TEST_ROOT/states.$_case"
    case "$_v" in quiet) return 0 ;; busy) return 1 ;; *) return 2 ;; esac
  }
  boot_rc_sleep() { :; }
  eval "$WAIT"
  boot_wait_for_rc_quiet test
}

if run_wait_case exact '100,100,101,102,103,104,105' 'quiet,quiet,quiet,quiet,quiet,quiet' 5; then
  pass 'exact five-second quiet boundary succeeds'
else
  fail 'exact five-second quiet boundary failed'
fi
if run_wait_case busy '100,100,101,102,103,104,105,106,107' 'busy,busy,quiet,quiet,quiet,quiet,quiet,quiet' 45; then
  pass 'busy time is not credited as quiet'
else
  fail 'busy-then-quiet timing failed'
fi

run_wait_logging_case() {
  _case="transition_logging"
  printf '%s\n' '100' '100' '101' '102' '103' '104' '105' '106' '107' > "$TEST_ROOT/times.$_case"
  printf '%s\n' 'busy:rc_service=restart_wireless' 'busy:rc_service=restart_wireless' \
    'quiet' 'quiet' 'quiet' 'quiet' 'quiet' 'quiet' > "$TEST_ROOT/states.$_case"
  : > "$TEST_ROOT/transition.log"
  MERV_MANAGER_MODE=boot; BOOT_RC_TIMEOUT=45; BOOT_RC_QUIET_SECONDS=5
  info() { printf '%s\n' "$*" >> "$TEST_ROOT/transition.log"; }
  error() { :; }
  boot_monotonic_now() {
    _v=$(sed -n '1p' "$TEST_ROOT/times.$_case")
    sed '1d' "$TEST_ROOT/times.$_case" > "$TEST_ROOT/times.$_case.next" && mv "$TEST_ROOT/times.$_case.next" "$TEST_ROOT/times.$_case"
    [ -n "$_v" ] || return 1; printf '%s\n' "$_v"
  }
  boot_rc_observe() {
    _v=$(sed -n '1p' "$TEST_ROOT/states.$_case")
    sed '1d' "$TEST_ROOT/states.$_case" > "$TEST_ROOT/states.$_case.next" && mv "$TEST_ROOT/states.$_case.next" "$TEST_ROOT/states.$_case"
    case "$_v" in
      busy:*) BOOT_RC_OBSERVE_REASON=${_v#busy:}; return 1 ;;
      quiet) BOOT_RC_OBSERVE_REASON=""; return 0 ;;
      *) return 2 ;;
    esac
  }
  boot_rc_sleep() { :; }
  eval "$WAIT"
  boot_wait_for_rc_quiet test
}

if run_wait_logging_case &&
   grep -Fq 'ASUS network activity observed (rc_service=restart_wireless); resetting quiet interval' "$TEST_ROOT/transition.log" &&
   grep -Fq 'ASUS network activity cleared; starting 5s quiet interval' "$TEST_ROOT/transition.log" &&
   [ "$(grep -Fc 'ASUS network activity observed (rc_service=restart_wireless); resetting quiet interval' "$TEST_ROOT/transition.log")" -eq 1 ]; then
  pass 'busy transition logging includes the observed RC reason without poll spam'
else
  fail 'busy transition logging did not preserve the expected reason and cadence'
fi
if run_wait_case rollback '110,110,109' 'quiet,quiet' 45; then
  fail 'clock rollback incorrectly succeeded'
else
  pass 'clock rollback fails closed'
fi
if run_wait_case failure '100,100' 'fail' 45; then
  fail 'observation failure incorrectly succeeded'
else
  pass 'observation failure fails closed'
fi
if run_wait_case invalid_time '100' 'quiet' 45; then
  fail 'missing monotonic timestamp incorrectly succeeded'
else
  pass 'missing monotonic timestamp fails closed'
fi
if run_wait_case rc_timeout '100,100,145' 'busy,busy' 45; then
  fail 'persistent RC activity incorrectly passed the monotonic timeout'
else
  pass 'persistent RC activity fails at the 45-second monotonic deadline'
fi

MERV_MANAGER_MODE=boot; BOOT_RC_TIMEOUT=0; BOOT_RC_QUIET_SECONDS=5
boot_monotonic_now() { fail 'disabled gate polled time'; return 1; }
boot_rc_observe() { fail 'disabled gate observed RC'; return 2; }
boot_rc_sleep() { fail 'disabled gate slept'; }
info() { :; }; error() { :; }
eval "$WAIT"
boot_wait_for_rc_quiet disabled || fail 'disabled gate did not return immediately'
pass 'disabled gate does not poll'

TEST_RC_SERVICE="$TEST_ROOT/rc_service"
rm -f "$TEST_RC_SERVICE"
ps() { printf '%s\n' 'PID CMD' '1 init'; }
eval "$OBSERVE"
boot_rc_observe; assert_eq "$?" 0 'idle observer result'
for token in restart_wireless wireless start_lan stop_lan switch; do
  printf '%s\n' "$token" > "$TEST_RC_SERVICE"
  boot_rc_observe; assert_eq "$?" 1 "queued $token observer result"
  assert_eq "$BOOT_RC_OBSERVE_REASON" "rc_service=$token" "queued $token observer reason"
done
rm -f "$TEST_RC_SERVICE"
ps() { printf '%s\n' 'PID CMD' '123 /sbin/service restart_wireless'; }
boot_rc_observe; assert_eq "$?" 1 'service process observer result'
assert_eq "$BOOT_RC_OBSERVE_REASON" 'process=service restart_wireless' 'service process observer reason'
ps() { printf '%s\n' 'PID CMD' '123 /usr/sbin/wlconf eth1 up'; }
boot_rc_observe; assert_eq "$?" 1 'direct wlconf observer result'
assert_eq "$BOOT_RC_OBSERVE_REASON" 'process=wlconf' 'direct wlconf observer reason'
ps() { return 1; }
boot_rc_observe; assert_eq "$?" 2 'ps failure observer result'
pass 'observer covers queue, concrete service worker, direct wlconf, and ps failure'

# Resolve once from a supplied inventory and require every all-radio result.
MERV_MANAGER_MODE=boot; MAX_SSIDS=2; SETTINGS_FILE="$TEST_ROOT/settings.json"; SSID_FILTER_FATAL=0
RESOLVE_COUNT_FILE="$TEST_ROOT/resolve-count"; printf '%s\n' 0 > "$RESOLVE_COUNT_FILE"
IFACE_COUNT=0; INVENTORY_PREPARE_COUNT=0
get_ssid_slot_value() { [ "$1" = 1 ] && printf '%s\n' IoT; }
merv_manager_inventory_prepare() { INVENTORY_PREPARE_COUNT=$((INVENTORY_PREPARE_COUNT + 1)); MERV_NVRAM_INVENTORY_FILE="$1"; return 0; }
ssid_in_nvram() { [ "$1" = IoT ]; }
find_if_by_ssid_any() { _n=$(cat "$RESOLVE_COUNT_FILE"); _n=$((_n + 1)); printf '%s\n' "$_n" > "$RESOLVE_COUNT_FILE"; printf '%s\n' wl0.2 wl1.2 wl2.2; }
iface_exists() { IFACE_COUNT=$((IFACE_COUNT + 1)); case "$1" in wl2.2) [ "$IFACE_COUNT" -gt 3 ] ;; *) return 0 ;; esac; }
DATE_FILE="$TEST_ROOT/ssid-times"; printf '%s\n' 100 100 101 > "$DATE_FILE"
boot_monotonic_now() { _v=$(sed -n '1p' "$DATE_FILE"); sed '1d' "$DATE_FILE" > "$DATE_FILE.next" && mv "$DATE_FILE.next" "$DATE_FILE"; printf '%s\n' "$_v"; }
sleep() { :; }; info() { :; }; warn() { :; }; error() { :; }
eval "$SSID_WAIT"
boot_wait_for_configured_ssids 30 "$TEST_ROOT/inventory" || fail 'all-radio readiness did not succeed'
assert_eq "$(cat "$RESOLVE_COUNT_FILE")" 1 'SSID resolver runs once across polling rounds'
[ "$IFACE_COUNT" -gt 3 ] || fail 'multi-radio readiness did not poll all expected interfaces'
pass 'SSID readiness resolves once and requires every matching VAP'

# A VAP that was resolved from the validated inventory but never appears in
# sysfs is now a fail-closed boot-readiness result, without a real-time sleep.
printf '%s\n' 0 > "$RESOLVE_COUNT_FILE"
find_if_by_ssid_any() { _n=$(cat "$RESOLVE_COUNT_FILE"); _n=$((_n + 1)); printf '%s\n' "$_n" > "$RESOLVE_COUNT_FILE"; printf '%s\n' wl0.1; }
iface_exists() { return 1; }
printf '%s\n' 100 100 129 130 > "$DATE_FILE"
if boot_wait_for_configured_ssids 30 "$TEST_ROOT/inventory"; then
  fail 'resolved interface timeout incorrectly continued boot readiness'
else
  assert_eq "$(cat "$RESOLVE_COUNT_FILE")" 1 'timeout path resolves the configured SSID once'
  pass 'resolved interface timeout fails closed before topology mutation'
fi

# Preserve manager ordering without invoking its router-side mutation body.
main_block=$(sed -n '/^main() {/,/^}/p' "$MANAGER")
line_gate1=$(printf '%s\n' "$main_block" | grep -n 'boot_wait_for_rc_quiet inventory' | cut -d: -f1)
line_inventory=$(printf '%s\n' "$main_block" | grep -n 'merv_nvram_inventory_read' | head -n 1 | cut -d: -f1)
line_gate2=$(printf '%s\n' "$main_block" | grep -n 'boot_wait_for_rc_quiet pre-mutation' | cut -d: -f1)
line_cache=$(printf '%s\n' "$main_block" | grep -n 'merv_iface_vid_cache_enable' | head -n 1 | cut -d: -f1)
line_arm=$(printf '%s\n' "$main_block" | grep -n 'merv_manager_arm_l2_before_mutation' | head -n 1 | cut -d: -f1)
line_final=$(printf '%s\n' "$main_block" | grep -n 'boot_rc_observe' | tail -n 1 | cut -d: -f1)
line_mutating=$(printf '%s\n' "$main_block" | grep -n 'merv_dhcp_hold_mark_mutating' | cut -d: -f1)
[ "$line_gate1" -lt "$line_inventory" ] || fail 'Gate #1 is not before the initial inventory'
[ "$line_gate2" -lt "$line_cache" ] || fail 'Gate #2 is not before cache enable'
[ "$line_cache" -lt "$line_arm" ] || fail 'cache enable is not before L2 arming'
[ "$line_arm" -lt "$line_final" ] && [ "$line_final" -lt "$line_mutating" ] || fail 'final RC admission is not between L2 arming and bridge-cleanup publication'
grep -q '^wait_for_rc_quiet()' "$MANAGER" || fail 'existing post-restart watcher missing'
pass 'boot admission ordering preserves the existing post-restart watcher'

grep -q '"BOOT_RC_TIMEOUT": "45"' "$BASE_DIR/settings/settings.json" || fail 'default setting missing'
grep -q 'json_get_section_value "General" "BOOT_RC_TIMEOUT"' "$MANAGER" || fail 'runtime General ownership missing'
grep -q 'type="number" min="0" max="120" step="1"' "$UI" || fail 'numeric UI constraints missing'
grep -q 'Boot RC timeout must be 0 or an integer from 5 to 120 seconds' "$UI" || fail 'UI disjunction validation missing'
SAVE_VALIDATE=$(awk '/^validate_boot_rc_timeout_kv\(\)/{p=1} p{print} p && /^}/{exit}' "$SAVE")
eval "$SAVE_VALIDATE"
for value in 0 5 45 120; do validate_boot_rc_timeout_kv BOOT_RC_TIMEOUT "$value" || fail "Save rejected $value"; done
for value in '' 1 4 -1 121 abc 45.5; do validate_boot_rc_timeout_kv BOOT_RC_TIMEOUT "$value" && fail "Save accepted '$value'"; done
. "$BASE_DIR/settings/lib_json.sh"
printf '%s\n' '{"General":{"BOOT_RC_TIMEOUT":"45"}}' > "$TEST_ROOT/digest-a.json"
printf '%s\n' '{"General":{"BOOT_RC_TIMEOUT":"46"}}' > "$TEST_ROOT/digest-b.json"
[ "$(merv_settings_node_sync_digest "$TEST_ROOT/digest-a.json")" != "$(merv_settings_node_sync_digest "$TEST_ROOT/digest-b.json")" ] || fail 'timeout did not affect node-sync digest'
[ -n "$(awk '/^seed_general_boot_rc_timeout_default\(\)/{p=1} p && /json_set_section_value "General" "BOOT_RC_TIMEOUT" "45"/{print; exit}' "$SAVE")" ] || fail 'missing General migration does not seed the sectioned default'
pass 'settings/UI validation and node-sync relevance'

[ "$FAILURES" -eq 0 ] || exit 1
printf '%s\n' 'BOOT_RC_ADMISSION_CONTRACT_OK'
