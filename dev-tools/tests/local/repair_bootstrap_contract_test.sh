#!/bin/sh
# Semantic contract test for the SSH bootstrap documented in docs/HELP.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-bootstrap-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
. "$ROOT/dev-tools/tests/local/selftest_context.sh" || fail 'self-test helper load'
merv_test_context_enable "$ROOT" "$WORK" || fail 'private self-test context'
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_FAKE_REPAIR=0
MERV_BOOTSTRAP_TEST_REPAIR_RC=0
MERV_BOOTSTRAP_TEST_UPDATER_RC=0

HELP_COMMAND="$WORK/bootstrap.sh"
awk '
  /^For `main`:$/ { after_main = 1; next }
  after_main && index($0, sprintf("%c%c%csh", 96, 96, 96)) == 1 { in_code = 1; next }
  in_code && index($0, sprintf("%c%c%c", 96, 96, 96)) == 1 { exit }
  in_code { print }
' "$ROOT/docs/HELP.md" >"$HELP_COMMAND"
[ -s "$HELP_COMMAND" ] || fail 'documented Emergency Update Repair bootstrap missing'
bootstrap_lines=$(wc -l <"$HELP_COMMAND" | tr -d '[:space:]')
[ "$bootstrap_lines" -eq 1 ] || fail "standalone bootstrap must be one physical line ($bootstrap_lines lines)"
for token in 'BRANCH="main"' 'AUTO_UPDATE="NO"' 'umask 077' 'mkdir "$d"' \
    "mervlan-repair-bootstrap-v1\\n" '/usr/sbin/curl -fsSL --retry 3 --connect-timeout 15' \
    '[ -s "$d/entry.sh" ]' '[ -f "$d/entry.sh" ]' '[ ! -L "$d/entry.sh" ]' \
    '/bin/sh -n "$d/entry.sh"' \
    'MERV_REPAIR_BOOTSTRAP_DIR="$d" /bin/sh "$d/entry.sh" "$BRANCH" "$AUTO_UPDATE"'; do
    grep -Fq "$token" "$HELP_COMMAND" || fail "one-line bootstrap is missing: $token"
done
! grep -Fq 'update_mervlan.sh update "$BRANCH"' "$HELP_COMMAND" || \
    fail 'normal updater orchestration still lives in HELP.md'

# Extract the production branch validator as written, then compare it with the
# branch case in the actual HELP.md command under both local POSIX shells.
PROD_VALID_REF="$WORK/production-valid-ref.sh"
awk '/^valid_ref\(\) \{$/ {copy=1} copy {print} copy && /^}$/ {exit} END {if (!copy) exit 1}' \
    "$REPAIR" >"$PROD_VALID_REF" || fail 'production valid_ref() helper missing'
PROD_REF_PROBE="$WORK/production-ref-probe.sh"
cat "$PROD_VALID_REF" >"$PROD_REF_PROBE"
printf '\nvalid_ref "$1"\n' >>"$PROD_REF_PROBE"

CASE="$WORK/case"
ADDON="$CASE/addon"
REMOTE_ROOT="$CASE/remote/mervlan-bootstrap-snapshot"
mkdir -p "$ADDON/functions" "$ADDON/settings" "$ADDON/.ssh" "$ADDON/tmp" \
    "$CASE/remote" "$REMOTE_ROOT" "$CASE/proc" "$CASE/locks" "$CASE/work" \
    "$CASE/progress" "$CASE/bootstrap"
printf '{"General":{},"SSH":{},"Nodes":{},"SSH_USER":"admin","SSH_PORT":"22","test_marker":"BOOTSTRAP_CREDENTIAL_SENTINEL"}\n' >"$ADDON/settings/settings.json"
cp "$ROOT/settings/lib_selftest_context.sh" "$ADDON/settings/lib_selftest_context.sh"
printf 'BOOTSTRAP_CREDENTIAL_SENTINEL\n' >"$ADDON/.ssh/vlan_manager"
printf 'bootstrap-db\n' >"$ADDON/tmp/mac_shield.db"
printf 'old\n' >"$ADDON/functions/update_mervlan.sh"

