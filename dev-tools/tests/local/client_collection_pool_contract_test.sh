#!/bin/sh
# Deterministic Client Collection integration contract for the bounded node
# pool.  The real collector and, for the marker cases, its parent-side result
# checks run against isolated fixture libraries; no router or SSH is contacted.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-client-pool.$$
FAKE_BASE="$TMP_ROOT/addon"
umask 077
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" || exit 1
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

# The fixture settings deliberately use TEST_RUNTIME, which is changed for
# each width/failure scenario before the real collector is launched.
cat > "$FAKE_BASE/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
TMPDIR="$TEST_RUNTIME/tmp"
LOCKDIR="$TEST_RUNTIME/locks"
COLLECTDIR="$TEST_RUNTIME/client_collection"
RESULTDIR="$TEST_RUNTIME/results"
OUT_FINAL="$RESULTDIR/vlan_clients.json"
FUNCDIR="$MERV_BASE/functions"
DRY_RUN=no
MERV_MAC_DB_ACTIVE="$TEST_RUNTIME/mac_shield.db"
MERV_MAC_OVERRIDE_DB="$TEST_RUNTIME/mac_shield_override.db"
MERV_CLIENT_NAME_DB="$TEST_RUNTIME/client_names.db"
export TMPDIR LOCKDIR COLLECTDIR RESULTDIR OUT_FINAL FUNCDIR DRY_RUN
export MERV_MAC_DB_ACTIVE MERV_MAC_OVERRIDE_DB MERV_CLIENT_NAME_DB
EOF

cat > "$FAKE_BASE/settings/log_settings.sh" <<'EOF'
LOG_SETTINGS_LOADED=1
LOG_chan_cli="$TEST_RUNTIME/cli.log"
LOG_chan_vlan="$TEST_RUNTIME/vlan.log"
export LOG_chan_cli LOG_chan_vlan
info() { printf 'INFO:%s\n' "$*" >> "$TEST_TRACE"; }
warn() { printf 'WARN:%s\n' "$*" >> "$TEST_TRACE"; }
error() { printf 'ERROR:%s\n' "$*" >> "$TEST_TRACE"; }
EOF

cat > "$FAKE_BASE/settings/lib_json.sh" <<'EOF'
LIB_JSON_LOADED=1
json_validate_file() { grep -q '"router"[[:space:]]*:' "$1"; }
json_get_flag() { :; }
merv_is_valid_node_id() {
    case "$1" in 1|2|3|4|5|6) return 0 ;; *) return 1 ;; esac
}
EOF

