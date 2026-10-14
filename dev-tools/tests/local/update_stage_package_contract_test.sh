#!/bin/sh
# Archive intent must be checked before tar/umask can discard permission bits.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
UPDATER="$ROOT/functions/update_mervlan.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-stage-package.XXXXXX")
cleanup_test_artifacts() {
 rc=$?
 if [ "$rc" -eq 0 ]; then
  rm -rf "$WORK"
 else
  printf 'PACKAGE_TEST_FAILURE_ARTIFACTS=%s\n' "$WORK" >&2
  find "$WORK" -maxdepth 2 -print >&2 2>/dev/null || :
  for log in "$WORK"/*.warnings; do [ -f "$log" ] && { printf '%s\n' "--- $log" >&2; cat "$log" >&2; }; done
 fi
}
trap cleanup_test_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
for section in 'PRIVATE UPDATE WORKSPACE' 'LOCAL ARCHIVE HELPERS' 'CORE STAGE VALIDATOR' 'UPDATE ARCHIVE EXTRACTION'; do
 sed -n "/^# $section BEGIN$/,/^# $section END$/p" "$UPDATER" >>"$WORK/helpers"
done
sed -n '/^update_filter_source_tree() {/,/^}$/p' "$UPDATER" >>"$WORK/helpers"
sed -n '/^update_changelog_version() {/,/^}$/p' "$UPDATER" >>"$WORK/helpers"
sed -n '/^update_path_size_kb() {/,/^}$/p' "$UPDATER" >>"$WORK/helpers"
CORE_STAGE_FILES=$(awk '
 /^CORE_STAGE_FILES="/ { sub(/^[^"]*"/, ""); in_list=1 }
 in_list { if ($0 ~ /"$/) { sub(/"$/, ""); print; exit }; print }
' "$UPDATER")
CORE_STAGE_DIRS=$(sed -n 's/^CORE_STAGE_DIRS="\(.*\)"$/\1/p' "$UPDATER")
[ -n "$CORE_STAGE_FILES" ] && [ -n "$CORE_STAGE_DIRS" ] || fail core-list
export CORE_STAGE_FILES CORE_STAGE_DIRS
[ "$(git -C "$ROOT" ls-tree HEAD functions/mervlan_full_cleanup.sh | awk '{print $1}')" = 100755 ] || fail git-cleaner-mode
[ "$(git -C "$ROOT" ls-files -s functions/mervlan_full_cleanup.sh | awk '{print $1}')" = 100755 ] || fail index-cleaner-mode
[ "$(LC_ALL=C ls -ldn "$ROOT/functions/mervlan_full_cleanup.sh" | awk '{print $1}')" = -rwxr-xr-x ] || fail worktree-cleaner-mode
# Fixture creation is independent: regular tar stores explicitly set modes.
# Never run the production extractor/normalizer while constructing archives.
umask 022
mkdir -p "$WORK/build/package"
for d in $CORE_STAGE_DIRS; do mkdir -p "$WORK/build/package/$d"; done
for f in $CORE_STAGE_FILES; do
 case "$f" in */*) parent=${f%/*} ;; *) parent=. ;; esac
 mkdir -p "$WORK/build/package/$parent"
 printf 'fixture\n' >"$WORK/build/package/$f"
done
cp -p "$ROOT/functions/mervlan_full_cleanup.sh" "$WORK/build/package/functions/mervlan_full_cleanup.sh"
cp -p "$ROOT/settings/lib_full_uninstall.sh" "$WORK/build/package/settings/lib_full_uninstall.sh"
cp -p "$ROOT/changelog.txt" "$WORK/build/package/changelog.txt"
for variant in 0755 0775 0644 0664 0750 0777 0700 0765 missing symlink hardlink duplicate helper-syntax helper-marker cleaner-syntax cleaner-marker core-file; do
 mkdir "$WORK/build-$variant"
 cp -a "$WORK/build/package" "$WORK/build-$variant/package"
 cleaner="$WORK/build-$variant/package/functions/mervlan_full_cleanup.sh"
 chmod 0755 "$cleaner"
 case "$variant" in
  0*) chmod "$variant" "$cleaner" ;;
  missing) rm "$cleaner" ;;
  symlink) rm "$cleaner"; ln -s ../install.sh "$cleaner" ;;
  hardlink) rm "$cleaner"; ln "$WORK/build-$variant/package/install.sh" "$cleaner" ;;
  helper-syntax) printf '\nif\n' >>"$WORK/build-$variant/package/settings/lib_full_uninstall.sh" ;;
  helper-marker) sed '/^# Full helper protocol: full-uninstall-v1$/d' "$ROOT/settings/lib_full_uninstall.sh" >"$WORK/build-$variant/package/settings/lib_full_uninstall.sh" ;;
  cleaner-syntax) printf '\nif\n' >>"$cleaner" ;;
  cleaner-marker) sed '/^# Cleaner protocol: phase6-v1$/d' "$ROOT/functions/mervlan_full_cleanup.sh" >"$cleaner" ;;
  core-file) rm "$WORK/build-$variant/package/install.sh" ;;
 esac
 # Normalize only fixture owner IDs to 0 so isolated root tar can restore
 # them. Modes come independently from explicit fixture chmod, never helper.
 python3 - "$WORK" "$variant" <<'FIXTURE'
import sys,tarfile
from pathlib import Path
work=Path(sys.argv[1]); variant=sys.argv[2]
def owner(info):
 info.uid=info.gid=0
 info.uname=info.gname=''
 return info
with tarfile.open(work/(variant+'.tar'),'w',format=tarfile.USTAR_FORMAT) as archive:
 archive.add(work/('build-'+variant)/'package',arcname='package',filter=owner)
 if variant=='duplicate':
  archive.add(work/('build-'+variant)/'package/functions/mervlan_full_cleanup.sh',arcname='package/functions/mervlan_full_cleanup.sh',filter=owner)
FIXTURE
 gzip -c "$WORK/$variant.tar" >"$WORK/$variant.tar.gz"
done
for spec in A-0775 B-0755 C-0777 D-0644; do
 identity=${spec%%-*}
 mode=${spec#*-}
 mkdir "$WORK/build-race-$spec"
 cp -a "$WORK/build/package" "$WORK/build-race-$spec/package"
 printf '\n# ARCHIVE_IDENTITY=%s\n' "$identity" >>"$WORK/build-race-$spec/package/functions/mervlan_full_cleanup.sh"
 chmod "$mode" "$WORK/build-race-$spec/package/functions/mervlan_full_cleanup.sh"
 python3 - "$WORK" "$spec" <<'FIXTURE'
import sys,tarfile
from pathlib import Path
work=Path(sys.argv[1]); spec=sys.argv[2]
def owner(info):
 info.uid=info.gid=0
 info.uname=info.gname=''
 return info
with tarfile.open(work/('race-'+spec+'.tar'),'w',format=tarfile.USTAR_FORMAT) as archive:
 archive.add(work/('build-race-'+spec)/'package',arcname='package',filter=owner)
FIXTURE
 gzip -c "$WORK/race-$spec.tar" >"$WORK/race-$spec.tar.gz"
done
printf 'truncated archive replacement\n' >"$WORK/replacement-truncated"
# Real Git packaging remains a separate integration fixture, not a repair tree.
git -C "$ROOT" archive --format=tar --prefix=package/ HEAD >"$WORK/git.tar"
gzip -c "$WORK/git.tar" >"$WORK/git.tar.gz"
cat >"$WORK/worker.sh" <<'WORKER'
set -eu
WORK=$1
role=$2
shellmode=$3
LOGPREFIX="$WORK/$role-$shellmode"
fail() { printf 'FAIL: %s/%s/%s\n' "$role" "$shellmode" "$*" >&2; exit 1; }
pass() { printf 'PASS: %s/%s/%s\n' "$role" "$shellmode" "$*"; }
backend=host
bb_or_host() {
 _applet="$1"; shift
 if [ "$backend" = busybox ]; then busybox "$_applet" "$@"; else command "$_applet" "$@"; fi
}
awk() { bb_or_host awk "$@"; }
cat() { bb_or_host cat "$@"; }
cmp() { bb_or_host cmp "$@"; }
cp() { bb_or_host cp "$@"; }
du() { bb_or_host du "$@"; }
grep() { bb_or_host grep "$@"; }
gzip() { bb_or_host gzip "$@"; }
id() { bb_or_host id "$@"; }
ln() { bb_or_host ln "$@"; }
ls() { bb_or_host ls "$@"; }
mkdir() { bb_or_host mkdir "$@"; }
mv() {
 _test_mv_src="$1"; _test_mv_dst="$2"
 printf '%s -> %s\n' "$_test_mv_src" "$_test_mv_dst" >>"$LOGPREFIX.mv"
 if [ "$_test_mv_src" = "$TMP_BASE/.cleaner-normalize/canonical-cleaner" ] &&
    [ "$_test_mv_dst" = "$TMP_BASE/package/functions/mervlan_full_cleanup.sh" ]; then
  case "$mv_fault" in
   publish-regular|publish-symlink|publish-directory|publish-absent)
    [ -f "$_test_mv_src" ] && [ ! -L "$_test_mv_src" ] || fail publication-hook-canonical-not-ready
    [ ! -e "$_test_mv_dst" ] && [ ! -L "$_test_mv_dst" ] || fail publication-hook-target-was-not-absent
    case "$mv_fault" in
     publish-regular)
      printf '#!/bin/sh\n# unrelated publication interference\n' >"$_test_mv_dst"
      bb_or_host chmod 0755 "$_test_mv_dst" || fail publication-hook-regular-mode ;;
     publish-symlink)
      ln -s "$LOGPREFIX.outside" "$_test_mv_dst" || fail publication-hook-symlink ;;
     publish-directory)
      mkdir "$_test_mv_dst" || fail publication-hook-directory ;;
     publish-absent) : ;;
    esac
    printf 'case=%s source=%s destination=%s target_was_absent=yes\n' \
     "$mv_fault" "$_test_mv_src" "$_test_mv_dst" >>"$LOGPREFIX.publication-injection"
    mv_fault=none ;;
  esac
 fi
 case "$_test_mv_dst:$mv_fault" in
  */.cleaner-normalize/archive-cleaner:leaf-before)
   rm -f "$TMP_BASE/package/functions/mervlan_full_cleanup.sh"
   ln -s "$LOGPREFIX.outside" "$TMP_BASE/package/functions/mervlan_full_cleanup.sh"
   mv_fault=none ;;
 esac
 bb_or_host mv "$@" || return $?
 case "$_test_mv_dst:$mv_fault" in
  */.cleaner-normalize/archive-cleaner:leaf-after)
   ln -s "$LOGPREFIX.outside" "$TMP_BASE/package/functions/mervlan_full_cleanup.sh"
   mv_fault=none ;;
 esac
 return 0
}
rm() { bb_or_host rm "$@"; }
chmod() { printf '%s\n' "$*" >>"$LOGPREFIX.chmod"; bb_or_host chmod "$@"; }
chown() { printf '%s\n' "$*" >>"$LOGPREFIX.chown"; bb_or_host chown "$@"; }
if [ "$role" = root ]; then [ "$(id -u)" = 0 ] || fail uid; else [ "$(id -u)" != 0 ] || fail uid; fi
# A caller's forged classification is erased when the real helpers load.
UPDATE_ARCHIVE_CLEANER_MODE=0775
_update_archive_validated_input=forged
. "$WORK/helpers"
[ -z "$UPDATE_ARCHIVE_CLEANER_MODE$_update_archive_validated_input" ] || fail inherited-admission
info() { :; }
warn() { printf '%s\n' "$*" >>"$LOGPREFIX.warnings"; }
format=gzip
transform=none
mv_fault=none
tar() {
 # Force the actual production gzip-list fallback, not a separate scanner.
 if [ "$format" = raw ]; then
  case "$1" in -tzf|-tvzf) return 1 ;; esac
 fi
 case "$1" in -xf|-xzf)
  printf 'extract\n' >>"$LOGPREFIX.extract"
  if [ "$backend" = busybox ]; then busybox tar "$@" || return 1; else command tar "$@" || return 1; fi
  case "$transform" in
   none) ;;
   0*) bb_or_host chmod "$transform" "$TMP_BASE/package/functions/mervlan_full_cleanup.sh" ;;
   symlink)
    rm "$TMP_BASE/package/functions/mervlan_full_cleanup.sh"
    ln -s "$LOGPREFIX.outside" "$TMP_BASE/package/functions/mervlan_full_cleanup.sh" ;;
   parent-symlink)
    rm -rf "$TMP_BASE/package/functions"
    ln -s "$LOGPREFIX.outside-dir" "$TMP_BASE/package/functions" ;;
  esac
  ;;
 *) if [ "$backend" = busybox ]; then busybox tar "$@"; else command tar "$@"; fi ;;
 esac
}
seq=0
setup() {
 seq=$((seq+1))
 TMP_DIR="$WORK"
 TMP_BASE="$TMP_DIR/$role-$shellmode-case-$seq"
 ARCHIVE="$TMP_BASE/mervlan.tar.gz"
 RAW_ARCHIVE="$TMP_BASE/raw.tar"
 STAGE_DIR="$TMP_BASE/stage"
 BACKUP_DIR="$TMP_BASE/backup"
 update_prepare_private_workspace || fail workspace-private-0700
 : >"$LOGPREFIX.warnings"
 : >"$LOGPREFIX.chmod"
 : >"$LOGPREFIX.chown"
 : >"$LOGPREFIX.publication-injection"
 : >"$LOGPREFIX.extract"
 : >"$LOGPREFIX.mv"
 transform=none
 mv_fault=none
}
extract_validated() {
 update_extract_archive "$TMP_BASE" "$UPDATE_ARCHIVE_FORMAT" || return 1
 update_close_stable_archive
}
admit_input() {
 cp "$input" "$ARCHIVE" || fail archive-copy
 validate_update_archive_members "$ARCHIVE"
}
setup
[ "$(LC_ALL=C ls -ldn "$TMP_BASE" | awk '{print $1}')" = drwx------ ] || fail workspace-mode-0700
[ "$(LC_ALL=C ls -ldn "$TMP_BASE" | awk '{print $3}')" = "$(id -u)" ] || fail workspace-owner
[ "$(LC_ALL=C ls -ldn "$STAGE_DIR" | awk '{print $1}')" = drwx------ ] || fail stage-workspace-mode
[ "$(LC_ALL=C ls -ldn "$BACKUP_DIR" | awk '{print $1}')" = drwx------ ] || fail backup-workspace-mode
shared_mode=$(LC_ALL=C ls -ldn "$TMP_DIR" | awk '{print $1}')
rm -rf "$TMP_BASE"
TMP_BASE="$TMP_DIR/stale-existing"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"; RAW_ARCHIVE="$TMP_BASE/raw.tar"
STAGE_DIR="$TMP_BASE/stage"; BACKUP_DIR="$TMP_BASE/backup"
mkdir "$TMP_BASE"
printf keep >"$TMP_BASE/marker"
if update_prepare_private_workspace; then fail stale-workspace-reused; fi
[ "$(cat "$TMP_BASE/marker")" = keep ] || fail stale-workspace-mutated
rm -rf "$TMP_BASE"
TMP_BASE="$TMP_DIR/stale-symlink"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"; RAW_ARCHIVE="$TMP_BASE/raw.tar"
STAGE_DIR="$TMP_BASE/stage"; BACKUP_DIR="$TMP_BASE/backup"
ln -s "$WORK/build/package" "$TMP_BASE"
if update_prepare_private_workspace; then fail symlink-workspace-accepted; fi
[ -L "$TMP_BASE" ] || fail symlink-workspace-removed
rm -f "$TMP_BASE"
TMP_DIR="$WORK/untrusted-child-$role-$shellmode"
TMP_BASE="$TMP_DIR/updates-test"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"; RAW_ARCHIVE="$TMP_BASE/raw.tar"
STAGE_DIR="$TMP_BASE/stage"; BACKUP_DIR="$TMP_BASE/backup"
mkdir "$TMP_DIR"
bb_or_host chmod 0777 "$TMP_DIR"
if update_prepare_private_workspace; then fail world-writable-parent-accepted; fi
[ "$(LC_ALL=C ls -ldn "$TMP_DIR" | awk '{print $1}')" = drwxrwxrwx ] || fail shared-root-permission-mutated
bb_or_host chmod 0755 "$TMP_DIR"
[ "$shared_mode" = drwx------ ] || fail test-shared-parent-unexpected-mode
pass private-workspace-0700-owner-freshness-and-stale-path-rejection
setup
input="$WORK/race-A-0775.tar.gz"
cp "$input" "$ARCHIVE"
printf 'reserved descriptor sentinel\n' >"$WORK/fd9-sentinel"
exec 9<"$WORK/fd9-sentinel"
if validate_update_archive_members "$ARCHIVE"; then fail descriptor-collision-accepted; fi
grep -Fq 'reserved descriptor 9 is already in use' "$LOGPREFIX.warnings" || fail descriptor-collision-diagnostic
[ -f "/proc/$$/fd/9" ] || fail descriptor-collision-was-closed
[ -f "$ARCHIVE" ] || fail descriptor-collision-unpublished-input
exec 9<&-
rm -rf "$TMP_BASE"
pass stable-descriptor-collision-is-fail-closed
for backend in host busybox; do
 for format in gzip raw; do
  for mask in 022 077; do
   for mode in 0755 0775; do
    setup
    input="$WORK/$mode.tar.gz"
    admit_input || fail "$backend/$format/$mask/$mode admission"
    [ ! -e "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || fail archive-name-not-unpublished
    [ "${UPDATE_ARCHIVE_FD_PATH}" = "/proc/$$/fd/9" ] && [ -f "$UPDATE_ARCHIVE_FD_PATH" ] || fail stable-fd-open
    [ "$UPDATE_ARCHIVE_CLEANER_MODE" = "$mode" ] || fail archive-mode-record
    [ "$UPDATE_ARCHIVE_TOPDIR" = package ] || fail archive-root
    stable_fd_path=$UPDATE_ARCHIVE_FD_PATH
    (
     umask "$mask"
     before=$(umask)
     extract_validated || fail extraction
     [ "$(umask)" = "$before" ] || fail caller-mask
    )
    update_close_stable_archive || fail parent-descriptor-close
    [ ! -e "$stable_fd_path" ] && [ ! -L "$stable_fd_path" ] || fail descriptor-close-still-published
    if [ "$format" = raw ]; then
     if tar -tf "$stable_fd_path" >/dev/null 2>&1; then fail descriptor-close-still-usable; fi
    else
     if tar -tzf "$stable_fd_path" >/dev/null 2>&1; then fail descriptor-close-still-usable; fi
    fi
    update_stage_core_valid "$TMP_BASE/package" || fail final-stage
    [ "$(LC_ALL=C ls -ldn "$TMP_BASE/package/functions/mervlan_full_cleanup.sh" | awk '{print $1}')" = -rwxr-xr-x ] || fail final-mode
    grep -Fq "$TMP_BASE/.cleaner-normalize/canonical-cleaner" "$LOGPREFIX.chmod" || fail updater-created-canonical-chmod
    case "$(cat "$LOGPREFIX.chmod")" in *"$TMP_BASE/package/functions/mervlan_full_cleanup.sh"*) fail archive-derived-path-chmod ;; esac
    [ "$(LC_ALL=C ls -ldn "$TMP_BASE/.cleaner-normalize" | awk '{print $1}')" = drwx------ ] || fail normalization-workspace-mode
   done
   for mode in 0644 0664 0750 0777 0700 0765; do
    setup
    input="$WORK/$mode.tar.gz"
    UPDATE_ARCHIVE_CLEANER_MODE=0775
    if admit_input; then fail "$mode admitted"; fi
    [ -z "$UPDATE_ARCHIVE_CLEANER_MODE" ] || fail rejected-admission-retained
    grep -Fq "Archive cleaner mode invalid: $mode; expected 0755 or known codeload 0775" "$LOGPREFIX.warnings" || fail "$mode diagnostic"
    # Deliberately try extraction after rejection. No tar -x or chmod may run.
    if extract_validated; then fail "$mode extracted after rejection"; fi
    [ ! -s "$LOGPREFIX.extract" ] && [ ! -s "$LOGPREFIX.chmod" ] || fail pre-extraction-boundary
   done
  done
 done
