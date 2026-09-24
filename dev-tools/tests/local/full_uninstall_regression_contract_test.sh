#!/bin/sh
# Focused regression coverage for the Full Uninstall maintenance-release and
# node cron-teardown contracts.  All fixtures stay beneath a private /tmp
# directory; no router or live addon paths are touched.

set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.full-uninstall.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
  _fur_src="$1"
  _fur_name="$2"
  _fur_out="$3"
  awk -v name="$_fur_name" '
    function brace_delta(line, i, c, n) {
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") n++
        else if (c == "}") n--
      }
      return n
    }
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" {
      inside = 1
    }
    inside {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$_fur_src" > "$_fur_out" || return 1
  [ -s "$_fur_out" ]
}

UNINSTALL="$BASE_DIR/uninstall.sh"
BOOT="$BASE_DIR/functions/mervlan_boot.sh"
RELEASE_FN="$TEST_ROOT/uninstall-release.sh"
EXIT_FN="$TEST_ROOT/uninstall-exit-handler.sh"
CRON_FN="$TEST_ROOT/disable-cron.sh"
NODE_BODY="$TEST_ROOT/nodedisable-body.sh"

extract_function "$UNINSTALL" uninstall_maintenance_release "$RELEASE_FN" ||
  fail 'uninstall release extraction'
extract_function "$UNINSTALL" uninstall_maintenance_exit_handler "$EXIT_FN" ||
  fail 'uninstall exit-handler extraction'
extract_function "$BOOT" disable_cron_now "$CRON_FN" ||
  fail 'cron helper extraction'
awk '
  /^  nodedisable\)/ { inside = 1; next }
  inside && /^    ;;$/ { exit }
  inside { print }
' "$BOOT" > "$NODE_BODY" || fail 'nodedisable extraction'
[ -s "$NODE_BODY" ] || fail 'nodedisable body empty'

# ---------------------------------------------------------------------------
# A — the canonical owner must be released while its runtime parent exists.
# This uses the real owner and maintenance libraries and the real uninstall
# release function; it does not replace release with an unconditional stub.
# ---------------------------------------------------------------------------
export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_UPDATE_JOURNAL="$TEST_ROOT/state/update.journal"
export MERV_UPDATE_QUIESCE_FILE="$TEST_ROOT/state/update.quiesce"
export MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/runtime/locks/mervlan_maintenance.lock"
mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/runtime/locks" "$TEST_ROOT/addon" ||
  fail 'maintenance fixture setup'
. "$BASE_DIR/settings/var_settings.sh" || fail 'settings load'
. "$BASE_DIR/settings/lib_update_state.sh" || fail 'maintenance load'
. "$RELEASE_FN" || fail 'real release function load'

mkdir -p "$TEST_ROOT/addon/source" || fail 'active-tree fixture setup'
merv_maintenance_direct_admit || fail 'fixture owner admission'
[ -f "$MERV_UPDATE_MAINTENANCE_LOCK/owner" ] || fail 'fixture owner record missing'
MERV_MAINTENANCE_ENTRY_ADMITTED=1
rm -rf "$TEST_ROOT/addon" "$TEST_ROOT/state" || fail 'fixture destructive work'
[ -d "$TEST_ROOT/runtime" ] || fail 'runtime disappeared before release'
uninstall_maintenance_release || fail 'canonical release with runtime parent'
[ "$(merv_owner_lock_state "$MERV_UPDATE_MAINTENANCE_LOCK")" = absent ] ||
  fail 'canonical owner remained after release'
[ -d "$TEST_ROOT/runtime" ] || fail 'runtime disappeared during release'
rm -rf "$TEST_ROOT/runtime" || fail 'post-release runtime cleanup'
[ ! -e "$TEST_ROOT/runtime" ] || fail 'runtime cleanup incomplete'
pass 'maintenance release precedes runtime-root removal'

# The old order must fail against the real authoritative release primitive.
mkdir -p "$TEST_ROOT/runtime/locks" || fail 'old-order fixture setup'
merv_maintenance_direct_admit || fail 'old-order fixture owner admission'
rm -rf "$TEST_ROOT/runtime" || fail 'old-order fixture runtime removal'
if merv_maintenance_direct_release; then
  fail 'old ordering unexpectedly released a missing owner parent'
