#!/bin/sh
# Standalone Recovery authenticated-child delegation contract.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.recovery-delegation.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

MERV_BASE="$BASE_DIR"
MERV_STATE_ROOT="$TEST_ROOT/state"
MERVLAN_RECOVERY_BACKUP_ROOT="$TEST_ROOT/backups"
MERVLAN_RECOVERY_ACTIVE_ROOT="$TEST_ROOT/active"
MERVLAN_RECOVERY_TMP_ROOT="$TEST_ROOT/tmp"
MERVLAN_RECOVERY_STATE_ROOT="$TEST_ROOT/state"
MERVLAN_RECOVERY_LOCK_OVERRIDE="$TEST_ROOT/locks/mervlan_maintenance.lock"
MERVLAN_RECOVERY_SOURCE_ONLY=1
export MERV_BASE MERV_STATE_ROOT MERVLAN_RECOVERY_BACKUP_ROOT \
  MERVLAN_RECOVERY_ACTIVE_ROOT MERVLAN_RECOVERY_TMP_ROOT \
  MERVLAN_RECOVERY_STATE_ROOT MERVLAN_RECOVERY_LOCK_OVERRIDE \
  MERVLAN_RECOVERY_SOURCE_ONLY
mkdir -p "$MERV_STATE_ROOT" "$MERVLAN_RECOVERY_BACKUP_ROOT" \
  "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$MERVLAN_RECOVERY_TMP_ROOT" \
  "${MERVLAN_RECOVERY_LOCK_OVERRIDE%/*}" || exit 1

. "$BASE_DIR/settings/lib_owner_lock.sh" || fail 'owner library load'
. "$BASE_DIR/settings/lib_update_state.sh" || fail 'Update-state library load'
. "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery source-only load'

RECOVERY_LOCK_OWNED=0
unset MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
  MERV_RECOVERY_DELEGATION MERV_MAINTENANCE_OWNER_PID \
  MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
if recovery_export_maintenance_context; then
  fail 'Recovery exported context before owning the lock'
fi
pass 'Recovery context export requires ownership first'

recovery_acquire_lock || fail 'Recovery owner acquisition'
recovery_owner_pid="$$"
recovery_owner_start="$RECOVERY_LOCK_START"
recovery_owner_nonce="$RECOVERY_LOCK_NONCE"
recovery_export_maintenance_context || fail 'Recovery context export'
[ "$MERV_MAINTENANCE_DELEGATED" = 1 ] || fail 'delegation flag'
[ "$MERV_MAINTENANCE_DELEGATION_KIND" = recovery ] || fail 'delegation kind'
[ "$MERV_RECOVERY_DELEGATION" = 1 ] || fail 'Recovery delegation flag'
[ "$MERV_MAINTENANCE_OWNER_PID" = "$recovery_owner_pid" ] || fail 'delegated PID'
[ "$MERV_MAINTENANCE_OWNER_START" = "$recovery_owner_start" ] || fail 'delegated start identity'
[ "$MERV_MAINTENANCE_OWNER_NONCE" = "$recovery_owner_nonce" ] || fail 'delegated nonce'
[ "$MERVLAN_RECOVERY_LOCK_OVERRIDE" = "$RECOVERY_LOCK" ] || fail 'delegated lock override'
merv_maintenance_delegation_valid || fail 'exact Recovery child context rejected'
pass 'Recovery exports the exact authenticated owner context'

recovery_expect_rejected() {
  recovery_reject_name="$1"
  if merv_maintenance_delegation_valid; then
    fail "wrong $recovery_reject_name accepted"
  fi
  pass "wrong $recovery_reject_name rejected"
}

MERV_MAINTENANCE_OWNER_PID=1
recovery_expect_rejected PID
MERV_MAINTENANCE_OWNER_PID="$recovery_owner_pid"
MERV_MAINTENANCE_OWNER_START=1
recovery_expect_rejected start-identity
MERV_MAINTENANCE_OWNER_START="$recovery_owner_start"
MERV_MAINTENANCE_OWNER_NONCE=wrong
recovery_expect_rejected nonce
MERV_MAINTENANCE_OWNER_NONCE="$recovery_owner_nonce"
MERV_MAINTENANCE_DELEGATION_KIND=install
recovery_expect_rejected kind
MERV_MAINTENANCE_DELEGATION_KIND=recovery
MERV_RECOVERY_DELEGATION=0
recovery_expect_rejected Recovery-flag
MERV_RECOVERY_DELEGATION=1
MERVLAN_RECOVERY_LOCK_OVERRIDE="$TEST_ROOT/locks/other.lock"
recovery_expect_rejected lock-override
MERVLAN_RECOVERY_LOCK_OVERRIDE="$RECOVERY_LOCK"
recovery_export_maintenance_context || fail 'Recovery context re-export'

# The same child admission gate used by mutating disable/setupdisable actions
# accepts the authenticated Recovery context and rejects an unauthenticated
# live owner. The production source also keeps both pre-activation calls under
# this gate.
for recovery_action in disable setupdisable; do
  if merv_update_mutation_blocked; then
    fail "pre-activation $recovery_action blocked under Recovery delegation"
  fi
  pass "pre-activation $recovery_action accepts Recovery delegation"
