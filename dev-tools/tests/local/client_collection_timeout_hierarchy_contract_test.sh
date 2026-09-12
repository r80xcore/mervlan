#!/bin/sh
# Client Collection timeout hierarchy contract.  The source assertions protect
# the exact production defaults; the isolated fixture exercises the real
# collector without contacting a router or waiting for production deadlines.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
SOURCE="$ROOT/functions/collect_clients.sh"
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-client-timeout-hierarchy.$$
FAKE_BASE="$TMP_ROOT/addon"
umask 077
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" || exit 1
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

extract_integer_assignment() {
    _cth_key="$1"
    awk -v key="$_cth_key" '
        $0 ~ "^[[:space:]]*" key "=" {
            count++
            value=$0
            sub("^[[:space:]]*" key "=", "", value)
            sub("[[:space:]]*$", "", value)
            if (value !~ "^[0-9][0-9]*$") invalid=1
            else if (count == 1) result=value
        }
        END {
            if (count != 1 || invalid || result == "") exit 1
            print result
        }
    ' "$SOURCE"
}

extract_default_assignment() {
    _cth_key="$1"
    _cth_env="$2"
    awk -v key="$_cth_key" -v env="$_cth_env" '
        BEGIN { prefix="\"${" env ":-" }
        $0 ~ "^[[:space:]]*" key "=" {
            count++
            value=$0
            sub("^[[:space:]]*" key "=", "", value)
            sub("[[:space:]]*$", "", value)
            if (substr(value, 1, length(prefix)) != prefix ||
                substr(value, length(value) - 1, 2) != "}\"") {
                invalid=1
                next
            }
            result_value=substr(value, length(prefix) + 1,
                                length(value) - length(prefix) - 2)
            if (result_value !~ /^[0-9][0-9]*$/) invalid=1
            else if (count == 1) result=result_value
        }
        END {
            if (count != 1 || invalid || result == "") exit 1
            print result
        }
    ' "$SOURCE"
}

extract_remote_run_wait() {
    awk '
        /^[[:space:]]*remote_cmd=.*run-wait/ {
            _occ_line=$0
            _occurrences=gsub(/run-wait/, "&", _occ_line)
            count += _occurrences
            if (_occurrences != 1) invalid=1
            _token=$0
            sub(/^.*run-wait[[:space:]]+/, "", _token)
            split(_token, _parts, /[[:space:]]+/)
            _token=_parts[1]
            if (_token !~ /^[0-9][0-9]*$/) invalid=1
            else if (count == 1) result=_token
        }
        END {
            if (count != 1 || invalid || result == "") exit 1
            print result
        }
    ' "$SOURCE"
}

REMOTE_WAIT=$(extract_remote_run_wait) || fail 'remote run-wait source contract is missing, malformed, or ambiguous'
SSH_TIMEOUT=$(extract_integer_assignment NODE_RESULT_SSH_TIMEOUT) ||
    fail 'NODE_RESULT_SSH_TIMEOUT source contract is missing, malformed, or ambiguous'
POOL_TIMEOUT=$(extract_default_assignment WAIT_TIMEOUT COLLECT_WAIT_TIMEOUT) ||
    fail 'COLLECT_WAIT_TIMEOUT default source contract is missing, malformed, or ambiguous'
MAIN_TIMEOUT=$(extract_default_assignment MAIN_TIMEOUT COLLECT_MAIN_TIMEOUT) ||
    fail 'MAIN_TIMEOUT source contract is missing, malformed, or ambiguous'
[ "$REMOTE_WAIT" -eq 120 ] || fail "remote run-wait default is $REMOTE_WAIT, expected 120"
[ "$SSH_TIMEOUT" -eq 150 ] || fail "collection SSH default is $SSH_TIMEOUT, expected 150"
[ "$POOL_TIMEOUT" -eq 180 ] || fail "node worker default is $POOL_TIMEOUT, expected 180"
[ "$MAIN_TIMEOUT" -eq 90 ] || fail "MAIN timeout default is $MAIN_TIMEOUT, expected 90"
[ "$REMOTE_WAIT" -lt "$SSH_TIMEOUT" ] || fail 'remote wait is not below collection SSH timeout'
[ "$SSH_TIMEOUT" -lt "$POOL_TIMEOUT" ] || fail 'collection SSH timeout is not below node worker timeout'
printf 'PASS source hierarchy run-wait=%s ssh=%s worker=%s main=%s with 120<150<180\n' \
    "$REMOTE_WAIT" "$SSH_TIMEOUT" "$POOL_TIMEOUT" "$MAIN_TIMEOUT"