fi
MERV_MAINTENANCE_ENTRY_OWNED=0
pass 'old ordering is rejected by authoritative owner release'

# The production terminal order is source-guarded as well as behavior-tested:
# explicit release, trap removal, and only then full-runtime cleanup.
_fur_release_line=$(grep -n '^if ! uninstall_maintenance_release; then' "$UNINSTALL" |
  tail -n 1 | cut -d: -f1)
_fur_trap_line=$(grep -n '^trap - EXIT$' "$UNINSTALL" | tail -n 1 | cut -d: -f1)
_fur_tmp_line=$(grep -n 'rm -rf /tmp/mervlan_tmp' "$UNINSTALL" | tail -n 1 | cut -d: -f1)
[ -n "$_fur_release_line" ] && [ -n "$_fur_trap_line" ] && [ -n "$_fur_tmp_line" ] ||
  fail 'terminal cleanup order markers missing'
[ "$_fur_release_line" -lt "$_fur_trap_line" ] &&
  [ "$_fur_trap_line" -lt "$_fur_tmp_line" ] ||
  fail 'runtime cleanup still precedes maintenance release'
pass 'production terminal cleanup order is source-guarded'

# ---------------------------------------------------------------------------
# B — successful explicit release must make the EXIT trap a no-op, while a
# failed terminal path still makes one safe release attempt.
# ---------------------------------------------------------------------------
_fur_success_child="$TEST_ROOT/release-success.sh"
cat > "$_fur_success_child" <<EOF
#!/bin/sh
set -u
TRACE="$TEST_ROOT/release-success.trace"
: > "\$TRACE"
merv_maintenance_direct_release() {
  printf '%s\n' release >> "\$TRACE"
  return 0
}
MERV_MAINTENANCE_ENTRY_ADMITTED=1
. "$RELEASE_FN"
. "$EXIT_FN"
uninstall_maintenance_release || exit 1
uninstall_maintenance_exit_handler
EOF
chmod 700 "$_fur_success_child" || fail 'success child permissions'
if "$_fur_success_child" >/dev/null 2>&1; then :; else fail 'success terminal cleanup child'; fi
[ "$(wc -l < "$TEST_ROOT/release-success.trace" | tr -d ' ')" = 1 ] ||
  fail 'successful terminal cleanup attempted duplicate release'
pass 'successful terminal cleanup avoids duplicate release'

_fur_failure_child="$TEST_ROOT/release-failure.sh"
cat > "$_fur_failure_child" <<EOF
#!/bin/sh
set -u
TRACE="$TEST_ROOT/release-failure.trace"
: > "\$TRACE"
merv_maintenance_direct_release() {
  printf '%s\n' release >> "\$TRACE"
  return 1
}
MERV_MAINTENANCE_ENTRY_ADMITTED=1
. "$RELEASE_FN"
. "$EXIT_FN"
uninstall_maintenance_exit_handler
EOF
chmod 700 "$_fur_failure_child" || fail 'failure child permissions'
"$_fur_failure_child" >/dev/null 2>&1
_fur_failure_rc=$?
[ "$_fur_failure_rc" -eq 1 ] || fail 'failed terminal cleanup status'
[ "$(wc -l < "$TEST_ROOT/release-failure.trace" | tr -d ' ')" = 1 ] ||
  fail 'failed terminal cleanup did not attempt safe release once'
pass 'failed terminal cleanup retains safe release attempt'

# ---------------------------------------------------------------------------
# C/D/E — exercise the real disable_cron_now helper with an isolated cru
# implementation: successful removal, already-absent idempotence, a retained
# stale entry, and an unverifiable listing all have distinct outcomes.
# ---------------------------------------------------------------------------
FAKE_CRU="$TEST_ROOT/fake-cru"
FAKE_CRU_STATE="$TEST_ROOT/cron.state"
cat > "$FAKE_CRU" <<'EOF'
#!/bin/sh
case "${1:-}" in
  a)
    printf '%s\n' "${3:-}" > "$FAKE_CRU_STATE"
    ;;
  d)
    if [ "${FAKE_CRU_KEEP:-0}" != "1" ]; then
      : > "$FAKE_CRU_STATE"
    fi
    ;;
  l)
    [ "${FAKE_CRU_LIST_FAIL:-0}" = "1" ] && exit 1
    cat "$FAKE_CRU_STATE" 2>/dev/null
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod 700 "$FAKE_CRU" || fail 'fake cru permissions'
export FAKE_CRU_STATE
CRU_BIN="$FAKE_CRU"
CRON_NAME=mervlan_health
INJ_BASE="$TEST_ROOT/node/addon"
warn() { :; }
info() { :; }
. "$CRON_FN" || fail 'cron helper load'

