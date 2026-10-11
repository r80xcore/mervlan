#!/bin/sh
# Exercise inert NODE bootstrap transport and the guarded first mutation.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/sync_nodes.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-admission.$$"
RUN_ID="$(date +%s 2>/dev/null || printf 700)-$$"
REMOTE_PARENT="/tmp/.mervlan-node-admission.$RUN_ID.1"
REMOTE_COHORT="$REMOTE_PARENT/cohort"
F_TEST="$TEST_ROOT/full.lock"
M_TEST="$TEST_ROOT/locks/mervlan_maintenance.lock"
_m_nonce=
_f_nonce=
_f_start=
_archive_parent=

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cleanup() {
    [ -z "$_f_nonce" ] || merv_full_fence_release "$F_TEST" "$$" "$_f_start" "$_f_nonce" >/dev/null 2>&1 || :
    [ -z "$_m_nonce" ] || merv_owner_lock_release "$M_TEST" "$_m_nonce" >/dev/null 2>&1 || :
    if [ -n "$_archive_parent" ] && [ -d "$_archive_parent" ] && [ ! -L "$_archive_parent" ]; then
        _owner="$_archive_parent/.owner"
        if [ -f "$_owner" ] && [ ! -L "$_owner" ] &&
           [ "$(sed -n '1p' "$_owner" 2>/dev/null)" = format=mervlan-node-admission-v1 ] &&
           [ "$(sed -n '2p' "$_owner" 2>/dev/null)" = "run=$RUN_ID" ] &&
           [ "$(sed -n '3p' "$_owner" 2>/dev/null)" = node=1 ]; then
            rm -rf "$_archive_parent"
        fi
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/continuations" "$TEST_ROOT/state/ssh_trust" \
  "$TEST_ROOT/nodefs" "$TEST_ROOT/bin" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" "$TEST_ROOT/continuations" \
  "$TEST_ROOT/state" "$TEST_ROOT/state/ssh_trust" "$TEST_ROOT/nodefs" "$TEST_ROOT/bin" || exit 1

. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
. "$BASE_DIR/settings/lib_selftest_context.sh" || exit 1
merv_selftest_context_create "$TEST_ROOT" || exit 1
MERVLAN_SELFTEST_CONTEXT=$MERVLAN_SELFTEST_CONTEXT
export MERVLAN_SELFTEST_CONTEXT
MERV_BASE=$BASE_DIR
MERV_STATE_ROOT="$TEST_ROOT/state"
MERV_ACTION_LOCK_PATH="$TEST_ROOT/locks/mervlan_action.lock"
MERV_ACTION_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
MERVLAN_MAINTENANCE_LOCK_OVERRIDE=$M_TEST
MERV_FULL_FENCE_PATH=$F_TEST
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
export MERV_BASE MERV_STATE_ROOT MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT
export MERV_OWNER_LOCK_PROC_ROOT MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE MERV_FULL_FENCE_PATH MERV_CONTINUATION_ROOT

. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_action_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_full_fence.sh" || exit 1
. "$BASE_DIR/settings/lib_continuation.sh" || exit 1
. "$BASE_DIR/settings/lib_mutation_admission.sh" || exit 1
. "$BASE_DIR/settings/lib_ssh.sh" || exit 1

cat > "$TEST_ROOT/bin/nvram" <<'EOF'
#!/bin/sh
case "${1:-}:${2:-}" in get:jffs2_on|get:jffs2_scripts) echo 1 ;; *) exit 1 ;; esac
EOF
chmod 700 "$TEST_ROOT/bin/nvram"
PATH="$TEST_ROOT/bin:$PATH"
export PATH

# Local transport fixture executes only the generated remote command. It does
# not replace the real dispatcher, cohort verifier, or admission libraries.
merv_ssh_exec() {
    [ "$#" -eq 3 ] || return 64
    sh -c "$3"
}
merv_ssh_stream_stdin() {
    [ "$#" -eq 3 ] || return 64
    sh -c "$3"
}