while IFS=' ' read -r mode path; do
    case "$mode" in format=*|cohort=*|\#*|'') continue ;; esac
    case "$path" in */*) parent=${path%/*} ;; *) parent=. ;; esac
    mkdir -p "$REMOTE_ROOT/$parent"
    cp -p "$ROOT/$path" "$REMOTE_ROOT/$path" || fail "snapshot source missing: $path"
    chmod "$mode" "$REMOTE_ROOT/$path" 2>/dev/null || fail "snapshot mode failed: $path"
done <"$MANIFEST"

cat >"$REMOTE_ROOT/functions/update_mervlan.sh" <<'EOF'
#!/bin/sh
[ "$1" = update ] || exit 91
printf '%s\n' "$@" >"$MERV_BOOTSTRAP_TEST_UPDATER_ARGS"
: >"$MERV_BOOTSTRAP_TEST_UPDATER_INVOKED"
exit "${MERV_BOOTSTRAP_TEST_UPDATER_RC:-0}"
EOF
chmod 755 "$REMOTE_ROOT/functions/update_mervlan.sh"

# Only the archive's repaired engine writes this marker. The downloaded raw
# bootstrap entrypoint is the unmodified current file, so this proves the
# post-extraction same-snapshot exec path was taken.
sed -i '/^main "\$@"/i [ -n "${MERV_REPAIR_HANDOFF_TEST_MARKER:-}" ] && printf "%s\\n" snapshot-engine >"$MERV_REPAIR_HANDOFF_TEST_MARKER"' \
    "$REMOTE_ROOT/functions/update_mervlan_repair.sh"
ARCHIVE="$CASE/remote/mervlan-bootstrap-snapshot.tar.gz"
( cd "$CASE/remote" && tar -czf "$ARCHIVE" "$(basename "$REMOTE_ROOT")" ) || fail 'bootstrap snapshot archive creation failed'

cat >"$CASE/curl" <<'EOF'
#!/bin/sh
out=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 2
case "$out" in */entry.sh) : >"$MERV_BOOTSTRAP_TEST_RAW_CURL_INVOKED" ;; esac
case "$MERV_BOOTSTRAP_TEST_MODE:$out" in
    download-fail:*/entry.sh) exit 22 ;;
    missing:*/entry.sh) exit 0 ;;
    empty:*/entry.sh) : >"$out" ;;
    symlink:*/entry.sh) ln -s "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" ;;
    syntax-fail:*/entry.sh)
        case "$url" in
            *"/refs/heads/$MERV_BOOTSTRAP_EXPECT_BRANCH/functions/update_mervlan_repair.sh") ;;
            *) exit 3 ;;
        esac
        printf 'if then\n' >"$out"
        ;;
    keep-extra:*/entry.sh)
        cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out"
        : >"${out%/*}/operator-note"
        ;;
    owner-missing:*/entry.sh)
        cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out"
        rm -f "${out%/*}/.owner"
        ;;
    owner-malformed:*/entry.sh)
        cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out"
        printf 'not-the-bootstrap-owner\n' >"${out%/*}/.owner"
        ;;
    */entry.sh)
        case "$url" in
            *"/refs/heads/$MERV_BOOTSTRAP_EXPECT_BRANCH/functions/update_mervlan_repair.sh") ;;
            *) exit 3 ;;
        esac
        cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out"
        ;;
    *) cp "$MERV_REPAIR_FIXTURE_ARCHIVE" "$out" ;;
esac
EOF
chmod 755 "$CASE/curl"

cat >"$CASE/sh" <<'EOF'
#!/bin/sh
if [ "$1" = -n ]; then
    case "${MERV_BOOTSTRAP_TEST_SHELL:-posix}" in
        busybox) busybox sh -n "$2" ;;
        *) /bin/sh -n "$2" ;;
    esac
    exit $?
fi
if [ "${MERV_BOOTSTRAP_TEST_MODE:-}" = branch-probe ]; then
    printf '%s\n' "$@" >"$MERV_BOOTSTRAP_TEST_ENTRY_ARGS"
    exit 0
fi
case "${MERV_BOOTSTRAP_TEST_SHELL:-posix}" in
    busybox) exec busybox sh "$@" ;;
    *) exec /bin/sh "$@" ;;
esac
EOF
chmod 755 "$CASE/sh"

