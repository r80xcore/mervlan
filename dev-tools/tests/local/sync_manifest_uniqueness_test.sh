#!/bin/sh
# Sync and admission bootstrap manifests contain unique relative file paths.

set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/sync_nodes.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

manifest_value() {
    awk -v name="$1" '
      $0 == name "=\"" { inside=1; next }
      inside && $0 == "\"" { exit }
      inside { print }
    ' "$SOURCE"
}

check_unique() {
    _cm_name=$1
    _cm_value=$(manifest_value "$_cm_name")
    [ -n "$_cm_value" ] || fail "$_cm_name missing"
    check_unique_paths "$_cm_name" "$_cm_value"
}

check_unique_paths() {
    _cm_name=$1
    _cm_value=$2
    _cm_seen=' '
    for _cm_path in $_cm_value; do
        case "$_cm_path" in
          ''|/*|*..*|*//*|*[!A-Za-z0-9_./-]*) fail "$_cm_name unsafe path $_cm_path" ;;
        esac
        case "$_cm_seen" in *" $_cm_path "*) fail "$_cm_name duplicate $_cm_path" ;; esac
        for _cm_prior in $_cm_seen; do
            case "$_cm_path" in "$_cm_prior"/*) fail "$_cm_name parent/child ambiguity $_cm_prior -> $_cm_path" ;; esac
            case "$_cm_prior" in "$_cm_path"/*) fail "$_cm_name parent/child ambiguity $_cm_path -> $_cm_prior" ;; esac
        done
        _cm_seen="$_cm_seen$_cm_path "
    done
    pass "$_cm_name has unique safe relative paths"
}

check_unique FILES_TO_COPY
check_unique FILES_TO_COPY_CHMOD
check_unique FILES_TO_COPY_CHMOD_644
check_unique SYNC_NODE_ADMISSION_FILES

_exec_manifest=$(awk '
  $0 == "EXEC_NODE_GUARD_FILES=\"" { inside=1; next }
  inside && $0 == "\"" { exit }
  inside { print }
' "$BASE_DIR/functions/execute_nodes.sh")
check_unique_paths EXEC_NODE_GUARD_FILES "$_exec_manifest"

# Execute may require only runtime files guaranteed by normal full Sync. There
# are no separately provisioned NODE-only capability exceptions today.
_sync_runtime_manifest=$(manifest_value FILES_TO_COPY | awk 'NF { print $1 }')
for _required in $_exec_manifest; do
    printf '%s\n' "$_sync_runtime_manifest" | grep -F -x "$_required" >/dev/null || \
      fail "Execute requires $_required, which full Sync does not deploy"
done
pass 'Execute prerequisite cohort is a subset of the full Sync runtime manifest'

_dispatcher_count=$(manifest_value FILES_TO_COPY | awk '$0 == "functions/mervlan_node_mutate.sh" { n++ } END { print n+0 }')
[ "$_dispatcher_count" -eq 1 ] || fail 'node mutation dispatcher must appear once in FILES_TO_COPY'

_bootstrap=$(manifest_value SYNC_NODE_ADMISSION_FILES)
_expected='settings/lib_selftest_context.sh
settings/lib_identity.sh
settings/lib_owner_lock.sh
settings/lib_action_lock.sh
settings/lib_update_state.sh
settings/lib_full_fence.sh
settings/lib_continuation.sh
settings/lib_mutation_admission.sh
functions/mervlan_node_mutate.sh'
[ "$_bootstrap" = "$_expected" ] || fail 'bootstrap cohort differs from the audited minimal source cohort'

printf '%s\n' 'SYNC_MANIFEST_UNIQUENESS_OK'
