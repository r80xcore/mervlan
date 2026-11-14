#!/bin/sh
# Behavioral contract test for the SSH bootstrap documented in docs/HELP.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-bootstrap-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

CASE="$WORK/case"
BOOT_ROOT="$CASE/bootstrap"
BIN="$CASE/bin"
SCRIPT="$CASE/bootstrap.sh"
mkdir -p "$BOOT_ROOT" "$BIN"

# Extract and execute the documented fenced command instead of matching its
# former one-line spelling. The temporary-root substitution confines all
# workspace creation and cleanup to this test fixture.
awk '
  /^```sh$/ { in_shell_fence=1; next }
  in_shell_fence && /^BRANCH="pre_v0\.53\.29-RC3-repair-test"$/ { capture=1 }
  capture && /^```$/ { exit }
  capture { print }
' "$ROOT/docs/HELP.md" >"$WORK/bootstrap.template"
[ -s "$WORK/bootstrap.template" ] || fail 'documented bootstrap block missing'
if grep -Eq '(^|[[:space:]/])mktemp([[:space:]]|$)' "$WORK/bootstrap.template"; then
    fail 'documented bootstrap retains a mktemp command dependency'
fi

VALID_BRANCH=pre_v0.53.29-RC3-repair-test
make_bootstrap() {
    _mb_branch=$1
    sed -e "s|^BRANCH=\"pre_v0.53.29-RC3-repair-test\"$|BRANCH=\"$_mb_branch\"|" \
        -e "s|/tmp/mervlan-bootstrap\\.|$BOOT_ROOT/mervlan-bootstrap.|g" \
        "$WORK/bootstrap.template" >"$SCRIPT" || fail 'could not prepare isolated bootstrap copy'
    /bin/sh -n "$SCRIPT" || fail 'documented bootstrap shell syntax failed'
}

REAL_MKDIR=$(command -v mkdir)
cat >"$BIN/mkdir" <<'EOF'
#!/bin/sh
[ -n "${MERV_MKDIR_LOG:-}" ] && printf '%s\n' "$1" >>"$MERV_MKDIR_LOG"
case "${MERV_MKDIR_TEST_MODE:-pass}" in
  collision_once)
    if [ ! -e "$MERV_MKDIR_MARKER" ]; then
      : >"$MERV_MKDIR_MARKER"
      "$MERV_REAL_MKDIR" "$1" || exit 1
      printf '%s\n' 'foreign collision sentinel' >"$1/.collision-sentinel" || exit 1
      "$MERV_REAL_MKDIR" "$1" >/dev/null 2>&1 && exit 0
      exit 1
    fi
    ;;
  collision_all)
    _mmt_count=$(wc -l <"$MERV_MKDIR_LOG" | tr -d ' ')
    if [ "$_mmt_count" -le 8 ]; then
      "$MERV_REAL_MKDIR" "$1" || exit 1
      printf '%s\n' 'foreign collision sentinel' >"$1/.collision-sentinel" || exit 1
      "$MERV_REAL_MKDIR" "$1" >/dev/null 2>&1 && exit 0
      exit 1
    fi
    ;;
esac
exec "$MERV_REAL_MKDIR" "$@"
EOF
chmod 755 "$BIN/mkdir"

cat >"$BIN/mktemp" <<'EOF'
#!/bin/sh
: >"$MERV_MKTEMP_LOG"
exit 99
EOF
chmod 755 "$BIN/mktemp"

cat >"$BIN/curl" <<'EOF'
#!/bin/sh
out= proto= proto_redir= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=${2:-}; shift 2 ;;
        --proto) proto=${2:-}; shift 2 ;;
        --proto-redir) proto_redir=${2:-}; shift 2 ;;
        https://*|http://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 91
printf 'proto=%s proto_redir=%s url=%s out=%s\n' \
    "$proto" "$proto_redir" "$url" "$out" >>"$MERV_CURL_LOG"
[ "$proto" = '=https' ] && [ "$proto_redir" = '=https' ] || exit 92
case "$url" in https://*) : ;; *) exit 93 ;; esac