make_command() {
    TEST_BRANCH="$1"
    awk -v branch="$1" -v auto_update="$2" '
        NR == 1 { sub(/^BRANCH="main"; AUTO_UPDATE="NO"; d=/,
                       "BRANCH=\"" branch "\"; AUTO_UPDATE=\"" auto_update "\"; d=") }
        { print }
    ' "$HELP_COMMAND" | sed \
        -e "s|/usr/sbin/curl|$CASE/curl|g" \
        -e "s|/bin/sh|$CASE/sh|g" \
        -e "s|/tmp/mervlan-bootstrap\.|$CASE/bootstrap/mervlan-bootstrap.|g" \
        >"$CASE/command.sh"
    /bin/sh -n "$CASE/command.sh" || fail 'documented bootstrap shell syntax failed'
    busybox sh -n "$CASE/command.sh" || fail 'documented bootstrap BusyBox syntax failed'
}

production_ref_accepts() {
    case "$1" in
        busybox) busybox sh "$PROD_REF_PROBE" "$2" >/dev/null 2>&1 ;;
        *) /bin/sh "$PROD_REF_PROBE" "$2" >/dev/null 2>&1 ;;
    esac
}

run_command() {
    {
        if [ "${MERV_BOOTSTRAP_TEST_PREEXISTING:-0}" = 1 ]; then
            printf 'mkdir "%s/bootstrap/mervlan-bootstrap.$$"\n' "$CASE"
        fi
        cat "$CASE/command.sh"
        printf '\n_rc=$?; printf "SHELL_CONTINUED_AFTER_BOOTSTRAP=%%s\\n" "$_rc"; exit "$_rc"\n'
    } >"$CASE/session.sh"
    case "${MERV_BOOTSTRAP_TEST_OUTER:-posix}" in
        busybox) _outer_shell="busybox sh" ;;
        *) _outer_shell="/bin/sh" ;;
    esac
    MERV_BASE="$ADDON" \
    MERV_REPAIR_CURL="$CASE/curl" \
    MERV_REPAIR_BOOTSTRAP_CURL="$CASE/curl" \
    MERV_REPAIR_BOOTSTRAP_TMP_ROOT="${MERV_REPAIR_BOOTSTRAP_TMP_ROOT:-$CASE/bootstrap}" \
    MERV_REPAIR_BOOTSTRAP_ENTRY="$REPAIR" \
    MERV_REPAIR_FIXTURE_ARCHIVE="$ARCHIVE" \
    MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
    MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
    MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
    MERV_REPAIR_PROC_ROOT="$CASE/proc" \
    MERV_REPAIR_TMP_ROOT="$CASE/work" \
    MERV_REPAIR_PROGRESS_ROOT="$CASE/progress" \
    MERV_REPAIR_HANDOFF_TEST_MARKER="$CASE/handoff-marker" \
    MERV_REPAIR_TEST_FAIL_PATH="${MERV_REPAIR_TEST_FAIL_PATH:-}" \
    MERV_BOOTSTRAP_TEST_MODE="$MERV_BOOTSTRAP_TEST_MODE" \
    MERV_BOOTSTRAP_EXPECT_BRANCH="$TEST_BRANCH" \
    MERV_BOOTSTRAP_TEST_SHELL="${MERV_BOOTSTRAP_TEST_SHELL:-posix}" \
    MERV_BOOTSTRAP_TEST_ENTRY_ARGS="$CASE/entry-args" \
    MERV_BOOTSTRAP_TEST_RAW_CURL_INVOKED="$CASE/raw-curl-invoked" \
    MERV_BOOTSTRAP_TEST_UPDATER_RC="$MERV_BOOTSTRAP_TEST_UPDATER_RC" \
    MERV_BOOTSTRAP_TEST_UPDATER_ARGS="$CASE/updater-args" \
    MERV_BOOTSTRAP_TEST_UPDATER_INVOKED="$CASE/updater-invoked" \
    MERV_BOOTSTRAP_TEST_SECRET='BOOTSTRAP_CREDENTIAL_SENTINEL' \
    PS1='' script -q -e --echo=never -c "exec $_outer_shell -i" \
        "$CASE/console.log" <"$CASE/session.sh" >/dev/null 2>&1
}