"$FAKE_CRU" a "$CRON_NAME" "*/5 * * * * $INJ_BASE/functions/heal_event.sh cron"
disable_cron_now || fail 'cron removal success path'
[ ! -s "$FAKE_CRU_STATE" ] || fail 'cron remained after successful removal'
pass 'node cron teardown removes the MerVLAN health entry'

disable_cron_now || fail 'already-absent cron idempotence'
pass 'node cron teardown is idempotent when already absent'

"$FAKE_CRU" a "$CRON_NAME" "*/5 * * * * $INJ_BASE/functions/heal_event.sh cron"
FAKE_CRU_KEEP=1
export FAKE_CRU_KEEP
if disable_cron_now; then fail 'stale cron accepted after failed deletion'; fi
grep -Fq 'heal_event.sh cron' "$FAKE_CRU_STATE" || fail 'stale cron fixture vanished unexpectedly'
pass 'stale cron verification failure returns non-zero'

FAKE_CRU_KEEP=0
FAKE_CRU_LIST_FAIL=1
export FAKE_CRU_LIST_FAIL
if disable_cron_now; then fail 'unverifiable cron listing accepted'; fi
pass 'cron listing failure returns non-zero'
unset FAKE_CRU_KEEP FAKE_CRU_LIST_FAIL

# The exact production node-local action must invoke the helper before it
# removes node control-plane state, and must retain the existing teardown calls.
grep -Fq 'if ! disable_cron_now; then' "$NODE_BODY" || fail 'nodedisable cron gate missing'
grep -Fq 'Could not disable MerVLAN health cron on node' "$NODE_BODY" ||
  fail 'nodedisable cron failure message missing'
grep -Fq 'merv_qt_teardown' "$NODE_BODY" || fail 'nodedisable MERV_QT teardown missing'
grep -Fq 'ebt_mac_shield_teardown' "$NODE_BODY" || fail 'nodedisable MERV_MAC teardown missing'
grep -Fq 'marker_present "$TEMPLATE_SERVICES" "$SERVICES_START"' "$NODE_BODY" ||
  fail 'nodedisable manager boot-entry verification missing'
grep -Fq 'marker_present "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START"' "$NODE_BODY" ||
  fail 'nodedisable addon boot-entry verification missing'
grep -Fq '[ "$_nodedisable_failed" -eq 0 ] || exit 1' "$NODE_BODY" ||
  fail 'nodedisable boot-entry failure gate missing'

NODE_SCRIPT="$TEST_ROOT/run-nodedisable.sh"
NODE_ROOT="$TEST_ROOT/node"
mkdir -p "$NODE_ROOT" "$TEST_ROOT/bin" || fail 'node fixture directories'
cat > "$TEST_ROOT/bin/ebtables" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 700 "$TEST_ROOT/bin/ebtables" || fail 'fake ebtables permissions'
mkdir -p "$NODE_ROOT/addon/functions" || fail 'node addon fixture'
printf '%s\n' \
  'unrelated-before' \
  '### >>> MERVLAN START: service-event [tpl=node-service-event.v1.tpl md5=test]' \
  'mervlan-node-hook' \
  '### <<< MERVLAN END: service-event [tpl=node-service-event.v1.tpl md5=test]' \
  'unrelated-after' > "$NODE_ROOT/service-event"
printf '%s\n' \
  'unrelated-before' \
  '### >>> MERVLAN START: services-start [tpl=node-services.v1.tpl md5=test]' \
  'mervlan-manager-boot' \
  '### <<< MERVLAN END: services-start [tpl=node-services.v1.tpl md5=test]' \
  '### >>> MERVLAN START: services-start [tpl=node-services-addon.v1.tpl md5=test]' \
  'mervlan-addon-boot' \
  '### <<< MERVLAN END: services-start [tpl=node-services-addon.v1.tpl md5=test]' \
  'unrelated-after' > "$NODE_ROOT/services-start" || fail 'node boot hook fixture'
