#!/bin/sh
# The mapper's optional installed-code patch and hardware-profile write share M.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan-mapper-maintenance.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_fn() {
  _ef_name=$1 _ef_src=$2 _ef_out=$3
  awk -v name="$_ef_name" '
    $0 ~ ("^" name "\\()[[:space:]]*\\{") { active=1; depth=0 }
    active {
      print
      line=$0
      opens=gsub(/\{/, "{", line)
      closes=gsub(/\}/, "}", line)
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$_ef_src" > "$_ef_out" || return 1
  [ -s "$_ef_out" ]
}

MAPPER="$BASE_DIR/functions/device_support_mapper.sh"
extract_fn mapper_patch_with_maintenance "$MAPPER" "$TEST_ROOT/patch.sh" || fail extract-function

TRACE="$TEST_ROOT/trace"
DEFAULT_HW_PROBE="$TEST_ROOT/hw_probe.sh"
HW_PROBE_PATH=$DEFAULT_HW_PROBE
PRODUCTID=test-router
PAYLOAD=test-payload
say() { printf '%s\n' "$*" >> "$TRACE"; }
mapper_patch_maintenance_enter() { printf 'M-enter\n' >> "$TRACE"; return "${ENTER_RC:-0}"; }
mapper_patch_maintenance_leave() { printf 'M-leave\n' >> "$TRACE"; }
patch_hw_probe() { printf 'patch\n' >> "$TRACE"; return "${PATCH_RC:-0}"; }
printf 'printf "profile-write\\n" >> "%s"\n' "$TRACE" > "$DEFAULT_HW_PROBE"
chmod 700 "$DEFAULT_HW_PROBE"
. "$TEST_ROOT/patch.sh" || fail load-function

: > "$TRACE"
mapper_patch_with_maintenance || fail patch-success
[ "$(cat "$TRACE")" = "M-enter
patch
Running hw_probe.sh once to apply the mapping into MerVLAN hardware settings...
profile-write
M-leave" ] || { cat "$TRACE" >&2; fail patch-and-profile-were-not-covered-by-M; }
pass 'patch publication and its profile write execute before exact M release'

: > "$TRACE"
PATCH_RC=1
if mapper_patch_with_maintenance; then fail patch-failure-return; fi
[ "$(cat "$TRACE")" = "M-enter
patch
M-leave" ] || fail failed-patch-release-order
pass 'failed patch releases only after the patch attempt and skips profile mutation'

_fn_start=$(grep -n '^mapper_patch_maintenance_enter()' "$MAPPER" | cut -d: -f1)
_fn_end=$(awk -v start="$_fn_start" 'NR > start && /^}/ { print NR; exit }' "$MAPPER")
sed -n "${_fn_start},${_fn_end}p" "$MAPPER" > "$TEST_ROOT/admit.sh"
_pre_f=$(grep -n 'merv_update_full_fence_clear' "$TEST_ROOT/admit.sh" | sed -n '1s/:.*//p')
_acquire=$(grep -n 'merv_owner_lock_acquire' "$TEST_ROOT/admit.sh" | cut -d: -f1)
_post_f=$(grep -n 'merv_update_full_fence_clear' "$TEST_ROOT/admit.sh" | sed -n '2s/:.*//p')
_quiesce=$(grep -n 'merv_maintenance_quiesce_classify' "$TEST_ROOT/admit.sh" | cut -d: -f1)
[ -n "$_pre_f$_acquire$_post_f$_quiesce" ] || fail admission-contract-missing
[ "$_pre_f" -lt "$_acquire" ] && [ "$_acquire" -lt "$_post_f" ] && [ "$_post_f" -lt "$_quiesce" ] || fail admission-order
if grep -q 'ip neigh del' "$MAPPER"; then fail readonly-discovery-mutates-neighbor-cache; fi
pass 'patch admission checks F before M, rechecks F and Q while M is held'
pass 'discovery/report path does not delete neighbor state'
printf '%s\n' 'DEVICE_SUPPORT_MAPPER_MAINTENANCE_OK'
