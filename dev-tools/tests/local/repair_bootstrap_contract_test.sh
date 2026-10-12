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
  /^For / && /main/ { after_main = 1; next }
  after_main && index($0, sprintf("%c%c%csh", 96, 96, 96)) == 1 { in_code = 1; next }
  in_code && index($0, sprintf("%c%c%c", 96, 96, 96)) == 1 { exit }
  in_code { print }
' "$ROOT/docs/HELP.md" >"$HELP_COMMAND"
[ -s "$HELP_COMMAND" ] || fail 'documented Emergency Update Repair bootstrap missing'
grep -Fq 'Starting emergency repair bootstrap' "$HELP_COMMAND" || fail 'bootstrap start stage missing'
grep -Fq 'MERV_REPAIR_BOOTSTRAP_DIR="$d"' "$HELP_COMMAND" || fail 'bootstrap workspace handoff missing'
grep -Fq 'update_mervlan.sh update "$BRANCH"' "$HELP_COMMAND" || fail 'explicit updater mode/branch form missing'

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
case "$MERV_BOOTSTRAP_TEST_MODE:$out" in
    download-fail:*/entry.sh) exit 22 ;;
    missing:*/entry.sh) exit 0 ;;
    symlink:*/entry.sh) ln -s "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" ;;
    syntax-fail:*/entry.sh)
        case "$url" in
            *"/refs/heads/$MERV_BOOTSTRAP_EXPECT_BRANCH/functions/update_mervlan_repair.sh") ;;
            *) exit 3 ;;
        esac
        printf 'if then\n' >"$out"
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
case "$1" in
    -n)
        /bin/sh -n "$2"
        exit $?
        ;;
    /jffs/addons/mervlan/functions/update_mervlan.sh)
        shift
        printf '%s\n' "$@" >"$MERV_BOOTSTRAP_TEST_UPDATER_ARGS"
        : >"$MERV_BOOTSTRAP_TEST_UPDATER_INVOKED"
        exit "$MERV_BOOTSTRAP_TEST_UPDATER_RC"
        ;;
    */entry.sh)
        if [ "$MERV_BOOTSTRAP_TEST_FAKE_REPAIR" = 1 ]; then
            printf '%s\n' "$2" >"$MERV_BOOTSTRAP_TEST_REPAIR_ARGS"
            : >"$MERV_BOOTSTRAP_TEST_REPAIR_INVOKED"
            exit "$MERV_BOOTSTRAP_TEST_REPAIR_RC"
        fi
        ;;
esac
exec /bin/sh "$@"
EOF
chmod 755 "$CASE/sh"

make_command() {
    TEST_BRANCH="$1"
    sed \
        -e "s|^BRANCH=\"main\"$|BRANCH=\"$1\"|" \
        -e "s|^AUTO_UPDATE=\"NO\"$|AUTO_UPDATE=\"$2\"|" \
        -e "s|/usr/sbin/curl|$CASE/curl|g" \
        -e "s|/bin/sh|$CASE/sh|g" \
        -e "s|/tmp/mervlan-bootstrap\.|$CASE/bootstrap/mervlan-bootstrap.|g" \
        "$HELP_COMMAND" >"$CASE/command.sh"
    /bin/sh -n "$CASE/command.sh" || fail 'documented bootstrap shell syntax failed'
    busybox sh -n "$CASE/command.sh" || fail 'documented bootstrap BusyBox syntax failed'
}

run_command() {
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
    MERV_BOOTSTRAP_TEST_MODE="$MERV_BOOTSTRAP_TEST_MODE" \
    MERV_BOOTSTRAP_EXPECT_BRANCH="$TEST_BRANCH" \
    MERV_BOOTSTRAP_TEST_FAKE_REPAIR="$MERV_BOOTSTRAP_TEST_FAKE_REPAIR" \
    MERV_BOOTSTRAP_TEST_REPAIR_RC="$MERV_BOOTSTRAP_TEST_REPAIR_RC" \
    MERV_BOOTSTRAP_TEST_UPDATER_RC="$MERV_BOOTSTRAP_TEST_UPDATER_RC" \
    MERV_BOOTSTRAP_TEST_REPAIR_ARGS="$CASE/repair-args" \
    MERV_BOOTSTRAP_TEST_REPAIR_INVOKED="$CASE/repair-invoked" \
    MERV_BOOTSTRAP_TEST_UPDATER_ARGS="$CASE/updater-args" \
    MERV_BOOTSTRAP_TEST_UPDATER_INVOKED="$CASE/updater-invoked" \
    MERV_BOOTSTRAP_TEST_SECRET='BOOTSTRAP_CREDENTIAL_SENTINEL' \
    script -q -e -c "exec /bin/sh '$CASE/command.sh'" "$CASE/console.log" </dev/null >/dev/null 2>&1
}

prepare_case() {
    rm -f "$CASE/repair-args" "$CASE/repair-invoked" \
        "$CASE/updater-args" "$CASE/updater-invoked" "$CASE/handoff-marker"
}
assert_updater_args() {
    [ -f "$CASE/updater-invoked" ] || fail 'normal updater was not invoked'
    printf '%s\n' "$1" "$2" >"$CASE/updater-expected"
    cmp -s "$CASE/updater-expected" "$CASE/updater-args" || fail 'normal updater argv mismatch'
}
normalize_console() { tr -d '\r' <"$CASE/console.log" >"$CASE/console.txt"; }
console_has() { grep -Fq "$1" "$CASE/console.txt"; }