cat > "$FAKE_BASE/settings/lib_ssh.sh" <<'EOF'
LIB_SSH_LOADED=1
merv_node_list() {
    _ccp_i=1
    while [ "$_ccp_i" -le "${NODE_COUNT:-1}" ]; do
        printf '%s 192.0.2.%s\n' "$_ccp_i" "$_ccp_i"
        _ccp_i=$((_ccp_i + 1))
    done
}
get_node_ssh_user() { printf '%s\n' admin; }
get_node_ssh_port() { printf '%s\n' 22; }
ssh_keys_effectively_installed() { return 0; }
merv_ssh_preflight_node_set() {
    printf 'preflight-start\n' >> "$TEST_TRACE"
    sleep 1
    printf 'preflight-end\n' >> "$TEST_TRACE"
    return 0
}
merv_node_resolve_endpoint() {
    printf 'resolve:%s:%s\n' "$1" "$2" >> "$TEST_TRACE"
    printf '198.51.100.%s\n' "$1"
}
merv_ssh_precheck() {
    printf 'precheck:%s:%s\n' "$1" "$2" >> "$TEST_TRACE"
    return 0
}
merv_ssh_skip_log() { printf 'skip:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TRACE"; }
merv_ssh_exec() {
    _ccp_node="$1"
    _ccp_configured="$2"
    _ccp_command="$3"
    mkdir "$TEST_RUNTIME/active-$_ccp_node" 2>/dev/null || :
    _ccp_wait=0
    while :; do
        _ccp_active=$(find "$TEST_RUNTIME" -maxdepth 1 -name 'active-*' -type d 2>/dev/null | wc -l | tr -d ' ')
        [ "$_ccp_active" -ge "${MERV_NODE_PARALLELISM:-1}" ] 2>/dev/null && break
        [ "$_ccp_wait" -ge 5 ] && break
        sleep 1
        _ccp_wait=$((_ccp_wait + 1))
    done
    printf 'remote-start:%s:%s:%s:%s:%s\n' \
        "$_ccp_node" "$_ccp_configured" "$_ccp_active" \
        "${MERV_NODE_JOB_DIR:-none}" "$_ccp_command" >> "$TEST_TRACE"
    sleep "${COLLECT_DELAY:-2}"
    rm -rf "$TEST_RUNTIME/active-$_ccp_node"
    printf 'remote-end:%s\n' "$_ccp_node" >> "$TEST_TRACE"
    printf '{"router":"%s","vlans":[]}' "$_ccp_configured"
}
EOF

cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_proc_start_time() { merv_identity_proc_start "$1" "${2:-/proc}"; }
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
merv_lock_acquire() { MERV_LOCK_NONCE=client-pool-fixture; return 0; }
merv_lock_release() { return 0; }
merv_lock_state() { printf '%s\n' inactive; }
merv_mac_best_db() { printf '%s\n' "$MERV_MAC_DB_ACTIVE"; }
EOF

cat > "$FAKE_BASE/settings/lib_update_state.sh" <<'EOF'
LIB_UPDATE_STATE_LOADED=1
merv_update_mutation_blocked() { return 1; }
EOF

cat > "$FAKE_BASE/functions/collect_local_clients.sh" <<'EOF'
#!/bin/sh
sleep 2
printf 'main-start:%s\n' "$1" >> "$TEST_TRACE"
printf '%s' '{"router":"Main Router","vlans":[]}' > "$1"
printf 'main-end\n' >> "$TEST_TRACE"
EOF
chmod 700 "$FAKE_BASE/functions/collect_local_clients.sh"
cp "$ROOT/settings/lib_node_jobs.sh" "$FAKE_BASE/settings/lib_node_jobs.sh" || exit 1
cp "$ROOT/settings/lib_identity.sh" "$FAKE_BASE/settings/lib_identity.sh" || exit 1

prepare_runtime() {
    TEST_RUNTIME="$1"
    TEST_TRACE="$TEST_RUNTIME/trace"
    export TEST_RUNTIME TEST_TRACE
    rm -rf "$TEST_RUNTIME"
    mkdir -p "$TEST_RUNTIME/tmp" "$TEST_RUNTIME/results" || return 1
    : > "$TEST_RUNTIME/mac_shield.db"
    : > "$TEST_RUNTIME/mac_shield_override.db"
    : > "$TEST_RUNTIME/client_names.db"
    printf '%s\n' '{"generated":"previous","nodes":[{"router":"previous"}]}' > "$TEST_RUNTIME/results/vlan_clients.json"
}

run_width() {
    _ccp_width="$1"
    prepare_runtime "$TMP_ROOT/width-$_ccp_width" || fail "width $_ccp_width fixture setup"
    NODE_COUNT=6
    MERV_NODE_PARALLELISM="$_ccp_width"
    # Launching six real wrappers can take longer than the two-second remote
    # fixture delay on the highest widths.  Keep the observed first batch
    # alive long enough that width 4/5 assertions measure the pool, not test
    # process-start scheduling.
    if [ "$_ccp_width" -ge 4 ]; then COLLECT_DELAY=5; else COLLECT_DELAY=2; fi
    export NODE_COUNT MERV_NODE_PARALLELISM COLLECT_DELAY
    MERV_BASE="$FAKE_BASE"
    SSH_KEY="$TMP_ROOT/id"
    SSH_PUBKEY="$TMP_ROOT/id.pub"
    export MERV_BASE SSH_KEY SSH_PUBKEY
    : > "$SSH_KEY"; : > "$SSH_PUBKEY"
    _ccp_before=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    sh "$ROOT/functions/collect_clients.sh" > "$TEST_RUNTIME/collector.out" 2>&1 &
    _ccp_pid=$!
    _ccp_seen=0
    _ccp_mid_changed=0
    _ccp_tick=0
    while kill -0 "$_ccp_pid" 2>/dev/null; do
        if [ "$_ccp_seen" -eq 0 ] && grep -q '^remote-start:' "$TEST_TRACE" 2>/dev/null; then
            _ccp_seen=1
            _ccp_now=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
            [ "$_ccp_now" = "$_ccp_before" ] || _ccp_mid_changed=1
        fi
        _ccp_tick=$((_ccp_tick + 1))
        [ "$_ccp_tick" -lt 45 ] || break
        sleep 1
    done
    wait "$_ccp_pid"; _ccp_rc=$?
    [ "$_ccp_rc" -eq 0 ] || {
        tail -n 40 "$TEST_RUNTIME/collector.out" >&2
        fail "real collector width $_ccp_width failed (rc=$_ccp_rc)"
    }
    [ "$_ccp_seen" -eq 1 ] || fail "width $_ccp_width did not observe remote work"
    [ "$_ccp_mid_changed" -eq 0 ] || fail "width $_ccp_width published while remote work was active"
    _ccp_starts=$(grep -c '^remote-start:' "$TEST_TRACE" 2>/dev/null || :)
    _ccp_ends=$(grep -c '^remote-end:' "$TEST_TRACE" 2>/dev/null || :)
    [ "$_ccp_starts" -eq 6 ] || fail "width $_ccp_width started $_ccp_starts of 6 nodes"
    [ "$_ccp_ends" -eq 6 ] || fail "width $_ccp_width ended $_ccp_ends of 6 nodes"
    _ccp_max=$(awk -F: '$1 == "remote-start" && ($4 + 0) > max { max = $4 + 0 } END { print max + 0 }' "$TEST_TRACE")
    [ "$_ccp_max" -eq "$_ccp_width" ] || fail "width $_ccp_width observed max concurrency $_ccp_max"
    _ccp_preflight=$(awk '$1 == "preflight-end" { print NR; exit }' "$TEST_TRACE")
    _ccp_main=$(awk '$1 ~ /^main-start:/ { print NR; exit }' "$TEST_TRACE")
    _ccp_remote=$(awk '$1 ~ /^remote-start:/ { print NR; exit }' "$TEST_TRACE")
    [ "$_ccp_preflight" -gt 0 ] && [ "$_ccp_main" -gt "$_ccp_preflight" ] &&
        [ "$_ccp_remote" -gt "$_ccp_preflight" ] || fail "width $_ccp_width started collection before serial preflight"
    grep -q '^main-start:.*/client_collection/main.json$' "$TEST_TRACE" ||
        fail "width $_ccp_width MAIN did not use its own collection artifact"
    awk -F: '$1 == "remote-start" && $5 ~ /\/node_[1-6]$/ { found = 1 } END { exit(found ? 0 : 1) }' "$TEST_TRACE" ||
        fail "width $_ccp_width remote artifact was not private to a node job"
    _ccp_router_count=$(grep -o '"router"' "$TEST_RUNTIME/results/vlan_clients.json" | wc -l | tr -d ' ')
    [ "$_ccp_router_count" -eq 7 ] || fail "width $_ccp_width published $_ccp_router_count routers instead of MAIN plus 6 nodes"
    [ ! -d "$TEST_RUNTIME/client_collection" ] || fail "width $_ccp_width left collection workspace"
    if find "$TEST_RUNTIME/tmp/node_jobs" -mindepth 1 -maxdepth 1 -print 2>/dev/null | grep -q .; then
        fail "width $_ccp_width left private node-job artifacts"
    fi
    printf 'PASS width=%s max=%s nodes=6 preflight-before-collection parent-merge-clean\n' \
        "$_ccp_width" "$_ccp_max"
}

run_marker_case() {
    _ccp_mode="$1"
    _ccp_base="$TMP_ROOT/marker-$_ccp_mode-addon"
    _ccp_runtime="$TMP_ROOT/marker-$_ccp_mode"
    rm -rf "$_ccp_base"
    mkdir -p "$_ccp_base"
    cp -R "$FAKE_BASE/." "$_ccp_base/" || fail "marker $_ccp_mode fixture copy"
    cat > "$_ccp_base/settings/lib_node_jobs.sh" <<'EOF'
#!/bin/sh
LIB_NODE_JOBS_LOADED=1
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh"
merv_proc_start_time() { printf '1\n'; }
merv_process_identity_matches() { return 1; }
mnj_result_validate() {
    MNJ_RESULT_STATE=
    [ -f "$1" ] || return 1
    grep -q '^format=ok$' "$1" || return 1
    MNJ_RESULT_STATE=ok
    return 0
}
mnj_pool_run() {
    _mnj_root="$1"; _mnj_phase="$2"; _mnj_nodes="$5"; _mnj_handler="$6"
    mkdir -p "$_mnj_root" || return 1
    while IFS=' ' read -r _mnj_node _mnj_ip _mnj_extra || [ -n "$_mnj_node" ]; do
        [ -n "$_mnj_node" ] || continue
        _mnj_dir="$_mnj_root/node_$_mnj_node"
        mkdir -p "$_mnj_dir" || return 1
        MERV_NODE_JOB_DIR="$_mnj_dir"; export MERV_NODE_JOB_DIR
        "$_mnj_handler" "$_mnj_node" "$_mnj_ip" || :
        case "${MARKER_MODE:-missing}" in
            malformed) printf 'not-a-terminal-result\n' > "$_mnj_dir/result" ;;
            valid) printf 'format=ok\n' > "$_mnj_dir/result" ;;
            *) : ;;
        esac
    done < "$_mnj_nodes"
    return 0
}
EOF
    prepare_runtime "$_ccp_runtime" || fail "marker $_ccp_mode runtime setup"
    NODE_COUNT=1; MERV_NODE_PARALLELISM=1; COLLECT_DELAY=0; MARKER_MODE="$_ccp_mode"
    MERV_BASE="$_ccp_base"
    SSH_KEY="$TMP_ROOT/id"; SSH_PUBKEY="$TMP_ROOT/id.pub"
    export NODE_COUNT MERV_NODE_PARALLELISM COLLECT_DELAY MARKER_MODE MERV_BASE SSH_KEY SSH_PUBKEY
    : > "$SSH_KEY"; : > "$SSH_PUBKEY"
    _ccp_before=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    if sh "$ROOT/functions/collect_clients.sh" > "$TEST_RUNTIME/collector.out" 2>&1; then
        _ccp_rc=0
    else
        _ccp_rc=$?
    fi
    [ "$_ccp_rc" -ne 0 ] || fail "marker $_ccp_mode was accepted as a successful collection"
    _ccp_after=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    [ "$_ccp_after" = "$_ccp_before" ] || fail "marker $_ccp_mode replaced previous inventory"
    [ -f "$TEST_RUNTIME/results/client_collection_fault" ] ||
        fail "marker $_ccp_mode did not record result-validation failure"
    assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'phase=result' \
        "marker $_ccp_mode did not record result-validation failure"
    assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'target=node-1' \
        "marker $_ccp_mode did not identify NODE1"
    assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'reason=missing-result' \
        "marker $_ccp_mode did not fail closed as missing/malformed result"
    [ ! -d "$TEST_RUNTIME/client_collection" ] || fail "marker $_ccp_mode left collection workspace"
    if find "$TEST_RUNTIME/tmp/node_jobs" -mindepth 1 -maxdepth 1 -print 2>/dev/null | grep -q .; then
        fail "marker $_ccp_mode left private node-job artifacts"
    fi
    printf 'PASS marker=%s rejected and preserved prior inventory\n' "$_ccp_mode"
}

