#!/bin/sh
# Contract test for the one-line SSH bootstrap documented in docs/HELP.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-bootstrap-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

COMMAND=$(sed -n '/^umask 077; c=/p' "$ROOT/docs/HELP.md")
[ -n "$COMMAND" ] || fail 'documented bootstrap command missing'
[ "$(printf '%s\n' "$COMMAND" | wc -l | tr -d ' ')" = 1 ] || fail 'bootstrap command is not a single canonical line'
printf '%s\n' "$COMMAND" | grep -Fq 'MERV_REPAIR_BOOTSTRAP_DIR="$d"' || fail 'bootstrap workspace handoff missing'
printf '%s\n' "$COMMAND" | grep -Fq '[ ! -L "$d/entry.sh" ]' || fail 'bootstrap entrypoint symlink guard missing'
grep -Fq 'same validated snapshot' "$ROOT/docs/HELP.md" || fail 'same-snapshot bootstrap documentation missing'

CASE="$WORK/case"
ADDON="$CASE/addon"
REMOTE_ROOT="$CASE/remote/mervlan-bootstrap-snapshot"
mkdir -p "$ADDON/functions" "$ADDON/settings" "$ADDON/.ssh" "$ADDON/tmp" \
    "$CASE/remote" "$REMOTE_ROOT" "$CASE/proc" "$CASE/locks" "$CASE/work" \
    "$CASE/progress" "$CASE/bootstrap"
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
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || exit 2
case "${MERV_BOOTSTRAP_TEST_MODE:-success}:$out" in
    download-fail:*) exit 22 ;;
    missing:*/entry.sh) exit 0 ;;
    symlink:*/entry.sh) ln -s "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" ;;
    */entry.sh) cp "$MERV_REPAIR_BOOTSTRAP_ENTRY" "$out" ;;
    *) cp "$MERV_REPAIR_FIXTURE_ARCHIVE" "$out" ;;
esac
EOF
chmod 755 "$CASE/curl"

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
    MERV_BOOTSTRAP_TEST_MODE="${MERV_BOOTSTRAP_TEST_MODE:-success}" \
    sh -c "$COMMAND"
}

rm -f "$CASE/handoff-marker"
run_command || fail 'documented bootstrap did not complete with a valid snapshot'
[ "$(cat "$CASE/handoff-marker")" = snapshot-engine ] || fail 'bootstrap did not execute same-snapshot repair engine'
for entry in "$CASE/bootstrap"/mervlan-repair-bootstrap.*; do
    [ -e "$entry" ] || continue
    fail 'successful bootstrap workspace was not retired'
done
pass 'documented bootstrap uses private workspace and same-snapshot handoff'

for mode in missing symlink download-fail; do
    MERV_BOOTSTRAP_TEST_MODE="$mode"
    if run_command; then
        fail "bootstrap accepted $mode fixture"
    fi
done
pass 'bootstrap missing-entrypoint, symlink-entrypoint, and download-failure cases block'

MERV_REPAIR_BOOTSTRAP_TMP_ROOT="$CASE/bootstrap/../unsafe"
if MERV_BOOTSTRAP_TEST_MODE=success run_command; then
    fail 'bootstrap accepted unsafe temporary root'
fi
pass 'bootstrap unsafe temporary-root case blocks before download'

printf '%s\n' 'REPAIR_BOOTSTRAP_CONTRACT_OK'
