#!/bin/sh
# Deterministic Sync endpoint-pin contract.  The real preflight emits a
# slot/canonical/verified-endpoint map; the real resolver consumes that map
# only when Sync enables it, while fake transfer boundaries record every
# command destination (including settings.json).

set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_ROOT="/tmp/mervlan_tmp/selftest.sync-endpoint.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

SETTINGS_FILE="$TEST_ROOT/settings.json"
PREFLIGHT_FILE="$TEST_ROOT/preflight.tsv"
ENDPOINT_MAP="$TEST_ROOT/endpoint.map"
PROBE_CALLS="$TEST_ROOT/probe.calls"
TRANSFER_CALLS="$TEST_ROOT/transfer.calls"
WAN_IP=198.51.100.10
ASUS_IP=192.0.2.10

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
MERV_MAX_NODES=1
export MERV_BASE SETTINGS_FILE MERV_STATE_ROOT MERV_SSH_TRUST_TEST_MODE
export MERV_SSH_TRUST_ROOT MERV_SSH_TRUST_FILE MERV_SSH_TRUST_PENDING_ROOT
export MERV_SSH_TRUST_REQUESTS_ROOT MERV_SSH_TRUST_STAGING_ROOT
export MERV_SSH_TRUST_QUARANTINE_ROOT MERV_SSH_TRUST_LOCK_PATH
export MERV_NODE_SSH_PORT MERV_MAX_NODES

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
printf '%s\n' "1 $ASUS_IP none" > "$PREFLIGHT_FILE" || exit 1
: > "$PROBE_CALLS"
: > "$TRANSFER_CALLS"

unset LIB_JSON_LOADED LIB_SSH_LOADED LIB_SSH_TRUST_LOADED
. "$ROOT/settings/lib_json.sh" || fail 'could not load JSON library'
. "$ROOT/settings/lib_ssh.sh" || fail 'could not load SSH library'

merv_ssh_hostkey_probe() {
    printf '%s\n' "$2" >> "$PROBE_CALLS"
    case "$2" in
        "$WAN_IP"|"$ASUS_IP")
            MERV_SSH_TRUST_LAST_REASON=verified
            MERV_SSH_TRUST_LAST_STATUS=verified
            return 0
            ;;
    esac
    MERV_SSH_TRUST_LAST_REASON=probe-failed
    MERV_SSH_TRUST_LAST_STATUS=probe-failed
    return 7
}

MERV_SSH_PREFLIGHT_ENDPOINT_MAP="$ENDPOINT_MAP"
export MERV_SSH_PREFLIGHT_ENDPOINT_MAP
merv_ssh_preflight_node_set "$PREFLIGHT_FILE" "$SETTINGS_FILE" >/dev/null 2>&1 || \
    fail 'real preflight rejected the verified WAN fixture'
[ "$(tr '\n' ',' < "$PROBE_CALLS")" = "$WAN_IP," ] || \
    fail 'preflight did not verify the expected WAN endpoint first'
[ "$(cat "$ENDPOINT_MAP")" = "1 $ASUS_IP $WAN_IP" ] || \
    fail 'preflight emitted an unexpected endpoint map'

unset MERV_SSH_PREFLIGHT_ENDPOINT_MAP
MERV_SSH_SYNC_ENDPOINT_MAP="$ENDPOINT_MAP"
export MERV_SSH_SYNC_ENDPOINT_MAP
PINNED=$(merv_node_endpoint_candidates 1 "$SETTINGS_FILE") || \
    fail 'Sync resolver rejected the completed endpoint map'
[ "$PINNED" = "$WAN_IP" ] || fail "Sync resolver did not pin WAN endpoint (got=$PINNED)"

# Without the Sync-only map, ordinary callers retain the expected-first list.
unset MERV_SSH_SYNC_ENDPOINT_MAP
UNPINNED=$(merv_node_endpoint_candidates 1 "$SETTINGS_FILE") || fail 'ordinary resolver failed'
UNPINNED_EXPECTED=$(printf '%s\n%s' "$WAN_IP" "$ASUS_IP")
[ "$UNPINNED" = "$UNPINNED_EXPECTED" ] || fail 'ordinary resolver behavior changed'
MERV_SSH_SYNC_ENDPOINT_MAP="$ENDPOINT_MAP"
export MERV_SSH_SYNC_ENDPOINT_MAP