prepare_case() {
    for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        rm -rf "$entry"
    done
    rm -f "$CASE/repair-args" "$CASE/repair-invoked" \
        "$CASE/updater-args" "$CASE/updater-invoked" "$CASE/handoff-marker" \
        "$CASE/entry-args" "$CASE/raw-curl-invoked"
}
assert_updater_args() {
    [ -f "$CASE/updater-invoked" ] || fail 'normal updater was not invoked'
    printf '%s\n' "$1" "$2" >"$CASE/updater-expected"
    cmp -s "$CASE/updater-expected" "$CASE/updater-args" || fail 'normal updater argv mismatch'
}
normalize_console() { tr -d '\r' <"$CASE/console.log" >"$CASE/console.txt"; }
console_has() { grep -Fq "$1" "$CASE/console.txt"; }
assert_continued_status() {
    normalize_console
    console_has "SHELL_CONTINUED_AFTER_BOOTSTRAP=$1" || \
        fail "bootstrap shell did not continue with status $1"
}

# Compare the documented bootstrap's actual branch case with the production
# valid_ref() helper for supported and rejected nonempty refs in both shells.
for ref in main dev pre_v0.53.29-RC1-dev feature/test feature_2 \
    _feature feature_ feature- feature/ feature//x feature/../x feature.lock 'feature!'; do
    for shell_kind in posix busybox; do
        if production_ref_accepts "$shell_kind" "$ref"; then
            production_accept=1
        else
            production_accept=0
        fi
        make_command "$ref" NO
        MERV_BOOTSTRAP_TEST_MODE=branch-probe
        MERV_BOOTSTRAP_TEST_SHELL="$shell_kind"
        MERV_BOOTSTRAP_TEST_OUTER="$shell_kind"
        MERV_BOOTSTRAP_TEST_PREEXISTING=0
        prepare_case
        if run_command; then
            bootstrap_rc=0
        else
            bootstrap_rc=$?
        fi
        assert_continued_status "$bootstrap_rc"
        case "$bootstrap_rc" in
            0) bootstrap_accept=1 ;;
            2) bootstrap_accept=0 ;;
            *) fail "branch probe for '$ref' returned unexpected status $bootstrap_rc" ;;
        esac
        [ "$bootstrap_accept" -eq "$production_accept" ] || \
            fail "$shell_kind bootstrap/production branch validator mismatch for '$ref'"
        if [ "$bootstrap_accept" -eq 1 ]; then
            [ -f "$CASE/raw-curl-invoked" ] || fail "valid ref '$ref' did not reach bootstrap download"
            [ -f "$CASE/entry-args" ] || fail "valid ref '$ref' was not passed to the repair entrypoint"
            [ "$(tail -n 2 "$CASE/entry-args" | sed -n '1p')" = "$ref" ] || \
                fail "bootstrap passed the wrong branch argument for '$ref'"
            [ "$(tail -n 1 "$CASE/entry-args")" = NO ] || \
                fail "bootstrap passed the wrong AUTO_UPDATE argument for '$ref'"
        else
            [ ! -f "$CASE/raw-curl-invoked" ] || fail "invalid ref '$ref' reached bootstrap download"
            [ ! -f "$CASE/entry-args" ] || fail "invalid ref '$ref' reached the repair entrypoint"
        fi
    done
done
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_SHELL=posix
MERV_BOOTSTRAP_TEST_OUTER=posix
MERV_BOOTSTRAP_TEST_PREEXISTING=0
pass 'one-line bootstrap and production valid_ref() agree under POSIX sh and BusyBox sh'

# AUTO_UPDATE=NO repairs completely, releases maintenance ownership, and exits.
make_command main NO
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_SHELL=busybox
MERV_BOOTSTRAP_TEST_OUTER=busybox
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 0 ] || fail "main repair with AUTO_UPDATE=NO returned $_rc"
assert_continued_status 0
[ ! -f "$CASE/updater-invoked" ] || fail 'AUTO_UPDATE=NO invoked Update'
normalize_console
for stage in 'MerVLAN update components repaired successfully from branch: main' \
    'No update was started.'; do
    console_has "$stage" || fail "success CLI stage missing: $stage"
done
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -e "$entry" ] || continue
    fail 'successful repair did not retire its owned bootstrap workspace'
