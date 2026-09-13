#!/bin/sh
# Targeted lifecycle-closure contract for the shared node pool and MAC Shield.
# The worker is real; only the handler, identity fixture paths, and Shield
# device actions are local fakes. No router, SSH, or live action is contacted.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-lifecycle-closure.$$"
FAKE_BASE="$TEST_ROOT/addon"
umask 077
mkdir -p "$FAKE_BASE/settings" "$FAKE_BASE/functions" "$TEST_ROOT/tmp/node_jobs" "$TEST_ROOT/db" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat > "$FAKE_BASE/settings/var_settings.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
TMPDIR="$TEST_ROOT/tmp"
LOCKDIR="$TEST_ROOT/locks"
SETTINGS_FILE="$TEST_ROOT/settings.json"
export TMPDIR LOCKDIR SETTINGS_FILE
EOF
cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_is_valid_node_id() { case "$1" in 1|2|3|4|5|6|7|8|9|10) return 0 ;; *) return 1 ;; esac; }
merv_proc_start_time() { merv_identity_proc_start "$1" "${2:-/proc}"; }
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
EOF
cp "$ROOT/settings/lib_identity.sh" "$FAKE_BASE/settings/lib_identity.sh" || exit 1
cp "$ROOT/settings/lib_node_jobs.sh" "$FAKE_BASE/settings/lib_node_jobs.sh" || exit 1

export MERV_BASE="$FAKE_BASE" TEST_ROOT
. "$FAKE_BASE/settings/lib_node_jobs.sh" || fail 'node-job library did not load'

TRACE="$TEST_ROOT/trace"
export TRACE
merv_proc_start_time() {
    if [ -n "${MNJ_POOL_PENDING_PID:-}" ]; then
        printf 'parent-identity-lookup\n' >> "$TRACE"
    else
        printf 'worker-identity-lookup\n' >> "$TRACE"
    fi
    merv_identity_proc_start "$1" "${2:-/proc}"
}
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }

pool_handler() {
    sleep 1
}
pending_probe() {
    [ "$1" = "${MNJ_POOL_PENDING_PID:-}" ] || return 1
    [ "$2" = "${MNJ_POOL_PENDING_DIR:-}" ] || return 1
    [ "$3" = "${MNJ_POOL_PENDING_NODE:-}" ] || return 1
    [ -z "${MNJ_POOL_PENDING_START:-}" ] || return 1
    printf 'pending-published\n' >> "$TRACE"
    MNJ_POOL_PENDING_HOOK_SEEN=1
}

printf '1 192.0.2.1\n' > "$TEST_ROOT/nodes"
MERV_NODE_PARALLELISM=1
MNJ_POOL_PENDING_HOOK=pending_probe
export MERV_NODE_PARALLELISM MNJ_POOL_PENDING_HOOK
if ! mnj_pool_run "$TEST_ROOT/tmp/node_jobs/first" closure 1 5 "$TEST_ROOT/nodes" pool_handler; then
    fail 'real pool did not complete the post-launch publication case'
fi
[ "${MNJ_POOL_PENDING_HOOK_SEEN:-0}" = 1 ] || fail 'post-$! pending hook did not observe publication'
_pending_line=$(grep -n '^pending-published$' "$TRACE" | head -1 | cut -d: -f1)
_lookup_line=$(grep -n '^parent-identity-lookup$' "$TRACE" | head -1 | cut -d: -f1)
[ -n "$_pending_line" ] && [ -n "$_lookup_line" ] && [ "$_pending_line" -lt "$_lookup_line" ] ||
    fail 'pending metadata was not published before parent identity lookup'
[ "${MNJ_POOL_ACTIVE:-1}" -eq 0 ] && ! mnj_pool_state_unresolved || fail 'completed pool remained unresolved'

# An unreconciled marker must be authoritative: a second invocation cannot
# reset metadata or create a replacement root while the first root is retained.
MNJ_POOL_ROOT="$TEST_ROOT/tmp/node_jobs/first"
MNJ_POOL_PHASE=closure
MNJ_POOL_ACTIVE=1
MNJ_POOL_PENDING_PID=999999
MNJ_POOL_PENDING_START=''
MNJ_POOL_PENDING_DIR="$TEST_ROOT/tmp/node_jobs/first/node_1"
MNJ_POOL_PENDING_NODE=1
_retained_pid="$MNJ_POOL_PENDING_PID"
_retained_dir="$MNJ_POOL_PENDING_DIR"
if mnj_pool_run "$TEST_ROOT/tmp/node_jobs/second" replacement 1 1 "$TEST_ROOT/nodes" pool_handler; then
    fail 'second pool started while prior pool state was unresolved'
fi
[ "$MNJ_POOL_ACTIVE" = 1 ] && [ "$MNJ_POOL_PENDING_PID" = "$_retained_pid" ] &&
    [ "$MNJ_POOL_PENDING_DIR" = "$_retained_dir" ] || fail 'unresolved metadata was overwritten'
[ ! -d "$TEST_ROOT/tmp/node_jobs/second" ] || fail 'replacement pool root was created'
[ -d "$TEST_ROOT/tmp/node_jobs/first" ] || fail 'retained pool workspace was removed'