: > "$NODE_ROOT/qt.state"
: > "$NODE_ROOT/mac.state"
: > "$NODE_ROOT/mac.active"
: > "$NODE_ROOT/mac.jffs"
"$FAKE_CRU" a "$CRON_NAME" "*/5 * * * * $INJ_BASE/functions/heal_event.sh cron"

cat > "$NODE_SCRIPT" <<EOF
#!/bin/sh
set -u
PATH="$TEST_ROOT/bin:\$PATH"
CRU_BIN="$FAKE_CRU"
CRON_NAME=mervlan_health
INJ_BASE="$INJ_BASE"
SERVICE_EVENT_WRAPPER="$NODE_ROOT/service-event"
SERVICES_START="$NODE_ROOT/services-start"
TEMPLATE_SERVICE_EVENT=node-service-event
TEMPLATE_SERVICES=node-services
TEMPLATE_SERVICES_ADDON=node-services-addon
MERV_MAC_DB_ACTIVE="$NODE_ROOT/mac.active"
MERV_MAC_DB_JFFS="$NODE_ROOT/mac.jffs"
MERV_NODE_CONTEXT=1
MERV_FORCE_LOCAL=0
FAKE_REMOVE_FAIL="\${FAKE_REMOVE_FAIL:-}"
FAKE_LEAVE_MARKER="\${FAKE_LEAVE_MARKER:-}"
warn() { :; }
info() { :; }
error() { :; }
is_node() { return 0; }
marker_present() {
  _rtn_name="\$1"
  _rtn_dest="\$2"
  case "\$_rtn_name" in
    node-services) _rtn_tpl=node-services.v1.tpl ;;
    node-services-addon) _rtn_tpl=node-services-addon.v1.tpl ;;
    *) return 1 ;;
  esac
  grep -Fq "[tpl=\$_rtn_tpl " "\$_rtn_dest"
}
remove_template_block() {
  _rtn_name="\$1"
  _rtn_dest="\$2"
  case "\$_rtn_name" in
    node-service-event) _rtn_tpl=node-service-event.v1.tpl ;;
    node-services) _rtn_tpl=node-services.v1.tpl ;;
    node-services-addon) _rtn_tpl=node-services-addon.v1.tpl ;;
    *) return 1 ;;
  esac
  [ "\${FAKE_REMOVE_FAIL:-}" = "\$_rtn_name" ] && return 1
  [ "\${FAKE_LEAVE_MARKER:-}" = "\$_rtn_name" ] && return 0
  _rtn_tmp="\${_rtn_dest}.tmp"
  _rtn_dest_id="\${_rtn_dest##*/}"
  awk -v dest="\$_rtn_dest_id" -v tpl="\$_rtn_tpl" '
    BEGIN { skipping = 0 }
    {
      start = "### >>> MERVLAN START: " dest " [tpl=" tpl " "
      end = "### <<< MERVLAN END: " dest " [tpl=" tpl " "
      if (!skipping && index(\$0, start) == 1) { skipping = 1; next }
      if (skipping && index(\$0, end) == 1) { skipping = 0; next }
      if (!skipping) print
    }
  ' "\$_rtn_dest" > "\$_rtn_tmp" || return 1
  mv "\$_rtn_tmp" "\$_rtn_dest"
}
merv_qt_teardown() { rm -f "$NODE_ROOT/qt.state"; }
ebt_mac_shield_teardown() { rm -f "$NODE_ROOT/mac.state"; }
. "$CRON_FN"
$(cat "$NODE_BODY")
EOF
chmod 700 "$NODE_SCRIPT" || fail 'nodedisable child permissions'
FAKE_REMOVE_FAIL=
FAKE_LEAVE_MARKER=
export FAKE_REMOVE_FAIL FAKE_LEAVE_MARKER
"$NODE_SCRIPT" >/dev/null 2>&1 || fail 'nodedisable local action'
[ ! -s "$FAKE_CRU_STATE" ] || fail 'nodedisable left health cron'
for _fur_hook in "$NODE_ROOT/service-event" "$NODE_ROOT/services-start"; do
  ! grep -Fq 'MERVLAN START' "$_fur_hook" || fail "nodedisable left hook: $_fur_hook"
  grep -Fq 'unrelated-before' "$_fur_hook" || fail "nodedisable removed unrelated hook content: $_fur_hook"
  grep -Fq 'unrelated-after' "$_fur_hook" || fail "nodedisable removed unrelated hook content: $_fur_hook"
