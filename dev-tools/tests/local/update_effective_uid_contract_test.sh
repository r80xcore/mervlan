#!/bin/sh
# Exercise the production Update workspace owner checks with no usable `id`.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
UPDATER="$ROOT/functions/update_mervlan.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-update-uid.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

sed -n '/^# PRIVATE UPDATE WORKSPACE BEGIN$/,/^# PRIVATE UPDATE WORKSPACE END$/p' "$UPDATER" |
  sed '/^# PRIVATE UPDATE WORKSPACE /d' >"$WORK/workspace-helpers.sh"
[ -s "$WORK/workspace-helpers.sh" ] || fail 'production workspace helper extraction'

ID_INVOKED="$WORK/id-invoked"
ID_FORBIDDEN_PATH=
id() {
  printf 'id was invoked\n' >>"$ID_INVOKED"
  return 127
}
warn() { printf '%s\n' "$*" >>"$WORK/warnings"; }

. "$WORK/workspace-helpers.sh"

if [ "$(update_effective_uid)" != "$(awk '/^Uid:/ { print $3; found=1; exit } END { if (!found) exit 1 }' "/proc/$$/status")" ]; then
  fail 'effective UID did not match the live /proc status tuple'
fi
_uid_tuple=$(update_uid_from_status "$WORK/no-such-status" 2>/dev/null) && fail 'missing proc status accepted'
printf 'Name:\ttest\n' >"$WORK/no-uid.status"
_uid_tuple=$(update_uid_from_status "$WORK/no-uid.status" 2>/dev/null) && fail 'missing Uid line accepted'
printf 'Uid:\t1000\t\t1002\t1003\n' >"$WORK/empty-effective.status"
_uid_tuple=$(update_uid_from_status "$WORK/empty-effective.status" 2>/dev/null) && fail 'empty effective UID accepted'
printf 'Uid:\t1000\tabc\t1002\t1003\n' >"$WORK/nonnumeric.status"
_uid_tuple=$(update_uid_from_status "$WORK/nonnumeric.status" 2>/dev/null) && fail 'nonnumeric effective UID accepted'
printf 'Uid:\t1000\t1001\t1002\n' >"$WORK/malformed.status"
_uid_tuple=$(update_uid_from_status "$WORK/malformed.status" 2>/dev/null) && fail 'malformed UID tuple accepted'
printf 'Uid:\t111\t222\t333\t444\n' >"$WORK/effective.status"
[ "$(update_uid_from_status "$WORK/effective.status")" = 222 ] || fail 'UID parser did not select the effective field'

TMP_DIR="$WORK/runtime"
TMP_BASE="$TMP_DIR/updates.uid-contract"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"
RAW_ARCHIVE="$TMP_BASE/mervlan.tar"
STAGE_DIR="$TMP_BASE/stage"
BACKUP_DIR="$TMP_BASE/backup"
umask 077
mkdir "$TMP_DIR"
update_prepare_private_workspace || fail 'actual private workspace validation with id unavailable'
update_private_directory_valid "$TMP_BASE" || fail 'TMP_BASE owner/mode validation'
update_private_directory_valid "$STAGE_DIR" || fail 'stage owner/mode validation'
update_private_directory_valid "$BACKUP_DIR" || fail 'backup owner/mode validation'
mkdir "$TMP_BASE/.cleaner-normalize"
update_private_directory_valid "$TMP_BASE/.cleaner-normalize" || fail 'normalization quarantine owner/mode validation'
[ ! -e "$ID_INVOKED" ] || fail 'production workspace validation invoked id'
pass 'production workspace and quarantine validators pass with id unavailable'

# Mock only ls's numeric owner field to prove the production validator rejects
# a private-looking directory owned by someone other than the effective UID.
ls() {
  _uid_test_last=
  for _uid_test_arg do _uid_test_last=$_uid_test_arg; done
  if [ -n "$ID_FORBIDDEN_PATH" ] && [ "$_uid_test_last" = "$ID_FORBIDDEN_PATH" ]; then
    printf 'drwx------ 2 999999 999999 4096 Jan 1 00:00 %s\n' "$_uid_test_last"
    return 0
  fi
  command ls "$@"
}
ID_FORBIDDEN_PATH="$TMP_BASE"
if update_private_directory_valid "$TMP_BASE"; then fail 'owner mismatch accepted'; fi
ID_FORBIDDEN_PATH=
[ ! -e "$ID_INVOKED" ] || fail 'owner mismatch path invoked id'
pass 'owner mismatch fails closed'

printf '%s\n' 'UPDATE_EFFECTIVE_UID_CONTRACT_OK'