# The NO path completes repair and never starts Update.
make_command main NO
MERV_BOOTSTRAP_TEST_FAKE_REPAIR=1
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_REPAIR_RC=0
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 0 ] || fail "main repair with AUTO_UPDATE=NO returned $_rc"
[ "$(cat "$CASE/repair-args")" = main ] || fail 'main repair branch argument mismatch'
[ ! -f "$CASE/updater-invoked" ] || fail 'AUTO_UPDATE=NO invoked Update'
normalize_console
for stage in 'Starting emergency repair bootstrap' 'Bootstrap download succeeded' \
    'Syntax verification succeeded' 'Starting emergency repair' \
    'Emergency repair completed' 'Normal update not requested' \
    'Finished with exit status 0'; do
    console_has "$stage" || fail "success CLI stage missing: $stage"
done
pass 'main repair success with AUTO_UPDATE=NO exits without Update'

# Both built-in channels must use the explicit mode and channel arguments.
for branch in main dev; do
    make_command "$branch" YES
    MERV_BOOTSTRAP_TEST_FAKE_REPAIR=1
    MERV_BOOTSTRAP_TEST_MODE=success
    MERV_BOOTSTRAP_TEST_REPAIR_RC=0
    MERV_BOOTSTRAP_TEST_UPDATER_RC=0
    prepare_case
    if run_command; then _rc=0; else _rc=$?; fi
    [ "$_rc" -eq 0 ] || fail "$branch AUTO_UPDATE returned $_rc"
    [ "$(cat "$CASE/repair-args")" = "$branch" ] || fail "$branch repair argument mismatch"
    assert_updater_args update "$branch"
    normalize_console
    console_has 'Starting normal update' || fail "$branch update start stage missing"
    console_has 'Normal update completed' || fail "$branch update completion stage missing"
done
pass 'main and dev AUTO_UPDATE invoke update with the selected branch'

# A complete real repair exercises the existing ref validator, immutable
# snapshot handoff, and canonical publication ledger with no progress token.
CUSTOM_BRANCH=pre_v0.53.29-RC1-dev
make_command "$CUSTOM_BRANCH" YES
MERV_BOOTSTRAP_TEST_FAKE_REPAIR=0
MERV_BOOTSTRAP_TEST_MODE=success
prepare_case
if run_command; then _rc=0; else _rc=$?; cat "$CASE/console.log" >&2; fi
[ "$_rc" -eq 0 ] || fail "custom branch repair/update returned $_rc"
[ "$(cat "$CASE/handoff-marker")" = snapshot-engine ] || fail 'repair did not execute the immutable snapshot engine'
assert_updater_args update "$CUSTOM_BRANCH"
normalize_console
grep -Eq '\[mervlan-repair\] Repair publication: [0-9]+/[0-9]+ files published' \
    "$CASE/console.txt" || fail 'interactive ledger-based repair progress missing'
if grep -Eq 'https?://|BOOTSTRAP_CREDENTIAL_SENTINEL|settings\.json|vlan_manager' \
    "$CASE/console.txt"; then
    fail 'bootstrap diagnostics exposed a URL, setting, credential marker, or SSH identity'
fi
for entry in "$CASE/bootstrap"/mervlan-bootstrap.*; do
    [ -e "$entry" ] || continue
    fail 'successful bootstrap workspace was not retired'
done
pass 'safe custom branch repair uses the immutable snapshot and ledger progress, then invokes update <branch>'

# Repair failure blocks normal Update and propagates the exact repair status.
make_command main YES
MERV_BOOTSTRAP_TEST_FAKE_REPAIR=1
MERV_BOOTSTRAP_TEST_MODE=success
MERV_BOOTSTRAP_TEST_REPAIR_RC=37
MERV_BOOTSTRAP_TEST_UPDATER_RC=0
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 37 ] || fail "repair exit status was not propagated: $_rc"
[ ! -f "$CASE/updater-invoked" ] || fail 'Update started after repair failure'
normalize_console
console_has 'Emergency repair failed (exit status 37)' || fail 'repair failure CLI stage missing'
console_has 'Finished with exit status 37' || fail 'repair failure final status missing'
pass 'repair failure blocks Update and propagates its exact status'

# The updater's exact status is the final bootstrap status.
MERV_BOOTSTRAP_TEST_REPAIR_RC=0
MERV_BOOTSTRAP_TEST_UPDATER_RC=53
prepare_case
if run_command; then _rc=0; else _rc=$?; fi
[ "$_rc" -eq 53 ] || fail "updater exit status was not propagated: $_rc"
assert_updater_args update main
normalize_console
console_has 'Normal update failed (exit status 53)' || fail 'updater failure CLI stage missing'
console_has 'Finished with exit status 53' || fail 'updater failure final status missing'
pass 'updater failure is visible and its exact status propagates'

# Download, regular-file, and syntax failures report a stage and stop.
for mode in download-fail missing symlink syntax-fail; do
    MERV_BOOTSTRAP_TEST_MODE="$mode"
    MERV_BOOTSTRAP_TEST_REPAIR_RC=0
    MERV_BOOTSTRAP_TEST_UPDATER_RC=0
    prepare_case
    if run_command; then
        fail "bootstrap accepted $mode input"
    else
        _rc=$?
    fi
    [ ! -f "$CASE/repair-invoked" ] || fail "$mode reached repair"
    [ ! -f "$CASE/updater-invoked" ] || fail "$mode invoked Update"
    normalize_console
    case "$mode" in
        download-fail) console_has 'Bootstrap download failed (exit status 22)' || fail 'download failure stage missing' ;;
        missing|symlink) console_has 'Bootstrap download did not produce a regular script' || fail "$mode validation stage missing" ;;
        syntax-fail) console_has 'Syntax verification failed (exit status 2)' || fail 'syntax failure stage missing' ;;
    esac
    console_has "Finished with exit status $_rc" || fail "$mode final status missing"
done
pass 'download, missing/symlink entrypoint, and syntax failures stop before repair'

# Unsafe branch syntax is refused by the installed repair/ref validator.
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