done
pass source-mode-matrix-both-tars-formats-masks-pre-extraction
# Demonstrate the exact bypass mechanism independently, then prove rejection.
if [ "$role" = nonroot ]; then
 mkdir "$LOGPREFIX.laundering"
 (umask 022; command tar -xf "$WORK/0777.tar" -C "$LOGPREFIX.laundering")
 [ "$(LC_ALL=C ls -ldn "$LOGPREFIX.laundering/package/functions/mervlan_full_cleanup.sh" | awk '{print $1}')" = -rwxr-xr-x ] || fail laundering-fixture
 update_stage_core_valid "$LOGPREFIX.laundering/package" || fail qc1-bypass-not-reproduced
 setup
 input="$WORK/0777.tar.gz"
 if admit_input; then fail laundering-admitted; fi
 [ ! -s "$LOGPREFIX.extract" ] || fail laundering-extracted
 pass qc1-0777-laundering-reproduced-and-blocked-before-extraction
fi
# Every listing/extraction path must consume the held archive object after its
# public transaction pathname is removed. Recreate that pathname with malformed,
# truncated, and different valid archives to prove it has no authority.
race_repeat=${MERV_PACKAGE_RACE_ITERATIONS:-100}
case "$race_repeat" in ''|*[!0-9]*) fail invalid-race-repeat ;; esac
for backend in host busybox; do
 for format in gzip raw; do
  i=1
  while [ "$i" -le "$race_repeat" ]; do
   setup
   input="$WORK/race-A-0775.tar.gz"
    admit_input || fail "$backend/$format/race admission"
    [ ! -e "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || fail archive-name-not-unpublished
    if cat "$ARCHIVE" >/dev/null 2>&1; then
     fail archive-path-still-readable-after-freeze
    fi
    case $((i % 4)) in
    0) replacement="$WORK/replacement-truncated"; replacement_raw="$WORK/replacement-truncated" ;;
    1) replacement="$WORK/race-B-0755.tar.gz"; replacement_raw="$WORK/race-B-0755.tar" ;;
    2) replacement="$WORK/race-C-0777.tar.gz"; replacement_raw="$WORK/race-C-0777.tar" ;;
    3) replacement="$WORK/race-D-0644.tar.gz"; replacement_raw="$WORK/race-D-0644.tar" ;;
   esac
   cp "$replacement" "$ARCHIVE" || fail recreate-old-archive-name
   replacement_sum=$(cksum "$ARCHIVE")
   if [ "$format" = raw ]; then
    [ ! -e "$RAW_ARCHIVE" ] && [ ! -L "$RAW_ARCHIVE" ] || fail raw-name-not-unpublished
    if cat "$RAW_ARCHIVE" >/dev/null 2>&1; then
     fail raw-path-still-readable-after-freeze
    fi
    cp "$replacement_raw" "$RAW_ARCHIVE" || fail recreate-old-raw-name
    raw_replacement_sum=$(cksum "$RAW_ARCHIVE")
   fi
   extract_validated || fail "$backend/$format/path-replacement-extraction"
   grep -Fq '# ARCHIVE_IDENTITY=A' "$TMP_BASE/package/functions/mervlan_full_cleanup.sh" || fail "$backend/$format/extracted-replacement-bytes"
   if grep -Fq '# ARCHIVE_IDENTITY=B' "$TMP_BASE/package/functions/mervlan_full_cleanup.sh"; then fail extracted-replacement-B; fi
   [ "$(cksum "$ARCHIVE")" = "$replacement_sum" ] || fail replacement-path-was-consumed
   if [ "$format" = raw ]; then [ "$(cksum "$RAW_ARCHIVE")" = "$raw_replacement_sum" ] || fail raw-replacement-path-was-consumed; fi
   [ ! -e "/proc/$$/fd/9" ] && [ ! -L "/proc/$$/fd/9" ] || fail descriptor-not-closed
   rm -rf "$TMP_BASE"
   i=$((i + 1))
  done
 done
