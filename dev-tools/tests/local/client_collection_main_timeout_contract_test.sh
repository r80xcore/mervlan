#!/bin/sh
# CLIENT-MAIN-TIMEOUT contract: a hung MAIN collector is terminated and
# reaped by its independent deadline before any remote pool work can start.
# The prior public inventory must remain byte-for-byte unchanged.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-client-main-timeout.$$
FAKE_BASE="$TMP_ROOT/addon"
TEST_RUNTIME="$TMP_ROOT/runtime"
TEST_TRACE="$TMP_ROOT/trace"
umask 077
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" "$TEST_RUNTIME" || exit 1
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

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
export TMPDIR LOCKDIR COLLECTDIR RESULTDIR OUT_FINAL FUNCDIR DRY_RUN
export MERV_MAC_DB_ACTIVE MERV_MAC_OVERRIDE_DB
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
merv_is_valid_node_id() { [ "$1" = 1 ]; }
EOF

cat > "$FAKE_BASE/settings/lib_ssh.sh" <<'EOF'
LIB_SSH_LOADED=1
merv_node_list() { printf '%s\n' '1 192.0.2.11'; }
get_node_ssh_user() { printf '%s\n' admin; }
get_node_ssh_port() { printf '%s\n' 22; }
ssh_keys_effectively_installed() { return 0; }
merv_ssh_preflight_node_set() {
  printf 'preflight\n' >> "$TEST_TRACE"
  return 0
}
merv_node_resolve_endpoint() { printf '%s\n' "$2"; }
merv_ssh_precheck() { return 0; }
merv_ssh_skip_log() { :; }
merv_ssh_exec() {
  printf 'remote-start:%s\n' "$1" >> "$TEST_TRACE"
  return 1
}
EOF

cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_proc_start_time() { merv_identity_proc_start "$1" "${2:-/proc}"; }
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
merv_lock_acquire() { MERV_LOCK_NONCE=main-timeout-fixture; return 0; }
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
printf 'main-start:%s\n' "$$" >> "$TEST_TRACE"
printf '%s\n' "$$" > "$TEST_RUNTIME/main.pid"
trap 'printf "main-term\n" >> "$TEST_TRACE"; exit 143' INT TERM
sleep 10
printf 'main-end\n' >> "$TEST_TRACE"
printf '%s' '{"router":"Main Router","vlans":[]}' > "$1"
EOF
chmod 700 "$FAKE_BASE/functions/collect_local_clients.sh" || exit 1

# The production collector uses the shared bounded node-job pool.  This case
# must prove the pool is never entered, but the real identity/pool code keeps
# the fixture aligned with production loading and process ownership.
cp "$ROOT/settings/lib_node_jobs.sh" "$FAKE_BASE/settings/lib_node_jobs.sh" || exit 1
cp "$ROOT/settings/lib_identity.sh" "$FAKE_BASE/settings/lib_identity.sh" || exit 1

export TEST_RUNTIME TEST_TRACE
MERV_BASE="$FAKE_BASE"
SSH_KEY="$TMP_ROOT/id"
SSH_PUBKEY="$TMP_ROOT/id.pub"
COLLECT_MAIN_TIMEOUT=1
COLLECT_WAIT_TIMEOUT=10
export MERV_BASE SSH_KEY SSH_PUBKEY COLLECT_MAIN_TIMEOUT COLLECT_WAIT_TIMEOUT
mkdir -p "$TEST_RUNTIME/tmp" "$TEST_RUNTIME/results" || exit 1
: > "$SSH_KEY"
: > "$SSH_PUBKEY"
: > "$TEST_TRACE"
: > "$TEST_RUNTIME/mac_shield.db"
: > "$TEST_RUNTIME/mac_shield_override.db"
printf '%s\n' '{"generated":"previous","nodes":[{"router":"previous"}]}' > "$TEST_RUNTIME/results/vlan_clients.json"
PREVIOUS_HASH=$(cksum "$TEST_RUNTIME/results/vlan_clients.json" | awk '{print $1 ":" $2}')

START_EPOCH=$(date +%s)
if sh "$ROOT/functions/collect_clients.sh" > "$TMP_ROOT/collector.out" 2>&1; then
  COLLECT_RC=0
else
  COLLECT_RC=$?
fi
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))

[ "$COLLECT_RC" -ne 0 ] || fail 'hung MAIN collection unexpectedly published success'
[ "$ELAPSED" -le 5 ] || fail "MAIN timeout exceeded bounded allowance (${ELAPSED}s)"

RESULT_FILE="$TEST_RUNTIME/results/vlan_clients.json"
CURRENT_HASH=$(cksum "$RESULT_FILE" | awk '{print $1 ":" $2}')
[ "$CURRENT_HASH" = "$PREVIOUS_HASH" ] || fail 'MAIN timeout replaced the previous public inventory'
assert_contains "$TEST_TRACE" 'main-start:' 'MAIN fixture did not start'
if grep -Fq 'remote-start:' "$TEST_TRACE"; then
  fail 'remote pool started after synchronous MAIN timeout'
fi
if [ -s "$TEST_RUNTIME/main.pid" ]; then
  _main_pid=$(cat "$TEST_RUNTIME/main.pid")
  case "$_main_pid" in ''|*[!0-9]*) fail 'MAIN fixture wrote malformed PID' ;; esac
  if kill -0 "$_main_pid" 2>/dev/null; then
    fail 'MAIN collector process was not reaped after timeout'
  fi
fi
[ -f "$TEST_RUNTIME/results/client_collection_fault" ] ||
  fail 'MAIN timeout did not record a bounded fault'
assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'phase=main' \
  'MAIN timeout fault did not identify the main phase'
assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'target=main' \
  'MAIN timeout fault did not identify MAIN'
assert_contains "$TEST_RUNTIME/results/client_collection_fault" 'reason=timeout' \
  'MAIN timeout fault did not identify timeout'
[ ! -d "$TEST_RUNTIME/client_collection" ] ||
  fail 'MAIN timeout left the collection workspace behind'

printf 'PASS MAIN timeout=%ss elapsed=%ss reaped-before-remote prior-inventory-preserved\n' \
  "$COLLECT_MAIN_TIMEOUT" "$ELAPSED"
printf 'CLIENT_COLLECTION_MAIN_TIMEOUT_CONTRACT_OK\n'
