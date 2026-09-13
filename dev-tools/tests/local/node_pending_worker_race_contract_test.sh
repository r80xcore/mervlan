#!/bin/sh
# Deterministic real-parent TERM coverage for the pool's pending-worker window.
# The worker and process identities are local fakes only; no router action runs.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-pending-worker-race.$$"
FAKE_BASE="$TEST_ROOT/addon"
umask 077
mkdir -p "$FAKE_BASE/settings" "$TEST_ROOT/tmp/node_jobs" || exit 1
test_cleanup() {
    [ "${TEST_KEEP:-0}" = 1 ] || rm -rf "$TEST_ROOT"
}
trap test_cleanup 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
require_file() { [ -s "$1" ] || fail "missing $1"; }
read_field() { sed -n "s/^$2=//p" "$1" | tail -1; }
proc_start() { awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null || :; }
same_process() {
    _spr_pid="$1" _spr_start="$2"
    _spr_now=$(proc_start "$_spr_pid")
    [ -n "$_spr_start" ] && [ "$_spr_now" = "$_spr_start" ]
}
safe_stop() {
    _ssp_pid="$1" _ssp_start="$2" _ssp_n=0
    same_process "$_ssp_pid" "$_ssp_start" || return 0
    command kill -TERM "$_ssp_pid" 2>/dev/null || :
    while [ "$_ssp_n" -lt 3 ] && same_process "$_ssp_pid" "$_ssp_start"; do sleep 1; _ssp_n=$((_ssp_n + 1)); done
    if same_process "$_ssp_pid" "$_ssp_start"; then
        command kill -KILL "$_ssp_pid" 2>/dev/null || :
        _ssp_n=0
        while [ "$_ssp_n" -lt 2 ] && same_process "$_ssp_pid" "$_ssp_start"; do sleep 1; _ssp_n=$((_ssp_n + 1)); done
    fi
    ! same_process "$_ssp_pid" "$_ssp_start"
}
wait_parent_bounded() {
    _wpb_pid="$1" _wpb_limit="${2:-10}" _wpb_n=0
    while command kill -0 "$_wpb_pid" 2>/dev/null; do
        [ "$_wpb_n" -lt "$_wpb_limit" ] || return 1
        sleep 1
        _wpb_n=$((_wpb_n + 1))
    done
    wait "$_wpb_pid" 2>/dev/null || :
    return 0
}

cat > "$FAKE_BASE/settings/var_settings.sh" <<EOF
VAR_SETTINGS_LOADED=1
TMPDIR="$TEST_ROOT/tmp"
LOCKDIR="$TEST_ROOT/locks"
export TMPDIR LOCKDIR
EOF
cat > "$FAKE_BASE/settings/lib_mervqt.sh" <<'EOF'
LIB_MERVQT_LOADED=1
merv_is_valid_node_id() { case "$1" in 1|2|3|4|5|6|7|8|9|10) return 0 ;; *) return 1 ;; esac; }
EOF
cp "$ROOT/settings/lib_identity.sh" "$FAKE_BASE/settings/lib_identity.sh" || exit 1

cat > "$TEST_ROOT/nodes" <<'EOF'
1 192.0.2.1
EOF

