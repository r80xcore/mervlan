#!/bin/sh
#
# Node Boot Autonomy and Fail-Closed Contract Test
#
# Verifies that node APs (IS_NODE=1) receive full autonomous boot configuration
# (TEMPLATE_SERVICES including boot shield, manager, and cron) when BOOT_ENABLED=1,
# preventing IoT/VLAN leakage to br0 on standalone node reboots.
#

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

BOOT_FILE="$MERV_BASE/functions/mervlan_boot.sh"
[ -f "$BOOT_FILE" ] || fail 'mervlan_boot.sh missing'

# 1. Static Contract: nodeenable must inspect BOOT_ENABLED
grep -Fq 'BOOT_ENABLED' "$BOOT_FILE" || fail 'BOOT_ENABLED reference missing from mervlan_boot.sh'
grep -Fq 'Installed node services-start (BOOT_ENABLED=1)' "$BOOT_FILE" || fail 'node services-start boot enable logging missing'

# 2. Behavioral Contract Harness
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-boot.$$"
umask 077
mkdir -p "$TEST_ROOT/settings" "$TEST_ROOT/scripts" "$TEST_ROOT/tmp" "$TEST_ROOT/locks" "$TEST_ROOT/state" || fail 'could not create test fixture'
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_TEST_ROOT="$TEST_ROOT"

# Mock settings and template environment
make_mock_env() {
    _boot_val="$1"

    cat > "$TEST_ROOT/settings.json" <<EOF
{
  "General": {
    "BOOT_ENABLED": "$_boot_val",
    "IS_NODE": "1",
    "NODE_ID": "1"
  },
  "BOOT_ENABLED": "$_boot_val",
  "IS_NODE": "1",
  "NODE_ID": "1",
  "VLAN_01": "50"
}
EOF

    : > "$TEST_ROOT/scripts/services-start"
    : > "$TEST_ROOT/scripts/service-event"
}

# Run nodeenable under fixtured environment
run_boot_action() {
    _action="$1"
    (
        export VAR_SETTINGS_LOADED=1
        export LOG_SETTINGS_LOADED=1
        export LIB_JSON_LOADED=1
        export LIB_SSH_LOADED=1
        export LIB_OWNER_LOCK_LOADED=1
        export LIB_MERVQT_LOADED=1
        export LIB_UPDATE_STATE_LOADED=1
        export LIB_NODE_RECONCILE_LOADED=1
        export LIB_ACTION_ACK_LOADED=1

        export MERV_BASE="$MERV_BASE"
        export MERV_STATE_ROOT="$TEST_ROOT/state"
        export TMPDIR="$TEST_ROOT/tmp"
        export LOCKDIR="$TEST_ROOT/locks"
        export SCRIPTS_DIR="$TEST_ROOT/scripts"
        export SERVICES_START="$TEST_ROOT/scripts/services-start"
        export SERVICE_EVENT_WRAPPER="$TEST_ROOT/scripts/service-event"
        export SETTINGS_FILE="$TEST_ROOT/settings.json"
        export HW_SETTINGS_FILE="$SETTINGS_FILE"
        export TEMPLATE_LIB="$MERV_BASE/templates/mervlan_templates.sh"
        export TEMPLATE_SERVICES="services-start"
        export TEMPLATE_SERVICES_ADDON="services-start-addon"
        export TEMPLATE_SERVICE_EVENT="service-event"
        export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
        export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
        export BOOT_SCRIPT="$BOOT_FILE"
        export SERVICE_EVENT_HANDLER="$MERV_BASE/functions/service-event-handler.sh"
        export MERV_DISABLE_LOCKS=1
        export MERV_FORCE_LOCAL=1
        export MERV_NODE_CONTEXT=1

        # Mocks
        info() { :; }
        warn() { :; }
        error() { :; }
        merv_has() { return 1; }
        get_node_ssh_user() { printf '%s\n' admin; }
        get_node_ssh_port() { printf '%s\n' 22; }
        ebt_mac_shield_teardown() { return 0; }
        ebt_quarantine_teardown() { return 0; }
        merv_update_mutation_blocked() { return 1; }
        reconcile_legacy_boot_file_locks() { return 0; }
        is_node() { return 0; }
        json_get_flag() {
            case "$1" in
                BOOT_ENABLED) grep -o '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | head -n 1 | awk -F'"' '{print $4}' ;;
                IS_NODE) echo "1" ;;
                NODE_ID) echo "1" ;;
                *) echo "${2:-}" ;;
            esac
        }

        # Source template library for real injection
        . "$TEMPLATE_LIB"

        # Source the actual mervlan_boot.sh functions for action dispatch
        . "$BOOT_FILE" "$_action" --local
    )
}

# Test Case 1: nodeenable with BOOT_ENABLED=1 must inject TEMPLATE_SERVICES into services-start
make_mock_env "1"
run_boot_action "nodeenable" || fail 'nodeenable execution failed for BOOT_ENABLED=1'

grep -Fq 'mervlan_boot_wrap.sh shield' "$TEST_ROOT/scripts/services-start" || fail 'services-start missing mervlan_boot_wrap.sh shield for node'
grep -Fq 'mervlan_boot_wrap.sh manager' "$TEST_ROOT/scripts/services-start" || fail 'services-start missing mervlan_boot_wrap.sh manager for node'
grep -Fq 'mervlan_boot_wrap.sh cron' "$TEST_ROOT/scripts/services-start" || fail 'services-start missing mervlan_boot_wrap.sh cron for node'
grep -Fq 'mervlan_boot_wrap.sh install' "$TEST_ROOT/scripts/services-start" || fail 'services-start missing mervlan_boot_wrap.sh install for node'
grep -Fq 'service-event-handler.sh' "$TEST_ROOT/scripts/service-event" || fail 'service-event missing handler for node'

pass "nodeenable-injects-services-start-when-boot-enabled"

# Test Case 2: nodeenable with BOOT_ENABLED=0 must NOT inject TEMPLATE_SERVICES
make_mock_env "0"
run_boot_action "nodeenable" || fail 'nodeenable execution failed for BOOT_ENABLED=0'

! grep -Fq 'mervlan_boot_wrap.sh shield' "$TEST_ROOT/scripts/services-start" || fail 'services-start contains shield when BOOT_ENABLED=0'
! grep -Fq 'mervlan_boot_wrap.sh manager' "$TEST_ROOT/scripts/services-start" || fail 'services-start contains manager when BOOT_ENABLED=0'
grep -Fq 'mervlan_boot_wrap.sh install' "$TEST_ROOT/scripts/services-start" || fail 'services-start missing addon mount when BOOT_ENABLED=0'

pass "nodeenable-omits-services-start-when-boot-disabled"

# Test Case 3: nodedisable removes both TEMPLATE_SERVICES and TEMPLATE_SERVICES_ADDON
make_mock_env "1"
run_boot_action "nodeenable" || fail 'nodeenable execution failed before nodedisable'
run_boot_action "nodedisable" || fail 'nodedisable execution failed'

! grep -Fq 'mervlan_boot_wrap.sh' "$TEST_ROOT/scripts/services-start" || fail 'services-start retains mervlan entries after nodedisable'
! grep -Fq 'service-event-handler.sh' "$TEST_ROOT/scripts/service-event" || fail 'service-event retains handler after nodedisable'

pass "nodedisable-removes-all-templates-cleanly"

printf 'NODE_BOOT_AUTONOMY_CONTRACT_OK\n'