SYNC_NODE_ADMISSION_FILES=$(awk '
  $0 == "SYNC_NODE_ADMISSION_FILES=\"" { inside=1; next }
  inside && $0 == "\"" { exit }
  inside { printf "%s ", $1 }
' "$SOURCE")
[ -n "$SYNC_NODE_ADMISSION_FILES" ] || fail missing-bootstrap-manifest
SYNC_RUN_ID=$RUN_ID
eval "$(sed -n '/^sync_node_admission_digest()/,/^# ========================================================================== #/p' "$SOURCE" | sed '$d')"

# The fixture starts as a blank NODE: no active MerVLAN tree or new admission
# library exists. The private source cohort is the only library source.
MERV_BASE=$BASE_DIR
sync_node_admission_freeze 1 || fail freeze-cohort
_archive_parent=$REMOTE_PARENT
[ "$(LC_ALL=C ls -ldn "$MERV_NODE_MUTATE_SOURCE_ROOT" | awk '{print $1}')" = drwx------ ] || fail local-root-mode
sync_node_admission_stage 1 192.0.2.1 || fail stage-and-verify-bootstrap
[ -f "$REMOTE_COHORT/functions/mervlan_node_mutate.sh" ] || fail staged-dispatcher
[ -f "$REMOTE_COHORT/settings/lib_mutation_admission.sh" ] || fail staged-admission-library
[ ! -e "$TEST_ROOT/nodefs/mervlan_backups" ] || fail 'bootstrap modified active state before admission'
[ ! -e "$MERV_ACTION_LOCK_PATH" ] || fail 'bootstrap verification acquired a target mutation owner'
[ ! -e "$TEST_ROOT/nodefs/mervlan" ] || fail 'bootstrap created an active MerVLAN tree'
pass 'blank/old NODE receives and verifies an inert admission cohort'

# A partial workspace left by an interrupted transfer is inert and must never
# be resumed or silently replaced as part of a later same-token operation.
mv "$REMOTE_COHORT/settings/lib_identity.sh" "$TEST_ROOT/bootstrap-lib.saved" || fail partial-save
if sync_node_admission_stage 1 192.0.2.1 >/dev/null 2>&1; then
    fail 'partial pre-existing bootstrap workspace was reused'
fi
[ ! -e "$REMOTE_COHORT/settings/lib_identity.sh" ] || fail 'stager replaced or resumed partial workspace'
mv "$TEST_ROOT/bootstrap-lib.saved" "$REMOTE_COHORT/settings/lib_identity.sh" || fail partial-restore
chmod 600 "$REMOTE_COHORT/settings/lib_identity.sh" || fail partial-restore-mode
pass 'interrupted partial bootstrap workspace remains inert and is not reused'

# Exclusion appearing after inert staging still blocks the very first guarded
# operation; only the code-source workspace may remain.
merv_full_fence_claim "$F_TEST" || fail claim-pre-first-operation-fence
_f_nonce=$MERV_FULL_FENCE_NONCE
_f_start=$MERV_FULL_FENCE_START
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] && [ ! -e "$TEST_ROOT/nodefs/mervlan_backups" ] || fail 'F allowed the first active Sync mutation'
merv_full_fence_release "$F_TEST" "$$" "$_f_start" "$_f_nonce" || fail release-pre-first-operation-fence
_f_nonce=
merv_owner_lock_acquire "$M_TEST" 0 0 bootstrap-pre-first-m-test || fail claim-pre-first-operation-maintenance
_m_nonce=$MERV_LOCK_NONCE
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] && [ ! -e "$TEST_ROOT/nodefs/mervlan_backups" ] || fail 'M allowed the first active Sync mutation'
merv_owner_lock_release "$M_TEST" "$_m_nonce" || fail release-pre-first-operation-maintenance
_m_nonce=
pass 'F and M appearing after inert staging block the first active mutation'

_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -eq 0 ] || fail "guarded first prepare-stage failed: $_out"
case "$_out" in *SYNC_STAGE_READY*) ;; *) fail "first guarded operation did not prepare the stage: $_out" ;; esac
_stage="$TEST_ROOT/nodefs/mervlan_backups/.mervlan.new.$RUN_ID.1"
[ -d "$_stage" ] || fail missing-node-stage
pass 'old/blank NODE performs its first active mutation under local R and admission'

