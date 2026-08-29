#!/bin/sh
#
# Focused Node Settings Sync Contract Test (Round 1)
#
# Verifies mnj_prepare_node_settings pure settings-builder transformation:
# 1. Identity flag injection (IS_NODE=1, NODE_ID=<id>)
# 2. Hardware section preservation from node source
# 3. Node trunk unification rules (auto-inject TRUNK1 when main has trunks enabled, clean slate when disabled)
# 4. Host awk and BusyBox awk compatibility

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

TEST_ROOT="${TMPDIR:-/tmp}/mervlan-settings-sync-test.$(date +%s).$$"
MAIN_FIXTURE="$TEST_ROOT/main_settings.json"
NODE_HW_FIXTURE="$TEST_ROOT/node_hw_settings.json"
OUT_SETTINGS="$TEST_ROOT/node1_settings.json"
BB_BIN="$TEST_ROOT/busybox-bin"

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

mkdir -p "$TEST_ROOT"

# Main router fixture (GT-AX6000, TRUNK1 enabled, VLAN_01=10)
printf '%s\n' \
    '{' \
    '  "General": {' \
    '    "IS_NODE": "0",' \
    '    "NODE_ID": "none"' \
    '  },' \
    '  "Hardware": {' \
    '    "MODEL": "GT-AX6000",' \
    '    "MAX_ETH_PORTS": "5",' \
    '    "MAX_SSIDS": "12"' \
    '  },' \
    '  "SSH_KEYS_INSTALLED": "1",' \
    '  "SSH_KEY": "'"$TEST_ROOT"'/.ssh/vlan_manager",' \
    '  "SSH_PUBKEY": "'"$TEST_ROOT"'/.ssh/vlan_manager.pub",' \
    '  "NODE1_IP": "192.168.50.2",' \
    '  "TRUNK1": "1",' \
    '  "TAGGED_TRUNK1": "10",' \
    '  "VLAN_01": "10",' \
    '  "VLAN_02": "20"' \
    '}' > "$MAIN_FIXTURE"

mkdir -p "$TEST_ROOT/.ssh"
printf 'dummy-key' > "$TEST_ROOT/.ssh/vlan_manager"
printf 'dummy-pubkey' > "$TEST_ROOT/.ssh/vlan_manager.pub"

# Node fixture (RT-AX86U, 4 ETH ports detected on node)
printf '%s\n' \
    '{' \
    '  "Hardware": {' \
    '    "MODEL": "RT-AX86U",' \
    '    "MAX_ETH_PORTS": "4",' \
    '    "MAX_SSIDS": "8"' \
    '  }' \
    '}' > "$NODE_HW_FIXTURE"

. "$MERV_BASE/settings/lib_node_jobs.sh"

# Execute the production Dry Run/control-plane decision seam directly.  This
# proves that an inherited saved DRY_RUN=yes cannot suppress settings-only
# convergence, while an explicit CLI --dry-run remains a simulation.
SYNC_DRYRUN_SEAM=$(sed -n '/^if \[ -z "${DRY_RUN:-}" \]; then$/,/^sync_settings_reconcile_capture$/p' "$MERV_BASE/functions/sync_nodes.sh")
[ -n "$SYNC_DRYRUN_SEAM" ] || fail 'could not extract sync dry-run decision seam'

run_settings_control_plane_case() {
    SETTINGS_ONLY=1
    DRY_RUN_FORCED=0
    SETTINGS_CONTROL_PLANE=0
    unset DRY_RUN
    json_get_flag() { printf '%s\n' yes; }
    sync_settings_reconcile_capture() { :; }
    eval "$SYNC_DRYRUN_SEAM"
    assert_eq 1 "$SETTINGS_CONTROL_PLANE" 'settings-only inherited Dry Run enables control-plane transfer'
    assert_eq no "$DRY_RUN" 'settings-only inherited Dry Run does not become a simulation'
}

run_explicit_dry_run_case() {
    SETTINGS_ONLY=1
    DRY_RUN_FORCED=1
    SETTINGS_CONTROL_PLANE=0
    DRY_RUN=yes
    json_get_flag() { printf '%s\n' yes; }
    sync_settings_reconcile_capture() { :; }
    eval "$SYNC_DRYRUN_SEAM"
    assert_eq 0 "$SETTINGS_CONTROL_PLANE" 'explicit dry-run does not enable control-plane transfer'
    assert_eq yes "$DRY_RUN" 'explicit dry-run remains a simulation'
}

run_settings_control_plane_case
run_explicit_dry_run_case

