#!/bin/sh
# CLIENT-NODE-02 contract: a NODE1 session timeout (SSH rc=5) is a failed
# collection generation.  Its private error artifact is diagnostic only; the
# previous public inventory must remain byte-for-byte unchanged.
# The real collect_clients.sh is executed against isolated fixture libraries;
# no SSH, router, or runtime state is contacted.

set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-client-node-02.$$
FAKE_BASE="$TMP_ROOT/addon"
TEST_RUNTIME="$TMP_ROOT/runtime"
TEST_TRACE="$TMP_ROOT/trace"
umask 077
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" "$TEST_RUNTIME" || exit 1
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$3"
}

cat > "$FAKE_BASE/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
TMPDIR="$TEST_RUNTIME/tmp"
LOCKDIR="$TEST_RUNTIME/locks"
COLLECTDIR="$TEST_RUNTIME/client_collection"
RESULTDIR="$TEST_RUNTIME/results"
OUT_FINAL="$RESULTDIR/vlan_clients.json"
FUNCDIR="$MERV_BASE/functions"
MERV_MAC_DB_ACTIVE="$TEST_RUNTIME/mac_shield.db"
MERV_MAC_OVERRIDE_DB="$TEST_RUNTIME/mac_shield_override.db"
export TMPDIR LOCKDIR COLLECTDIR RESULTDIR OUT_FINAL FUNCDIR
export MERV_MAC_DB_ACTIVE MERV_MAC_OVERRIDE_DB
merv_proc_start_time() { printf '%s\n' 1; }
merv_process_identity_matches() { return 1; }
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
EOF

cat > "$FAKE_BASE/settings/lib_ssh.sh" <<'EOF'
LIB_SSH_LOADED=1
merv_node_list() { printf '%s\n' '1 192.0.2.11'; }
get_node_ssh_user() { printf '%s\n' admin; }
get_node_ssh_port() { printf '%s\n' 22; }
ssh_keys_effectively_installed() { return 0; }
merv_node_resolve_endpoint() {
  printf 'resolve node=%s configured=%s\n' "$1" "$2" >> "$TEST_TRACE"
  printf '%s\n' "$2"
}
merv_ssh_precheck() {
  printf 'precheck node=%s transport=%s\n' "$1" "$2" >> "$TEST_TRACE"
  return 0
}
merv_ssh_skip_log() {
  printf 'skip node=%s configured=%s phase=%s\n' "$1" "$2" "$3" >> "$TEST_TRACE"
}
merv_ssh_preflight_node_set() {
  printf 'preflight ok\n' >> "$TEST_TRACE"
  return 0
}
merv_ssh_exec() {
  printf 'ssh_exec node=%s configured=%s timeout=%s rc=5\n' "$1" "$2" "${MERV_SSH_TIMEOUT:-unset}" >> "$TEST_TRACE"
  MERV_SSH_LAST_REASON=session-timeout
  MERV_SSH_LAST_DETAIL='NODE1 fixture session timeout'
  return 5
}
EOF

cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_lock_state() { printf '%s\n' inactive; }
merv_lock_acquire() { MERV_LOCK_NONCE=node02-fixture; return 0; }
merv_lock_release() { return 0; }
merv_mac_best_db() { printf '%s\n' "$MERV_MAC_DB_ACTIVE"; }
EOF

cat > "$FAKE_BASE/settings/lib_update_state.sh" <<'EOF'
LIB_UPDATE_STATE_LOADED=1
merv_update_mutation_blocked() { return 1; }
EOF

cat > "$FAKE_BASE/functions/collect_local_clients.sh" <<'EOF'
#!/bin/sh
printf '%s' '{"router":"Main Router","vlans":[]}' > "$1"
EOF
chmod 700 "$FAKE_BASE/functions/collect_local_clients.sh" || exit 1

export TEST_RUNTIME TEST_TRACE
MERV_BASE="$FAKE_BASE"
SSH_KEY="$TMP_ROOT/id"
SSH_PUBKEY="$TMP_ROOT/id.pub"
export MERV_BASE SSH_KEY SSH_PUBKEY
mkdir -p "$TEST_RUNTIME/tmp" || exit 1
: > "$SSH_KEY"
: > "$SSH_PUBKEY"
: > "$TEST_RUNTIME/mac_shield.db"
: > "$TEST_RUNTIME/mac_shield_override.db"
: > "$TEST_TRACE"
mkdir -p "$TEST_RUNTIME/results" || exit 1
printf '%s\n' '{"generated":"previous","nodes":[{"router":"previous"}]}' > "$TEST_RUNTIME/results/vlan_clients.json"
PREVIOUS_HASH=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')

if sh "$ROOT/functions/collect_clients.sh" > "$TMP_ROOT/collector.out" 2>&1; then
    COLLECT_RC=0
else
    COLLECT_RC=$?
fi
[ "$COLLECT_RC" -ne 0 ] || fail 'parent collection published success after NODE1 session timeout'

RESULT_FILE="$TEST_RUNTIME/results/vlan_clients.json"
[ -s "$RESULT_FILE" ] || fail 'previous public inventory disappeared after failure'
CURRENT_HASH=$(cksum "$RESULT_FILE" | awk '{print $1 ":" $2}')
[ "$CURRENT_HASH" = "$PREVIOUS_HASH" ] || fail 'failed generation replaced the previous public inventory'
assert_contains "$TEST_TRACE" 'ssh_exec node=1 configured=192.0.2.11 timeout=45 rc=5' \
    'NODE1 fixture did not produce SSH rc=5'
assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'phase=worker' \
    'failure diagnostic did not record the worker phase'
assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'reason=worker-nonzero' \
    'failure diagnostic did not record the worker failure reason'
[ ! -d "$TEST_RUNTIME/client_collection" ] || fail 'collector left temporary collection state behind'

printf 'FIXTURE: NODE1 session-timeout classified by merv_ssh_exec as rc=5\n'
printf 'RESULT: parent collect_clients.sh rc=%s and preserved the prior aggregate\n' "$COLLECT_RC"
printf 'ARTIFACT: NODE1 error=session-timeout remained private; bounded fault recorded\n'
printf 'CLIENT_NODE_02_TIMEOUT_CONTRACT_OK\n'
