#!/bin/sh
# Focused contract for Sync Nodes' staged node boot-lifecycle reconciliation.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/sync_nodes.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-sync-node-boot.$(date +%s).$$"
SCRIPTS_DIR="$TEST_ROOT/scripts"
export SCRIPTS_DIR

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    _expected="$1"
    _actual="$2"
    _label="$3"
    [ "$_actual" = "$_expected" ] || fail "$_label: expected '$_expected', got '$_actual'"
}

assert_file_count() {
    _expected="$1"
    _pattern="$2"
    _file="$3"
    _label="$4"
    _actual=$(grep -cF "$_pattern" "$_file" 2>/dev/null) || :
    _actual=${_actual:-0}
    assert_eq "$_expected" "$_actual" "$_label"
}

mkdir -p "$TEST_ROOT" "$SCRIPTS_DIR"

# Extract and execute the production-generated remote helper.  This keeps the
# fixture on the same code path that activate_staged_node embeds in its remote
# transaction, without sourcing sync_nodes.sh (which dispatches immediately).
eval "$(sed -n '/^sync_node_boot_reconcile_body()/,/^}/p' "$SOURCE")"
REMOTE_BODY="$TEST_ROOT/remote-body.sh"
sync_node_boot_reconcile_body > "$REMOTE_BODY"
/bin/sh -n "$REMOTE_BODY" || fail 'generated remote reconciliation body is not valid POSIX shell'
eval "$(cat "$REMOTE_BODY")"

make_fake_boot() {
    _root="$1"
    mkdir -p "$_root/settings" "$_root/functions"
    cp "$BASE_DIR/settings/lib_json.sh" "$_root/settings/lib_json.sh"
    cat > "$_root/functions/mervlan_boot.sh" <<'FAKE_BOOT'
#!/bin/sh
base=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scripts="${SCRIPTS_DIR:?}"
services="$scripts/services-start"
event="$scripts/service-event"
log="$base/boot.calls"
printf '%s MERV_NODE_CONTEXT=%s\n' "$1" "${MERV_NODE_CONTEXT:-}" >> "$log"

marker_count() {
    _count=$(grep -cF "$1" "$2" 2>/dev/null) || :
    printf '%s\n' "${_count:-0}"
}

case "$1" in
    nodeenable)
        [ "${2:-}" = "--local" ] || exit 2
        : > "$event"
        : > "$services"
        printf '%s\n' '### >>> MERVLAN START: service-event [tpl=service-event.v2.tpl md5=test]' >> "$event"
        printf '%s\n' '### <<< MERVLAN END: service-event [tpl=service-event.v2.tpl md5=test]' >> "$event"
        printf '%s\n' '### >>> MERVLAN START: services-start-addon [tpl=services-start-addon.v2.tpl md5=test]' >> "$services"
        printf '%s\n' '### <<< MERVLAN END: services-start-addon [tpl=services-start-addon.v2.tpl md5=test]' >> "$services"
        ;;
    enable)
        if [ -f "$base/fail-enable" ]; then exit 17; fi
        if [ "$(marker_count '### >>> MERVLAN START: services-start [tpl=services-start.v' "$services")" = 0 ]; then
            printf '%s\n' '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=test]' >> "$services"
            printf '%s\n' '### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=test]' >> "$services"
        fi
        if [ ! -f "$base/omit-cron" ]; then : > "$base/cron"; fi
        ;;
    disable)
        sed '/tpl=services-start\.v/d' "$services" > "$services.tmp" && mv "$services.tmp" "$services"
        rm -f "$base/cron"
        ;;
    report)
        . "$base/settings/lib_json.sh"
        desired=$(json_get_flag BOOT_ENABLED 0 "$base/settings/settings.json")
        if [ -f "$base/cron" ]; then cron=present; else cron=absent; fi
        if [ "$(marker_count '### >>> MERVLAN START: services-start-addon [tpl=services-start-addon.v' "$services")" = 1 ]; then addon=node-on; else addon=node-off; fi
        if [ -f "$event" ] && grep -qF '### >>> MERVLAN START: service-event [tpl=service-event.v' "$event"; then event_state=active; else event_state=missing; fi
        printf 'REPORT hw=test boot=%s addon=%s event=%s cron=%s is_node=yes mac_shield=off\n' "$desired" "$addon" "$event_state" "$cron"
        ;;
    *) exit 2 ;;
esac
exit 0
FAKE_BOOT
    chmod 755 "$_root/functions/mervlan_boot.sh"
}

make_fixture() {
    _name="$1"
    _desired="$2"
    _initial="$3"
    _root="$TEST_ROOT/$_name"
    make_fake_boot "$_root"
    printf '%s\n' '{' '  "General": {' "    \"BOOT_ENABLED\": \"$_desired\"," '    "IS_NODE": "1"' '  }' '}' > "$_root/settings/settings.json"
    : > "$SCRIPTS_DIR/services-start"
    : > "$SCRIPTS_DIR/service-event"
    case "$_initial" in
        enabled)
            MERV_NODE_CONTEXT=1 sh "$_root/functions/mervlan_boot.sh" nodeenable --local
            MERV_NODE_CONTEXT=1 sh "$_root/functions/mervlan_boot.sh" enable
            ;;
        disabled)
            MERV_NODE_CONTEXT=1 sh "$_root/functions/mervlan_boot.sh" nodeenable --local
            MERV_NODE_CONTEXT=1 sh "$_root/functions/mervlan_boot.sh" disable
            ;;
        baseline)
            MERV_NODE_CONTEXT=1 sh "$_root/functions/mervlan_boot.sh" nodeenable --local
            ;;
        *) fail "unknown fixture initial state $_initial" ;;
    esac
    printf '%s\n' "$_root"
}