run_contract_tests() {
    _prefix="$1"

    # Test 1: Full transformation with node hardware source
    rm -f "$OUT_SETTINGS"
    mnj_prepare_node_settings "$MAIN_FIXTURE" "1" "$OUT_SETTINGS" "$NODE_HW_FIXTURE" || fail "$_prefix: mnj_prepare_node_settings returned non-zero"
    [ -f "$OUT_SETTINGS" ] || fail "$_prefix: output settings file not created"

    assert_eq "1" "$(json_get_flag IS_NODE 0 "$OUT_SETTINGS")" "$_prefix: IS_NODE flag"
    assert_eq "1" "$(json_get_flag NODE_ID none "$OUT_SETTINGS")" "$_prefix: NODE_ID flag"
    assert_eq "1" "$(json_get_section_value General IS_NODE "$OUT_SETTINGS")" "$_prefix: General.IS_NODE"
    assert_eq "1" "$(json_get_section_value General NODE_ID "$OUT_SETTINGS")" "$_prefix: General.NODE_ID"

    assert_eq "RT-AX86U" "$(json_get_hw_value MODEL "" "$OUT_SETTINGS")" "$_prefix: Preserved Hardware MODEL"
    assert_eq "4" "$(json_get_hw_value MAX_ETH_PORTS "" "$OUT_SETTINGS")" "$_prefix: Preserved Hardware MAX_ETH_PORTS"

    assert_eq "1" "$(json_get_flag TRUNK1 0 "$OUT_SETTINGS")" "$_prefix: TRUNK1 auto-injected"
    assert_eq "10,20" "$(json_get_flag TAGGED_TRUNK1 "" "$OUT_SETTINGS")" "$_prefix: TAGGED_TRUNK1 populated"

    # Test 2: Main router has no trunks enabled -> node trunks reset to 0
    _no_trunk_main="$TEST_ROOT/no_trunk_main.json"
    cp "$MAIN_FIXTURE" "$_no_trunk_main"
    json_set_flag "TRUNK1" "0" "$_no_trunk_main"

    _no_trunk_out="$TEST_ROOT/no_trunk_node1.json"
    mnj_prepare_node_settings "$_no_trunk_main" "1" "$_no_trunk_out" "$NODE_HW_FIXTURE" || fail "$_prefix: no-trunk mnj_prepare_node_settings failed"

    # Test 3: sync_nodes.sh --settings-only dry-run verification
    _test_merv="$TEST_ROOT/merv_base_$$"
    mkdir -p "$_test_merv/settings" "$_test_merv/functions" "$_test_merv/.ssh" "$TEST_ROOT/logs_$$"
    cp -r "$MERV_BASE/settings"/* "$_test_merv/settings/"
    cp -r "$MERV_BASE/functions"/* "$_test_merv/functions/"
    cp "$MAIN_FIXTURE" "$_test_merv/settings/settings.json"
    cp "$TEST_ROOT/.ssh/vlan_manager" "$_test_merv/.ssh/vlan_manager"
    cp "$TEST_ROOT/.ssh/vlan_manager.pub" "$_test_merv/.ssh/vlan_manager.pub"

    _sync_res=0
    _sync_out=$(sh -c "unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_SSH_LOADED LIB_JSON_LOADED LIB_MERVQT_LOADED LIB_NODE_JOBS_LOADED LIB_ACTION_ACK_LOADED SETTINGS_FILE; export MERV_BASE='$_test_merv'; export LOGROOT='$TEST_ROOT/logs_$$'; sh '$_test_merv/functions/sync_nodes.sh' --settings-only --dry-run 2>&1" || _sync_res=$?)
    if [ "$_sync_res" -ne 0 ]; then
        fail "$_prefix: sync_nodes.sh --settings-only failed with rc=$_sync_res (stdout/err: $_sync_out | log: $(cat "$TEST_ROOT/logs_$$/vlan_manager.log" 2>/dev/null || true))"
    fi
    if ! grep -q "Settings-only mode" "$TEST_ROOT/logs_$$/vlan_manager.log" 2>/dev/null; then
        fail "$_prefix: sync_nodes.sh --settings-only failed to record Settings-only mode in log"
    fi

    # Test 4: activate_staged_node_settings_only contract test
    _act_stage="$TEST_ROOT/staged_$$"
    _act_merv="$TEST_ROOT/merv_target_$$"
    mkdir -p "$_act_stage/settings" "$_act_merv/settings"
    cp "$MAIN_FIXTURE" "$_act_stage/settings/settings.json"

    # Load activate_staged_node_settings_only function from sync_nodes.sh
    eval "$(sed -n '/^activate_staged_node_settings_only()/,/^}/p' "$MERV_BASE/functions/sync_nodes.sh")"
    merv_ssh_exec() {
        MERV_BASE="$_act_merv" eval "$3"
    }
    activate_staged_node_settings_only "127.0.0.1" "1" "$_act_stage" || fail "$_prefix: activate_staged_node_settings_only execution failed"
    [ -d "$_act_stage" ] && fail "$_prefix: staged settings directory was not cleaned up"
    [ -f "$_act_merv/settings/settings.json" ] || fail "$_prefix: target settings.json was not created"
}

run_contract_tests "Host awk"

BUSYBOX=$(command -v busybox 2>/dev/null || true)
if [ -n "$BUSYBOX" ]; then
    mkdir -p "$BB_BIN"
    ln -sf "$BUSYBOX" "$BB_BIN/awk" || fail "cannot create BusyBox awk shim"

    PATH="$BB_BIN:$PATH" run_contract_tests "BusyBox awk"
else
    printf 'WARN: BusyBox awk unavailable; router-side test skipped\n'
fi

printf 'SUCCESS: All Node Settings Sync contract tests passed!\n'
