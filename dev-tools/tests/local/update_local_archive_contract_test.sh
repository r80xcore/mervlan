#!/bin/sh
# Local-only contract coverage for the safe local-archive Update source.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
UPDATER="$ROOT/functions/update_mervlan.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-local-update.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
expect_reject() {
  if "$@"; then
    fail "accepted: $*"
  fi
  return 0
}

# Exercise the exact production helper bodies without invoking an Update.
HELPERS="$WORK/helpers.sh"
sed -n '/^# LOCAL ARCHIVE HELPERS BEGIN$/,/^# LOCAL ARCHIVE HELPERS END$/p' "$UPDATER" |
  sed '/^# LOCAL ARCHIVE HELPERS /d' >"$HELPERS"
sed -n '/^# CORE STAGE VALIDATOR BEGIN$/,/^# CORE STAGE VALIDATOR END$/p' "$UPDATER" |
  sed '/^# CORE STAGE VALIDATOR /d' >>"$HELPERS"
[ -s "$HELPERS" ] || fail 'helper extraction failed'

TMP_BASE="$WORK/owned"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"
RAW_ARCHIVE="$TMP_BASE/mervlan.tar"
mkdir -p "$TMP_BASE"
info() { :; }
warn() { :; }
. "$HELPERS"

make_regular_archive() {
  _mla_archive="$1"
  _mla_root="$WORK/build-$2"
  rm -rf "$_mla_root"
  mkdir -p "$_mla_root/package"
  printf 'payload\n' >"$_mla_root/package/file"
  tar -czf "$_mla_archive" -C "$_mla_root" package
}

valid="$WORK/valid.tar.gz"
make_regular_archive "$valid" valid
before=$(cksum "$valid")
acquire_local_update_archive "$valid" "$ARCHIVE" || fail 'valid local acquisition'
[ "$(cksum "$valid")" = "$before" ] || fail 'local source was modified'
validate_update_archive_members "$ARCHIVE" || fail 'valid local archive rejected'
[ "$UPDATE_ARCHIVE_TOPDIR" = package ] || fail 'valid archive top root was not recorded'
[ -s "$ARCHIVE" ] && [ ! -e "$ARCHIVE.part" ] || fail 'owned archive publication is not atomic/complete'
pass local-acquisition-and-safe-regular-archive

expect_reject acquire_local_update_archive relative.tar.gz "$ARCHIVE"
expect_reject acquire_local_update_archive "$WORK/missing.tar.gz" "$ARCHIVE"
: >"$WORK/empty.tar.gz"
expect_reject acquire_local_update_archive "$WORK/empty.tar.gz" "$ARCHIVE"
ln -s "$valid" "$WORK/source-link.tar.gz"
expect_reject acquire_local_update_archive "$WORK/source-link.tar.gz" "$ARCHIVE"
pass local-source-path-and-file-policy

printf 'not-gzip\n' >"$WORK/corrupt.tar.gz"
expect_reject validate_update_archive_members "$WORK/corrupt.tar.gz"
printf 'not-a-tar\n' | gzip -c >"$WORK/not-tar.tar.gz"
expect_reject validate_update_archive_members "$WORK/not-tar.tar.gz"
pass corrupt-and-invalid-tar-rejected

absroot="$WORK/absolute-root"
mkdir -p "$absroot/root"
printf x >"$absroot/root/file"
tar -czPf "$WORK/absolute.tar.gz" "$absroot/root" 2>/dev/null || fail 'absolute fixture creation'
expect_reject validate_update_archive_members "$WORK/absolute.tar.gz"

mkdir -p "$WORK/traversal/root"
printf x >"$WORK/traversal/root/file"
tar -czf "$WORK/traversal.tar.gz" --transform='s|^root|../escape|' -C "$WORK/traversal" root
expect_reject validate_update_archive_members "$WORK/traversal.tar.gz"
tar -czf "$WORK/nested-traversal.tar.gz" --transform='s|^root/file|root/../file|' -C "$WORK/traversal" root
expect_reject validate_update_archive_members "$WORK/nested-traversal.tar.gz"
pass absolute-and-traversal-members-rejected

