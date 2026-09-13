#!/bin/sh
# WAN-PREFLIGHT-01 contract: an ambiguous WAN Native rc=7/probe-failed may use
# the ASUS recovery endpoint only when a bounded ICMP probe also proves the
# future endpoint absent. A reachable endpoint remains fail-closed.

set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_ROOT="/tmp/mervlan_tmp/selftest.wan-preflight.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

SETTINGS_FILE="$TEST_ROOT/settings.json"
PREFLIGHT_FILE="$TEST_ROOT/preflight.tsv"
PROBE_CALLS="$TEST_ROOT/probe.calls"
WRAPPER_CALLS="$TEST_ROOT/wrapper.calls"
PING_RESULT=absent
MERV_BASE="$ROOT"
MERV_STATE_ROOT="$TEST_ROOT/state"
MERV_SSH_TRUST_TEST_MODE=1
MERV_SSH_TRUST_ROOT="$TEST_ROOT/ssh_trust"
MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/known_hosts.v1"
MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_ROOT/pending"
MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_ROOT/requests"
MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_ROOT/staging"
MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_ROOT/quarantine"
MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_ROOT/state.lock"
MERV_NODE_SSH_PORT=22
export SETTINGS_FILE MERV_BASE MERV_STATE_ROOT MERV_SSH_TRUST_TEST_MODE
export MERV_SSH_TRUST_ROOT MERV_SSH_TRUST_FILE MERV_SSH_TRUST_PENDING_ROOT
export MERV_SSH_TRUST_REQUESTS_ROOT MERV_SSH_TRUST_STAGING_ROOT
export MERV_SSH_TRUST_QUARANTINE_ROOT MERV_SSH_TRUST_LOCK_PATH MERV_NODE_SSH_PORT

printf '%s\n' \
    '{' \
    '  "Nodes": {' \
    '    "NODE1": "192.0.2.10",' \
    '    "NODE1_WAN_NATIVE_IP": "198.51.100.10"' \
    '  },' \
    '  "VLAN": {' \
    '    "WAN_Native": {' \
    '      "WAN_NATIVE_NODE1": "190"' \
    '    }' \
    '  }' \
    '}' > "$SETTINGS_FILE" || exit 1
printf '%s\n' '1 192.0.2.10 none' > "$PREFLIGHT_FILE" || exit 1
: > "$PROBE_CALLS"
: > "$WRAPPER_CALLS"

# Use the real resolver, wrapper, and trust preflight with only probe/SSH
# network boundaries stubbed. Load JSON before the SSH resolver, matching the
# established endpoint-resolver contract's fixture setup.
. "$ROOT/settings/lib_json.sh" || fail 'could not load JSON library'
LIB_SSH_TRUST_LOADED=1
. "$ROOT/settings/lib_ssh.sh" || fail 'could not load SSH library'
unset LIB_SSH_TRUST_LOADED
. "$ROOT/settings/lib_ssh_trust.sh" || fail 'could not load SSH trust library'

_merv_ping_ok() {
    [ "$PING_RESULT" = reachable ]
}

EXPECTED_ENDPOINTS=$(merv_node_endpoint_candidates 1 "$SETTINGS_FILE") || \
    fail 'endpoint resolver rejected valid WAN Native fixture'
printf 'DEBUG endpoints=%s\n' "$(printf '%s' "$EXPECTED_ENDPOINTS" | tr '\n' ',')" >&2
[ "$(printf '%s\n' "$EXPECTED_ENDPOINTS" | sed -n '1p')" = 198.51.100.10 ] || \
    fail 'WAN Native endpoint was not resolver-preferred'
[ "$(printf '%s\n' "$EXPECTED_ENDPOINTS" | sed -n '2p')" = 192.0.2.10 ] || \
    fail 'ASUS recovery endpoint was not retained by resolver'

# The WAN probe fails with the ambiguous generic rc=7/probe-failed result. Its
# future endpoint is absent, so the verified ASUS recovery endpoint may run.
merv_ssh_hostkey_probe() {
    printf '%s\n' "$2" >> "$PROBE_CALLS"
    case "$2" in
        198.51.100.10)
            MERV_SSH_TRUST_LAST_REASON=probe-failed
            MERV_SSH_TRUST_LAST_STATUS=probe-failed
            return 7
            ;;
        192.0.2.10)
            MERV_SSH_TRUST_LAST_REASON=verified
            MERV_SSH_TRUST_LAST_STATUS=verified
            return 0
            ;;
        *)
            MERV_SSH_TRUST_LAST_REASON=probe-failed
            return 7
            ;;
    esac
}

