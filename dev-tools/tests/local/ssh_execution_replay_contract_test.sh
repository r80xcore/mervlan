#!/bin/sh
# Deterministic execution-layer contract: real merv_ssh_exec_endpoint calls
# must never replay a potentially mutating remote command by default.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-ssh-exec.$$
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

SETTINGS_FILE="$TMP_ROOT/settings.json"
MERV_BASE="$ROOT"
export SETTINGS_FILE MERV_BASE
cat > "$SETTINGS_FILE" <<'EOF'
{
  "Nodes": {
    "NODE1": "192.168.186.201",
    "NODE1_WAN_NATIVE_IP": "192.168.190.201"
  },
  "VLAN": {
    "WAN_Native": {
      "WAN_NATIVE_NODE1": "190"
    }
  }
}
EOF

. "$ROOT/settings/lib_json.sh"
LIB_SSH_TRUST_LOADED=1
. "$ROOT/settings/lib_ssh.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; [ ! -f "$TMP_ROOT/args" ] || sed 's/^/argv: /' "$TMP_ROOT/args" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got=$1 expected=$2)"; }
call_count() { wc -l < "$TMP_ROOT/calls" | tr -d '[:space:]'; }
call_hosts() { tr '\n' ',' < "$TMP_ROOT/calls"; }

SSH_KEY="$TMP_ROOT/test.key"
: > "$SSH_KEY"
export SSH_KEY
MERV_SSH_RETRIES=3
MERV_SSH_RETRY_DELAY=0
MERV_SSH_TIMEOUT=1
MERV_SSH_TMP_ROOT="$TMP_ROOT"
export MERV_SSH_RETRIES MERV_SSH_RETRY_DELAY MERV_SSH_TIMEOUT MERV_SSH_TMP_ROOT

# Exercise the production endpoint execution function while replacing only its
# external network/trust dependencies with deterministic local equivalents.
merv_ssh_precheck() { return 0; }
merv_ssh_precheck_cache_matches() { return 1; }
merv_ssh_node_mac() { printf '%s\n' 'aa:bb:cc:dd:ee:ff'; }
get_node_ssh_port() { printf '%s\n' 22; }
get_node_ssh_user() { printf '%s\n' admin; }
merv_ssh_prepare_known_host() { return 0; }
merv_ssh_release_known_host() { return 0; }
_merv_ssh_tmp_root() { return 0; }
_merv_ssh_tmp_acquire() { MERV_SSH_ERR_FILE="$TMP_ROOT/stderr.$$.${MERV_SSH_TMP_SEQ:-0}"; : > "$MERV_SSH_ERR_FILE"; }
_merv_ssh_tmp_release() { rm -f "$MERV_SSH_ERR_FILE"; }

FAKE_CLIENT="$TMP_ROOT/fake-dbclient"
cat > "$FAKE_CLIENT" <<'EOF'
#!/bin/sh
host=""
for arg in "$@"; do
  case "$arg" in *@*) host="$arg" ;; esac
done
printf '%s\n' "$@" >> "$MERV_TEST_ARGS"
printf '%s\n' "$host" >> "$MERV_TEST_CALLS"
case "${MERV_TEST_MODE:-}:$host" in
  remote-*:admin@192.168.190.201) exit "${MERV_TEST_REMOTE_RC:-1}" ;;
  session-timeout:admin@192.168.190.201) exit 124 ;;
  refused:admin@192.168.190.201) printf '%s\n' 'Connection refused' >&2; exit 1 ;;
  connect-timeout:admin@192.168.190.201) printf '%s\n' 'Connection timed out' >&2; exit 1 ;;
  no-route:admin@192.168.190.201) printf '%s\n' 'No route to host' >&2; exit 1 ;;
  host-key:admin@192.168.190.201) printf '%s\n' 'Host key mismatch' >&2; exit 1 ;;
esac
printf '%s' ok
EOF
chmod 700 "$FAKE_CLIENT"
MERV_SSH_CLIENT="$FAKE_CLIENT"
export MERV_SSH_CLIENT

reset_case() {
  : > "$TMP_ROOT/calls"
  MERV_TEST_CALLS="$TMP_ROOT/calls"
  MERV_TEST_ARGS="$TMP_ROOT/args"
  MERV_SSH_EXEC_RETRY_SAFE=0
  export MERV_TEST_CALLS MERV_TEST_ARGS MERV_SSH_EXEC_RETRY_SAFE
}

for remote_rc in 1 2 126 127; do
  reset_case
  MERV_TEST_MODE=remote-rc
  MERV_TEST_REMOTE_RC="$remote_rc"
  export MERV_TEST_MODE MERV_TEST_REMOTE_RC
  if merv_ssh_exec 1 192.168.186.201 'mutating fixture' >/dev/null 2>&1; then
    fail "remote rc=$remote_rc unexpectedly succeeded"
  fi
  assert_eq "$(call_count)" 1 "remote rc=$remote_rc executes exactly once"
  assert_eq "$(call_hosts)" 'admin@192.168.190.201,' "remote rc=$remote_rc has no fallback"
done

reset_case
MERV_TEST_MODE=session-timeout
export MERV_TEST_MODE
if merv_ssh_exec 1 192.168.186.201 'mutating timeout fixture' >/dev/null 2>&1; then
  fail 'session timeout unexpectedly succeeded'
fi
assert_eq "$MERV_SSH_LAST_REASON" session-timeout 'session timeout is classified as ambiguous'
assert_eq "$(call_hosts)" 'admin@192.168.190.201,' 'session timeout has no replay or fallback'

for transport_mode in refused connect-timeout no-route; do
  reset_case
  MERV_TEST_MODE="$transport_mode"
  export MERV_TEST_MODE
  merv_ssh_exec 1 192.168.186.201 'transport fixture' > "$TMP_ROOT/out" || fail "$transport_mode did not fall back"
  assert_eq "$(cat "$TMP_ROOT/out")" ok "$transport_mode fallback output"
  assert_eq "$(call_hosts)" 'admin@192.168.190.201,admin@192.168.186.201,' "$transport_mode fallback order"
done

reset_case
MERV_TEST_MODE=host-key
export MERV_TEST_MODE
if merv_ssh_exec 1 192.168.186.201 'trust fixture' >/dev/null 2>&1; then
  fail 'host-key mismatch unexpectedly succeeded'
fi
assert_eq "$MERV_SSH_LAST_REASON" host-key-mismatch 'host-key mismatch is fail-closed'
assert_eq "$(call_hosts)" 'admin@192.168.190.201,' 'host-key mismatch has no fallback'

reset_case
MERV_TEST_MODE=refused
MERV_SSH_EXEC_RETRY_SAFE=1
export MERV_TEST_MODE MERV_SSH_EXEC_RETRY_SAFE
merv_ssh_exec 1 192.168.186.201 'explicitly idempotent fixture' > "$TMP_ROOT/out" || fail 'explicit safe retry did not recover through fallback'
assert_eq "$(call_hosts)" 'admin@192.168.190.201,admin@192.168.190.201,admin@192.168.190.201,admin@192.168.186.201,' 'safe retry is explicit and limited to transport failure'

printf 'PASS ssh execution replay contract\n'