done
pass "archive-object-path-replacement-gzip-and-raw-fallback-stress-${race_repeat}x-per-backend-format"
for backend in host busybox; do
 for format in gzip raw; do
  for variant in missing symlink hardlink duplicate; do
   setup
   input="$WORK/$variant.tar.gz"
   if admit_input; then fail "$variant admitted"; fi
   if extract_validated; then fail "$variant extracted"; fi
   [ ! -s "$LOGPREFIX.extract" ] && [ ! -s "$LOGPREFIX.chmod" ] || fail path-type-boundary
  done
  for variant in helper-syntax helper-marker cleaner-syntax cleaner-marker core-file; do
   setup
   input="$WORK/$variant.tar.gz"
   admit_input || fail "$variant mode admission"
   case "$variant" in
    cleaner-syntax|cleaner-marker)
     if extract_validated; then fail "$variant was published"; fi
     update_stage_core_valid "$WORK/build-$variant/package" && fail "$variant stage contract accepted"
     if [ "$variant" = cleaner-syntax ]; then
      expected='Canonical cleaner failed shell syntax validation'
      stage_expected='functions/mervlan_full_cleanup.sh failed shell syntax validation'
     else
      expected='Canonical cleaner protocol marker missing (expected phase6-v1)'
      stage_expected='cleaner protocol marker missing (expected phase6-v1)'
     fi
     grep -Fq "$expected" "$LOGPREFIX.warnings" || fail "$variant canonical diagnostic"
     grep -Fq "$stage_expected" "$LOGPREFIX.warnings" || fail "$variant stage diagnostic"
     continue ;;
   esac
   extract_validated || fail "$variant extraction"
   if update_stage_core_valid "$TMP_BASE/package"; then fail "$variant stage accepted"; fi
   case "$variant" in
    helper-syntax) expected='settings/lib_full_uninstall.sh failed shell syntax validation' ;;
    helper-marker) expected='Full helper protocol marker missing (expected full-uninstall-v1)' ;;
    cleaner-syntax) expected='functions/mervlan_full_cleanup.sh failed shell syntax validation' ;;
    cleaner-marker) expected='cleaner protocol marker missing (expected phase6-v1)' ;;
    core-file) expected='Missing core file in stage: install.sh' ;;
   esac
   grep -Fq "$expected" "$LOGPREFIX.warnings" || fail "$variant diagnostic"
  done
 done
