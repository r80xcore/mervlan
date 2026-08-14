#!/bin/sh
# Deterministic contract for dual ASUS/WAN-Native node management endpoints.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-node-endpoint.$$
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
SETTINGS_FILE="$TMP_ROOT/settings.json"
export SETTINGS_FILE
MERV_BASE="$ROOT"
export MERV_BASE

cat > "$SETTINGS_FILE" <<'EOF'
{
  "Nodes": {
    "NODE1": "192.168.186.201",
    "NODE1_WAN_NATIVE_IP": "192.168.190.201",
    "NODE2": "192.168.186.202",
    "NODE2_WAN_NATIVE_IP": "192.168.190.202"
  },
  "VLAN": {
    "WAN_Native": {
      "WAN_NATIVE_NODE1": "190",
      "WAN_NATIVE_NODE2": "none"
    }
  }
}
EOF

. "$ROOT/settings/lib_json.sh"
LIB_SSH_TRUST_LOADED=1
. "$ROOT/settings/lib_ssh.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got=$1 expected=$2)"; }

expected='192.168.190.201
192.168.186.201'
assert_eq "$(merv_node_endpoint_candidates 1)" "$expected" 'WAN Native expected-first order'
assert_eq "$(merv_node_endpoint_candidates 2)" '192.168.186.202
192.168.190.202' 'ASUS expected-first order'

merv_ssh_exec_endpoint() {
  case "${TEST_REACHABLE:-}:$2" in
    *:"${TEST_REACHABLE:-}") printf 'connected:%s' "$2"; return 0 ;;
  esac
  MERV_SSH_LAST_REASON=unreachable
  MERV_SSH_LAST_DETAIL="fixture unreachable"
  return 4
}

TEST_REACHABLE=192.168.190.201
assert_eq "$(merv_ssh_exec 1 192.168.186.201 'echo connected')" 'connected:192.168.190.201' 'WAN endpoint selected'
TEST_REACHABLE=192.168.186.201
assert_eq "$(merv_ssh_exec 1 192.168.186.201 'echo connected')" 'connected:192.168.186.201' 'ASUS fallback selected during WAN transition'
TEST_REACHABLE=192.168.190.202
assert_eq "$(merv_ssh_exec 2 192.168.186.202 'echo connected')" 'connected:192.168.190.202' 'WAN fallback selected during ASUS revert transition'

merv_ssh_exec_endpoint() {
  MERV_SSH_LAST_REASON=host-key-mismatch
  MERV_SSH_LAST_DETAIL='fixture host key mismatch'
  return 6
}
if merv_ssh_exec 1 192.168.186.201 'echo connected' >/dev/null 2>&1; then
  fail 'host-key mismatch must fail closed'
fi

# A remote nonzero result is ambiguous: a mutating command may already have
# run, so the resolver must never replay it at the recovery endpoint.
for _remote_rc in 1 2 126 127; do
  TEST_CALLS=''
  merv_ssh_exec_endpoint() {
    TEST_CALLS="${TEST_CALLS}$2,"
    MERV_SSH_LAST_REASON=remote-cmd-failed
    MERV_SSH_LAST_DETAIL="fixture remote rc=${_remote_rc}"
    return 5
  }
  if merv_ssh_exec 1 192.168.186.201 'mutating fixture' >/dev/null 2>&1; then
    fail "remote rc=${_remote_rc} unexpectedly succeeded"
  fi
  assert_eq "$TEST_CALLS" '192.168.190.201,' "remote rc=${_remote_rc} must not fall back"
done

# Only a positive transport classification may advance to the configured ASUS
# recovery endpoint. These fixtures exercise the complete allowlist.
for _transport_reason in unreachable timeout refused no-route; do
  TEST_CALLS=''
  merv_ssh_exec_endpoint() {
    TEST_CALLS="${TEST_CALLS}$2,"
    if [ "$2" = 192.168.190.201 ]; then
      MERV_SSH_LAST_REASON="$_transport_reason"
      MERV_SSH_LAST_DETAIL='fixture pre-session transport failure'
      return 4
    fi
    printf 'connected:%s' "$2"
    return 0
  }
  merv_ssh_exec 1 192.168.186.201 'read-only fixture' > "$TMP_ROOT/transport.out" || fail "$_transport_reason fallback failed"
  assert_eq "$(cat "$TMP_ROOT/transport.out")" 'connected:192.168.186.201' "$_transport_reason fallback result"
  assert_eq "$TEST_CALLS" '192.168.190.201,192.168.186.201,' "$_transport_reason fallback order"
done

sed 's/"NODE1_WAN_NATIVE_IP": "192.168.190.201"/"NODE1_WAN_NATIVE_IP": "none"/' "$SETTINGS_FILE" > "$TMP_ROOT/missing.json"
if merv_node_validate_wan_native_management "$TMP_ROOT/missing.json"; then
  fail 'numeric WAN Native without management endpoint must fail validation'
fi

sed 's/"192.168.190.201"/"300.1.1.1"/' "$SETTINGS_FILE" > "$TMP_ROOT/invalid.json"
if merv_node_endpoint_candidates 1 "$TMP_ROOT/invalid.json" >/dev/null 2>&1; then
  fail 'invalid WAN endpoint must be rejected'
fi

printf 'PASS node endpoint resolver contract\n'