# The separate child is the real owning parent: it runs the production launch
# sequence and receives TERM while its production pending hook is active.
cat > "$TEST_ROOT/parent.sh" <<'EOF'
#!/bin/sh
set -u
MERV_BASE="$1"; CASE_ROOT="$2"; CASE_MODE="$3"; REPO_ROOT="$4"
export MERV_BASE CASE_ROOT CASE_MODE
. "$REPO_ROOT/settings/lib_node_jobs.sh" || exit 90
TRACE="$CASE_ROOT/trace"; STATE="$CASE_ROOT/state"; NODES="$CASE_ROOT/nodes"
export TRACE STATE NODES
merv_proc_start_time() {
    if [ "${CASE_MODE:-}" = identity-fail ] && [ -n "${MNJ_POOL_PENDING_PID:-}" ]; then
        printf 'identity-lookup-failed\n' >> "$TRACE"
        return 1
    fi
    merv_identity_proc_start "$1" "${2:-/proc}"
}
merv_process_identity_matches() { merv_identity_matches "$1" "$2" "${3:-/proc}"; }
kill() {
    printf 'kill %s\n' "$*" >> "$TRACE"
    command kill "$@"
}
save_state() {
    printf 'active=%s\npending_pid=%s\npending_start=%s\npending_dir=%s\npending_node=%s\nslot_pid=%s\nreplacement=%s\ncleanup_rc=%s\n' \
        "${MNJ_POOL_ACTIVE:-}" "${MNJ_POOL_PENDING_PID:-}" "${MNJ_POOL_PENDING_START:-}" "${MNJ_POOL_PENDING_DIR:-}" "${MNJ_POOL_PENDING_NODE:-}" "${MNJ_S1_PID:-}" "${REPLACEMENT_RC:-}" "${CLEANUP_RC:-}" > "$STATE"
}
parent_cleanup() {
    CLEANUP_RC=0
    mnj_pool_abort_active timeout pending-parent-term || CLEANUP_RC=$?
    if [ "${CASE_MODE:-}" = identity-fail ]; then
        REPLACEMENT_RC=0
        mnj_pool_run "$CASE_ROOT/replacement" pending 1 5 "$NODES" worker_long || REPLACEMENT_RC=$?
    fi
    save_state
    exit 0
}
trap parent_cleanup TERM INT
worker_long() {
    trap 'printf "worker-term\n" >> "$TRACE"; exit 0' TERM INT
    printf 'worker-start\n' >> "$TRACE"
    while :; do printf 'mutation\n' >> "$TRACE"; sleep 1; done
}
worker_short() { printf 'worker-start\nmutation\n' >> "$TRACE"; return 0; }
pending_hook() {
    case "$CASE_MODE" in
        term|identity-fail)
            # Keep the wrapper in the exact parent-pending window, but wait
            # until its child identity file exists so P1 can prove cleanup of
            # both the wrapper and a live fake handler rather than exercising
            # a separate child-publication race.
            _hook_n=0
            while [ ! -s "$2/child.pid" ]; do
                [ "$_hook_n" -lt 5 ] || exit 91
                sleep 1
                _hook_n=$((_hook_n + 1))
            done
            ;;
        exited)
            # Publish the observation first, then hold the parent before its
            # start lookup while the short worker exits naturally.
            printf 'pending pid=%s dir=%s node=%s start=%s\n' "$1" "$2" "$3" "${MNJ_POOL_PENDING_START:-}" > "$CASE_ROOT/pending"
            sleep 5
            return 0
            ;;
        normal) : ;;
    esac
    printf 'pending pid=%s dir=%s node=%s start=%s\n' "$1" "$2" "$3" "${MNJ_POOL_PENDING_START:-}" > "$CASE_ROOT/pending"
    case "$CASE_MODE" in term|identity-fail) while :; do sleep 1; done ;; esac
}
MNJ_POOL_PENDING_HOOK=pending_hook
export MNJ_POOL_PENDING_HOOK
case "$CASE_MODE" in
    normal) mnj_pool_run "$CASE_ROOT/pool" pending 1 5 "$NODES" worker_short; POOL_RC=$?; CLEANUP_RC="$POOL_RC"; REPLACEMENT_RC=''; save_state; exit "$POOL_RC" ;;
    exited) mnj_pool_run "$CASE_ROOT/pool" pending 1 5 "$NODES" worker_short; POOL_RC=$?; CLEANUP_RC="$POOL_RC"; REPLACEMENT_RC=''; save_state; exit "$POOL_RC" ;;
    *) mnj_pool_run "$CASE_ROOT/pool" pending 1 60 "$NODES" worker_long; exit $? ;;
esac
EOF
chmod +x "$TEST_ROOT/parent.sh"