run_marker_case missing
run_marker_case malformed

# A local phase marker must never mask generic retained node-pool ownership.
# Use the real collector against a deliberately unresolved pool fixture and
# prove it preserves the previous public inventory, pool workspace, and lock.
run_unresolved_pool_case() {
    _ccp_base="$TMP_ROOT/unresolved-addon"
    _ccp_runtime="$TMP_ROOT/unresolved"
    rm -rf "$_ccp_base"
    mkdir -p "$_ccp_base" || fail 'unresolved fixture setup'
    cp -R "$FAKE_BASE/." "$_ccp_base/" || fail 'unresolved fixture copy'
    cat > "$_ccp_base/settings/lib_node_jobs.sh" <<'EOF'
#!/bin/sh
LIB_NODE_JOBS_LOADED=1
mnj_pool_state_unresolved() { return 0; }
mnj_pool_run() {
    MNJ_POOL_ROOT="$1"; MNJ_POOL_PHASE="$2"; MNJ_POOL_ACTIVE=1
    MNJ_POOL_PENDING_PID=999999; MNJ_POOL_PENDING_START=''
    MNJ_POOL_PENDING_DIR="$1/node_1"; MNJ_POOL_PENDING_NODE=1
    mkdir -p "$MNJ_POOL_PENDING_DIR" || return 1
    : > "$MNJ_POOL_PENDING_DIR/retained-marker"
    return 2
}
mnj_pool_abort_active() { return 1; }
EOF
    cat >> "$_ccp_base/settings/lib_mervqt.sh" <<'EOF'
merv_lock_release() { : > "$TEST_RUNTIME/lock-released"; return 0; }
EOF
    prepare_runtime "$_ccp_runtime" || fail 'unresolved runtime setup'
    NODE_COUNT=1; MERV_NODE_PARALLELISM=1; COLLECT_DELAY=0
    MERV_BASE="$_ccp_base"
    SSH_KEY="$TMP_ROOT/id"; SSH_PUBKEY="$TMP_ROOT/id.pub"
    export NODE_COUNT MERV_NODE_PARALLELISM COLLECT_DELAY MERV_BASE SSH_KEY SSH_PUBKEY
    : > "$SSH_KEY"; : > "$SSH_PUBKEY"
    _ccp_before=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    if sh "$ROOT/functions/collect_clients.sh" > "$TEST_RUNTIME/collector.out" 2>&1; then
        fail 'collector accepted an unresolved generic node pool'
    fi
    _ccp_after=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    [ "$_ccp_after" = "$_ccp_before" ] || fail 'unresolved pool replaced previous public inventory'
    [ -d "$TEST_RUNTIME/client_collection" ] || fail 'unresolved pool removed collection workspace'
    [ ! -e "$TEST_RUNTIME/lock-released" ] || fail 'unresolved pool released collection lock'
    [ -f "$TEST_RUNTIME/tmp/node_jobs/client."*/node_1/retained-marker ] ||
        fail 'unresolved pool workspace was not retained'
    printf 'PASS unresolved generic pool preserves collection ownership and inventory\n'
}

run_unresolved_pool_case
for _ccp_width in 1 2 3 4 5; do
    run_width "$_ccp_width"
done
printf 'CLIENT_COLLECTION_POOL_CONTRACT_OK\n'