done
pass 'main repair success with AUTO_UPDATE=NO exits without Update'
MERV_BOOTSTRAP_TEST_SHELL=posix
MERV_BOOTSTRAP_TEST_OUTER=posix

# AUTO_UPDATE=YES runs only after the same-snapshot repair completes; the
# repaired updater receives its explicit mode and selected branch.
make_command main YES
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
prepare_case
if run_command; then _rc=0; else _rc=$?; cat "$CASE/console.log" >&2; fi
[ "$_rc" -eq 0 ] || fail "AUTO_UPDATE=YES repair/update returned $_rc"
assert_continued_status 0
assert_updater_args update main
normalize_console
grep -Eq '\[mervlan-repair\] Repair publication: [0-9]+/[0-9]+ files published' \
    "$CASE/console.txt" || fail 'interactive ledger-based repair progress missing'
console_has 'Starting normal update from branch: main' || fail 'normal update start stage missing'
console_has 'Normal update completed successfully.' || fail 'normal update completion stage missing'
if grep -Eq 'https?://|BOOTSTRAP_CREDENTIAL_SENTINEL|settings\.json|vlan_manager' \
    "$CASE/console.txt"; then
    fail 'bootstrap diagnostics exposed a URL, setting, credential marker, or SSH identity'
fi
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -e "$entry" ] || continue
    fail 'successful repair/update did not retire its owned bootstrap workspace'
done
pass 'AUTO_UPDATE=YES follows successful same-snapshot repair and calls update <branch>'

# The custom branch and AUTO_UPDATE intent survive exec into the downloaded
# same-snapshot engine and only that engine launches the updater.
CUSTOM_BRANCH=pre_v0.53.29-RC1-dev
make_command "$CUSTOM_BRANCH" YES
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
prepare_case
if run_command; then _rc=0; else _rc=$?; cat "$CASE/console.log" >&2; fi
[ "$_rc" -eq 0 ] || fail "custom branch repair/update returned $_rc"
assert_continued_status 0
[ "$(cat "$CASE/handoff-marker")" = snapshot-engine ] || fail 'repair did not execute the immutable snapshot engine'
assert_updater_args update "$CUSTOM_BRANCH"
normalize_console
console_has "MerVLAN update components repaired successfully from branch: $CUSTOM_BRANCH" || \
    fail 'same-snapshot engine lost the selected branch'
pass 'custom branch and AUTO_UPDATE survive same-snapshot exec exactly once'

# Repair failure blocks Update and retains transaction and bootstrap evidence.
make_command main YES
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
MERV_REPAIR_TEST_FAIL_PATH=install.sh
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -ne 0 ] || fail 'injected repair failure returned success'
[ ! -f "$CASE/updater-invoked" ] || fail 'Update started after repair failure'
retained=0
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -d "$entry" ] || continue
    [ -f "$entry/.owner" ] && [ -f "$entry/entry.sh" ] || fail 'repair failure lost bootstrap evidence'
    retained=1
done
[ "$retained" -eq 1 ] || fail 'repair failure did not retain its private workspace'
unset MERV_REPAIR_TEST_FAIL_PATH
pass 'repair failure blocks Update and retains diagnostic evidence'

# Preserve the updater's exact status and keep bootstrap evidence on failure.
MERV_BOOTSTRAP_TEST_UPDATER_RC=53
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 53 ] || fail "updater exit status was not propagated: $_rc"
assert_updater_args update main
normalize_console
console_has 'Normal update failed (exit status 53).' || fail 'updater failure CLI stage missing'
retained=0
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -d "$entry" ] || continue
    [ -f "$entry/.owner" ] && [ -f "$entry/entry.sh" ] || fail 'updater failure lost bootstrap evidence'
    retained=1
done
[ "$retained" -eq 1 ] || fail 'updater failure did not retain its private workspace'
pass 'updater failure is visible and its exact status propagates'

