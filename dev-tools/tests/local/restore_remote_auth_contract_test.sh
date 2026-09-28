#!/bin/sh
# Contract for the normal Restore candidate remote-auth gate.  The fake SSH
# probe is injected at the library boundary; the production helper still
# owns the private trust context, direct diagnostic-preserving call shape, and
# fail-closed node loop.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-restore-remote-auth.$$"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15
mkdir -p "$TEST_ROOT/work" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

MERV_BASE="$ROOT"
SETTINGS_FILE="$TEST_ROOT/settings.json"
TRUST_FILE="$TEST_ROOT/known_hosts.v1"
KEY_FILE="$TEST_ROOT/vlan_manager"
PUB_FILE="$TEST_ROOT/vlan_manager.pub"
printf '%s\n' '{}' > "$SETTINGS_FILE" || fail settings
printf '%s\n' 'trust-fixture' > "$TRUST_FILE" || fail trust
printf '%s\n' 'private-fixture' > "$KEY_FILE" || fail private-key
printf '%s\n' 'public-fixture' > "$PUB_FILE" || fail public-key
export MERV_BASE SETTINGS_FILE

. "$ROOT/settings/lib_json.sh" || fail json-library
LIB_SSH_TRUST_LOADED=1
. "$ROOT/settings/lib_ssh.sh" || fail ssh-library
. "$ROOT/settings/lib_backup_state.sh" || fail backup-state-library
info() { :; }

# The helper must use the canonical list reader and the production SSH probe
# boundary, but the test must not require a live node or a valid host key.
merv_node_list() {
    printf '%s\n' '1 192.168.186.201' '2 192.168.186.202'
}
merv_ssh_trust_validate_db() { return 0; }

# Exercise the real candidate-context wrapper before replacing only its network
# boundary below.  A stale endpoint from an earlier candidate must not leak
# into the next probe's result, and the caller's endpoint/context variables
# must be restored after the bounded probe returns.
merv_ssh_test() {
    MERV_NODE_ENDPOINT_SELECTED=198.51.100.77
    MERV_NODE_ENDPOINT_EXPECTED=198.51.100.77
    MERV_NODE_ENDPOINT_FALLBACK=0
    MERV_SSH_KEY_TYPE=ssh-ed25519
    MERV_SSH_KEY_MODE=-rw-------
    MERV_SSH_KEY_UID=0
    MERV_SSH_KEY_SIZE=128
    MERV_SSH_KEY_FINGERPRINT=SHA256:candidate
    SSH_TRUST_FINGERPRINT=SHA256:trust
    MERV_SSH_FORENSIC_LAST_FILE=/tmp/candidate-forensic.log
    MERV_SSH_LAST_REASON=
    MERV_SSH_LAST_DETAIL=
    return 0
}
MERV_NODE_ENDPOINT_SELECTED=198.51.100.99
MERV_NODE_ENDPOINT_EXPECTED=198.51.100.99
MERV_NODE_ENDPOINT_FALLBACK=1
MERV_SSH_DIAGNOSTIC_CONTEXT=caller-context
MERV_SSH_DIAGNOSTIC_CAPTURE=caller-capture
if merv_ssh_test_context "$SETTINGS_FILE" "$KEY_FILE" "$PUB_FILE" 1 192.168.186.201 "$TEST_ROOT/work/ssh_forensics"; then
    :
else
    fail candidate-context-wrapper
fi
[ "$MERV_SSH_CANDIDATE_AUTH_ENDPOINT" = 198.51.100.77 ] || fail candidate-context-selected-endpoint
[ "$MERV_SSH_CANDIDATE_AUTH_FORENSIC" = /tmp/candidate-forensic.log ] || fail candidate-context-forensic
[ "$MERV_NODE_ENDPOINT_SELECTED" = 198.51.100.99 ] || fail candidate-context-restored-selected-endpoint
[ "$MERV_NODE_ENDPOINT_EXPECTED" = 198.51.100.99 ] || fail candidate-context-restored-expected-endpoint
[ "$MERV_NODE_ENDPOINT_FALLBACK" = 1 ] || fail candidate-context-restored-fallback
[ "$MERV_SSH_DIAGNOSTIC_CONTEXT" = caller-context ] || fail candidate-context-restored-diagnostic-context
[ "$MERV_SSH_DIAGNOSTIC_CAPTURE" = caller-capture ] || fail candidate-context-restored-diagnostic-capture
pass candidate-context-restores-caller-state