printf '%s\n' 'bootstrap payload' > "$TEST_ROOT/payload" || fail payload
merv_ssh_node_mutate_stream 1 192.0.2.1 put-stage-file "$RUN_ID" 1 functions/bootstrap-test.sh \
  < "$TEST_ROOT/payload" >/dev/null || fail streamed-stage-write
cmp -s "$TEST_ROOT/payload" "$_stage/functions/bootstrap-test.sh" || fail staged-payload-mismatch
pass 'streamed Sync writes remain inside the guarded target operation'

_package="$TEST_ROOT/package"
mkdir -p "$_package/settings" "$_package/functions" || fail package-dirs
printf '%s\n' '{"Hardware":{},"General":{}}' > "$_package/settings/settings.json" || fail package-settings
cp "$BASE_DIR/settings/lib_json.sh" "$_package/settings/lib_json.sh" || fail package-json
for _rel in lib_selftest_context.sh lib_identity.sh lib_owner_lock.sh lib_action_lock.sh \
  lib_update_state.sh lib_full_fence.sh lib_continuation.sh lib_mutation_admission.sh; do
    cp "$BASE_DIR/settings/$_rel" "$_package/settings/$_rel" || fail "package-$_rel"
done
cat > "$_package/settings/lib_boot_integrity.sh" <<'EOF'
merv_boot_read_preference() { printf '0\n'; }
merv_boot_verify_local() { return 0; }
EOF
cat > "$_package/functions/mervlan_boot.sh" <<'EOF'
#!/bin/sh
case "${1:-}" in
  nodeenable|disable) exit 0 ;;
  report) printf '%s\n' 'addon=node-on event=active boot=0 cron=absent manager_hook=absent' ;;
  *) exit 1 ;;
esac
EOF
cat > "$_package/functions/hw_probe.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cp "$BASE_DIR/functions/mervlan_node_mutate.sh" "$_package/functions/mervlan_node_mutate.sh" || fail package-dispatcher
chmod 755 "$_package/functions/mervlan_boot.sh" "$_package/functions/hw_probe.sh" \
  "$_package/functions/mervlan_node_mutate.sh" || fail package-executable-mode
tar -cf "$TEST_ROOT/runtime.tar" -C "$_package" \
  settings/settings.json settings/lib_json.sh settings/lib_boot_integrity.sh \
  settings/lib_selftest_context.sh settings/lib_identity.sh settings/lib_owner_lock.sh \
  settings/lib_action_lock.sh settings/lib_update_state.sh settings/lib_full_fence.sh \
  settings/lib_continuation.sh settings/lib_mutation_admission.sh \
  functions/mervlan_node_mutate.sh functions/mervlan_boot.sh functions/hw_probe.sh || fail package-tar
merv_ssh_node_mutate_stream 1 192.0.2.1 extract-stage "$RUN_ID" 1 \
  settings/settings.json settings/lib_json.sh settings/lib_boot_integrity.sh \
  settings/lib_selftest_context.sh settings/lib_identity.sh settings/lib_owner_lock.sh \
  settings/lib_action_lock.sh settings/lib_update_state.sh settings/lib_full_fence.sh \
  settings/lib_continuation.sh settings/lib_mutation_admission.sh \
  functions/mervlan_node_mutate.sh functions/mervlan_boot.sh functions/hw_probe.sh \
  < "$TEST_ROOT/runtime.tar" >/dev/null || fail guarded-runtime-extract