# Source the production Shield library with its optional dependencies marked
# loaded, then verify collection and direct push both stop before build/mkdir.
LIB_OWNER_LOCK_LOADED=1 LIB_SSH_LOADED=1 LIB_MAC_SHIELD_SNAPSHOT_LOADED=''
export LIB_OWNER_LOCK_LOADED LIB_SSH_LOADED
MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
MERV_MAC_OVERRIDE_DB="$TEST_ROOT/db/override.db"
DRY_RUN=no
export MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS MERV_MAC_OVERRIDE_DB DRY_RUN
: > "$MERV_MAC_DB_ACTIVE"
. "$ROOT/settings/mac_shield_snapshot.sh" || fail 'Shield library did not load'
MERV_MAC_BUILD_CALLED=0
merv_mac_build_snapshot() { MERV_MAC_BUILD_CALLED=1; : > "$1"; printf '0\n'; }
warn() { :; }
if merv_mac_snapshot; then fail 'Shield collection accepted unresolved pool state'; fi
[ "$MERV_MAC_BUILD_CALLED" -eq 0 ] || fail 'Shield collection built while pool state was unresolved'
[ "$MERV_MAC_LAST_STATUS" = pool_unresolved ] || fail "Shield status=$MERV_MAC_LAST_STATUS"
if merv_mac_push_db_to_nodes '1 192.0.2.1'; then fail 'Shield push accepted unresolved pool state'; fi
[ ! -d "$TEST_ROOT/tmp/node_jobs/mac_push."* ] 2>/dev/null || fail 'Shield created a push workspace while unresolved'

# If the pool becomes unresolved after Shield acquires its own lock, that
# ownership must remain retained with the worker workspace for reconciliation.
MNJ_POOL_ACTIVE=0
MNJ_POOL_PENDING_PID=''; MNJ_POOL_PENDING_START=''; MNJ_POOL_PENDING_DIR=''; MNJ_POOL_PENDING_NODE=''
MNJ_S1_PID=''; MNJ_S1_START=''; MNJ_S1_DIR=''; MNJ_S1_NODE=''; MNJ_S1_DEADLINE=''
MNJ_S2_PID=''; MNJ_S2_START=''; MNJ_S2_DIR=''; MNJ_S2_NODE=''; MNJ_S2_DEADLINE=''
MNJ_S3_PID=''; MNJ_S3_START=''; MNJ_S3_DIR=''; MNJ_S3_NODE=''; MNJ_S3_DEADLINE=''
MNJ_S4_PID=''; MNJ_S4_START=''; MNJ_S4_DIR=''; MNJ_S4_NODE=''; MNJ_S4_DEADLINE=''
MNJ_S5_PID=''; MNJ_S5_START=''; MNJ_S5_DIR=''; MNJ_S5_NODE=''; MNJ_S5_DEADLINE=''
MERV_MAC_NODE_SYNC=1
MERV_NODE_PARALLELISM=1
MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
SSH_KEY="$TEST_ROOT/db/key"
: > "$SSH_KEY"
export MERV_MAC_NODE_SYNC MERV_NODE_PARALLELISM MERV_MAC_SNAPSHOT_FORCE_RELOAD SSH_KEY
mkdir -p "$TEST_ROOT/locks"
merv_owner_lock_acquire() { mkdir "$1" 2>/dev/null || return 1; MERV_LOCK_NONCE=closure-lock; return 0; }
merv_owner_lock_release() { : > "$TEST_ROOT/released"; return 0; }
merv_mac_snapshot_preconditions_ok() { return 0; }
merv_mac_is_main() { return 0; }
merv_mac_node_list() { printf '1 192.0.2.1\n'; }
merv_ssh_preflight_node_lines() { return 0; }
ssh_keys_effectively_installed() { return 0; }
merv_has() { return 0; }
merv_mac_build_snapshot() { printf '%s aa:bb:cc:dd:ee:01 wl0.1 10\n' "$(date +%s)" > "$1"; printf '1\n'; }
merv_mac_merge_db() { : > "$MERV_MAC_DB_ACTIVE"; return 0; }
ebt_mac_shield_init_and_apply() { return 0; }
mnj_pool_run() { MNJ_POOL_ROOT="$1"; MNJ_POOL_PHASE="$2"; MNJ_POOL_ACTIVE=1; mkdir -p "$1/node_1"; return 2; }
mnj_pool_abort_active() { return 1; }
if merv_mac_snapshot; then fail 'Shield collection accepted a pool that became unresolved'; fi
[ "$MERV_MAC_LAST_STATUS" = pool_unresolved ] || fail "late Shield status=$MERV_MAC_LAST_STATUS"
[ -d "$TEST_ROOT/locks/mac_snapshot.lock" ] || fail 'late unresolved Shield lock was released'
[ ! -e "$TEST_ROOT/released" ] || fail 'late unresolved Shield release hook ran'
[ -d "$MNJ_POOL_ROOT" ] || fail 'late unresolved Shield workspace was removed'

printf 'NODE_POOL_LIFECYCLE_CLOSURE_CONTRACT_OK\n'