mkdir -p "$WORK/links/root"
printf x >"$WORK/links/root/regular"
ln -s regular "$WORK/links/root/symlink"
tar -czf "$WORK/symlink-member.tar.gz" -C "$WORK/links" root
expect_reject validate_update_archive_members "$WORK/symlink-member.tar.gz"
rm -f "$WORK/links/root/symlink"
ln "$WORK/links/root/regular" "$WORK/links/root/hardlink"
tar -czf "$WORK/hardlink-member.tar.gz" -C "$WORK/links" root
expect_reject validate_update_archive_members "$WORK/hardlink-member.tar.gz"
pass link-members-rejected

# ASUSWRT-Merlin BusyBox v1.25.1 target qualification (NODE1, 2026-08-24):
# verbose symlinks begin with `l`, and hardlinks are rendered as a normal file
# with ` -> target`. Exercise the exact production validator against that
# observed representation without running an Update or extracting anything.
tar() {
  case " $* " in
    *' -tzf '*) printf '%s\n' root/ root/hardlink root/symlink root/regular ;;
    *' -tvzf '*)
      printf '%s\n' \
        'drwxrwxrwx 0/0         0 2026-08-24 10:42:19 root/' \
        '-rw-rw-rw- 0/0         6 2026-08-24 10:42:19 root/hardlink' \
        'lrwxrwxrwx 0/0         0 2026-08-24 10:42:19 root/symlink -> regular' \
        '-rw-rw-rw- 0/0         0 2026-08-24 10:42:19 root/regular -> root/hardlink'
      ;;
    *) return 1 ;;
  esac
}
expect_reject validate_update_archive_members "$WORK/asus-busybox-links.tar.gz"
unset -f tar
pass asus-busybox-link-representation-rejected

mkdir -p "$WORK/roots/root-a" "$WORK/roots/root-b"
printf a >"$WORK/roots/root-a/file"; printf b >"$WORK/roots/root-b/file"
tar -czf "$WORK/multiple-roots.tar.gz" -C "$WORK/roots" root-a root-b
expect_reject validate_update_archive_members "$WORK/multiple-roots.tar.gz"
pass multiple-roots-rejected

CORE_STAGE_FILES=$(awk '
  /^CORE_STAGE_FILES="/ { sub(/^[^"]*"/, ""); in_list=1 }
  in_list {
    if ($0 ~ /"$/) { sub(/"$/, ""); print; exit }
    print
  }
' "$UPDATER")
CORE_STAGE_DIRS=$(sed -n 's/^CORE_STAGE_DIRS="\(.*\)"$/\1/p' "$UPDATER")
[ -n "$CORE_STAGE_FILES" ] && [ -n "$CORE_STAGE_DIRS" ] || fail 'core payload contract extraction failed'
stage="$WORK/stage"
mkdir -p "$stage"
for d in $CORE_STAGE_DIRS; do mkdir -p "$stage/$d"; done
for f in $CORE_STAGE_FILES; do
  case "$f" in */*) parent=${f%/*};; *) parent=.;; esac
  mkdir -p "$stage/$parent"
  printf x >"$stage/$f"
done
update_stage_core_valid "$stage" || fail 'complete synthetic core payload rejected'
rm -f "$stage/install.sh"
expect_reject update_stage_core_valid "$stage"
pass incomplete-payload-rejected-after-safe-extraction

grep -Fq 'if [ "$UPDATE_SOURCE" = "remote" ]; then' "$UPDATER" || fail 'remote curl gate missing'
grep -Fq 'acquire_local_update_archive "$UPDATE_LOCAL_ARCHIVE" "$ARCHIVE"' "$UPDATER" || fail 'local acquisition path missing'
grep -Fq 'set_update_log_policy "${3:-}"' "$UPDATER" || fail 'local log policy parsing missing'
grep -Fq 'UPDATE_SOURCE="local"' "$UPDATER" || fail 'local source state missing'
pass local-mode-avoids-curl-and-keeps-log-policy-contract

printf 'UPDATE_LOCAL_ARCHIVE_CONTRACT_OK\n'
