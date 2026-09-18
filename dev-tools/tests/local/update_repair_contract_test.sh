#!/bin/sh
# Local-only contract fixture for the standalone Emergency Update Repair path.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
MANAGER="$ROOT/functions/mervlan_manager.sh"
UPDATER="$ROOT/functions/update_mervlan.sh"
INSTALLER="$ROOT/install.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-repair-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3"; }

build_remote() {
  remote="$1"; branch="$2"
  branch_key=$(printf '%s' "$branch" | sed 's/[^A-Za-z0-9._-]/_/g')
  remote_branch="$remote/$branch_key"
  remote_root_name="mervlan-${branch_key}-fixture"
  remote_tree="$remote_branch/$remote_root_name"
  REMOTE_ARCHIVE="$remote/$branch_key.snapshot.tar.gz"
  REMOTE_BRANCH_DIR="$remote_branch"
  REMOTE_ROOT_NAME="$remote_root_name"
  REMOTE_TREE="$remote_tree"
  mkdir -p "$remote_tree"
  while IFS=' ' read -r mode path; do
    case "$mode" in format=*|cohort=*|\#*|'') continue;; esac
    case "$path" in */*) parent=${path%/*};; *) parent=.;; esac
    mkdir -p "$remote_tree/$parent"
    cp -p "$ROOT/$path" "$remote_tree/$path"
  done < "$MANIFEST"
  ( cd "$remote_branch" && tar -czf "$REMOTE_ARCHIVE" "$remote_root_name" )
}

repack_remote() {
  ( cd "$REMOTE_BRANCH_DIR" && tar -czf "$REMOTE_ARCHIVE" "$REMOTE_ROOT_NAME" )
}

setup_case() {
  name="$1"; branch="${2:-main}"
  CASE="$WORK/$name"; ADDON="$CASE/addon"; REMOTE="$CASE/remote"
  mkdir -p "$ADDON/functions" "$ADDON/settings" "$ADDON/.ssh" "$ADDON/tmp" "$CASE/work" "$CASE/proc"
  printf 'old-installer\n' > "$ADDON/install.sh"
  printf 'old-updater\n' > "$ADDON/functions/update_mervlan.sh"
  printf '{"keep":"settings"}\n' > "$ADDON/settings/settings.json"
  printf 'private-key\n' > "$ADDON/.ssh/vlan_manager"
  printf 'db-state\n' > "$ADDON/tmp/mac_shield.db"
  build_remote "$REMOTE" "$branch"
  cat > "$CASE/fake-curl" <<'EOF'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2;; *) shift;; esac
done
[ -n "$out" ] || exit 2
[ "${MERV_REPAIR_TEST_FAIL_DOWNLOAD:-0}" != 1 ] || exit 22
cp "$MERV_REPAIR_FIXTURE_ARCHIVE" "$out"
EOF
  chmod 755 "$CASE/fake-curl"
}

run_repair() {
  MERV_BASE="$ADDON" MERV_REPAIR_CURL="$CASE/fake-curl" \
  MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
  MERV_REPAIR_FIXTURE_ARCHIVE="$REMOTE_ARCHIVE" \
  MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
  MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
  MERV_REPAIR_PROC_ROOT="${MERV_REPAIR_PROC_ROOT:-$CASE/proc}" \
  MERV_REPAIR_TMP_ROOT="$CASE/work" \
  MERV_REPAIR_PROGRESS_ROOT="$CASE/progress" \
  sh "$REPAIR" "$1"
}

grep -Eq '^[[:space:]]*\.[[:space:]]|^[[:space:]]*source[[:space:]]' "$REPAIR" && fail 'repair script must not source MerVLAN code'
sh -n "$REPAIR" || fail 'repair shell syntax'
[ "$(grep -Fc 'if ! run_trunk_if_configured; then' "$MANAGER")" -ge 1 ] || fail 'manager must stop after trunk failure'
grep -Fq '[ -x "$_update_tree/functions/mervlan_wan.sh" ]' "$UPDATER" || fail 'updater tree validation must require executable WAN helper'
[ "$(grep -Fc 'functions/mervlan_wan.sh) [ -x "$MERV_BASE/$_req" ]' "$INSTALLER")" -ge 2 ] || fail 'installer standard/final validation must require executable WAN helper'
[ "$(sed -n '1p' "$MANIFEST")" = 'format=2' ] || fail 'manifest format header'
grep -Fq '0644 settings/settings.json' "$MANIFEST" && fail 'manifest must not replace settings.json'

setup_case success main
before_settings=$(cksum "$ADDON/settings/settings.json")
before_key=$(cksum "$ADDON/.ssh/vlan_manager")
before_db=$(cksum "$ADDON/tmp/mac_shield.db")
run_repair main || fail 'successful repair'
grep -Fq 'Standalone emergency repair' "$ADDON/functions/update_mervlan_repair.sh" || fail 'repair payload not published'
assert_eq "$(cksum "$ADDON/settings/settings.json")" "$before_settings" 'settings changed'
assert_eq "$(cksum "$ADDON/.ssh/vlan_manager")" "$before_key" 'SSH key changed'
assert_eq "$(cksum "$ADDON/tmp/mac_shield.db")" "$before_db" 'database changed'
[ "$(stat -c %a "$ADDON/functions/update_mervlan.sh")" = 755 ] || fail 'script mode'
[ "$(stat -c %a "$ADDON/settings/lib_json.sh")" = 644 ] || fail 'library mode'

setup_case missing-helper main
manifest="$REMOTE_TREE/functions/update_mervlan_repair.manifest"
sed '/^0755 functions\/mervlan_wan\.sh$/d' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
repack_remote
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'missing WAN helper manifest succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'missing helper published files'

setup_case helper-mode main
manifest="$REMOTE_TREE/functions/update_mervlan_repair.manifest"
sed 's/^0755 functions\/mervlan_wan\.sh$/0644 functions\/mervlan_wan.sh/' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
repack_remote
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'non-0755 WAN helper manifest succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'non-0755 helper published files'

setup_case download main
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_TEST_FAIL_DOWNLOAD=1 run_repair main && fail 'forced download failure succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'download failure published files'

# Legacy .15 direct CLI mutators are identified from exact NUL-delimited
# /proc/<pid>/cmdline arguments.  A matching live process blocks; a command
# that merely mentions the path as data does not.
make_proc_entry() {
  _mpe_root="$1" _mpe_pid="$2" _mpe_arg="$3" _mpe_cwd="${4:-}"
  mkdir -p "$_mpe_root/$_mpe_pid"
  printf 'sh\000%s\000' "$_mpe_arg" >"$_mpe_root/$_mpe_pid/cmdline"
  cat "/proc/$$/stat" >"$_mpe_root/$_mpe_pid/stat"
  [ -z "$_mpe_cwd" ] || ln -s "$_mpe_cwd" "$_mpe_root/$_mpe_pid/cwd"
}

setup_case legacy-updater main
make_proc_entry "$CASE/proc" "$$" "$ADDON/functions/update_mervlan.sh"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'live legacy updater was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'live legacy updater changed files'

setup_case legacy-installer main
make_proc_entry "$CASE/proc" "$$" "$ADDON/install.sh"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'live legacy installer was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'live legacy installer changed files'

# v0.53.15 documented invocations use a shell plus a relative script argv.
# Resolve only candidate argv values through the process' real /proc cwd; a
# missing or unverifiable cwd is deliberately blocking rather than guessed.
setup_case legacy-relative-root-updater main
make_proc_entry "$CASE/proc" "$$" 'functions/update_mervlan.sh' "$ADDON"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'root-relative legacy updater was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'root-relative updater changed files'

setup_case legacy-relative-functions-updater main
make_proc_entry "$CASE/proc" "$$" 'update_mervlan.sh' "$ADDON/functions"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'functions-relative legacy updater was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'functions-relative updater changed files'

setup_case legacy-relative-root-installer main
make_proc_entry "$CASE/proc" "$$" 'install.sh' "$ADDON"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'root-relative legacy installer was not blocked'

setup_case legacy-relative-root-uninstaller main
make_proc_entry "$CASE/proc" "$$" 'uninstall.sh' "$ADDON"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'root-relative legacy uninstaller was not blocked'

setup_case legacy-boot-wrap main
make_proc_entry "$CASE/proc" "$$" "$ADDON/functions/mervlan_boot_wrap.sh"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'live legacy boot wrapper was not blocked'

setup_case legacy-relative-unverifiable-cwd main
make_proc_entry "$CASE/proc" "$$" 'functions/update_mervlan.sh'
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'candidate with unavailable cwd was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'unverifiable cwd changed files'

setup_case legacy-relative-decoy main
make_proc_entry "$CASE/proc" "$$" 'unrelated.sh' "$ADDON"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main || fail 'unrelated relative argv was treated as a mutator'

setup_case legacy-event-lock main
make_proc_entry "$CASE/proc" "$$" "$ADDON/functions/unrelated.sh"
mkdir -p "$CASE/locks/vlan_event.lock"
printf '%s\n' "$$" >"$CASE/locks/vlan_event.lock/pid"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'live legacy event lock was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'live legacy event lock changed files'

setup_case legacy-decoy main
make_proc_entry "$CASE/proc" "$$" "sh -c echo $ADDON/functions/update_mervlan.sh"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main || fail 'decoy command text was treated as a live mutator'

setup_case legacy-dead-lock main
mkdir -p "$CASE/locks/vlan_event.lock"
printf '999999\n' >"$CASE/locks/vlan_event.lock/pid"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main || fail 'dead legacy lock blocked repair'

setup_case legacy-unobservable main
make_proc_entry "$CASE/proc" "$$" "$ADDON/functions/update_mervlan.sh"
printf 'not-a-stat\n' >"$CASE/proc/$$/stat"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'unverifiable legacy process was not blocked'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'unverifiable legacy process changed files'
printf '%s\n' 'PASS: exact legacy CLI/process identity and lock exclusion contracts'

# A canonical lock can be reclaimed only after a dead/mismatched owner is
# proved. A live PID with malformed or unreadable /proc identity stays in
# place: rescue must not quarantine or replace ambiguous ownership.
setup_case canonical-owner-unobservable main
make_proc_entry "$CASE/proc" "$$" 'unrelated.sh' "$ADDON"
printf 'not-a-stat\n' >"$CASE/proc/$$/stat"
mkdir -p "$CASE/locks/mervlan_maintenance.lock"
owner_start=$(awk '{print $22}' "/proc/$$/stat")
owner_now=$(date +%s)
printf 'pid=%s\nproc_start_time=%s\nowner_nonce=live-owner\ncreated=%s\nheartbeat=%s\n' \
  "$$" "$owner_start" "$owner_now" "$owner_now" >"$CASE/locks/mervlan_maintenance.lock/owner"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'unobservable canonical owner was reclaimed'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'unobservable canonical owner changed files'
[ -d "$CASE/locks/mervlan_maintenance.lock" ] || fail 'unobservable canonical lock was replaced'
grep -Fqx 'owner_nonce=live-owner' "$CASE/locks/mervlan_maintenance.lock/owner" || fail 'unobservable canonical owner was quarantined'
printf '%s\n' 'PASS: canonical-owner unobservable identity blocks takeover'

setup_case canonical-owner-live main
make_proc_entry "$CASE/proc" "$$" 'unrelated.sh' "$ADDON"
mkdir -p "$CASE/locks/mervlan_maintenance.lock"
owner_start=$(awk '{print $22}' "/proc/$$/stat")
owner_now=$(date +%s)
printf 'pid=%s\nproc_start_time=%s\nowner_nonce=matching-owner\ncreated=%s\nheartbeat=%s\n' \
  "$$" "$owner_start" "$owner_now" "$owner_now" >"$CASE/locks/mervlan_maintenance.lock/owner"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main && fail 'matching canonical owner was not blocked'
[ -d "$CASE/locks/mervlan_maintenance.lock" ] || fail 'matching canonical lock was replaced'

setup_case canonical-owner-reused main
make_proc_entry "$CASE/proc" "$$" 'unrelated.sh' "$ADDON"
mkdir -p "$CASE/locks/mervlan_maintenance.lock"
owner_now=$(date +%s)
printf 'pid=%s\nproc_start_time=1\nowner_nonce=reused-owner\ncreated=%s\nheartbeat=%s\n' \
  "$$" "$owner_now" "$owner_now" >"$CASE/locks/mervlan_maintenance.lock/owner"
MERV_REPAIR_PROC_ROOT="$CASE/proc" run_repair main || fail 'readable reused canonical owner blocked repair'
find "$CASE/locks" -maxdepth 1 -type d -name 'mervlan_maintenance.lock.repair-stale.*' | grep . \
  || fail 'readable reused canonical owner was not quarantined'
printf '%s\n' 'PASS: canonical owner blocks only live/unknown identities and reclaims reused identity'

setup_case prior-workspace main
mkdir "$CASE/work/mervlan_repair.1.2.3"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'preserved prior repair workspace was reused'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'prior workspace changed active files'

setup_case invalid main
printf 'if then\n' > "$REMOTE_TREE/functions/update_mervlan.sh"
repack_remote
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'invalid shell payload succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'invalid shell payload published files'

setup_case rollback main
old=$(cksum "$ADDON/functions/update_mervlan.sh")
old_installer=$(cksum "$ADDON/install.sh")
MERV_REPAIR_TEST_FAIL_PATH=functions/mervlan_boot.sh run_repair main && fail 'forced publication failure succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'rollback did not restore earlier file'
assert_eq "$(cksum "$ADDON/install.sh")" "$old_installer" 'rollback did not restore top-level file'
find "$ADDON" -name '*.repair.*' | grep . && fail 'publication temporary file remained'
for evidence in "$CASE"/work/mervlan_repair.*; do
  ls -ld "$evidence" >/dev/null 2>&1 || continue
  rm -rf "$evidence"
done

# Replace the canonical owner during the publication syscall. The repair must
# detect the successor at post-publication finalization, avoid rolling back
# after ownership is lost, and retain both the successor record and evidence.
setup_case replacement-race main
mkdir -p "$CASE/bin"
cat >"$CASE/bin/mv" <<'EOF'
#!/bin/sh
if [ "${MERV_REPAIR_TEST_RACE:-0}" = 1 ] &&
   [ "${MERV_REPAIR_TEST_RACE_MARKED:-0}" != 1 ] &&
   [ "$#" -ge 3 ] && [ "$1" = -f ] &&
   [ "$3" = "$MERV_BASE/functions/update_mervlan.sh" ] &&
   [ ! -e "$MERV_REPAIR_TEST_RACE_MARKER" ]; then
  _race_pid="$PPID"
  _race_stat=$(cat "/proc/$_race_pid/stat" 2>/dev/null || printf '')
  _race_after=${_race_stat#*)}
  set -- $_race_after
  _race_start=${20:-1}
  _race_now=$(date +%s 2>/dev/null || printf 1)
  _race_tmp="$MERV_REPAIR_MAINTENANCE_LOCK/owner.successor.$$"
  printf 'pid=%s\nproc_start_time=%s\nowner_nonce=successor\ncreated=%s\nheartbeat=%s\n' \
    "$_race_pid" "$_race_start" "$_race_now" "$_race_now" >"$_race_tmp"
  chmod 600 "$_race_tmp"
  /bin/mv -f "$_race_tmp" "$MERV_REPAIR_MAINTENANCE_LOCK/owner"
  : >"$MERV_REPAIR_TEST_RACE_MARKER"
fi
exec /bin/mv "$@"
EOF
chmod 755 "$CASE/bin/mv"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
if PATH="$CASE/bin:$PATH" MERV_REPAIR_TEST_RACE=1 \
   MERV_REPAIR_TEST_RACE_MARKER="$CASE/race-marker" run_repair main; then
  fail 'owner replacement race was reported as successful'
fi
[ -f "$CASE/locks/mervlan_maintenance.lock/owner" ] || fail 'replacement owner record disappeared'
grep -Fqx 'owner_nonce=successor' "$CASE/locks/mervlan_maintenance.lock/owner" || fail 'successor owner was not retained'
race_evidence=0
for evidence in "$CASE"/work/mervlan_repair.*; do
  if [ -d "$evidence" ]; then race_evidence=1; break; fi
done
[ "$race_evidence" = 1 ] || fail 'replacement race evidence was not retained'
printf '%s\n' 'PASS: canonical-owner replacement race stops finalization safely'

setup_case custom feature/test
run_repair feature/test || fail 'safe slash custom branch rejected'
MERV_BASE="$ADDON" MERV_REPAIR_CURL="$CASE/fake-curl" \
  MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
  MERV_REPAIR_FIXTURE_ARCHIVE="$REMOTE_ARCHIVE" \
  MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
  MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" sh "$REPAIR" '../bad' && fail 'unsafe branch accepted'

# Drift guard: update core, sync payload, and installer requirements must be
# repairable unless they are explicitly protected state.
for path in $(grep -hEo 'functions/[A-Za-z0-9_./-]+\.sh|settings/[A-Za-z0-9_./-]+\.sh|templates/[A-Za-z0-9_./-]+\.sh' \
  "$ROOT/functions/update_mervlan.sh" "$ROOT/functions/sync_nodes.sh" "$ROOT/install.sh" | sort -u); do
  [ -f "$ROOT/$path" ] || continue
  [ "$path" = settings/settings.json ] && continue
  grep -Fq " $path" "$MANIFEST" || fail "manifest drift: $path"
done

printf '%s\n' 'PASS: standalone repair isolation, failure rollback, branch, mode, and manifest-drift contracts'