cat > "$FAKE_BASE/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
TMPDIR="$TEST_RUNTIME/tmp"
LOCKDIR="$TEST_RUNTIME/locks"
SETTINGS_FILE="$TEST_RUNTIME/settings.json"
COLLECTDIR="$TEST_RUNTIME/client_collection"
RESULTDIR="$TEST_RUNTIME/results"
OUT_FINAL="$RESULTDIR/vlan_clients.json"
FUNCDIR="$MERV_BASE/functions"
DRY_RUN=no
MERV_MAC_DB_ACTIVE="$TEST_RUNTIME/mac_shield.db"
MERV_MAC_OVERRIDE_DB="$TEST_RUNTIME/mac_shield_override.db"
MERV_CLIENT_NAME_DB="$TEST_RUNTIME/client_names.db"
export TMPDIR LOCKDIR SETTINGS_FILE COLLECTDIR RESULTDIR OUT_FINAL FUNCDIR DRY_RUN
export MERV_MAC_DB_ACTIVE MERV_MAC_OVERRIDE_DB MERV_CLIENT_NAME_DB
EOF

cat > "$FAKE_BASE/settings/log_settings.sh" <<'EOF'
LOG_SETTINGS_LOADED=1
LOG_chan_cli="$TEST_RUNTIME/cli.log"
LOG_chan_vlan="$TEST_RUNTIME/vlan.log"
export LOG_chan_cli LOG_chan_vlan
info() { :; }
warn() { :; }
error() { :; }
EOF

cat > "$FAKE_BASE/settings/lib_json.sh" <<'EOF'
LIB_JSON_LOADED=1
json_validate_file() { grep -q '"router"[[:space:]]*:' "$1"; }
json_get_flag() { :; }
merv_is_valid_node_id() { [ "$1" = 1 ]; }
EOF

cat > "$FAKE_BASE/settings/lib_ssh.sh" <<'EOF'
LIB_SSH_LOADED=1
merv_node_list() { printf '%s\n' '1 192.0.2.11'; }
get_node_ssh_user() { printf '%s\n' admin; }
get_node_ssh_port() { printf '%s\n' 22; }
ssh_keys_effectively_installed() { return 0; }
merv_ssh_preflight_node_set() { return 0; }
merv_node_resolve_endpoint() { printf '%s\n' "$2"; }
merv_ssh_precheck() { return 0; }
merv_ssh_skip_log() { :; }
merv_ssh_exec() {
    _cth_node="$1"
    _cth_configured="$2"
    _cth_command="$3"
    printf 'ssh-exec node=%s timeout=%s mode=%s command=%s\n' \
        "$_cth_node" "${MERV_SSH_TIMEOUT:-unset}" "${FAKE_NODE_MODE:-unset}" "$_cth_command" >> "$TEST_TRACE"
    case "${FAKE_NODE_MODE:-}" in
        delayed)
            # Symbolically represent a delay beyond the old 45s transport
            # budget, scaled to one second so the regression stays fast.
            printf 'node-busy symbolic-duration=46s scaled-duration=1s\n' >> "$TEST_TRACE"
            sleep 1
            printf '%s' '{"router":"NODE-delayed","vlans":[]}'
            ;;
        fast)
            printf 'node-fast immediate\n' >> "$TEST_TRACE"
            printf '%s' '{"router":"NODE-fast","vlans":[]}'
            ;;
        failure)
            printf 'node-failure genuine-collector-error\n' >> "$TEST_TRACE"
            MERV_SSH_LAST_REASON=remote-command-failed
            return 7
            ;;
        *)
            MERV_SSH_LAST_REASON=fixture-mode-invalid
            return 9
            ;;
    esac
}
EOF

cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_proc_start_time() { merv_identity_proc_start "$1" "${2:-/proc}"; }
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
merv_lock_state() { printf '%s\n' inactive; }
merv_lock_acquire() { MERV_LOCK_NONCE=timeout-hierarchy-fixture; return 0; }
merv_lock_release() { return 0; }
merv_mac_best_db() { printf '%s\n' "$MERV_MAC_DB_ACTIVE"; }
EOF

cat > "$FAKE_BASE/settings/lib_update_state.sh" <<'EOF'
LIB_UPDATE_STATE_LOADED=1
merv_update_mutation_blocked() { return 1; }
EOF

cat > "$FAKE_BASE/functions/collect_local_clients.sh" <<'EOF'
#!/bin/sh
printf '%s' '{"router":"MAIN","vlans":[]}' > "$1"
EOF
chmod 700 "$FAKE_BASE/functions/collect_local_clients.sh" || exit 1
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
    printf '%s\n' '{"generated":"previous","nodes":[{"router":"previous"}]}' > \
        "$TEST_RUNTIME/results/vlan_clients.json"
}