done
grep -Fq 'MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" disable' \
  "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery disable call missing'
grep -Fq 'MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" setupdisable' \
  "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery setupdisable call missing'

# Exercise recovery_reconcile() with real child-boundary validation. Each
# fixture child validates the exact context and records its tuple; all four
# children must receive the same owner identity and lock override.
target="$TEST_ROOT/target"
context_log="$TEST_ROOT/context.log"
mkdir -p "$target/functions" "$target/settings" "$target/www" || exit 1
for child in uninstall.sh install.sh functions/mervlan_boot.sh; do
  child_path="$target/$child"
  cat > "$child_path" <<'CHILD'
#!/bin/sh
set -u
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 41
. "$MERV_BASE/settings/lib_update_state.sh" || exit 42
merv_maintenance_delegation_valid || exit 43
printf '%s|%s|%s|%s|%s\n' "$1" "$MERV_MAINTENANCE_OWNER_PID" \
  "$MERV_MAINTENANCE_OWNER_START" "$MERV_MAINTENANCE_OWNER_NONCE" \
  "$MERVLAN_RECOVERY_LOCK_OVERRIDE" >> "$MERV_TEST_CONTEXT_LOG" || exit 44
CHILD
  chmod 755 "$child_path" || exit 1
done
printf '# fixture\n' > "$target/settings/fixture.sh"
printf '/* fixture */\n' > "$target/www/fixture.css"
printf '<!-- fixture -->\n' > "$target/www/fixture.html"
MERV_TEST_CONTEXT_LOG="$context_log"
export MERV_TEST_CONTEXT_LOG
MERVLAN_RECOVERY_TEST_MODE=0
recovery_reconcile "$target" 0 || fail 'Recovery reconcile child delegation'
[ "$(wc -l < "$context_log")" -eq 4 ] || fail 'unexpected child delegation count'
while IFS='|' read -r recovery_child recovery_pid recovery_start recovery_nonce recovery_override; do
  [ "$recovery_pid" = "$recovery_owner_pid" ] || fail 'child PID changed during reconcile'
  [ "$recovery_start" = "$recovery_owner_start" ] || fail 'child start identity changed during reconcile'
  [ "$recovery_nonce" = "$recovery_owner_nonce" ] || fail 'child nonce changed during reconcile'
  [ "$recovery_override" = "$RECOVERY_LOCK" ] || fail 'child lock override changed during reconcile'
done < "$context_log"
pass 'recovery_reconcile reuses one authenticated owner tuple'

# Remove delegation while the owner is still live: an unrelated child must be
# blocked by the existing fail-closed maintenance gate.
MERV_MAINTENANCE_DELEGATED=0
MERV_RECOVERY_DELEGATION=0
MERVLAN_MAINTENANCE_LOCK_OVERRIDE="$RECOVERY_LOCK"
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE
if ! merv_update_mutation_blocked; then
  fail 'unrelated live maintenance owner was not blocked'
fi
pass 'unrelated live maintenance owner remains fail-closed'
unset MERVLAN_MAINTENANCE_LOCK_OVERRIDE
recovery_export_maintenance_context || fail 'Recovery context restoration'
recovery_release_lock || fail 'Recovery owner release'
[ ! -e "$RECOVERY_LOCK" ] || fail 'Recovery owner lock remained after release'

# A pre-activation Recovery failure must release its owner and preserve the
# untouched active installation and exact recovery root without guessing any
# transaction state away.
printf 'active-sentinel\n' > "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel"
cp -p "$BASE_DIR/settings/lib_maintenance_recovery.sh" \
  "$MERVLAN_RECOVERY_BACKUP_ROOT/recovery_state.sh" || exit 1
cp -p "$BASE_DIR/settings/lib_update_state.sh" \
  "$MERVLAN_RECOVERY_BACKUP_ROOT/update_state.sh" || exit 1
RECOVERY_LOCK_OWNED=0
RECOVERY_LOCK_NONCE=""
RECOVERY_LOCK_START=""
MERVLAN_RECOVERY_TEST_MODE=0
(
  trap recovery_cleanup EXIT
  recovery_restore mervlan.backup.missing.tar.gz yes >/dev/null 2>&1
)
recovery_failure_rc=$?
[ "$recovery_failure_rc" -ne 0 ] || fail 'pre-activation Recovery failure unexpectedly succeeded'
[ -f "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel" ] || fail 'active installation changed on pre-activation failure'
[ ! -e "$RECOVERY_LOCK" ] || fail 'pre-activation failure retained owner lock'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.recovery" ] || fail 'pre-activation failure created durable marker'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.old.$$" ] || fail 'pre-activation failure left old tree'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.new.$$" ] || fail 'pre-activation failure left new tree'
pass 'pre-activation Recovery failure releases owner and preserves active state'

printf 'RECOVERY_DELEGATION_CONTRACT_OK\n'