run_helper() {
    _root="$1"
    SYNC_NODE_BOOT_DETAIL=""
    SYNC_NODE_BOOT_REPORT=""
    export SYNC_NODE_BOOT_DETAIL SYNC_NODE_BOOT_REPORT
    sync_node_boot_reconcile "$_root"
}

enabled_root=$(make_fixture enabled 1 baseline)
run_helper "$enabled_root" || fail 'BOOT_ENABLED=1 baseline reconciliation failed'
assert_file_count 1 '### >>> MERVLAN START: services-start [tpl=services-start.v' "$SCRIPTS_DIR/services-start" 'enabled manager block'
assert_file_count 1 '### >>> MERVLAN START: services-start-addon [tpl=services-start-addon.v' "$SCRIPTS_DIR/services-start" 'enabled addon block'
assert_file_count 1 '### >>> MERVLAN START: service-event [tpl=service-event.v' "$SCRIPTS_DIR/service-event" 'enabled service-event block'
[ -f "$enabled_root/cron" ] || fail 'BOOT_ENABLED=1 reconciliation did not create cron'
grep -q 'enable MERV_NODE_CONTEXT=1' "$enabled_root/boot.calls" || fail 'enabled reconciliation was not node-local'

# Re-running enabled reconciliation must not duplicate the injected block.
run_helper "$enabled_root" || fail 'already-enabled reconciliation failed'
assert_file_count 1 '### >>> MERVLAN START: services-start [tpl=services-start.v' "$SCRIPTS_DIR/services-start" 'enabled manager block idempotence'

disabled_root=$(make_fixture disabled 0 enabled)
run_helper "$disabled_root" || fail 'BOOT_ENABLED=0 enabled-state cleanup failed'
assert_file_count 0 '### >>> MERVLAN START: services-start [tpl=services-start.v' "$SCRIPTS_DIR/services-start" 'disabled manager block'
assert_file_count 1 '### >>> MERVLAN START: services-start-addon [tpl=services-start-addon.v' "$SCRIPTS_DIR/services-start" 'disabled addon block'
assert_file_count 1 '### >>> MERVLAN START: service-event [tpl=service-event.v' "$SCRIPTS_DIR/service-event" 'disabled service-event block'
[ ! -f "$disabled_root/cron" ] || fail 'BOOT_ENABLED=0 reconciliation left cron'

# Disabled reconciliation is also idempotent.
run_helper "$disabled_root" || fail 'already-disabled reconciliation failed'
assert_file_count 0 '### >>> MERVLAN START: services-start [tpl=services-start.v' "$SCRIPTS_DIR/services-start" 'disabled manager idempotence'

malformed_root=$(make_fixture malformed maybe baseline)
if run_helper "$malformed_root"; then
    fail 'malformed BOOT_ENABLED was accepted'
fi
[ "${SYNC_NODE_BOOT_DETAIL:-}" = invalid-boot-enabled ] || fail 'malformed BOOT_ENABLED reason was not precise'
grep -q '^nodeenable ' "$malformed_root/boot.calls" || fail 'malformed fixture did not establish baseline'
if grep -q '^enable\|^disable' "$malformed_root/boot.calls"; then
    fail 'malformed BOOT_ENABLED invoked a boot action'
fi

enable_failure_root=$(make_fixture enable-failure 1 baseline)
: > "$enable_failure_root/fail-enable"
if run_helper "$enable_failure_root"; then
    fail 'enable failure was accepted'
fi
[ "${SYNC_NODE_BOOT_DETAIL:-}" = boot-enable-failed ] || fail 'enable failure reason was not precise'

verification_failure_root=$(make_fixture verification-failure 1 baseline)
: > "$verification_failure_root/omit-cron"
if run_helper "$verification_failure_root"; then
    fail 'effective-state verification failure was accepted'
fi
[ "${SYNC_NODE_BOOT_DETAIL:-}" = node-cron-missing ] || fail 'effective-state failure reason was not precise'

# The production activation path must reconcile both the new tree and the
# restored old tree, and must expose failures instead of emitting success.
_reconcile_calls=$(grep -cF 'sync_node_boot_reconcile \"\$active\"' "$SOURCE" 2>/dev/null) || :
_reconcile_calls=${_reconcile_calls:-0}
[ "$_reconcile_calls" -ge 2 ] || fail 'activation and rollback do not both reconcile boot state'
grep -qF 'STAGED_NODE_ROLLBACK_FAIL' "$SOURCE" || fail 'rollback boot reconciliation failure is not surfaced'
grep -qF 'STAGED_NODE_OK' "$SOURCE" || fail 'staged success marker missing'

printf 'SYNC_NODE_BOOT_RECONCILE_CONTRACT_OK\n'