# Current-candidate membership, canonical identity, and duplicate-row checks
# are all fail-closed before a transfer can be attempted.
printf '%s\n' "1 $ASUS_IP 203.0.113.77" > "$ENDPOINT_MAP"
if merv_node_endpoint_candidates 1 "$SETTINGS_FILE" >/dev/null 2>&1; then
    fail 'stale endpoint map was accepted'
fi
printf '%s\n' "1 192.0.2.99 $WAN_IP" > "$ENDPOINT_MAP"
if merv_node_endpoint_candidates 1 "$SETTINGS_FILE" >/dev/null 2>&1; then
    fail 'canonical-identity mismatch was accepted'
fi
printf '%s\n' "1 $ASUS_IP $WAN_IP" "1 $ASUS_IP $WAN_IP" > "$ENDPOINT_MAP"
if merv_node_endpoint_candidates 1 "$SETTINGS_FILE" >/dev/null 2>&1; then
    fail 'duplicate endpoint-map row was accepted'
fi
printf '%s\n' "1 $ASUS_IP $WAN_IP" > "$ENDPOINT_MAP"

# Fake only the network boundaries.  These calls mirror Sync's batch stream,
# settings stream, and post-copy command; all must receive the pinned endpoint.
merv_ssh_exec() {
    printf 'exec|%s|%s\n' "$2" "$3" >> "$TRANSFER_CALLS"
    return 0
}
merv_ssh_stream_stdin() {
    printf 'batch|%s|%s\n' "$2" "$3" >> "$TRANSFER_CALLS"
    return 0
}
merv_ssh_stream_file() {
    printf 'settings|%s|%s\n' "$2" "$4" >> "$TRANSFER_CALLS"
    return 0
}

SYNC_SELECTED_ENDPOINT=$(merv_node_endpoint_candidates 1 "$SETTINGS_FILE" | sed -n '1p') || \
    fail 'could not select endpoint for transfer fixture'
merv_ssh_exec 1 "$SYNC_SELECTED_ENDPOINT" 'mkdir -p /jffs/addons/mervlan_backups' || fail exec
merv_ssh_stream_stdin 1 "$SYNC_SELECTED_ENDPOINT" 'cd /jffs/addons/mervlan && tar -xf -' || fail batch
merv_ssh_stream_file 1 "$SYNC_SELECTED_ENDPOINT" "$SETTINGS_FILE" '/jffs/addons/mervlan/settings/settings.json' || fail settings

if awk -F '|' -v expected="$WAN_IP" '$2 != expected { bad=1 } END { exit bad }' "$TRANSFER_CALLS"; then
    :
else
    fail 'a Sync transfer command targeted a non-pinned endpoint'
fi
[ "$(wc -l < "$TRANSFER_CALLS" | tr -d ' ')" = 3 ] || fail 'transfer fixture did not exercise all boundaries'

grep -q 'MERV_SSH_PREFLIGHT_ENDPOINT_MAP' "$ROOT/functions/sync_nodes.sh" || \
    fail 'Sync does not stage the preflight endpoint map'
grep -q 'MERV_SSH_SYNC_ENDPOINT_MAP' "$ROOT/functions/sync_nodes.sh" || \
    fail 'Sync does not promote/consume the endpoint map'
grep -q 'node_ip=$(merv_node_endpoint_candidates "$node_id"' "$ROOT/functions/sync_nodes.sh" || \
    fail 'Sync worker does not resolve its selected endpoint before operations'
grep -q 'merv_ssh_stream_stdin "$node_id" "$node_ip"' "$ROOT/functions/sync_nodes.sh" || \
    fail 'Sync batch transfer does not use the selected endpoint'
grep -q 'merv_ssh_stream_file "$node_id" "$node_ip"' "$ROOT/functions/sync_nodes.sh" || \
    fail 'Sync settings/file transfer does not use the selected endpoint'

printf 'PREFLIGHT: verified=%s canonical=%s map=%s\n' "$WAN_IP" "$ASUS_IP" "$(cat "$ENDPOINT_MAP")"
printf 'RESOLVER: Sync-only pin=%s; ordinary resolver retains WAN+ASUS candidates\n' "$PINNED"
printf 'TRANSFERS: all %s command/settings/batch destinations=%s\n' \
    "$(wc -l < "$TRANSFER_CALLS" | tr -d ' ')" "$WAN_IP"
printf 'EVIDENCE: stale, identity-mismatch, and duplicate maps fail closed\n'
printf 'SYNC_ENDPOINT_PIN_CONTRACT_OK\n'