done
pass missing-links-duplicates-and-special-stage-predicates
# Fault injection alters only independent fixture extraction, not admission.
backend=busybox
format=gzip
printf 'outside\n' >"$LOGPREFIX.outside"
command chmod 0775 "$LOGPREFIX.outside"
mkdir "$LOGPREFIX.outside-dir"
cp -p "$LOGPREFIX.outside" "$LOGPREFIX.outside-dir/mervlan_full_cleanup.sh"
for pair in 0755:0775 0755:0750 0775:0777 0775:0750 0775:symlink 0775:parent-symlink; do
 setup
 source_mode=${pair%%:*}
 input="$WORK/$source_mode.tar.gz"
 admit_input || fail transformation-admission
 transform=${pair#*:}
 if extract_validated; then fail "$pair transformation accepted"; fi
 [ ! -s "$LOGPREFIX.chmod" ] || fail "$pair repaired unexpectedly"
 [ "$(LC_ALL=C ls -ldn "$LOGPREFIX.outside" | awk '{print $1}')" = -rwxrwxr-x ] || fail followed-leaf-symlink
 [ "$(LC_ALL=C ls -ldn "$LOGPREFIX.outside-dir/mervlan_full_cleanup.sh" | awk '{print $1}')" = -rwxrwxr-x ] || fail followed-parent-symlink
done
for target_mode in 0775 0755; do
 setup
 input="$WORK/0775.tar.gz"
 admit_input || fail normalization-admission
 transform=$target_mode
 extract_validated || fail authorized-normalization
 update_stage_core_valid "$TMP_BASE/package" || fail normalized-stage
 grep -Fq "$TMP_BASE/.cleaner-normalize/canonical-cleaner" "$LOGPREFIX.chmod" || fail normalization-scope
 grep -Fq "$TMP_BASE/.cleaner-normalize/canonical-cleaner -> $TMP_BASE/package/functions/mervlan_full_cleanup.sh" "$LOGPREFIX.mv" || fail atomic-canonical-publication
 [ "$(LC_ALL=C ls -ldn "$TMP_BASE/.cleaner-normalize" | awk '{print $1}')" = drwx------ ] || fail normalization-directory-mode
done
# Race the original cleaner entry at the rename boundary. A leaf symlink is
# moved as a symlink and rejected; a recreated public leaf after quarantine is
# noticed before canonicalization or chmod. The external target remains intact.
for fault in leaf-before leaf-after; do
 i=1
 while [ "$i" -le "$race_repeat" ]; do
  setup
  input="$WORK/race-A-0775.tar.gz"
  admit_input || fail "$fault admission"
  mv_fault=$fault
  if extract_validated; then fail "$fault normalization accepted"; fi
  [ ! -s "$LOGPREFIX.chmod" ] || fail "$fault invoked-chmod"
  [ "$(LC_ALL=C ls -ldn "$LOGPREFIX.outside" | awk '{print $1}')" = -rwxrwxr-x ] || fail "$fault external-target-mode"
  [ "$(cat "$LOGPREFIX.outside")" = outside ] || fail "$fault external-target-content"
  rm -rf "$TMP_BASE"
  i=$((i + 1))
 done
done
# A parent symlink and an unexpected quarantine object are rejected before
# moving or chmodding anything under the external target.
setup
input="$WORK/race-A-0775.tar.gz"
admit_input || fail parent-symlink-admission
transform=parent-symlink
if extract_validated; then fail parent-symlink-accepted; fi
[ ! -s "$LOGPREFIX.chmod" ] || fail parent-symlink-chmod
[ "$(LC_ALL=C ls -ldn "$LOGPREFIX.outside-dir/mervlan_full_cleanup.sh" | awk '{print $1}')" = -rwxrwxr-x ] || fail parent-symlink-external-mode
rm -rf "$TMP_BASE"
setup
input="$WORK/race-A-0775.tar.gz"
admit_input || fail precreated-quarantine-admission
(umask 077; mkdir "$TMP_BASE/.cleaner-normalize")
if extract_validated; then fail precreated-quarantine-accepted; fi
[ ! -s "$LOGPREFIX.chmod" ] || fail precreated-quarantine-chmod
[ "$(LC_ALL=C ls -ldn "$TMP_BASE/.cleaner-normalize" | awk '{print $1}')" = drwx------ ] || fail precreated-quarantine-mutated
rm -rf "$TMP_BASE"
# Inject each target type only when the production helper calls the final
# canonical-cleaner mv. The mv wrapper above verifies the target is still
# absent at that exact point (after the production absence check), records the
# reached hook, and then delegates to the real host/BusyBox mv implementation.
publication_repeat=${MERV_PUBLICATION_RACE_ITERATIONS:-100}
case "$publication_repeat" in ''|*[!0-9]*) fail invalid-publication-race-repeat ;; esac
[ "$publication_repeat" -gt 0 ] || fail zero-publication-race-repeat
for backend in host busybox; do
 for publication_fault in publish-regular publish-symlink publish-directory publish-absent; do
  i=1
  case_result=
  while [ "$i" -le "$publication_repeat" ]; do
   setup
   input="$WORK/race-A-0775.tar.gz"
   admit_input || fail "$backend/$publication_fault admission"
   outside_sum_before=$(cksum "$LOGPREFIX.outside")
   outside_mode_before=$(LC_ALL=C ls -ldn "$LOGPREFIX.outside" | awk '{print $1}')
   mv_fault=$publication_fault
   if extract_validated; then publication_rc=0; else publication_rc=$?; fi
   [ "$(wc -l <"$LOGPREFIX.publication-injection")" -eq 1 ] || fail "$backend/$publication_fault publication-hook-not-reached-once"
   grep -Fq "case=$publication_fault " "$LOGPREFIX.publication-injection" || fail "$backend/$publication_fault publication-hook-case"
   grep -Fq "$TMP_BASE/.cleaner-normalize/canonical-cleaner -> $TMP_BASE/package/functions/mervlan_full_cleanup.sh" "$LOGPREFIX.mv" || fail "$backend/$publication_fault actual-publication-mv-not-reached"
   target="$TMP_BASE/package/functions/mervlan_full_cleanup.sh"
   if [ "$publication_fault" = publish-directory ]; then
    [ "$publication_rc" -ne 0 ] || fail "$backend/directory-interference-reported-success"
    [ -d "$target" ] && [ ! -L "$target" ] || fail "$backend/directory-interference-target-lost"
    if update_stage_core_valid "$TMP_BASE/package"; then fail "$backend/directory-interference-stage-valid"; fi
    if ! grep -Fq 'Canonical cleaner publication verification failed' "$LOGPREFIX.warnings" &&
       ! grep -Fq 'Could not atomically publish canonical cleaner' "$LOGPREFIX.warnings"; then
     fail "$backend/directory-interference-not-failed-closed"
    fi
   elif [ "$publication_rc" -eq 0 ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || fail "$backend/$publication_fault-published-type"
    [ "$(LC_ALL=C ls -ldn "$target" | awk '{print $1}')" = -rwxr-xr-x ] || fail "$backend/$publication_fault-published-mode"
    cmp -s "$TMP_BASE/.cleaner-normalize/archive-cleaner" "$target" || fail "$backend/$publication_fault-interference-bytes-published"
    update_stage_core_valid "$TMP_BASE/package" || fail "$backend/$publication_fault-final-stage"
   else
    # A failed command may leave only the already-qualified canonical bytes;
    # it must never make the inserted bytes a valid final stage.
    if update_stage_core_valid "$TMP_BASE/package"; then
     [ -f "$target" ] && [ ! -L "$target" ] || fail "$backend/$publication_fault-failure-left-valid-nonfile"
     cmp -s "$TMP_BASE/.cleaner-normalize/archive-cleaner" "$target" || fail "$backend/$publication_fault-failure-left-interference-bytes"
    elif [ -f "$target" ] && [ ! -L "$target" ]; then
     if cmp -s "$TMP_BASE/.cleaner-normalize/archive-cleaner" "$target"; then :; fi
    fi
   fi
   [ "$(cksum "$LOGPREFIX.outside")" = "$outside_sum_before" ] || fail "$backend/$publication_fault-external-target-content"
   [ "$(LC_ALL=C ls -ldn "$LOGPREFIX.outside" | awk '{print $1}')" = "$outside_mode_before" ] || fail "$backend/$publication_fault-external-target-mode"
   if grep -Fq "$LOGPREFIX.outside" "$LOGPREFIX.chmod"; then fail "$backend/$publication_fault-external-target-chmod"; fi
   if grep -Fq "$LOGPREFIX.outside" "$LOGPREFIX.chown"; then fail "$backend/$publication_fault-external-target-chown"; fi
   if [ "$i" -eq 1 ]; then case_result=$publication_rc; fi
   rm -rf "$TMP_BASE"
   i=$((i + 1))
  done
  case "$publication_fault:$case_result" in
   publish-regular:0) pass "$backend/publication-regular-insertion-replaced-by-canonical-bytes" ;;
   publish-regular:*) pass "$backend/publication-regular-insertion-failed-closed" ;;
   publish-symlink:0) pass "$backend/publication-symlink-insertion-replaced-without-following-target" ;;
   publish-symlink:*) pass "$backend/publication-symlink-insertion-failed-closed" ;;
   publish-directory:*) pass "$backend/publication-directory-insertion-failed-closed" ;;
   publish-absent:0) pass "$backend/publication-absence-control-succeeded" ;;
   *) fail "$backend/$publication_fault unexpected-publication-result:$case_result" ;;
  esac
 done