run_collection() {
    _cth_mode="$1"
    _cth_runtime="$TMP_ROOT/runtime-$_cth_mode"
    prepare_runtime "$_cth_runtime" || fail "$_cth_mode fixture setup failed"
    FAKE_NODE_MODE="$_cth_mode"
    MERV_BASE="$FAKE_BASE"
    SSH_KEY="$TMP_ROOT/id"
    SSH_PUBKEY="$TMP_ROOT/id.pub"
    MERV_NODE_PARALLELISM=1
    unset COLLECT_WAIT_TIMEOUT COLLECT_MAIN_TIMEOUT
    export FAKE_NODE_MODE MERV_BASE SSH_KEY SSH_PUBKEY MERV_NODE_PARALLELISM
    : > "$SSH_KEY"
    : > "$SSH_PUBKEY"
    COLLECTION_PREVIOUS_HASH=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
    if [ "$_cth_mode" = delayed ]; then
        sh "$ROOT/functions/collect_clients.sh" > "$TEST_RUNTIME/collector.out" 2>&1 &
        COLLECTION_PID=$!
        _cth_seen=0
        _cth_tick=0
        while [ "$_cth_tick" -lt 10 ]; do
            if grep -Fq 'symbolic-duration=46s scaled-duration=1s' "$TEST_TRACE" 2>/dev/null; then
                _cth_seen=1
                break
            fi
            sleep 1
            _cth_tick=$((_cth_tick + 1))
        done
        if [ "$_cth_seen" -ne 1 ]; then
            kill -TERM "$COLLECTION_PID" 2>/dev/null || :
            wait "$COLLECTION_PID" 2>/dev/null || :
            fail 'delayed NODE fixture did not reach its busy interval'
        fi
        _cth_mid_hash=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
        [ "$_cth_mid_hash" = "$COLLECTION_PREVIOUS_HASH" ] || {
            kill -TERM "$COLLECTION_PID" 2>/dev/null || :
            wait "$COLLECTION_PID" 2>/dev/null || :
            fail 'delayed NODE replaced public inventory before generation completed'
        }
        wait "$COLLECTION_PID"
        COLLECTION_RC=$?
    else
        if sh "$ROOT/functions/collect_clients.sh" > "$TEST_RUNTIME/collector.out" 2>&1; then
            COLLECTION_RC=0
        else
            COLLECTION_RC=$?
        fi
    fi
}

run_collection delayed
[ "$COLLECTION_RC" -eq 0 ] || {
    tail -n 40 "$TEST_RUNTIME/collector.out" >&2
    fail 'delayed NODE did not eventually complete collection'
}
assert_contains "$TEST_TRACE" 'timeout=150 mode=delayed' \
    'delayed NODE did not receive the 150s SSH timeout'
assert_contains "$TEST_TRACE" 'post_apply_worker.sh' \
    'delayed NODE did not receive the observation worker command'
assert_contains "$TEST_TRACE" 'run-wait 120' \
    'delayed NODE did not receive run-wait 120'
assert_contains "$TEST_TRACE" 'symbolic-duration=46s scaled-duration=1s' \
    'delayed NODE fixture did not exercise the scaled busy interval'
assert_contains "$TEST_RUNTIME/results/vlan_clients.json" '"router":"NODE-delayed"' \
    'successful delayed NODE result was not included'
_cth_delayed_hash=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
[ "$_cth_delayed_hash" != "$COLLECTION_PREVIOUS_HASH" ] || \
    fail 'delayed NODE published without replacing the previous inventory'
printf 'PASS delayed NODE eventually succeeds and publishes the complete result\n'

run_collection fast
[ "$COLLECTION_RC" -eq 0 ] || {
    tail -n 40 "$TEST_RUNTIME/collector.out" >&2
    fail 'fast NODE did not complete immediately'
}
assert_contains "$TEST_TRACE" 'node-fast immediate' \
    'fast NODE fixture did not take its immediate-success path'
assert_contains "$TEST_RUNTIME/results/vlan_clients.json" '"router":"NODE-fast"' \
    'successful fast NODE result was not included'
_cth_fast_hash=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
[ "$_cth_fast_hash" != "$COLLECTION_PREVIOUS_HASH" ] || \
    fail 'fast NODE did not publish the complete successful inventory'
printf 'PASS fast NODE still succeeds immediately\n'

run_collection failure
[ "$COLLECTION_RC" -ne 0 ] || fail 'genuine NODE collector failure became success'
_cth_failure_hash=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')
[ "$_cth_failure_hash" = "$COLLECTION_PREVIOUS_HASH" ] || \
    fail 'genuine NODE failure replaced the previous public inventory'
assert_contains "$TEST_TRACE" 'node-failure genuine-collector-error' \
    'genuine NODE collector failure fixture did not run'
_cth_failure_calls=$(grep -c '^ssh-exec ' "$TEST_TRACE" 2>/dev/null || :)
[ "$_cth_failure_calls" -eq 1 ] || fail "genuine NODE failure was retried ($_cth_failure_calls calls)"
assert_contains "$TEST_RUNTIME/results/vlan_clients.json" '"router":"previous"' \
    'failed NODE generation replaced the previous public inventory'
printf 'PASS genuine NODE collector failure remains a failure and preserves old inventory\n'

printf 'CLIENT_COLLECTION_TIMEOUT_HIERARCHY_CONTRACT_OK\n'