# A one-argument WebUI-style launch ignores inherited AUTO_UPDATE. The normal
# service dispatcher continues to pass the existing branch-only CLI form.
prepare_case
if AUTO_UPDATE=YES MERV_BASE="$ADDON" \
    MERV_REPAIR_CURL="$CASE/curl" \
    MERV_REPAIR_FIXTURE_ARCHIVE="$ARCHIVE" \
    MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
    MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
    MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
    MERV_REPAIR_PROC_ROOT="$CASE/proc" \
    MERV_REPAIR_TMP_ROOT="$CASE/work" \
    MERV_REPAIR_PROGRESS_ROOT="$CASE/progress" \
    MERV_BOOTSTRAP_TEST_UPDATER_RC=0 \
    MERV_BOOTSTRAP_TEST_UPDATER_ARGS="$CASE/updater-args" \
    MERV_BOOTSTRAP_TEST_UPDATER_INVOKED="$CASE/updater-invoked" \
    /bin/sh "$REPAIR" main >"$CASE/inherited-auto.log" 2>&1; then
    _rc=0
else
    _rc=$?
fi
[ "$_rc" -eq 0 ] || fail "one-argument repair rejected inherited AUTO_UPDATE: $_rc"
[ ! -f "$CASE/updater-invoked" ] || fail 'inherited AUTO_UPDATE launched Update for a one-argument repair'
grep -Fq 'dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan_repair.sh" main' \
    "$ROOT/functions/service-event-handler.sh" || fail 'WebUI dispatcher repair branch changed'
pass 'WebUI-style repair ignores inherited AUTO_UPDATE and leaves update orchestration to dispatcher'

# Cleanup removes only the owned entrypoint and marker, leaving unrelated data.
MERV_BOOTSTRAP_TEST_MODE=keep-extra
make_command main NO
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 0 ] || fail "repair with an extra bootstrap artifact returned $_rc"
extra_found=0
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -d "$entry" ] || continue
    [ -f "$entry/operator-note" ] || fail 'bootstrap cleanup left an unexpected directory without its extra file'
    [ ! -e "$entry/entry.sh" ] && [ ! -e "$entry/.owner" ] || fail 'bootstrap cleanup left owned artifacts'
    extra_found=1
done
[ "$extra_found" -eq 1 ] || fail 'bootstrap cleanup removed or missed the unrelated operator note'
pass 'successful cleanup removes only owned bootstrap artifacts'

# A missing or malformed ownership marker prevents cleanup from removing the
# downloaded entrypoint or its workspace.
for mode in owner-missing owner-malformed; do
    MERV_BOOTSTRAP_TEST_MODE="$mode"
    make_command main NO
    prepare_case
    if run_command; then _rc=0; else _rc=$?; fi
    [ "$_rc" -eq 0 ] || fail "$mode cleanup guard changed repair status to $_rc"
    assert_continued_status 0
    retained=0
    for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
        [ -d "$entry" ] || continue
        [ -f "$entry/entry.sh" ] || fail "$mode cleanup removed the downloaded entrypoint"
        if [ "$mode" = owner-missing ]; then
            [ ! -e "$entry/.owner" ] || fail 'missing ownership marker unexpectedly appeared'
        else
            grep -Fqx 'not-the-bootstrap-owner' "$entry/.owner" || \
                fail 'malformed ownership marker was changed'
        fi
        retained=1
    done
    [ "$retained" -eq 1 ] || fail "$mode cleanup removed the unowned bootstrap workspace"
done
pass 'missing or malformed ownership markers preserve bootstrap evidence'

# Bootstrap download, empty-file, file-type, and syntax failures stop and retain evidence.
for mode in download-fail missing empty symlink syntax-fail; do
    MERV_BOOTSTRAP_TEST_MODE="$mode"
    MERV_BOOTSTRAP_TEST_UPDATER_RC=0
    prepare_case
    if run_command; then
        fail "bootstrap accepted $mode input"
    else
        _rc=$?
    fi
    [ ! -f "$CASE/updater-invoked" ] || fail "$mode invoked Update"
    assert_continued_status "$_rc"
    case "$mode" in
        download-fail) [ "$_rc" -eq 22 ] || fail "download failure status was not propagated: $_rc" ;;
        syntax-fail) [ "$_rc" -eq 2 ] || fail "syntax failure status was not propagated: $_rc" ;;
        *) [ "$_rc" -ne 0 ] || fail "$mode failure returned success" ;;
    esac
    retained=0
    for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
        [ -d "$entry" ] || continue
        [ -f "$entry/.owner" ] || fail "$mode did not retain workspace marker"
        if [ "$mode" = missing ] || [ "$mode" = download-fail ]; then
            [ ! -e "$entry/entry.sh" ] && [ ! -L "$entry/entry.sh" ] || fail 'missing entrypoint unexpectedly exists'
        elif [ "$mode" = empty ]; then
            [ -f "$entry/entry.sh" ] && [ ! -s "$entry/entry.sh" ] || fail 'empty download was not retained as an empty file'
        else
            [ -e "$entry/entry.sh" ] || [ -L "$entry/entry.sh" ] || fail "$mode did not retain entrypoint"
        fi
        retained=1
    done
    [ "$retained" -eq 1 ] || fail "$mode did not retain bootstrap evidence"