merv_ssh_node_mutate_exec 1 192.0.2.1 finalize-stage "$RUN_ID" 1 \
  644:settings/settings.json 644:settings/lib_json.sh 644:settings/lib_boot_integrity.sh \
  644:settings/lib_selftest_context.sh 644:settings/lib_identity.sh 644:settings/lib_owner_lock.sh \
  644:settings/lib_action_lock.sh 644:settings/lib_update_state.sh 644:settings/lib_full_fence.sh \
  644:settings/lib_continuation.sh 644:settings/lib_mutation_admission.sh \
  755:functions/mervlan_node_mutate.sh 755:functions/mervlan_boot.sh 755:functions/hw_probe.sh \
  >/dev/null || fail guarded-runtime-finalize
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 activate-full "$RUN_ID" 1 2>&1) || fail "guarded blank-node activation failed: $_out"
case "$_out" in *STAGED_NODE_OK*) ;; *) fail "blank-node Sync activation did not complete: $_out" ;; esac
[ -f "$TEST_ROOT/nodefs/mervlan/settings/lib_mutation_admission.sh" ] || fail active-admission-library-missing
[ -x "$TEST_ROOT/nodefs/mervlan/functions/mervlan_node_mutate.sh" ] || fail active-dispatcher-missing
pass 'blank-node guarded Sync stage, runtime installation, and activation complete'

# An old active install can contain an incompatible lib_full_fence. The
# dispatcher must source the frozen fence before update_state can opportunistically
# source from MERV_BASE, otherwise an active F would be missed.
cat > "$TEST_ROOT/nodefs/mervlan/settings/lib_full_fence.sh" <<'EOF'
LIB_FULL_FENCE_LOADED=1
merv_full_fence_classify() { printf 'absent\n'; }
EOF
chmod 600 "$TEST_ROOT/nodefs/mervlan/settings/lib_full_fence.sh" || fail stale-active-fence-mode

# F and M appearing after inert staging must block before the next active
# filesystem operation. The code-only workspace remains present and inert.
merv_full_fence_claim "$F_TEST" || fail claim-test-fence
_f_nonce=$MERV_FULL_FENCE_NONCE
_f_start=$MERV_FULL_FENCE_START
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] || fail 'Full fence allowed a NODE mutation'
[ ! -e "$_stage" ] || fail 'F-blocked mutation created a stage'
merv_full_fence_release "$F_TEST" "$$" "$_f_start" "$_f_nonce" || fail release-test-fence
_f_nonce=
pass 'F appearing after bootstrap staging blocks before active mutation'

merv_owner_lock_acquire "$M_TEST" 0 0 bootstrap-m-test || fail claim-test-maintenance
_m_nonce=$MERV_LOCK_NONCE
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] || fail 'maintenance M allowed a NODE mutation'
[ ! -e "$_stage" ] || fail 'M-blocked mutation created a stage'
merv_owner_lock_release "$M_TEST" "$_m_nonce" || fail release-test-maintenance
_m_nonce=
pass 'M appearing after bootstrap staging blocks before active mutation'

# A malformed F object and an obstructed M path are also fail-closed.
: > "$F_TEST" || fail malformed-fence-fixture
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] && [ ! -e "$_stage" ] || fail 'malformed F did not block cleanly'
rm -f "$F_TEST" || fail remove-malformed-fence
ln -s "$TEST_ROOT/foreign-m-owner" "$M_TEST" || fail malformed-maintenance-fixture
_out=$(merv_ssh_node_mutate_exec 1 192.0.2.1 prepare-stage "$RUN_ID" 1 2>&1)
_rc=$?
[ "$_rc" -ne 0 ] && [ ! -e "$_stage" ] || fail 'obstructed M did not block cleanly'
rm -f "$M_TEST" || fail remove-malformed-maintenance
pass 'malformed F and obstructed M remain fail-closed'

# Tampering with a transferred library, a duplicate expected member, or a
# symlink member prevents verification before the dispatcher sources code.
printf '%s\n' '# tampered' >> "$REMOTE_COHORT/settings/lib_mutation_admission.sh" || fail tamper-library
if merv_ssh_node_mutate_exec 1 192.0.2.1 verify-bootstrap-cohort "$RUN_ID" 1 >/dev/null 2>&1; then
    fail 'tampered target bootstrap library was accepted'
fi
cp "$MERV_NODE_MUTATE_SOURCE_ROOT/settings/lib_mutation_admission.sh" \
  "$REMOTE_COHORT/settings/lib_mutation_admission.sh" || fail restore-library
