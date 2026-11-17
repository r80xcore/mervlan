#!/bin/sh
# Contract coverage for immutable-ref standalone Repair invocation.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
HELP="$ROOT/docs/HELP.md"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan_standalone_fixture.repair-ref.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

grep -Fq 'full lowercase 40-character commit SHA' "$HELP" || fail 'help does not require an immutable source SHA'
grep -Fq 'SOURCE_SHA=' "$HELP" || fail 'help omits the standalone source reference'
grep -Fq 'verified copy' "$HELP" || fail 'help omits the separately verified bootstrap requirement'
grep -Fq 'branch labels and is not wired' "$HELP" || fail 'help hides the current WebUI pin limitation'

cat >"$WORK/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >>"$MERV_REPAIR_CURL_LOG"
exit 22
CURL
chmod 700 "$WORK/curl"
: >"$WORK/curl.log"

for invalid in main dev refs/main abcdef0123456789ABCDEF0123456789abcdef01 short; do
  if MERV_REPAIR_CURL="$WORK/curl" MERV_REPAIR_CURL_LOG="$WORK/curl.log" \
      /bin/sh "$REPAIR" "$invalid" >"$WORK/out" 2>&1; then
    fail "mutable or malformed reference was accepted: $invalid"
  fi
  grep -Fq 'full 40-character immutable source commit SHA' "$WORK/out" ||
    fail "immutable-ref refusal missing for: $invalid"
done
[ ! -s "$WORK/curl.log" ] || fail 'invalid references reached the network client'
pass 'branch labels and malformed refs are rejected before network access'

# A valid commit id reaches the one-snapshot transport path. The fake client
# records the URL and fails before any archive or installed-file mutation.
FIXTURE="$WORK/fixture"
BASE="$FIXTURE/jffs/addons/mervlan"
BACKUPS="$FIXTURE/jffs/addons/mervlan_backups"
mkdir -p "$BASE" "$BACKUPS" "$FIXTURE/tmp/locks" "$FIXTURE/proc" "$FIXTURE/tmp"
printf 'MemAvailable: 400000 kB\n' >"$FIXTURE/meminfo"
REF=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if MERV_BASE="$BASE" \
   MERV_REPAIR_TEST_ONLY=1 \
   MERV_REPAIR_TMP_ROOT="$FIXTURE/tmp" \
   MERV_REPAIR_PROC_ROOT="$FIXTURE/proc" \
   MERV_REPAIR_MEMINFO="$FIXTURE/meminfo" \
   MERV_REPAIR_BACKUP_ROOT="$BACKUPS" \
   MERV_REPAIR_LOCK="$FIXTURE/tmp/locks/mervlan_maintenance.lock" \
   MERV_REPAIR_ACTION_LOCK="$FIXTURE/tmp/locks/mervlan_action.lock" \
   MERV_REPAIR_MANAGER_LOCK="$FIXTURE/tmp/locks/mervlan_manager.lock" \
   MERV_REPAIR_LEGACY_LOCK_ROOT="$FIXTURE/tmp/locks" \
   MERV_REPAIR_SNAPSHOT_BASE=https://repair.test/snapshot \
   MERV_REPAIR_CURL="$WORK/curl" \
   MERV_REPAIR_CURL_LOG="$WORK/curl.log" \
   /bin/sh "$REPAIR" "$REF" >"$WORK/valid-ref.out" 2>&1; then
  fail 'injected immutable snapshot download failure was ignored'
fi
grep -Fq "https://repair.test/snapshot/$REF" "$WORK/curl.log" ||
  fail 'full commit SHA was not used as the snapshot URL reference'
pass 'valid immutable SHA selects exactly one snapshot URL'

printf 'REPAIR_BOOTSTRAP_CONTRACT_OK\n'
