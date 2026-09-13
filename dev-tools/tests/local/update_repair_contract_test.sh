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
  while IFS=' ' read -r mode path; do
    case "$mode" in format=1|\#*|'') continue;; esac
    case "$path" in */*) parent=${path%/*};; *) parent=.;; esac
    mkdir -p "$remote/$branch/$parent"
    cp "$ROOT/$path" "$remote/$branch/$path"
  done < "$MANIFEST"
}

setup_case() {
  name="$1"; branch="${2:-main}"
  CASE="$WORK/$name"; ADDON="$CASE/addon"; REMOTE="$CASE/remote"
  mkdir -p "$ADDON/functions" "$ADDON/settings" "$ADDON/.ssh" "$ADDON/tmp"
  printf 'old-installer\n' > "$ADDON/install.sh"
  printf 'old-updater\n' > "$ADDON/functions/update_mervlan.sh"
  printf '{"keep":"settings"}\n' > "$ADDON/settings/settings.json"
  printf 'private-key\n' > "$ADDON/.ssh/vlan_manager"
  printf 'db-state\n' > "$ADDON/tmp/mac_shield.db"
  build_remote "$REMOTE" "$branch"
  cat > "$CASE/fake-curl" <<'EOF'
#!/bin/sh
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2;; *) url="$1"; shift;; esac
done
path=${url#*"/$MERV_REPAIR_TEST_BRANCH/"}
[ "$path" != "$url" ] || exit 2
[ "${MERV_REPAIR_TEST_FAIL_DOWNLOAD:-}" != "$path" ] || exit 22
cp "$MERV_REPAIR_FIXTURE_REMOTE/$MERV_REPAIR_TEST_BRANCH/$path" "$out"
EOF
  chmod 755 "$CASE/fake-curl"
}

run_repair() {
  MERV_BASE="$ADDON" MERV_REPAIR_CURL="$CASE/fake-curl" \
  MERV_REPAIR_RAW_BASE='https://repair.test' MERV_REPAIR_FIXTURE_REMOTE="$REMOTE" \
  MERV_REPAIR_TEST_BRANCH="$1" sh "$REPAIR" "$1"
}

grep -Eq '^[[:space:]]*\.[[:space:]]|^[[:space:]]*source[[:space:]]' "$REPAIR" && fail 'repair script must not source MerVLAN code'
sh -n "$REPAIR" || fail 'repair shell syntax'
[ "$(grep -Fc 'if ! run_trunk_if_configured; then' "$MANAGER")" -ge 1 ] || fail 'manager must stop after trunk failure'
grep -Fq '[ -x "$_update_tree/functions/mervlan_wan.sh" ]' "$UPDATER" || fail 'updater tree validation must require executable WAN helper'
[ "$(grep -Fc 'functions/mervlan_wan.sh) [ -x "$MERV_BASE/$_req" ]' "$INSTALLER")" -ge 2 ] || fail 'installer standard/final validation must require executable WAN helper'
[ "$(sed -n '1p' "$MANIFEST")" = 'format=1' ] || fail 'manifest format header'
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
manifest="$REMOTE/main/functions/update_mervlan_repair.manifest"
sed '/^0755 functions\/mervlan_wan\.sh$/d' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'missing WAN helper manifest succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'missing helper published files'

setup_case helper-mode main
manifest="$REMOTE/main/functions/update_mervlan_repair.manifest"
sed 's/^0755 functions\/mervlan_wan\.sh$/0644 functions\/mervlan_wan.sh/' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
old=$(cksum "$ADDON/functions/update_mervlan.sh")
run_repair main && fail 'non-0755 WAN helper manifest succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'non-0755 helper published files'

setup_case download main
old=$(cksum "$ADDON/functions/update_mervlan.sh")
MERV_REPAIR_TEST_FAIL_DOWNLOAD=functions/mervlan_boot.sh run_repair main && fail 'forced download failure succeeded'
assert_eq "$(cksum "$ADDON/functions/update_mervlan.sh")" "$old" 'download failure published files'

setup_case invalid main
printf 'if then\n' > "$REMOTE/main/functions/update_mervlan.sh"
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

setup_case custom feature/test
run_repair feature/test || fail 'safe slash custom branch rejected'
MERV_BASE="$ADDON" MERV_REPAIR_CURL="$CASE/fake-curl" sh "$REPAIR" '../bad' && fail 'unsafe branch accepted'

# Drift guard: update core, sync payload, and installer requirements must be
# repairable unless they are explicitly protected state.
for path in $(grep -hEo 'functions/[A-Za-z0-9_./-]+\.sh|settings/[A-Za-z0-9_./-]+\.sh|templates/[A-Za-z0-9_./-]+\.sh' \
  "$ROOT/functions/update_mervlan.sh" "$ROOT/functions/sync_nodes.sh" "$ROOT/install.sh" | sort -u); do
  [ -f "$ROOT/$path" ] || continue
  [ "$path" = settings/settings.json ] && continue
  grep -Fq " $path" "$MANIFEST" || fail "manifest drift: $path"
done

printf '%s\n' 'PASS: standalone repair isolation, failure rollback, branch, mode, and manifest-drift contracts'