done
if grep -Fq 'MERVLAN START' "$NODE_ROOT/services-start"; then
  fail 'nodedisable left a services-start marker'
fi
[ ! -e "$NODE_ROOT/qt.state" ] || fail 'nodedisable left MERV_QT state'
[ ! -e "$NODE_ROOT/mac.state" ] || fail 'nodedisable left MERV_MAC state'
[ ! -e "$NODE_ROOT/mac.active" ] && [ ! -e "$NODE_ROOT/mac.jffs" ] ||
  fail 'nodedisable left MAC database state'
pass 'nodedisable preserves existing teardown semantics'

reset_node_fixture() {
  printf '%s\n' \
    'unrelated-before' \
    '### >>> MERVLAN START: service-event [tpl=node-service-event.v1.tpl md5=test]' \
    'mervlan-node-hook' \
    '### <<< MERVLAN END: service-event [tpl=node-service-event.v1.tpl md5=test]' \
    'unrelated-after' > "$NODE_ROOT/service-event" || fail 'node event reset'
  printf '%s\n' \
    'unrelated-before' \
    '### >>> MERVLAN START: services-start [tpl=node-services.v1.tpl md5=test]' \
    'mervlan-manager-boot' \
    '### <<< MERVLAN END: services-start [tpl=node-services.v1.tpl md5=test]' \
    '### >>> MERVLAN START: services-start [tpl=node-services-addon.v1.tpl md5=test]' \
    'mervlan-addon-boot' \
    '### <<< MERVLAN END: services-start [tpl=node-services-addon.v1.tpl md5=test]' \
    'unrelated-after' > "$NODE_ROOT/services-start" || fail 'node services reset'
  : > "$NODE_ROOT/qt.state"
  : > "$NODE_ROOT/mac.state"
  : > "$NODE_ROOT/mac.active"
  : > "$NODE_ROOT/mac.jffs"
  "$FAKE_CRU" a "$CRON_NAME" "*/5 * * * * $INJ_BASE/functions/heal_event.sh cron"
  FAKE_REMOVE_FAIL=
  FAKE_LEAVE_MARKER=
  export FAKE_REMOVE_FAIL FAKE_LEAVE_MARKER
}

reset_node_fixture
FAKE_REMOVE_FAIL=node-services
export FAKE_REMOVE_FAIL
if "$NODE_SCRIPT" >/dev/null 2>&1; then fail 'manager boot-entry removal failure accepted'; fi
pass 'manager boot-entry removal failure returns non-zero'

reset_node_fixture
FAKE_REMOVE_FAIL=node-services-addon
export FAKE_REMOVE_FAIL
if "$NODE_SCRIPT" >/dev/null 2>&1; then fail 'addon boot-entry removal failure accepted'; fi
pass 'addon boot-entry removal failure returns non-zero'

reset_node_fixture
FAKE_LEAVE_MARKER=node-services
export FAKE_LEAVE_MARKER
if "$NODE_SCRIPT" >/dev/null 2>&1; then fail 'remaining manager boot-entry accepted'; fi
pass 'remaining manager boot-entry returns non-zero'

reset_node_fixture
FAKE_LEAVE_MARKER=node-services-addon
export FAKE_LEAVE_MARKER
if "$NODE_SCRIPT" >/dev/null 2>&1; then fail 'remaining addon boot-entry accepted'; fi
pass 'remaining addon boot-entry returns non-zero'

reset_node_fixture
printf '%s\n' unrelated-only > "$NODE_ROOT/services-start"
FAKE_REMOVE_FAIL=
FAKE_LEAVE_MARKER=
export FAKE_REMOVE_FAIL FAKE_LEAVE_MARKER
"$NODE_SCRIPT" >/dev/null 2>&1 || fail 'missing boot-entry blocks were not idempotent'
pass 'missing boot-entry blocks remain idempotent'

reset_node_fixture
rm -f "$NODE_ROOT/services-start"
"$NODE_SCRIPT" >/dev/null 2>&1 || fail 'missing services-start file was not idempotent'
pass 'missing services-start file remains idempotent'

printf 'FULL_UNINSTALL_REGRESSION_CONTRACT_OK\n'
