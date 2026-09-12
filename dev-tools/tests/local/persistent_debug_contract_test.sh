#!/bin/sh
# Deterministic contract for opt-in WAN Native persistent diagnostics.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-persistent-debug.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
write_settings() {
  printf '{\n  "VLAN": {\n    "WAN_Native": {\n      "PERSISTENT_DEBUG_LOGGING": "%s"\n    }\n  }\n}\n' "$1" > "$TEST_ROOT/settings.json"
}
write_settings_without_persistent_debug() {
  printf '{\n  "VLAN": {\n    "WAN_Native": {\n      "WAN_NATIVE_MAIN": "none"\n    }\n  }\n}\n' > "$TEST_ROOT/settings.json"
}

MERV_BASE="$BASE_DIR"
SETTINGS_FILE="$TEST_ROOT/settings.json"
MERV_PERSISTENT_DEBUG_DIR="$TEST_ROOT/jffs-debug"
MERV_PERSISTENT_DEBUG_MAX_FILES=2
MERV_PERSISTENT_DEBUG_MAX_BYTES=128
export MERV_BASE SETTINGS_FILE MERV_PERSISTENT_DEBUG_DIR
export MERV_PERSISTENT_DEBUG_MAX_FILES MERV_PERSISTENT_DEBUG_MAX_BYTES

. "$BASE_DIR/settings/lib_json.sh"
. "$BASE_DIR/settings/lib_debug.sh"

# A pre-feature WAN_Native subsection must receive the new setting through
# the normal nested setter; returning success without insertion would make an
# upgrade appear configured while runtime continued to see a missing key.
cat > "$TEST_ROOT/legacy-settings.json" <<'EOF'
{
  "VLAN": {
    "WAN_Native": {
      "WAN_NATIVE_MAIN": "none"
    }
  }
}
EOF
json_set_section2_value VLAN WAN_Native PERSISTENT_DEBUG_LOGGING 0 "$TEST_ROOT/legacy-settings.json" || fail 'legacy nested setting upsert failed'
[ "$(json_get_section2_value VLAN WAN_Native PERSISTENT_DEBUG_LOGGING "$TEST_ROOT/legacy-settings.json")" = 0 ] || fail 'legacy nested setting was not inserted'

# Absent, explicit-off, and malformed settings must remain off and produce no
# flash directory.
write_settings_without_persistent_debug
persistent_debug_init_from_settings "$SETTINGS_FILE"
! persistent_debug_is_enabled || fail 'missing setting enables persistent debug'
persistent_debug_run_start WANMAIN
[ ! -e "$MERV_PERSISTENT_DEBUG_DIR" ] || fail 'missing setting created persistent debug path'

write_settings 0
persistent_debug_init_from_settings "$SETTINGS_FILE"
! persistent_debug_is_enabled || fail 'explicit off enables persistent debug'
persistent_debug_run_start WANMAIN
[ ! -e "$MERV_PERSISTENT_DEBUG_DIR" ] || fail 'explicit off created persistent debug path'

write_settings invalid
persistent_debug_init_from_settings "$SETTINGS_FILE"
! persistent_debug_is_enabled || fail 'invalid setting enables persistent debug'

# An explicit enable creates a bounded JFFS-style run log and current breadcrumb.
write_settings 1
persistent_debug_init_from_settings "$SETTINGS_FILE"
persistent_debug_is_enabled || fail 'explicit enable did not activate persistent debug'
persistent_debug_run_start WANMAIN
[ -n "$MERV_PERSISTENT_DEBUG_RUN_ID" ] || fail 'enabled run has no identifier'
[ -s "$MERV_PERSISTENT_DEBUG_RUN_LOG" ] || fail 'enabled run has no log'
[ -f "$MERV_PERSISTENT_DEBUG_BREADCRUMB" ] || fail 'enabled run has no breadcrumb'
persistent_debug_event bridge-swap-complete 'member=eth0.190 result=ok'
grep -q 'RUN=WANMAIN-' "$MERV_PERSISTENT_DEBUG_RUN_LOG" || fail 'run ID not recorded'
grep -q 'stage=bridge-swap-complete member=eth0.190 result=ok' "$MERV_PERSISTENT_DEBUG_RUN_LOG" || fail 'lifecycle event not recorded'

# Rotation and the byte cap are independent of the network operation.
printf '%0800d\n' 0 >> "$MERV_PERSISTENT_DEBUG_RUN_LOG"
persistent_debug_trim "$MERV_PERSISTENT_DEBUG_RUN_LOG"
[ "$(wc -c < "$MERV_PERSISTENT_DEBUG_RUN_LOG" | tr -d '[:space:]')" -le 128 ] || fail 'active run exceeds byte cap'
touch "$MERV_PERSISTENT_DEBUG_DIR/wan-native-main-old-a.log" "$MERV_PERSISTENT_DEBUG_DIR/wan-native-main-old-b.log" "$MERV_PERSISTENT_DEBUG_DIR/wan-native-main-old-c.log"
persistent_debug_trim "$MERV_PERSISTENT_DEBUG_RUN_LOG"
set -- "$MERV_PERSISTENT_DEBUG_DIR"/wan-native-main-*.log
[ -f "$1" ] || fail 'rotation removed every run log'
[ "$#" -le 2 ] || fail 'run rotation exceeded file cap'

# A completed transaction clears only the diagnostic breadcrumb.
persistent_debug_complete ok
[ ! -e "$MERV_PERSISTENT_DEBUG_BREADCRUMB" ] || fail 'successful completion retained breadcrumb'

# An unwritable destination is observational only: helper remains successful.
MERV_PERSISTENT_DEBUG_DIR="$TEST_ROOT/not-a-directory"
: > "$MERV_PERSISTENT_DEBUG_DIR"
export MERV_PERSISTENT_DEBUG_DIR
persistent_debug_init_from_settings "$SETTINGS_FILE"
persistent_debug_run_start WANMAIN || fail 'unwritable diagnostics changed control flow'
persistent_debug_event synthetic 'result=ignored' || fail 'unwritable diagnostics changed event flow'

printf 'PERSISTENT_DEBUG_CONTRACT_OK\n'
