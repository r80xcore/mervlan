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
export MERV_SETTINGS_RECONCILE_PUBLIC_ROOT="$TEST_ROOT/public"
export MERV_SETTINGS_RECONCILE_PUBLIC_FILE="$TEST_ROOT/public/tmp/results/settings_reconcile.json"
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
[ -f "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE" ] || fail projection-publish
projection=$(cat "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE")
case "$projection" in
    *'"active":false'*|*'settings_digest'*|*'node_list_digest'*|*'md5:'*|*'cksum:'*) fail projection-publish-content ;;
esac
case "$projection" in
    *'"format":1'*'"active":true'*'"generation":1'*'"status":"pending"'*'"attempt":2'*'"next_epoch":1234'*) ;;
    *) fail projection-publish-values ;;
esac
pass projection-publish-safe-active-state

merv_settings_reconcile_update 1 md5:settings-a cksum:1:2 retry 3 5678 || fail projection-update
projection=$(cat "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE")
case "$projection" in
    *'"active":true'*'"generation":1'*'"status":"retry"'*'"attempt":3'*'"next_epoch":5678'*) ;;
    *) fail projection-update-values ;;
esac
pass projection-update-safe-active-state

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
projection=$(cat "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE")
case "$projection" in *'"active":true'*) ;; *) fail projection-newer-active ;; esac
case "$projection" in *'"generation":2'*'"status":"queued"'*) ;; *) fail projection-newer-state ;; esac
if merv_settings_reconcile_clear 1; then
    fail stale-clear-accepted
fi
merv_settings_reconcile_read || fail stale-clear-damaged-state
[ "$MERV_SETTINGS_RECONCILE_GENERATION" = 2 ] || fail stale-clear-removed-newer
projection=$(cat "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE")
case "$projection" in *'"active":true'*) ;; *) fail stale-clear-altered-projection ;; esac
case "$projection" in *'"generation":2'*'"status":"queued"'*) ;; *) fail stale-clear-altered-projection ;; esac
pass newer-publish-conditional-clear

merv_settings_reconcile_clear 2 || fail matching-clear
if merv_settings_reconcile_read; then
    fail clear-left-state
fi
projection=$(cat "$MERV_SETTINGS_RECONCILE_PUBLIC_FILE")
case "$projection" in *'"active":false'*) ;; *) fail projection-matching-clear ;; esac
case "$projection" in *'"generation":2'*'"status":"verified"'*) ;; *) fail projection-matching-clear ;; esac
pass matching-clear

# A bad public override must fail closed for the observer only.  The protected
# marker operation still succeeds and remains authoritative.
MERV_SETTINGS_RECONCILE_PUBLIC_FILE="$TEST_ROOT/public/unsafe.json"
merv_settings_reconcile_publish md5:projection-safe cksum:projection-safe pending 0 0 || fail projection-unsafe-broke-publish
merv_settings_reconcile_read || fail projection-unsafe-broke-state
[ ! -e "$TEST_ROOT/public/unsafe.json" ] || fail projection-unsafe-wrote-file
MERV_SETTINGS_RECONCILE_PUBLIC_FILE="$TEST_ROOT/public/tmp/results/settings_reconcile.json"
if merv_settings_reconcile_public_path_valid "$TEST_ROOT/public/../unsafe/tmp/results/settings_reconcile.json"; then
    fail projection-traversal-accepted
fi
pass projection-unsafe-override-fails-safe

if merv_settings_reconcile_publish 'md5:bad value' cksum:1:2 pending 0 0; then
    fail unsafe-digest-accepted
fi
if merv_settings_reconcile_publish md5:ok cksum:1:2 bogus 0 0; then
    fail unsafe-status-accepted
fi
pass bounded-values-rejected

printf 'SETTINGS_RECONCILE_STATE_OK\n'