done
pass "cleaner-publication-target-interference-stress-${publication_repeat}x-per-case-host-and-busybox-mv"
pass "cleaner-quarantine-race-stress-${race_repeat}x-per-fault-and-atomic-publication"
pass post-extraction-exact-matrix-and-symlink-chmod-guards
# Every source/ref shares the same admission and extraction path.
for source in main dev custom tag local; do
 setup
 input="$WORK/0775.tar.gz"
 UPDATE_SOURCE=remote
 case "$source" in
  main) GITHUB_REF=refs/heads/main ;;
  dev) GITHUB_REF=refs/heads/dev ;;
  custom) GITHUB_REF=refs/heads/pre_v0.53.29-RC1-dev ;;
  tag) GITHUB_REF=refs/tags/v0.53.29 ;;
  local) UPDATE_SOURCE=local; GITHUB_REF=local ;;
 esac
 admit_input || fail "$source archive"
 extract_validated || fail "$source extract"
 update_filter_source_tree "$TMP_BASE/package" || fail "$source filter"
 update_stage_core_valid "$TMP_BASE/package" || fail "$source stage"
 pass "$source-shared-archive-path"
done
# Real Git package integration: metadata, not repaired fixture permissions.
setup
input="$WORK/git.tar.gz"
admit_input || fail git-package-admission
[ "$UPDATE_ARCHIVE_CLEANER_MODE" = 0775 ] || fail git-package-mode
extract_validated || fail git-package-extract
update_stage_core_valid "$TMP_BASE/package" || fail git-package-stage
pass exact-git-package-integration
printf "PACKAGE_WORKER_CASES role=%s shell=%s cases=%s\n" "$role" "$shellmode" "$seq"
WORKER
# Explicit root and non-root executions; neither changes host/router ownership.
if [ "$(id -u)" = 0 ]; then
 sh "$WORK/worker.sh" "$WORK" root host
 busybox sh "$WORK/worker.sh" "$WORK" root busybox-shell
 if unshare --user --map-user=1000 --map-group=1000 true 2>/dev/null; then
  unshare --user --map-user=1000 --map-group=1000 sh "$WORK/worker.sh" "$WORK" nonroot unshare
 else
  printf 'PACKAGE_ROOT_CONTEXT=PASS NONROOT_CONTEXT=NOT_AVAILABLE\n'
 fi