if merv_ssh_preflight_node_set "$PREFLIGHT_FILE" "$SETTINGS_FILE" >/dev/null 2>&1; then
    PREFLIGHT_RC=0
else
    PREFLIGHT_RC=$?
fi
[ "$PREFLIGHT_RC" -eq 0 ] || fail "batch preflight did not use absent-endpoint fallback (rc=$PREFLIGHT_RC)"
PREFLIGHT_CALLS=$(tr '\n' ',' < "$PROBE_CALLS")
[ "$PREFLIGHT_CALLS" = '198.51.100.10,192.0.2.10,' ] || \
    fail 'batch preflight did not try ASUS recovery after absent endpoint'

# The normal configured-nodes entry point must use the same policy.
: > "$PROBE_CALLS"
if merv_ssh_preflight_configured_nodes "$SETTINGS_FILE" >/dev/null 2>&1; then
    CONFIGURED_RC=0
else
    CONFIGURED_RC=$?
fi
[ "$CONFIGURED_RC" -eq 0 ] || fail "configured preflight did not use absent-endpoint fallback (rc=$CONFIGURED_RC)"
CONFIGURED_CALLS=$(tr '\n' ',' < "$PROBE_CALLS")
[ "$CONFIGURED_CALLS" = '198.51.100.10,192.0.2.10,' ] || \
    fail 'configured preflight diverged from batch fallback order'

# A responsive endpoint that cannot complete its host-key probe must remain
# terminal: it may represent an identity, trust, or capability fault.
PING_RESULT=reachable
: > "$PROBE_CALLS"
if merv_ssh_preflight_node_set "$PREFLIGHT_FILE" "$SETTINGS_FILE" >/dev/null 2>&1; then
    REACHABLE_RC=0
else
    REACHABLE_RC=$?
fi
[ "$REACHABLE_RC" -eq 7 ] || fail "reachable probe-failed endpoint returned rc=$REACHABLE_RC instead of rc=7"
[ "${MERV_SSH_LAST_REASON:-}" = probe-failed ] || \
    fail "reachable probe-failed reason was '${MERV_SSH_LAST_REASON:-}'"
[ "$(tr '\n' ',' < "$PROBE_CALLS")" = '198.51.100.10,' ] || \
    fail 'reachable probe-failed endpoint incorrectly tried ASUS recovery'

# Contrast: the ordinary execution wrapper falls back for an allowlisted
# pre-session transport classification (unreachable), using the same endpoint
# candidates. This is intentionally not used to reinterpret probe-failed.
merv_ssh_exec_endpoint() {
    printf '%s\n' "$2" >> "$WRAPPER_CALLS"
    case "$2" in
        198.51.100.10)
            MERV_SSH_LAST_REASON=unreachable
            MERV_SSH_LAST_DETAIL='fixture pre-session transport failure'
            return 4
            ;;
        192.0.2.10)
            printf '%s\n' 'connected:192.0.2.10'
            return 0
            ;;
    esac
    MERV_SSH_LAST_REASON=unreachable
    return 4
}

if merv_ssh_exec 1 192.0.2.10 'read-only fixture' > "$TEST_ROOT/wrapper.out"; then
    WRAPPER_RC=0
else
    WRAPPER_RC=$?
fi
[ "$WRAPPER_RC" -eq 0 ] || fail "execution wrapper did not use intended fallback (rc=$WRAPPER_RC)"
[ "$(cat "$TEST_ROOT/wrapper.out")" = 'connected:192.0.2.10' ] || \
    fail 'execution wrapper returned unexpected recovery output'
[ "$(tr '\n' ',' < "$WRAPPER_CALLS")" = '198.51.100.10,192.0.2.10,' ] || \
    fail 'execution wrapper fallback order differed from resolver candidates'

printf 'FIXTURE: resolver candidates WAN Native=198.51.100.10, ASUS recovery=192.0.2.10\n'
printf 'PREFLIGHT: absent WAN rc=7/probe-failed; batch rc=%s; probes=%s\n' \
    "$PREFLIGHT_RC" "$PREFLIGHT_CALLS"
printf 'CONFIGURED: absent WAN rc=7/probe-failed; batch rc=%s; probes=%s\n' \
    "$CONFIGURED_RC" "$CONFIGURED_CALLS"
printf 'WRAPPER: allowlisted unreachable fallback rc=%s; calls=%s\n' \
    "$WRAPPER_RC" "$(tr '\n' ',' < "$WRAPPER_CALLS")"
printf 'EVIDENCE: preflight shares absent-endpoint fallback and remains fail-closed when ping responds\n'
printf 'WAN_PREFLIGHT_01_CONTRACT_OK\n'