done
pass 'download, empty/missing/symlink entrypoint, and syntax failures stop and retain evidence'

# A pre-existing private bootstrap path is never reused or overwritten.
make_command main NO
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_PREEXISTING=1
prepare_case
if run_command; then fail 'bootstrap reused an existing private directory'; else _rc=$?; fi
[ "$_rc" -ne 0 ] || fail 'existing bootstrap directory returned success'
assert_continued_status "$_rc"
[ ! -f "$CASE/raw-curl-invoked" ] || fail 'existing bootstrap directory reached curl'
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -d "$entry" ] || continue
    [ ! -e "$entry/.owner" ] && [ ! -e "$entry/entry.sh" ] || \
        fail 'existing bootstrap directory was modified'
done
MERV_BOOTSTRAP_TEST_PREEXISTING=0
pass 'bootstrap refuses an existing private directory and continues the shell'

# Unsafe branch syntax is rejected before any download or workspace creation.
make_command 'feature/../invalid' YES
MERV_BOOTSTRAP_TEST_MODE=success
prepare_case
if run_command; then fail 'bootstrap accepted unsafe branch'; else _invalid_rc=$?; fi
[ "$_invalid_rc" -eq 2 ] || fail "unsafe bootstrap branch returned $_invalid_rc instead of 2"
assert_continued_status 2
[ ! -f "$CASE/raw-curl-invoked" ] || fail 'unsafe branch reached bootstrap download'
[ ! -f "$CASE/updater-invoked" ] || fail 'unsafe branch invoked Update'
pass 'bootstrap rejects malformed custom branch before download'

# AUTO_UPDATE is strict at both bootstrap and repair entrypoint boundaries.
make_command main MAYBE
prepare_case
if run_command; then fail 'bootstrap accepted invalid AUTO_UPDATE'; else _invalid_rc=$?; fi
[ "$_invalid_rc" -eq 2 ] || fail "invalid AUTO_UPDATE returned $_invalid_rc instead of 2"
assert_continued_status 2
[ ! -f "$CASE/updater-invoked" ] || fail 'invalid AUTO_UPDATE invoked Update'
if MERV_BASE="$ADDON" /bin/sh "$REPAIR" main ''; then
    fail 'repair accepted empty AUTO_UPDATE argument'
else
    _invalid_rc=$?
fi
[ "$_invalid_rc" -eq 2 ] || fail "empty repair AUTO_UPDATE returned $_invalid_rc instead of 2"
pass 'invalid AUTO_UPDATE values fail closed'

# The established direct CLI branch syntax and safe-ref validation remain.
if MERV_BASE="$ADDON" MERV_REPAIR_TMP_ROOT="$CASE/work" \
    MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
    MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
    MERV_REPAIR_PROC_ROOT="$CASE/proc" \
    /bin/sh "$REPAIR" 'feature/../invalid' >"$CASE/invalid-branch.log" 2>&1; then
    fail 'repair accepted an unsafe branch'
else
    _invalid_rc=$?
fi
[ "$_invalid_rc" -eq 2 ] || fail "unsafe branch returned $_invalid_rc instead of 2"
grep -Fq 'Invalid branch; use main, dev, or a safe custom branch name.' "$CASE/invalid-branch.log" || \
    fail 'repair ref validator rejection missing'
pass 'existing repair ref validation rejects malformed branch syntax'

printf '%s\n' 'REPAIR_BOOTSTRAP_CONTRACT_OK'