else
 sh "$WORK/worker.sh" "$WORK" nonroot host
 busybox sh "$WORK/worker.sh" "$WORK" nonroot busybox-shell
 printf 'PACKAGE_ROOT_CONTEXT=NOT_AVAILABLE NONROOT_CONTEXT=PASS\n'
fi
# Pairing tests vary metadata columns without assuming date/owner positions.
. "$WORK/helpers"
warn() { printf '%s\n' "$*" >>"$WORK/pair.warnings"; }
TMP_BASE="$WORK/pair"
RAW_ARCHIVE="$TMP_BASE/raw.tar"
TMP_DIR="$WORK"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"
STAGE_DIR="$TMP_BASE/stage"
BACKUP_DIR="$TMP_BASE/backup"
update_prepare_private_workspace || fail pair-workspace
printf x >"$WORK/fixture-source.tar"
style=gnu
pair_fault=none
tar() {
 case "$1" in
  -tzf) printf '%s\n' package/ package/functions/mervlan_full_cleanup.sh ;;
  -tvzf)
   if [ "$style" = gnu ]; then
    printf '%s\n' 'drwxr-xr-x 0/0 0 2026-10-13 01:00 package/'
    line='-rwxr-xr-x 0/0 7 2026-10-13 01:00 package/functions/mervlan_full_cleanup.sh'
   else
    printf '%s\n' 'drwxr-xr-x root/root 0 2026-10-13 01:00:00 package/'
    line='-rwxr-xr-x root/root 7 2026-10-13 01:00:00 package/functions/mervlan_full_cleanup.sh'
   fi
   case "$pair_fault" in
    none) printf '%s\n' "$line" ;;
    name) printf '%s\n' '-rwxr-xr-x 0/0 7 today now package/other' ;;
    short) : ;;
    extra) printf '%s\n' "$line" "$line" ;;
   esac ;;
  *) return 1 ;;
 esac
}
printf 'first\nsecond\n' >"$WORK/fd-sentinel"
exec 3<"$WORK/fd-sentinel"
IFS= read -r sentinel <&3
[ "$sentinel" = first ] || fail fd-before
for style in gnu busybox; do
 pair_fault=none
 cp "$WORK/fixture-source.tar" "$ARCHIVE"
 validate_update_archive_members "$ARCHIVE" || fail "$style listing pairing"
 [ "$UPDATE_ARCHIVE_CLEANER_MODE" = 0755 ] || fail pairing-mode
 for pair_fault in name short extra; do
  cp "$WORK/fixture-source.tar" "$ARCHIVE"
  if validate_update_archive_members "$ARCHIVE"; then fail "$pair_fault listing accepted"; fi
  [ -z "$UPDATE_ARCHIVE_CLEANER_MODE" ] || fail partial-listing-admission
 done