prepare_case() {
    _pc_name="$1"
    mkdir -p "$TEST_ROOT/tmp/node_jobs/$_pc_name"
    cp "$TEST_ROOT/nodes" "$TEST_ROOT/tmp/node_jobs/$_pc_name/nodes"
    : > "$TEST_ROOT/tmp/node_jobs/$_pc_name/trace"
}
launch_case() {
    _lc_name="$1" _lc_mode="$2"
    "$TEST_ROOT/parent.sh" "$FAKE_BASE" "$TEST_ROOT/tmp/node_jobs/$_lc_name" "$_lc_mode" "$ROOT" >"$TEST_ROOT/tmp/node_jobs/$_lc_name/parent.out" 2>&1 &
    CASE_PARENT_PID=$!
}
wait_for_pending() {
    _wfp_file="$1" _wfp_n=0
    while [ ! -s "$_wfp_file" ]; do
        [ "$_wfp_n" -lt 5 ] || return 1
        sleep 1
        _wfp_n=$((_wfp_n + 1))
    done
}

# P1: exact real-launch pending window, successful identity lookup and TERM.
prepare_case p1
launch_case p1 term
wait_for_pending "$TEST_ROOT/tmp/node_jobs/p1/pending" || fail 'P1 pending hook was not reached'
_p1_pid=$(sed -n 's/^pending pid=\([0-9][0-9]*\).*/\1/p' "$TEST_ROOT/tmp/node_jobs/p1/pending")
_p1_dir=$(sed -n 's/^pending pid=[0-9][0-9]* dir=\([^ ]*\).*/\1/p' "$TEST_ROOT/tmp/node_jobs/p1/pending")
[ -n "$_p1_pid" ] || fail 'P1 did not publish a pending PID'
_p1_child_pid=$(cat "$_p1_dir/child.pid" 2>/dev/null || :)
_p1_child_start=$(proc_start "$_p1_child_pid")
[ -n "$_p1_child_pid" ] && [ -n "$_p1_child_start" ] || fail 'P1 live fake child identity was not published'
_p1_begin=$(date +%s)
command kill -TERM "$CASE_PARENT_PID" || fail 'P1 could not TERM the owning parent'
wait_parent_bounded "$CASE_PARENT_PID" 8 || { safe_stop "$_p1_pid" "$(proc_start "$_p1_pid")" || :; fail 'P1 parent cleanup exceeded bounded deadline'; }
_p1_elapsed=$(( $(date +%s) - _p1_begin ))
require_file "$TEST_ROOT/tmp/node_jobs/p1/state"
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p1/state" cleanup_rc)" = 0 ] || fail 'P1 cleanup failed'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p1/state" active)" = 0 ] || fail 'P1 left active pool state'
[ -z "$(read_field "$TEST_ROOT/tmp/node_jobs/p1/state" pending_pid)" ] && [ -z "$(read_field "$TEST_ROOT/tmp/node_jobs/p1/state" slot_pid)" ] || fail 'P1 retained pending or slot metadata'
[ "$_p1_elapsed" -le 8 ] || fail 'P1 cleanup was not bounded'
[ ! -d "/proc/$_p1_pid" ] || fail 'P1 worker wrapper survived cleanup'
! same_process "$_p1_child_pid" "$_p1_child_start" || fail 'P1 worker child survived cleanup'
_p1_before=$(grep -c '^mutation$' "$TEST_ROOT/tmp/node_jobs/p1/trace" 2>/dev/null || :)
sleep 2
_p1_after=$(grep -c '^mutation$' "$TEST_ROOT/tmp/node_jobs/p1/trace" 2>/dev/null || :)
[ "$_p1_after" = "$_p1_before" ] || fail 'P1 fake mutation continued after cleanup'
grep -q '^worker-term$' "$TEST_ROOT/tmp/node_jobs/p1/trace" || fail 'P1 worker TERM path did not run'
printf 'PASS P1 resolved identity TERM elapsed=%ss\n' "$_p1_elapsed"