chmod 600 "$REMOTE_COHORT/settings/lib_mutation_admission.sh" || fail restore-library-mode
_saved_manifest=$MERV_NODE_MUTATE_BOOTSTRAP_MANIFEST
MERV_NODE_MUTATE_BOOTSTRAP_MANIFEST="$_saved_manifest$_saved_manifest"
if merv_ssh_node_mutate_exec 1 192.0.2.1 verify-bootstrap-cohort "$RUN_ID" 1 >/dev/null 2>&1; then
    fail 'duplicate expected cohort members were accepted'
fi
MERV_NODE_MUTATE_BOOTSTRAP_MANIFEST=$_saved_manifest
mv "$REMOTE_COHORT/settings/lib_identity.sh" "$TEST_ROOT/lib_identity.saved" || fail save-member
ln -s "$TEST_ROOT/lib_identity.saved" "$REMOTE_COHORT/settings/lib_identity.sh" || fail symlink-member
if merv_ssh_node_mutate_exec 1 192.0.2.1 verify-bootstrap-cohort "$RUN_ID" 1 >/dev/null 2>&1; then
    fail 'symlink bootstrap member was accepted'
fi
rm -f "$REMOTE_COHORT/settings/lib_identity.sh" || fail unlink-member
mv "$TEST_ROOT/lib_identity.saved" "$REMOTE_COHORT/settings/lib_identity.sh" || fail restore-member
chmod 600 "$REMOTE_COHORT/settings/lib_identity.sh" || fail restore-member-mode
pass 'tampered, duplicate, and symlink bootstrap members are rejected'

# An unexpected pre-existing workspace object is never followed or replaced.
_saved_source_root=$MERV_NODE_MUTATE_SOURCE_ROOT
_saved_remote_root=$MERV_NODE_MUTATE_BOOTSTRAP_ROOT
_saved_manifest=$MERV_NODE_MUTATE_BOOTSTRAP_MANIFEST
_saved_run=$MERV_NODE_MUTATE_BOOTSTRAP_RUN
_saved_node=$MERV_NODE_MUTATE_BOOTSTRAP_NODE
_obstruction_run=$RUN_ID
SYNC_RUN_ID=$_obstruction_run
sync_node_admission_freeze 2 || fail obstruction-freeze
_obstruction_parent="/tmp/.mervlan-node-admission.$_obstruction_run.2"
ln -s "$TEST_ROOT" "$_obstruction_parent" || fail obstruction-create
if sync_node_admission_stage 2 192.0.2.2 >/dev/null 2>&1; then fail 'bootstrap followed a symlinked workspace'; fi
[ -L "$_obstruction_parent" ] || fail 'bootstrap replaced the obstructing symlink'
rm -f "$_obstruction_parent" || fail obstruction-remove
sync_node_admission_local_cleanup || fail obstruction-local-cleanup
MERV_NODE_MUTATE_SOURCE_ROOT=$_saved_source_root
MERV_NODE_MUTATE_BOOTSTRAP_ROOT=$_saved_remote_root
MERV_NODE_MUTATE_BOOTSTRAP_MANIFEST=$_saved_manifest
MERV_NODE_MUTATE_BOOTSTRAP_RUN=$_saved_run
MERV_NODE_MUTATE_BOOTSTRAP_NODE=$_saved_node
MERV_NODE_MUTATE_BOOTSTRAP_ACTIVE=1
SYNC_RUN_ID=$RUN_ID
pass 'symlinked workspace obstruction is refused and preserved'

# Retire only the exact successful workspace. No automatic cleanup is needed
# for inert files when the parent/SSH transaction ends ambiguously.
merv_ssh_node_mutate_exec 1 192.0.2.1 cleanup-bootstrap-cohort "$RUN_ID" 1 >/dev/null || fail exact-bootstrap-cleanup
[ ! -e "$REMOTE_PARENT" ] && [ ! -L "$REMOTE_PARENT" ] || fail bootstrap-workspace-remains
_archive_parent=
pass 'successful Sync can retire only its exact run-bound inert workspace'

printf '%s\n' 'NODE_ADMISSION_BOOTSTRAP_OK'