done
update_close_stable_archive || fail pair-close-fd
IFS= read -r sentinel <&3
[ "$sentinel" = second ] || fail fd-after
exec 3<&-
unset -f tar
pass paired-listing-names-counts-formats-and-fd-restoration
# Audit executable source order, not a test-only alternate dispatcher.
python3 - "$UPDATER" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
validate=s.index('if ! validate_update_archive_members "$ARCHIVE"; then')
raw=s.index('update_extract_archive "$TMP_BASE" raw || fail_update extracting')
gzip=s.index('update_extract_archive "$TMP_BASE" gzip || fail_update extracting')
workspace=s.index('update_prepare_private_workspace ||',s.index('if [ "$MODE" = "update" ]'))
download=s.index('download_update_archive "$GITHUB_URL" "$ARCHIVE"')
local_copy=s.index('acquire_local_update_archive "$UPDATE_LOCAL_ARCHIVE" "$ARCHIVE"')
teardown=s.index('if ! run_update_step "pre-update main disable"',validate)
setup=s.index('if ! run_update_step "pre-update main setupdisable"',validate)
displace=s.index('if ! mv "$MERV_BASE" "$UPDATE_JFFS_OLD"',validate)
activate=s.index('if ! mv "$UPDATE_JFFS_STAGE" "$MERV_BASE"',validate)
stage=s.index('update_stage_core_valid "$STAGE_DIR" ||',validate)
assert validate < raw < stage and validate < gzip < stage
assert stage < min(teardown,setup,displace,activate)
assert workspace < download and workspace < local_copy < validate
guard=s[validate:s.index('\nfi',validate)]
assert 'fail_update extracting "Archive failed pre-extraction member or cleaner mode validation"' in guard
fail_start=s.index('fail_update() {')
fail_body=s[fail_start:s.index('\n}',fail_start)+2]
assert fail_body.endswith('exit 1\n}')
assert s.count('if ! validate_update_archive_members "$ARCHIVE"; then') == 1
assert 'downloaded archive failed core MerVLAN validation' in s
assert 'exec 9<"$_update_freeze_input"' in s and 'rm -f "$_update_freeze_input"' in s
assert 'tar -xzf "$UPDATE_ARCHIVE_FD_PATH"' in s and 'tar -tzf "$UPDATE_ARCHIVE_FD_PATH"' in s
assert 'chmod 0755 "$_update_norm_canonical"' in s
assert 'chmod g-w "$_update_norm_cleaner"' not in s
assert 'update_close_stable_archive || fail_update extracting "Could not close stable archive object after extraction"' in s
assert 'UPDATE_TMP_BASE_PRIVATE' in s and 'not a private updater-owned 0700 directory' in s
print('PASS: shared source path admission precedes extraction/teardown/activation')
PY
