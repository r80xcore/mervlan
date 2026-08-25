#!/bin/sh
# Focused local contract test for the durable settings-convergence state.
# The harness is isolated and never contacts a router or sources state data.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.settings-reconcile.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_SETTINGS_RECONCILE_FILE="$MERV_STATE_ROOT/settings_reconcile.state"

. "$BASE_DIR/settings/var_settings.sh" || exit 1
. "$BASE_DIR/settings/lib_settings_reconcile.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

merv_settings_reconcile_publish md5:settings-a cksum:1:2 pending 2 1234 || fail publish
merv_settings_reconcile_read || fail read
[ "$MERV_SETTINGS_RECONCILE_FORMAT" = 1 ] || fail format
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 1 ] || fail first-generation
[ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" = md5:settings-a ] || fail settings-digest
[ "$MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST" = cksum:1:2 ] || fail node-list-digest
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail status
[ "$MERV_SETTINGS_RECONCILE_ATTEMPT" = 2 ] || fail attempt
[ "$MERV_SETTINGS_RECONCILE_NEXT_EPOCH" = 1234 ] || fail next-epoch
[ "$(merv_settings_reconcile_get generation '')" = 1 ] || fail getter
[ "$(stat -c '%a' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)" = 600 ] || fail mode
pass publish-read-mode

# Removing one complete record line models a truncated write.  Readers must
# reject it rather than exposing partial values to a caller.
cp "$MERV_SETTINGS_RECONCILE_FILE" "$TEST_ROOT/good.state" || fail state-copy
sed '$d' "$TEST_ROOT/good.state" > "$MERV_SETTINGS_RECONCILE_FILE" || fail state-truncate
if merv_settings_reconcile_read; then
    fail truncated-state-accepted
fi
pass malformed-truncated-rejected

# A fresh publish replaces malformed state and advances from the last valid
# generation known by the writer.  It is therefore safe to recover after a
# damaged marker without sourcing or replaying its contents.
merv_settings_reconcile_publish md5:settings-b cksum:3:4 retry 3 5678 || fail superseding-publish
merv_settings_reconcile_read || fail superseding-read
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 1 ] || fail recovered-generation
[ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" = md5:settings-b ] || fail superseding-settings-digest
[ "$MERV_SETTINGS_RECONCILE_STATUS" = retry ] || fail superseding-status

merv_settings_reconcile_publish md5:settings-c cksum:5:6 queued 0 0 || fail newer-publish
merv_settings_reconcile_read || fail newer-read
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 2 ] || fail newer-generation
[ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" = md5:settings-c ] || fail newer-settings-digest
if merv_settings_reconcile_clear 1; then
    fail stale-clear-accepted
fi
merv_settings_reconcile_read || fail stale-clear-damaged-state
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 2 ] || fail stale-clear-removed-newer
pass newer-publish-conditional-clear

merv_settings_reconcile_clear 2 || fail matching-clear
if merv_settings_reconcile_read; then
    fail clear-left-state
fi
pass matching-clear

if merv_settings_reconcile_publish 'md5:bad value' cksum:1:2 pending 0 0; then
    fail unsafe-digest-accepted
fi
if merv_settings_reconcile_publish md5:ok cksum:1:2 bogus 0 0; then
    fail unsafe-status-accepted
fi
pass bounded-values-rejected

printf 'SETTINGS_RECONCILE_STATE_OK\n'