case "$out" in
    */repair.sh)
        _curl_workspace=${out%/*}
        [ -d "$_curl_workspace" ] || exit 94
        _curl_mode=$(stat -c '%a' "$_curl_workspace" 2>/dev/null) || exit 95
        [ "$_curl_mode" = 700 ] || exit 96
        printf '%s\n' "$_curl_workspace" >"$MERV_WORKSPACE_CAPTURE"
        printf '%s\n' "$_curl_mode" >"$MERV_WORKSPACE_MODE"
        case "$MERV_CURL_MODE" in
            simple_success|simple_engine_failure)
                cp "$MERV_SIMPLE_ENGINE" "$out" || exit 97
                ;;
            simple_download_failure) exit 22 ;;
            simple_bad_syntax)
                printf '%s\n' '#!/bin/sh' \
                    'printf "executed\\n" >"$MERV_SIMPLE_ENGINE_MARKER"' \
                    'if then' >"$out"
                ;;
            full_success|full_unsafe_root)
                cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" || exit 97
                ;;
            full_missing) : ;;
            full_symlink) ln -s "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" || exit 98 ;;
            full_download_failure) exit 22 ;;
            full_snapshot_failure) cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" || exit 97 ;;
            *) exit 90 ;;
        esac
        ;;
    *)
        case "$MERV_CURL_MODE" in
            full_success|full_unsafe_root|full_missing|full_symlink|full_download_failure)
                cp "$MERV_REPAIR_FIXTURE_ARCHIVE" "$out" || exit 97
                ;;
            full_snapshot_failure) exit 23 ;;
            *) exit 90 ;;
        esac
        ;;
esac
EOF
chmod 755 "$BIN/curl"

SIMPLE_ENGINE="$CASE/simple-engine.sh"
cat >"$SIMPLE_ENGINE" <<'EOF'
#!/bin/sh
[ "${1:-}" = "$MERV_EXPECTED_BRANCH" ] || exit 19
[ -z "${MERV_SIMPLE_ENGINE_MARKER:-}" ] || printf '%s\n' executed >"$MERV_SIMPLE_ENGINE_MARKER"
exit "${MERV_SIMPLE_ENGINE_RC:-0}"
EOF
chmod 755 "$SIMPLE_ENGINE"

CURL_MODE=simple_success
MKDIR_MODE=pass
ENGINE_RC=0
EXPECTED_BRANCH=$VALID_BRANCH
reset_logs() {
    rm -f "$CASE/curl.log" "$CASE/mkdir.log" "$CASE/mkdir.marker" \
        "$CASE/workspace.capture" "$CASE/workspace.mode" "$CASE/mktemp.log" \
        "$CASE/simple-engine.marker"
}
run_bootstrap() {
    _rb_log=$1
    if env \
        PATH="$BIN:$PATH" \
        MERV_REAL_MKDIR="$REAL_MKDIR" \
        MERV_MKDIR_LOG="$CASE/mkdir.log" \
        MERV_MKDIR_MARKER="$CASE/mkdir.marker" \
        MERV_MKDIR_TEST_MODE="$MKDIR_MODE" \
        MERV_MKTEMP_LOG="$CASE/mktemp.log" \
        MERV_CURL_LOG="$CASE/curl.log" \
        MERV_CURL_MODE="$CURL_MODE" \
        MERV_WORKSPACE_CAPTURE="$CASE/workspace.capture" \
        MERV_WORKSPACE_MODE="$CASE/workspace.mode" \
        MERV_SIMPLE_ENGINE="$SIMPLE_ENGINE" \
        MERV_EXPECTED_BRANCH="$EXPECTED_BRANCH" \
        MERV_SIMPLE_ENGINE_RC="$ENGINE_RC" \
        MERV_SIMPLE_ENGINE_MARKER="$CASE/simple-engine.marker" \
        MERV_REPAIR_BOOTSTRAP_ENTRY="$REPAIR" \
        MERV_REPAIR_FIXTURE_ARCHIVE="$CASE/fixture.tar.gz" \
        MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
        /bin/sh "$SCRIPT" >"$_rb_log" 2>&1
    then RUN_RC=0; else RUN_RC=$?; fi
}
curl_count() { [ -f "$CASE/curl.log" ] && wc -l <"$CASE/curl.log" | tr -d ' ' || printf '0\n'; }
mkdir_count() { [ -f "$CASE/mkdir.log" ] && wc -l <"$CASE/mkdir.log" | tr -d ' ' || printf '0\n'; }
assert_no_mktemp() { [ ! -e "$CASE/mktemp.log" ] || fail 'bootstrap invoked the mktemp stub'; }
assert_private_workspace() {
    [ -f "$CASE/workspace.capture" ] || fail 'curl did not observe an allocated workspace'
    _apw_path=$(cat "$CASE/workspace.capture")
    case "$_apw_path" in "$BOOT_ROOT"/mervlan-bootstrap.*) : ;; *) fail 'bootstrap workspace escaped the isolated root' ;; esac
    [ "$(cat "$CASE/workspace.mode")" = 700 ] || fail 'workspace was not private mode 0700 while in use'
}
assert_transport_log() {
    [ -s "$CASE/curl.log" ] || fail 'curl was not invoked'
    if ! awk '
      {
        if ($1 != "proto==https" || $2 != "proto_redir==https" || $3 !~ /^url=https:\/\//) exit 1
        count++
      }
      END { if (count == 0) exit 1 }
    ' "$CASE/curl.log"; then fail 'a download did not require HTTPS for initial and redirected URLs'; fi
}
assert_retained_evidence() {
    _are_log=$1 _are_rc=$2 _are_expect_file=$3
    [ -f "$CASE/workspace.capture" ] || fail 'failed bootstrap did not record its allocated workspace'
    _are_path=$(cat "$CASE/workspace.capture")
    [ -d "$_are_path" ] || fail 'failed bootstrap removed its workspace evidence'
    case "$_are_expect_file" in
        yes) [ -e "$_are_path/repair.sh" ] || fail 'failure evidence omitted the downloaded entrypoint' ;;
        no) [ ! -e "$_are_path/repair.sh" ] || fail 'failed download unexpectedly created an entrypoint' ;;
    esac
    grep -Fq "Bootstrap failed ($_are_rc); retained evidence: $_are_path" "$_are_log" ||
        fail 'failure output did not identify the retained workspace'
}

# Branch validation must fail before the first allocation or network call.
make_bootstrap '../invalid'
reset_logs
CURL_MODE=simple_success MKDIR_MODE=pass ENGINE_RC=0 EXPECTED_BRANCH=../invalid
run_bootstrap "$CASE/invalid-branch.log"
[ "$RUN_RC" -eq 2 ] || fail "invalid branch returned $RUN_RC instead of 2"
[ "$(curl_count)" -eq 0 ] && [ "$(mkdir_count)" -eq 0 ] || fail 'invalid branch reached allocation or download'
grep -Fq 'Invalid repair branch name' "$CASE/invalid-branch.log" || fail 'invalid branch diagnostic missing'
assert_no_mktemp
pass 'branch validation rejects invalid input before allocation or download'

# A successful documented bootstrap uses a private directory and HTTPS-only
# curl options, executes the handed-off script, then removes only its workspace.
make_bootstrap "$VALID_BRANCH"
reset_logs
CURL_MODE=simple_success MKDIR_MODE=pass ENGINE_RC=0 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/simple-success.log"
[ "$RUN_RC" -eq 0 ] || fail "simple successful bootstrap returned $RUN_RC"
assert_private_workspace
assert_transport_log
[ "$(curl_count)" -eq 1 ] || fail 'simple bootstrap made an unexpected number of downloads'
grep -Fq "url=https://raw.githubusercontent.com/r80xcore/mervlan/refs/heads/$VALID_BRANCH/functions/update_mervlan_repair.sh" "$CASE/curl.log" ||
    fail 'validated branch was not used in the HTTPS download URL'
[ -f "$CASE/simple-engine.marker" ] || fail 'validated entrypoint was not executed with the selected branch'
_success_ws=$(cat "$CASE/workspace.capture")
[ ! -e "$_success_ws" ] || fail 'successful bootstrap workspace was not cleaned up'
[ "$(mkdir_count)" -eq 1 ] || fail 'uncontended workspace allocation was not a single mkdir'
assert_no_mktemp
pass 'private workspace, HTTPS transport, handoff, syntax path, cleanup, and no-mktemp behavior pass'

# Force one exclusive-name collision. The first directory is foreign to the
# bootstrap and must remain untouched while the next candidate succeeds.
reset_logs
CURL_MODE=simple_success MKDIR_MODE=collision_once ENGINE_RC=0 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/collision-once.log"
[ "$RUN_RC" -eq 0 ] || fail "bootstrap did not recover from one workspace collision (rc=$RUN_RC)"
[ "$(mkdir_count)" -eq 2 ] || fail 'bootstrap did not retry exactly once after a workspace collision'
_collision_one=$(sed -n '1p' "$CASE/mkdir.log")
_collision_two=$(sed -n '2p' "$CASE/mkdir.log")
[ -n "$_collision_one" ] && [ -n "$_collision_two" ] && [ "$_collision_one" != "$_collision_two" ] ||
    fail 'workspace retry reused the colliding name'
[ -f "$_collision_one/.collision-sentinel" ] || fail 'bootstrap removed or reused the foreign collision directory'
[ ! -e "$_collision_two" ] || fail 'successful retry workspace was not cleaned up'
assert_private_workspace
assert_transport_log
rm -rf "$_collision_one"
assert_no_mktemp
pass 'exclusive mkdir collision is preserved and a fresh workspace is used'

# Force every bounded attempt to collide. No download is allowed after the
# eighth refusal, and every foreign fixture directory must remain intact.
reset_logs
CURL_MODE=simple_success MKDIR_MODE=collision_all ENGINE_RC=0 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/collision-all.log"
[ "$RUN_RC" -eq 1 ] || fail "eight allocation collisions returned $RUN_RC instead of 1"
[ "$(mkdir_count)" -eq 8 ] || fail 'workspace collision handling was not bounded to eight attempts'
[ "$(curl_count)" -eq 0 ] || fail 'bootstrap downloaded after workspace allocation failed'
grep -Fq 'Unable to allocate private bootstrap workspace after 8 attempts' "$CASE/collision-all.log" ||
    fail 'bounded allocation failure diagnostic missing'
while IFS= read -r _collision_path; do
    case "$_collision_path" in "$BOOT_ROOT"/mervlan-bootstrap.*) : ;; *) fail 'collision fixture escaped test root' ;; esac
    [ -f "$_collision_path/.collision-sentinel" ] || fail 'bootstrap modified a foreign collision directory'
    rm -rf "$_collision_path"
done <"$CASE/mkdir.log"
assert_no_mktemp
pass 'workspace allocation stops after eight collisions without downloading or removing foreign state'

# Download, syntax, and entrypoint errors must propagate and preserve evidence.
reset_logs
CURL_MODE=simple_download_failure MKDIR_MODE=pass ENGINE_RC=0 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/download-failure.log"
[ "$RUN_RC" -eq 22 ] || fail "curl exit status was not propagated (got $RUN_RC)"
assert_retained_evidence "$CASE/download-failure.log" 22 no
assert_no_mktemp
pass 'bootstrap download error propagates and retains evidence'

reset_logs
CURL_MODE=simple_bad_syntax MKDIR_MODE=pass ENGINE_RC=0 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/syntax-failure.log"
[ "$RUN_RC" -eq 2 ] || fail "invalid downloaded shell was not rejected with syntax status 2 (got $RUN_RC)"
[ ! -e "$CASE/simple-engine.marker" ] || fail 'invalid downloaded shell executed before syntax validation'
assert_retained_evidence "$CASE/syntax-failure.log" 2 yes
assert_no_mktemp
pass 'downloaded entrypoint syntax is checked before execution and failure evidence is retained'

reset_logs
CURL_MODE=simple_engine_failure MKDIR_MODE=pass ENGINE_RC=7 EXPECTED_BRANCH=$VALID_BRANCH
run_bootstrap "$CASE/engine-failure.log"
[ "$RUN_RC" -eq 7 ] || fail "entrypoint status was not propagated (got $RUN_RC)"
[ -f "$CASE/simple-engine.marker" ] || fail 'engine failure fixture did not execute'
assert_retained_evidence "$CASE/engine-failure.log" 7 yes
assert_no_mktemp
pass 'entrypoint error propagates and failure evidence is retained'

# Build a complete local snapshot fixture. The marker is injected only into
# the downloaded archive engine, proving same-snapshot handoff rather than
# execution of the raw bootstrap entrypoint alone.
ADDON="$CASE/addon"
REMOTE_ROOT="$CASE/remote/mervlan-bootstrap-snapshot"
mkdir -p "$ADDON/functions" "$ADDON/settings" "$ADDON/.ssh" "$ADDON/tmp" \
    "$CASE/remote" "$REMOTE_ROOT" "$CASE/proc" "$CASE/locks" "$CASE/work" \
    "$CASE/progress" "$BOOT_ROOT"
printf '{"General":{},"SSH":{},"Nodes":{},"SSH_USER":"admin","SSH_PORT":"22"}\n' >"$ADDON/settings/settings.json"
printf 'bootstrap-key\n' >"$ADDON/.ssh/vlan_manager"
printf 'bootstrap-db\n' >"$ADDON/tmp/mac_shield.db"
printf 'old\n' >"$ADDON/functions/update_mervlan.sh"

while IFS=' ' read -r mode path; do
    case "$mode" in format=*|cohort=*|\#*|'') continue ;; esac
    case "$path" in */*) parent=${path%/*} ;; *) parent=. ;; esac
    mkdir -p "$REMOTE_ROOT/$parent"
    cp -p "$ROOT/$path" "$REMOTE_ROOT/$path" || fail "snapshot source missing: $path"
    chmod "$mode" "$REMOTE_ROOT/$path" 2>/dev/null || fail "snapshot mode failed: $path"
done <"$MANIFEST"
sed -i '/^main "\$@"/i [ -n "${MERV_REPAIR_HANDOFF_TEST_MARKER:-}" ] \&\& printf "%s\\n" snapshot-engine >"$MERV_REPAIR_HANDOFF_TEST_MARKER"' \
    "$REMOTE_ROOT/functions/update_mervlan_repair.sh"
ARCHIVE="$CASE/remote/mervlan-bootstrap-snapshot.tar.gz"
( cd "$CASE/remote" && tar -czf "$ARCHIVE" "$(basename "$REMOTE_ROOT")" ) || fail 'bootstrap snapshot archive creation failed'

run_full() {
    _rf_log=$1 _rf_tmp_root=$2 _rf_mode=$3
    if env \
        PATH="$BIN:$PATH" \
        MERV_REAL_MKDIR="$REAL_MKDIR" \
        MERV_MKDIR_LOG="$CASE/mkdir.log" \
        MERV_MKDIR_MARKER="$CASE/mkdir.marker" \
        MERV_MKDIR_TEST_MODE=pass \
        MERV_MKTEMP_LOG="$CASE/mktemp.log" \
        MERV_CURL_LOG="$CASE/curl.log" \
        MERV_CURL_MODE="$_rf_mode" \
        MERV_WORKSPACE_CAPTURE="$CASE/workspace.capture" \
        MERV_WORKSPACE_MODE="$CASE/workspace.mode" \
        MERV_BASE="$ADDON" \
        MERV_REPAIR_CURL="$BIN/curl" \
        MERV_REPAIR_BOOTSTRAP_CURL="$BIN/curl" \
        MERV_REPAIR_BOOTSTRAP_DIR= \
        MERV_REPAIR_BOOTSTRAP_ENTRY="$REPAIR" \
        MERV_REPAIR_FIXTURE_ARCHIVE="$ARCHIVE" \
        MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
        MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
        MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
        MERV_REPAIR_PROC_ROOT="$CASE/proc" \
        MERV_REPAIR_TMP_ROOT="$_rf_tmp_root" \
        MERV_REPAIR_PROGRESS_ROOT="$CASE/progress" \
        MERV_REPAIR_HANDOFF_STATE= \
        MERV_REPAIR_HANDOFF_TEST_MARKER="$CASE/handoff-marker" \
        /bin/sh "$SCRIPT" >"$_rf_log" 2>&1
    then RUN_RC=0; else RUN_RC=$?; fi
}

make_bootstrap "$VALID_BRANCH"
reset_logs
run_full "$CASE/full-success.log" "$CASE/work" full_success
[ "$RUN_RC" -eq 0 ] || { cat "$CASE/full-success.log" >&2; fail "complete documented bootstrap/repair transaction failed (rc=$RUN_RC)"; }
[ "$(cat "$CASE/handoff-marker")" = snapshot-engine ] || fail 'bootstrap did not execute the engine from the validated source snapshot'
[ "$(cat "$ADDON/.ssh/vlan_manager")" = bootstrap-key ] || fail 'bootstrap repair changed protected SSH data'
[ "$(cat "$ADDON/tmp/mac_shield.db")" = bootstrap-db ] || fail 'bootstrap repair changed protected database data'
grep -Fq 'No update was started.' "$CASE/full-success.log" || fail 'bootstrap transaction entered or implied Update'
[ "$(curl_count)" -eq 2 ] || fail 'complete handoff did not make exactly the bootstrap and snapshot HTTPS requests'
assert_transport_log
assert_private_workspace
_full_ws=$(cat "$CASE/workspace.capture")
[ ! -e "$_full_ws" ] || fail 'successful full bootstrap did not clean its workspace'
assert_no_mktemp
pass 'same-snapshot bootstrap handoff succeeds, preserves protected data, and cleans up'

# Failure-path checks exercise cleanup policy on the actual documented script.
for mode in full_missing full_symlink full_download_failure full_snapshot_failure; do
    reset_logs
    run_full "$CASE/$mode.log" "$CASE/work" "$mode"
    case "$mode" in
        full_download_failure) [ "$RUN_RC" -eq 22 ] || fail "raw download error returned $RUN_RC instead of 22" ;;
        full_snapshot_failure) [ "$RUN_RC" -eq 1 ] || fail "snapshot download failure returned $RUN_RC instead of 1" ;;
        *) [ "$RUN_RC" -eq 1 ] || fail "$mode returned $RUN_RC instead of 1" ;;
    esac
    case "$mode" in full_symlink|full_snapshot_failure) _want_file=yes ;; *) _want_file=no ;; esac
    assert_retained_evidence "$CASE/$mode.log" "$RUN_RC" "$_want_file"
    case "$mode" in
        full_missing) [ ! -e "$(cat "$CASE/workspace.capture")/repair.sh" ] || fail 'missing-entry fixture unexpectedly created a file' ;;
        full_symlink) [ -L "$(cat "$CASE/workspace.capture")/repair.sh" ] || fail 'symlink-entry fixture was not retained' ;;
        full_download_failure) [ ! -e "$(cat "$CASE/workspace.capture")/repair.sh" ] || fail 'failed raw download unexpectedly created a file' ;;
        full_snapshot_failure)
            [ -f "$(cat "$CASE/workspace.capture")/repair.sh" ] || fail 'snapshot failure evidence lost the bootstrap engine'
            [ "$(curl_count)" -eq 2 ] || fail 'snapshot failure fixture did not reach exactly one archive download'
            grep -Fq 'Repair evidence retained at ' "$CASE/full_snapshot_failure.log" || fail 'snapshot failure did not retain the inner Repair workspace'
            grep -Fq 'Bootstrap failed (1); retained evidence: ' "$CASE/full_snapshot_failure.log" || fail 'snapshot failure status was not propagated by bootstrap'
            ;;
    esac
    assert_no_mktemp
done
pass 'missing, symlinked, failed bootstrap downloads, and failed snapshot downloads block and retain evidence'

# Preserve and correct the former unsafe-root assertion: the documented
# bootstrap has no such override, while its downloaded engine must reject the
# actual MERV_REPAIR_TMP_ROOT traversal before requesting a source snapshot.
reset_logs
run_full "$CASE/unsafe-root.log" "$CASE/work/../unsafe" full_unsafe_root
[ "$RUN_RC" -eq 1 ] || fail "unsafe Repair workspace root returned $RUN_RC instead of 1"
[ "$(curl_count)" -eq 1 ] || fail 'unsafe Repair workspace root reached the snapshot download'
assert_retained_evidence "$CASE/unsafe-root.log" 1 yes
grep -Fq 'prior repair workspace' "$CASE/unsafe-root.log" || fail 'unsafe Repair workspace root was not rejected by the engine'
assert_no_mktemp
pass 'Repair engine rejects an unsafe workspace root before snapshot download'

printf '%s\n' 'REPAIR_BOOTSTRAP_CONTRACT_OK'