CALLS="$TEST_ROOT/calls"
: > "$CALLS"
merv_ssh_test_context() {
    _test_settings="$1"; _test_key="$2"; _test_pub="$3"; _test_node="$4"; _test_endpoint="$5"; _test_diag="$6"
    printf '%s|%s|%s|%s\n' "$_test_node" "$_test_endpoint" "$_test_key" "$_test_diag" >> "$CALLS"
    MERV_SSH_CANDIDATE_AUTH_ENDPOINT="$_test_endpoint"
    return "${TEST_AUTH_RC:-0}"
}

TEST_AUTH_RC=0
export TEST_AUTH_RC
merv_backup_state_remote_auth_preflight \
    "$SETTINGS_FILE" "$TRUST_FILE" "$TEST_ROOT/work" "$KEY_FILE" "$PUB_FILE" || fail remote-auth-success
[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" -eq 2 ] || fail success-probed-every-node
grep -Fq "1|192.168.186.201|$KEY_FILE|$TEST_ROOT/work/ssh_forensics" "$CALLS" || fail node1-probe-context
grep -Fq "2|192.168.186.202|$KEY_FILE|$TEST_ROOT/work/ssh_forensics" "$CALLS" || fail node2-probe-context
[ ! -d "$TEST_ROOT/work/trust-context" ] || fail success-left-trust-context
pass candidate-auth-success-probes-all-nodes

: > "$CALLS"
TEST_AUTH_RC=5
export TEST_AUTH_RC
MERV_SSH_LAST_REASON=publickey-rejected
MERV_SSH_LAST_DETAIL='explicit public-key rejection fixture'
if merv_backup_state_remote_auth_preflight \
    "$SETTINGS_FILE" "$TRUST_FILE" "$TEST_ROOT/work" "$KEY_FILE" "$PUB_FILE"; then
    fail remote-auth-failure-accepted
fi
[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" -eq 1 ] || fail failure-continued-to-next-node
[ "$MERV_SSH_LAST_REASON" = candidate-remote-auth-failed ] || fail failure-reason
printf '%s\n' "$MERV_SSH_LAST_DETAIL" | grep -Fq 'NODE1' || fail failure-node-detail
[ ! -d "$TEST_ROOT/work/trust-context" ] || fail failure-left-trust-context
pass candidate-auth-failure-stops-before-activation-boundary

RESTORE="$ROOT/functions/mervlan_backup.sh"
_gate_line=$(grep -n 'merv_backup_state_remote_auth_preflight' "$RESTORE" | sed -n '1p' | cut -d: -f1)
_activation_line=$(grep -n 'mb_write_result running activating' "$RESTORE" | sed -n '1p' | cut -d: -f1)
_transaction_line=$(grep -n 'mb_prepare_trust_transaction ||' "$RESTORE" | sed -n '1p' | cut -d: -f1)
case "$_gate_line:$_activation_line:$_transaction_line" in
    ''|*[!0-9:]*) fail restore-order-line-detection ;;
esac
[ "$_gate_line" -lt "$_transaction_line" ] || fail gate-after-trust-transaction
[ "$_gate_line" -lt "$_activation_line" ] || fail gate-after-activation
grep -Fq 'merv_ssh_test_context' "$ROOT/settings/lib_backup_state.sh" || fail direct-context-probe-contract
grep -Fq 'MERV_SSH_DIAGNOSTIC_CONTEXT' "$ROOT/settings/lib_ssh.sh" || fail diagnostic-context-contract
pass restore-auth-gate-precedes-activation

# The maintained probe helper captures stdout by redirection in the current
# shell; it must never hide merv_ssh_exec diagnostics in $(...).
_test_helper=$(sed -n '/^merv_ssh_test() {/,/^}/p' "$ROOT/settings/lib_ssh.sh")
printf '%s\n' "$_test_helper" | grep -Fq 'merv_ssh_exec "$1" "$2" "echo connected" >' || fail ssh-test-direct-call
if printf '%s\n' "$_test_helper" | grep -Fq '$(merv_ssh_exec'; then
    fail ssh-test-command-substitution
fi
pass qualification-probe-preserves-diagnostics

printf 'PASS restore remote-auth contract\n'
