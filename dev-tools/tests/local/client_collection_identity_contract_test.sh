#!/bin/sh
# Run the real collection entry script against deterministic library boundaries
# to prove WAN-Native transport does not replace the configured node identity.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-client-identity.$$
FAKE_BASE="$TMP_ROOT/addon"
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" "$TMP_ROOT/runtime"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

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
export TMPDIR LOCKDIR COLLECTDIR RESULTDIR OUT_FINAL FUNCDIR
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
json_validate_file() { grep -q '"router"' "$1"; }
merv_is_valid_node_id() { [ "$1" = 1 ]; }
EOF

cat > "$FAKE_BASE/settings/lib_ssh.sh" <<'EOF'
LIB_SSH_LOADED=1
merv_node_list() { printf '%s\n' '1 192.168.186.201'; }
get_node_ssh_user() { printf '%s\n' admin; }
get_node_ssh_port() { printf '%s\n' 22; }
ssh_keys_effectively_installed() { return 0; }
merv_node_resolve_endpoint() {
  printf 'resolve:%s:%s\n' "$1" "$2" >> "$TEST_TRACE"
  printf '%s\n' 192.168.190.201
}
merv_ssh_precheck() { printf 'precheck:%s:%s\n' "$1" "$2" >> "$TEST_TRACE"; return 0; }
merv_ssh_skip_log() { printf 'skip:%s:%s\n' "$1" "$2" >> "$TEST_TRACE"; }
merv_ssh_preflight_node_set() { return 0; }
merv_ssh_exec() {
  printf 'exec:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TRACE"
  # The shared wrapper receives the configured identity, resolves the selected
  # transport internally, and connects to the WAN-Native endpoint.
  printf 'connect:%s:%s\n' "$1" 192.168.190.201 >> "$TEST_TRACE"
  printf '%s' '{"router":"192.168.186.201","vlans":[]}'
}
EOF

cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_proc_start_time() { merv_identity_proc_start "$1" "${2:-/proc}"; }
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
merv_lock_acquire() { return 0; }
merv_lock_release() { return 0; }
merv_lock_state() { printf '%s\n' inactive; }
EOF

cat > "$FAKE_BASE/settings/lib_update_state.sh" <<'EOF'
LIB_UPDATE_STATE_LOADED=1
merv_update_mutation_blocked() { return 1; }
EOF

cat > "$FAKE_BASE/functions/collect_local_clients.sh" <<'EOF'
#!/bin/sh
printf '%s' '{"router":"Main Router","vlans":[]}' > "$1"
EOF
chmod 700 "$FAKE_BASE/functions/collect_local_clients.sh"

# The production collector now uses the shared bounded node-job pool. Keep the
# fixture isolated while supplying the real pool and identity implementations.
cp "$ROOT/settings/lib_node_jobs.sh" "$FAKE_BASE/settings/lib_node_jobs.sh"
cp "$ROOT/settings/lib_identity.sh" "$FAKE_BASE/settings/lib_identity.sh"

TEST_RUNTIME="$TMP_ROOT/runtime"
TEST_TRACE="$TMP_ROOT/trace"
MERV_BASE="$FAKE_BASE"
SSH_KEY="$TMP_ROOT/id"
SSH_PUBKEY="$TMP_ROOT/id.pub"
export TEST_RUNTIME TEST_TRACE MERV_BASE SSH_KEY SSH_PUBKEY
mkdir -p "$TEST_RUNTIME/tmp"
: > "$SSH_KEY"
: > "$SSH_PUBKEY"

sh "$ROOT/functions/collect_clients.sh" || fail 'real collector failed in deterministic boundary fixture'

assert_contains "$TEST_TRACE" 'resolve:1:192.168.186.201' 'resolver must receive configured ASUS identity'
assert_contains "$TEST_TRACE" 'precheck:1:192.168.190.201' 'precheck must use selected WAN-Native transport'
assert_contains "$TEST_TRACE" 'exec:1:192.168.186.201:' 'SSH wrapper must retain configured identity argument'
assert_contains "$TEST_TRACE" 'connect:1:192.168.190.201' 'collection must connect through the WAN-Native transport'
assert_contains "$TEST_TRACE" "MERV_OBS_CLIENT_ROUTER='192.168.186.201'" 'remote artifact identity must remain configured ASUS address'
assert_contains "$TEST_RUNTIME/results/vlan_clients.json" '"router":"192.168.186.201"' 'published node artifact must retain configured ASUS identity'
if grep -Fq '"router":"192.168.190.201"' "$TEST_RUNTIME/results/vlan_clients.json"; then
  fail 'WAN-Native transport address leaked into published router identity'
fi
if find "$TEST_RUNTIME/tmp/node_jobs" -mindepth 1 -maxdepth 1 -print 2>/dev/null | grep -q .; then
  fail 'successful collection left a private bounded-pool workspace behind'
fi

printf 'PASS client collection identity contract\n'