# P2: exact same window, but identity lookup is unavailable.  Parent must
# retain the claim and refuse a replacement; the harness then safely reaps it.
prepare_case p2
launch_case p2 identity-fail
wait_for_pending "$TEST_ROOT/tmp/node_jobs/p2/pending" || fail 'P2 pending hook was not reached'
_p2_pid=$(sed -n 's/^pending pid=\([0-9][0-9]*\).*/\1/p' "$TEST_ROOT/tmp/node_jobs/p2/pending")
_p2_start=$(proc_start "$_p2_pid")
[ -n "$_p2_pid" ] && [ -n "$_p2_start" ] || fail 'P2 pending worker identity unavailable to harness'
_p2_begin=$(date +%s)
command kill -TERM "$CASE_PARENT_PID" || fail 'P2 could not TERM the owning parent'
wait_parent_bounded "$CASE_PARENT_PID" 4 || { safe_stop "$_p2_pid" "$_p2_start" || :; fail 'P2 parent cleanup blocked'; }
_p2_elapsed=$(( $(date +%s) - _p2_begin ))
require_file "$TEST_ROOT/tmp/node_jobs/p2/state"
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p2/state" cleanup_rc)" != 0 ] || fail 'P2 cleanup unexpectedly succeeded'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p2/state" active)" = 1 ] || fail 'P2 cleared unresolved active state'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p2/state" pending_pid)" = "$_p2_pid" ] || fail 'P2 discarded pending ownership'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p2/state" replacement)" != 0 ] || fail 'P2 replacement pool was not refused'
[ "$_p2_elapsed" -le 4 ] || fail 'P2 cleanup was not prompt'
if grep -E "^kill (-TERM|-KILL) $_p2_pid$" "$TEST_ROOT/tmp/node_jobs/p2/trace" >/dev/null 2>&1; then
    fail 'P2 used a PID-only destructive signal while identity lookup failed'
fi
safe_stop "$_p2_pid" "$_p2_start" || fail 'P2 harness could not safely clean retained worker'
printf 'PASS P2 identity failure fail-closed elapsed=%ss\n' "$_p2_elapsed"

# P3: worker exits while the hook holds start publication; TERM then reaps
# terminal pending state without creating a false unresolved pool.
prepare_case p3
launch_case p3 exited
wait_for_pending "$TEST_ROOT/tmp/node_jobs/p3/pending" || fail 'P3 pending hook was not reached'
sleep 3
command kill -TERM "$CASE_PARENT_PID" || fail 'P3 could not TERM the owning parent'
wait_parent_bounded "$CASE_PARENT_PID" 5 || fail 'P3 terminal-worker cleanup exceeded deadline'
require_file "$TEST_ROOT/tmp/node_jobs/p3/state"
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p3/state" cleanup_rc)" = 0 ] || fail 'P3 cleanup failed for exited worker'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p3/state" active)" = 0 ] || fail 'P3 left an exited pending worker unresolved'
[ -z "$(read_field "$TEST_ROOT/tmp/node_jobs/p3/state" pending_pid)" ] || fail 'P3 retained terminal pending PID'
printf 'PASS P3 exited pending worker reconciled\n'

# P4: ordinary pending-to-slot publication remains a successful pool run.
prepare_case p4
launch_case p4 normal
wait_parent_bounded "$CASE_PARENT_PID" 8 || fail 'P4 normal pool did not finish'
require_file "$TEST_ROOT/tmp/node_jobs/p4/state"
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p4/state" cleanup_rc)" = 0 ] || fail 'P4 normal pool failed'
[ "$(read_field "$TEST_ROOT/tmp/node_jobs/p4/state" active)" = 0 ] || fail 'P4 normal pool remained active'
[ -z "$(read_field "$TEST_ROOT/tmp/node_jobs/p4/state" pending_pid)" ] && [ -z "$(read_field "$TEST_ROOT/tmp/node_jobs/p4/state" slot_pid)" ] || fail 'P4 retained pending or slot metadata'
printf 'PASS P4 normal pending-to-slot path\n'
printf 'NODE_PENDING_WORKER_RACE_CONTRACT_OK\n'
