#!/bin/sh
# Focused contract for the bounded SSH timeout used by staged node activation.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/sync_nodes.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-sync-node-timeout.$(date +%s).$$"
TRACE="$TEST_ROOT/trace"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$TEST_ROOT"

# Stub the guarded transport boundary so the contract exercises the real
# timeout scoping and failure classification without a device-side mutation.
merv_ssh_node_mutate_exec() {
    printf 'timeout=%s\n' "${MERV_SSH_TIMEOUT:-unset}" >> "$TRACE"
    printf 'STAGED_NODE_OK\n'
    return 0
}

eval "$(sed -n '/^activate_staged_node()/,/^activate_staged_node_settings_only()/p' "$SOURCE" | sed '$d')"

MERV_BASE=/jffs/addons/mervlan
MERV_SSH_TIMEOUT=10
SYNC_RUN_ID=test-run-1
export MERV_BASE MERV_SSH_TIMEOUT SYNC_RUN_ID

activate_staged_node 1 192.0.2.1 \
    /jffs/addons/mervlan_backups/.mervlan.new.test.1 \
    /jffs/addons/mervlan_backups/.mervlan.old.test.1 \
    >/dev/null || fail 'activation success fixture failed'

[ "$(sed -n '1p' "$TRACE")" = 'timeout=30' ] || fail 'activation did not use the bounded extended timeout'
[ "$MERV_SSH_TIMEOUT" = 10 ] || fail 'normal SSH timeout was not restored after activation'

# A transport/session failure must remain a failure and must identify the
# remote activation transaction instead of falling through to an unknown reason.
merv_ssh_node_mutate_exec() {
    printf 'timeout=%s\n' "${MERV_SSH_TIMEOUT:-unset}" >> "$TRACE"
    return 5
}

if activate_staged_node 1 192.0.2.1 \
    /jffs/addons/mervlan_backups/.mervlan.new.test.2 \
    /jffs/addons/mervlan_backups/.mervlan.old.test.2 \
    >/dev/null 2>&1; then
    fail 'activation transport failure was accepted'
fi
[ "${MERV_SSH_LAST_REASON:-}" = node-activation-ssh-failed ] || fail 'activation transport failure reason was not precise'
[ "${MERV_SSH_TIMEOUT:-}" = 10 ] || fail 'normal SSH timeout was not restored after failed activation'

printf 'SYNC_NODE_ACTIVATION_TIMEOUT_CONTRACT_OK\n'
