#!/bin/sh
# MAC Shield must not create MerVLAN residue on a stripped or partial node.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-node-readiness.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export MERV_BASE="$BASE_DIR"
export VAR_SETTINGS_LOADED=1
export LIB_SSH_LOADED=1
export LIB_ACTION_LOCK_LOADED=1
export TMPDIR="$TEST_ROOT/tmp"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export SETTINGS_FILE="$TEST_ROOT/settings.json"
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
export MERV_MAC_OVERRIDE_DB="$TEST_ROOT/db/override.db"
export SSH_KEY="$TEST_ROOT/db/ssh.key"
mkdir -p "$TMPDIR" "$LOCKDIR" "$RESULTDIR" "$MERV_STATE_ROOT" "$TEST_ROOT/db"
: > "$SETTINGS_FILE"
: > "$MERV_MAC_DB_ACTIVE"
: > "$MERV_MAC_OVERRIDE_DB"
: > "$SSH_KEY"

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
merv_is_valid_node_id() {
  case "$1" in 1|2|3|4|5|6|7|8|9|10) return 0 ;; *) return 1 ;; esac
}
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

TRACE="$TEST_ROOT/trace"
REMOTE_MODE=node-not-provisioned

info() { :; }
warn() { :; }
error() { :; }
merv_mac_log() { :; }
merv_mac_logv() { :; }
merv_node_resolve_endpoint() { printf '%s\n' "$2"; }
merv_ssh_precheck() { printf 'precheck\n' >> "$TRACE"; return 0; }
merv_ssh_exec() {
  case "$3" in
    *node-not-provisioned*|*node-control-plane-incomplete*|*node-ready*)
      printf 'readiness:%s\n' "$REMOTE_MODE" >> "$TRACE"
      printf '%s\n' "$REMOTE_MODE"
      return 0
      ;;
    *mkdir*) printf 'mkdir\n' >> "$TRACE"; return 0 ;;
    *ebt_mac_shield_init_and_apply*) printf 'reload\n' >> "$TRACE"; return 0 ;;
    *) printf 'unexpected-exec\n' >> "$TRACE"; return 1 ;;
  esac
}
merv_ssh_stream_file() {
  if [ "$4" = "$MERV_MAC_DB_ACTIVE" ]; then
    printf 'stream-db\n' >> "$TRACE"
  else
    printf 'stream-override\n' >> "$TRACE"
  fi
  return 0
}

run_case() {
  _rn_mode="$1"
  REMOTE_MODE="$_rn_mode"
  : > "$TRACE"
  if merv_mac_push_node 1 192.0.2.1; then
    _rn_rc=0
  else
    _rn_rc=$?
  fi
  case "$_rn_mode" in
    node-not-provisioned|node-control-plane-incomplete)
      [ "$_rn_rc" -ne 0 ] || fail "$_rn_mode was accepted"
      [ "$(grep -c '^precheck$' "$TRACE" 2>/dev/null || :)" -eq 1 ] || fail "$_rn_mode did not precheck"
      [ "$(grep -c '^readiness:' "$TRACE" 2>/dev/null || :)" -eq 1 ] || fail "$_rn_mode did not perform readiness check"
      ! grep -qE '^(mkdir|stream-db|stream-override|reload)$' "$TRACE" || fail "$_rn_mode mutated the node"
      ;;
    node-ready)
      [ "$_rn_rc" -eq 0 ] || fail "ready node push failed"
      expected='precheck
readiness:node-ready
mkdir
stream-db
stream-override
reload'
      actual=$(cat "$TRACE")
      [ "$actual" = "$expected" ] || fail "ready node order was: $actual"
      ;;
  esac
}

run_case node-not-provisioned
run_case node-control-plane-incomplete
run_case node-ready
printf 'MAC_NODE_READINESS_CONTRACT_OK\n'
