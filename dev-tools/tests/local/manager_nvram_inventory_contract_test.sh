#!/bin/sh
# Manager NVRAM inventory contract.
#
# Exercises the production inventory reader, timeout seam, and manager main
# preflight with a fixture nvram command.  The fixture deliberately blocks the
# actual `nvram show` operation; elapsed time is therefore bounded by the
# production timeout helper rather than a simulated clock.  No router state is
# touched and all fixture state is private to this process.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-manager-nvram.$$"
BIN_DIR="$TEST_ROOT/bin"
TRACE="$TEST_ROOT/trace"
INVENTORY_ROOT="$TEST_ROOT/inventory"
umask 077
mkdir -p "$BIN_DIR" "$INVENTORY_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

FAILURES=0
MANAGER_CASES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }
case_pass() {
  MANAGER_CASES=$((MANAGER_CASES + 1))
  [ "$FAILURES" -eq "$1" ] && pass "$2"
}

MANAGER="$BASE_DIR/functions/mervlan_manager.sh"
SNAPSHOT="$BASE_DIR/settings/mac_shield_snapshot.sh"
[ -f "$MANAGER" ] || fail "manager source missing: $MANAGER"
[ -f "$SNAPSHOT" ] || fail "snapshot source missing: $SNAPSHOT"

# The command is the NVRAM-related production boundary.  In stall mode it
# never returns on its own; the extracted production timeout helper must reap
# it.  Normal mode is a stable inventory fixture used to prove the valid path.
cat > "$BIN_DIR/nvram" <<'EOF'
#!/bin/sh
if [ "${1:-}" != show ]; then
  exit 2
fi
printf 'show-start\n' >> "$MANAGER_NVRAM_TRACE"
if [ "${MANAGER_NVRAM_MODE:-normal}" = stall ]; then
  exec sleep 10
fi
  case "${MANAGER_NVRAM_MODE:-normal}" in
  exit-status)
    printf 'status-output\n'
    exit 7
    ;;
  normal)
    {
      printf 'wl0.1_ssid=Guest\n'
      printf 'wl0.1_ifname=wl0.1\n'
      printf 'size: 123\n'
      printf 'unrelated=preserved-by-source-but-not-selected\n'
      printf 'wl_ssid=base-radio-but-not-an-inventory-target\n'
      printf 'wl_ifname=eth0\n'
      printf 'wlbp_ssid=backhaul-but-not-an-inventory-target\n'
      printf 'wlbp_ifname=wlbp0\n'
      printf 'wl0/foo_ssid=slash-namespace-but-not-an-inventory-target\n'
      printf 'wl0:foo_ifname=colon-namespace-but-not-an-inventory-target\n'
      printf '0:ccode=US\n'
      printf '0:ccode=US-duplicate-unrelated\n'
      printf '1:macaddr=00:11:22:33:44:55\n'
      printf 'pci/1/1/ccode=US\n'
      printf 'wl0.10_akm=psk2sae\n'
      printf 'wl0.10_auth=0\n'
      printf 'wl0.10_bss_enabled=0\n'
      printf 'wl2_chansps=firmware-wireless-metadata\n'
      _long_value=$(printf '%0717d' 0 | tr '0' X)
      printf 'rc_support=%s\n' "$_long_value"
      _normal_i=0
      while [ "$_normal_i" -lt 4653 ]; do
        printf 'unrelated_%04d=ignored-%04d\n' "$_normal_i" "$_normal_i"
        _normal_i=$((_normal_i + 1))
      done
    } > "${MANAGER_NVRAM_NORMAL_FILE:?}" || exit 3
    cat "$MANAGER_NVRAM_NORMAL_FILE" || exit 3
    ;;
  near-match)
    printf 'wl0.1_ssid=Guest\n'
    printf 'wl0.1_ifname=wl0.1\n'
    printf 'wl0..1_ssid=near-match\n'
    printf 'wl0.1_ssid_extra=suffix-variant\n'
    printf 'xwl0.1_ssid=prefix-variant\n'
    printf 'wlbp_ssid=unrelated-prefix\n'
    ;;
  saved-live)
    [ -n "${MANAGER_NVRAM_SAVED_LIVE_FILE:-}" ] &&
      [ -f "$MANAGER_NVRAM_SAVED_LIVE_FILE" ] || exit 3
    cat "$MANAGER_NVRAM_SAVED_LIVE_FILE" || exit 3
    ;;
  malformed-key)
    printf 'wl0.1_ssid\n'
    printf 'wl0.1_ifname\n'
    ;;
  malformed-prefix)
    printf 'wl0foo_ssid=Malformed\n'
    ;;
  malformed-suffix)
    printf 'wl0.1_ssid_extra=Malformed\n'
    ;;
  unsafe-ssid)
    printf 'wl0.1_ssid=Guest\001Unsafe\n'
    ;;
  unsafe-ifname)
    printf 'wl0.1_ifname=wl0.1;touch\n'
    ;;
  duplicate)
    printf 'wl0.1_ssid=Guest\n'
    printf 'wl0.1_ssid=Guest-again\n'
    ;;
esac
printf 'show-end\n' >> "$MANAGER_NVRAM_TRACE"
exit 0
EOF
chmod 700 "$BIN_DIR/nvram" || exit 1

PATH="$BIN_DIR:$PATH"
export PATH
MANAGER_NVRAM_TRACE="$TRACE"
MANAGER_NVRAM_NORMAL_FILE="$TEST_ROOT/normal.raw"
MANAGER_NVRAM_MODE=normal
export MANAGER_NVRAM_TRACE MANAGER_NVRAM_NORMAL_FILE MANAGER_NVRAM_MODE

# Extract complete named production functions.  Closing braces inside the
# bodies are indented; the unindented brace is the function boundary.
extract_fn() {
  _ef_src="$1" _ef_name="$2" _ef_dst="$3"
  awk -v wanted="$_ef_name" '
    $0 ~ ("^" wanted "\\(\\)[[:space:]]*\\{") { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_ef_src" > "$_ef_dst" || return 1
  [ -s "$_ef_dst" ]
}

EXTRACTED="$TEST_ROOT/extracted"
mkdir -p "$EXTRACTED" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_process_start "$EXTRACTED/inventory-process.sh" || fail 'inventory process-start extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_clear_state "$EXTRACTED/inventory-clear-state.sh" || fail 'inventory clear-state extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_set_error "$EXTRACTED/inventory-set-error.sh" || fail 'inventory set-error extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_target_key_valid "$EXTRACTED/inventory-target-key.sh" || fail 'inventory target-key extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_artifacts_safe "$EXTRACTED/inventory-artifacts-safe.sh" || fail 'inventory artifact safety extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_validate_records "$EXTRACTED/inventory-validate.sh" || fail 'inventory record validation extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_path "$EXTRACTED/inventory-path.sh" || fail 'inventory path extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_publish_state "$EXTRACTED/inventory-publish.sh" || fail 'inventory state extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_mark_error "$EXTRACTED/inventory-error.sh" || fail 'inventory error extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_invalidate "$EXTRACTED/inventory-invalidate.sh" || fail 'inventory invalidate extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_read "$EXTRACTED/inventory-read.sh" || fail 'inventory read extraction'
extract_fn "$SNAPSHOT" merv_nvram_inventory_value "$EXTRACTED/inventory-value.sh" || fail 'inventory value extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_pairs_validate "$EXTRACTED/iface-pairs-validate.sh" || fail 'derived pair validator extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_cache_path "$EXTRACTED/iface-cache-path.sh" || fail 'derived cache path extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_cache_remove_files "$EXTRACTED/iface-cache-remove.sh" || fail 'derived cache removal extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_cache_enable "$EXTRACTED/iface-cache-enable.sh" || fail 'derived cache enable extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_cache_invalidate "$EXTRACTED/iface-cache-invalidate.sh" || fail 'derived cache invalidation extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_cache_disable "$EXTRACTED/iface-cache-disable.sh" || fail 'derived cache disable extraction'
extract_fn "$SNAPSHOT" merv_iface_vid_list "$EXTRACTED/iface-list.sh" || fail 'derived cache list extraction'
extract_fn "$MANAGER" main "$EXTRACTED/main.sh" || fail 'manager main extraction'
extract_fn "$MANAGER" cleanup_on_exit "$EXTRACTED/cleanup.sh" || fail 'manager cleanup extraction'
for _manager_fn in \
  normalize_basic normalize_iface normalize_ssid to_lower \
  merv_manager_inventory_file_is_current merv_manager_inventory_prepare \
  ssid_configured_for_iface is_internal_vap find_if_by_ssid find_if_by_ssid_any \
  ssid_in_nvram boot_wait_for_configured_ssids nvram_base_for_ifname \
  set_ap_isolation attach_to_bridge bind_configured_ssids; do
  extract_fn "$MANAGER" "$_manager_fn" "$EXTRACTED/$_manager_fn.sh" || \
    fail "manager SSID helper extraction: $_manager_fn"
done
extract_fn "$BASE_DIR/settings/lib_ssh.sh" _merv_timeout_collect_tree \
  "$EXTRACTED/timeout-collect.sh" || fail 'timeout tree collector extraction'
extract_fn "$BASE_DIR/settings/lib_ssh.sh" _merv_timeout_signal_tree \
  "$EXTRACTED/timeout-signal.sh" || fail 'timeout tree signal extraction'
extract_fn "$BASE_DIR/settings/lib_ssh.sh" _merv_timeout_run "$EXTRACTED/timeout.sh" || fail 'timeout helper extraction'

# XT8/ASUSWRT has no native timeout applet.  Force the production fallback so
# normal and stalled `nvram show` paths exercise the live shell shape locally.
merv_has() {
  [ "${1:-}" != timeout ] && command -v "$1" >/dev/null 2>&1
}
_merv_log_err() { printf 'TIMEOUT-ERROR:%s\n' "$*" >> "$TRACE"; }
. "$EXTRACTED/timeout-collect.sh" || fail 'timeout tree collector load'
. "$EXTRACTED/timeout-signal.sh" || fail 'timeout tree signal load'
. "$EXTRACTED/timeout.sh" || fail 'timeout helper load'
for _inventory_piece in "$EXTRACTED"/inventory-*.sh; do
  . "$_inventory_piece" || fail "inventory helper load: $_inventory_piece"
done
for _iface_piece in "$EXTRACTED"/iface-*.sh; do
  . "$_iface_piece" || fail "derived cache helper load: $_iface_piece"
done
for _manager_piece in \
  normalize_basic normalize_iface normalize_ssid to_lower \
  merv_manager_inventory_file_is_current merv_manager_inventory_prepare \
  ssid_configured_for_iface is_internal_vap find_if_by_ssid find_if_by_ssid_any \
  ssid_in_nvram boot_wait_for_configured_ssids nvram_base_for_ifname \
  set_ap_isolation bind_configured_ssids; do
  . "$EXTRACTED/$_manager_piece.sh" || fail "manager SSID helper load: $_manager_piece"
done

# Derived-cache tests keep the NVRAM read itself out of the oracle.  This stub
# is replaced by the real builder in the RC contract; here it lets the real
# cache wrapper exercise state identity and row validation deterministically.
mervqt_valid_vid() {
  [ "$1" -ge 2 ] 2>/dev/null && [ "$1" -le 4094 ] 2>/dev/null
}
MOCK_DERIVED_ROWS='wl0.1 10'
merv_mac_build_expected_iface_vid() {
  printf '%s\n' "$MOCK_DERIVED_ROWS"
}

# Valid normal inventory: one real `nvram show`, validated records, and the
# process-scoped cache remain unchanged across repeated reads.
MERV_NVRAM_INVENTORY_ROOT="$INVENTORY_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=manager
MERV_NVRAM_READ_TIMEOUT=2
MERV_NVRAM_INVENTORY_MAX_RAW_BYTES=1048576
MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS=32768
MERV_NVRAM_INVENTORY_MAX_RAW_LINES=32768
MERV_NVRAM_INVENTORY_MAX_RAW_LINE_BYTES=8192
MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES=32768
MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS=128
MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES=256
MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES=128
MERV_SSH_TMPDIR="$TEST_ROOT/timeout-root"
mkdir -p "$MERV_SSH_TMPDIR" || exit 1
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE MERV_NVRAM_READ_TIMEOUT \
  MERV_NVRAM_INVENTORY_MAX_RAW_BYTES MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS \
  MERV_NVRAM_INVENTORY_MAX_RAW_LINES MERV_NVRAM_INVENTORY_MAX_RAW_LINE_BYTES \
  MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES \
  MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES \
  MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES MERV_SSH_TMPDIR
: > "$TRACE"

timeout_tree_clean() {
  _ttc_leftovers=$(find "$MERV_SSH_TMPDIR" -type d -name 'timeout_out.*' -print 2>/dev/null) || return 1
  [ -z "$_ttc_leftovers" ]
}

# The live inventory caller enables noclobber while holding fd 3.  Exercise
# the real fallback directly in that shell shape and retain exact child
# output/status assertions so an ordinary `>` regression fails deterministically.
_case_failures=$FAILURES
rm -f "$TEST_ROOT/fallback-success.out"
if (
  set -C
  exec 3> "$TEST_ROOT/fallback-success.out" 2>/dev/null || exit 126
  _merv_timeout_run 2 nvram show >&3 2>/dev/null
  _timeout_capture_rc=$?
  exec 3>&-
  exit "$_timeout_capture_rc"
); then
  _timeout_capture_rc=0
else
  _timeout_capture_rc=$?
fi
[ "$_timeout_capture_rc" -eq 0 ] || fail "fallback normal command returned rc=$_timeout_capture_rc, expected 0"
cmp -s "$MANAGER_NVRAM_NORMAL_FILE" "$TEST_ROOT/fallback-success.out" ||
  fail 'fallback normal command output changed or was lost under noclobber'
timeout_tree_clean || fail 'fallback normal command left timeout scratch tree behind'
case_pass "$_case_failures" 'fallback preserved successful nvram status/output under noclobber and cleaned its tree'

MANAGER_NVRAM_MODE=exit-status
export MANAGER_NVRAM_MODE
_case_failures=$FAILURES
rm -f "$TEST_ROOT/fallback-status.out"
if (
  set -C
  exec 3> "$TEST_ROOT/fallback-status.out" 2>/dev/null || exit 126
  _merv_timeout_run 2 nvram show >&3 2>/dev/null
  _timeout_capture_rc=$?
  exec 3>&-
  exit "$_timeout_capture_rc"
); then
  _timeout_capture_rc=0
else
  _timeout_capture_rc=$?
fi
[ "$_timeout_capture_rc" -eq 7 ] || fail "fallback nonzero command returned rc=$_timeout_capture_rc, expected 7"
[ "$(cat "$TEST_ROOT/fallback-status.out" 2>/dev/null || printf '')" = status-output ] ||
  fail 'fallback nonzero command output was not preserved exactly'
timeout_tree_clean || fail 'fallback nonzero command left timeout scratch tree behind'
case_pass "$_case_failures" 'fallback preserved exact nonzero status/output and cleaned its tree'

MANAGER_NVRAM_MODE=stall
export MANAGER_NVRAM_MODE
_case_failures=$FAILURES
rm -f "$TEST_ROOT/fallback-timeout.out"
START_EPOCH=$(date +%s)
if (
  set -C
  exec 3> "$TEST_ROOT/fallback-timeout.out" 2>/dev/null || exit 126
  _merv_timeout_run 1 nvram show >&3 2>/dev/null
  _timeout_capture_rc=$?
  exec 3>&-
  exit "$_timeout_capture_rc"
); then
  _timeout_capture_rc=0
else
  _timeout_capture_rc=$?
fi
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
[ "$_timeout_capture_rc" -eq 124 ] || fail "fallback stalled command returned rc=$_timeout_capture_rc, expected 124"
[ ! -s "$TEST_ROOT/fallback-timeout.out" ] || fail 'fallback stalled command emitted unexpected output'
[ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 5 ] || fail "fallback stalled command exceeded hard bound (${ELAPSED}s)"
timeout_tree_clean || fail 'fallback stalled command left timeout scratch tree behind'
case_pass "$_case_failures" "fallback enforced hard deadline/status and cleaned its tree in ${ELAPSED}s"

MANAGER_NVRAM_MODE=normal
export MANAGER_NVRAM_MODE
: > "$TRACE"
_case_failures=$FAILURES
if ! merv_nvram_inventory_read; then
  fail "normal inventory unexpectedly failed (reason=${MERV_NVRAM_INVENTORY_REASON:-unset})"
fi
[ "$(wc -c < "$MANAGER_NVRAM_NORMAL_FILE" 2>/dev/null || printf 0)" -ge 100000 ] ||
  fail 'normal fixture is not live-sized by raw bytes'
[ "$(wc -l < "$MANAGER_NVRAM_NORMAL_FILE" 2>/dev/null || printf 0)" = 4672 ] ||
  fail 'normal fixture line count changed from the live-shaped input'
[ "$(awk 'index($0, "=") > 0 { n++ } END { print n + 0 }' "$MANAGER_NVRAM_NORMAL_FILE" 2>/dev/null || printf 0)" = 4671 ] ||
  fail 'normal fixture record count changed from the live-shaped input'
[ "$(awk '{ if (length($0) > max) max=length($0) } END { print max + 0 }' "$MANAGER_NVRAM_NORMAL_FILE" 2>/dev/null || printf 0)" = 728 ] ||
  fail 'normal fixture maximum unrelated line is not the live-observed 728 bytes'
[ "${MERV_NVRAM_INVENTORY_STATUS:-}" = valid ] || fail 'normal inventory status is not valid'
[ "$(merv_nvram_inventory_value wl0.1_ssid 2>/dev/null)" = Guest ] || fail 'normal inventory SSID value changed'
[ "$(merv_nvram_inventory_value wl0.1_ifname 2>/dev/null)" = wl0.1 ] || fail 'normal inventory ifname value changed'
[ "$(wc -l < "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null || printf 0)" = 2 ] || fail 'normal inventory retained unrelated NVRAM keys'
if grep -Eq '^(0:ccode|1:macaddr|pci/1/1/ccode|wl_ssid|wl_ifname|wlbp_ssid|wlbp_ifname)=' \
    "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null; then
  fail 'normal inventory selected unrelated NVRAM keys'
fi
merv_nvram_inventory_read || fail 'cached normal inventory read failed'
[ "$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)" = 1 ] || fail 'normal inventory did not retain one cached nvram show'
case_pass "$_case_failures" 'normal inventory validated and cached without changing selected records'

# Target-looking but non-exact firmware keys are unrelated records.  Only the
# two exact target records may be selected.
merv_nvram_inventory_invalidate || fail 'near-match inventory invalidation failed'
MANAGER_NVRAM_MODE=near-match
export MANAGER_NVRAM_MODE
_case_failures=$FAILURES
if ! merv_nvram_inventory_read; then
  fail "near-match inventory unexpectedly failed (reason=${MERV_NVRAM_INVENTORY_REASON:-unset})"
fi
[ "$(wc -l < "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null || printf 0)" = 2 ] ||
  fail 'near-match inventory selected a non-exact key'
case_pass "$_case_failures" 'near-match wl and wlbp namespaces were ignored semantically'

# When the bounded live-probe artifacts are present, feed their complete
# MAIN/NODE1 captures through the same production parser.  The cases are
# optional so this local contract remains portable outside the evidence bundle.
run_saved_live_case() {
  _rsl_label="$1"
  _rsl_file="$2"
  _rsl_expected_keys="$3"
  _rsl_expected_records="$4"
  if [ ! -f "$_rsl_file" ] || [ ! -f "$_rsl_expected_keys" ]; then
    printf 'SKIP: %s saved-live fixture unavailable (%s)\n' "$_rsl_label" "$_rsl_file" >&2
    return 0
  fi
  merv_nvram_inventory_invalidate || fail "$_rsl_label saved-live invalidation failed"
  MANAGER_NVRAM_MODE=saved-live
  MANAGER_NVRAM_SAVED_LIVE_FILE="$_rsl_file"
  export MANAGER_NVRAM_MODE MANAGER_NVRAM_SAVED_LIVE_FILE
  _case_failures=$FAILURES
  if ! merv_nvram_inventory_read; then
    fail "$_rsl_label saved-live inventory failed (reason=${MERV_NVRAM_INVENTORY_REASON:-unset})"
  fi
  [ "${MERV_NVRAM_INVENTORY_STATUS:-}" = valid ] || fail "$_rsl_label saved-live status is not valid"
  [ "$(wc -l < "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null || printf 0)" = "$_rsl_expected_records" ] ||
    fail "$_rsl_label saved-live selected record count changed"
  awk -F= '{print $1}' "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null | sort > "$TEST_ROOT/${_rsl_label}.selected.keys"
  awk '{sub(/\r$/, ""); print}' "$_rsl_expected_keys" | sort > "$TEST_ROOT/${_rsl_label}.expected.keys"
  cmp -s "$TEST_ROOT/${_rsl_label}.selected.keys" "$TEST_ROOT/${_rsl_label}.expected.keys" ||
    fail "$_rsl_label saved-live exact target key set changed"
  if grep -Eq '^(wl_|wlbp_|[0-9]+:|[^=]*/[^=]*=)' "${MERV_NVRAM_INVENTORY_FILE:-}" 2>/dev/null; then
    fail "$_rsl_label saved-live retained an unrelated key"
  fi
  [ "$(merv_nvram_inventory_value wl0.1_ifname 2>/dev/null)" = wl0.1 ] ||
    fail "$_rsl_label saved-live selected ifname lookup changed"
  merv_nvram_inventory_read || fail "$_rsl_label saved-live cache revalidation failed"
  case_pass "$_case_failures" "$_rsl_label saved-live parser accepted raw bounds and selected exact targets"
}

run_saved_live_case MAIN "$BASE_DIR/.tmp/CORR-PREDEP-LIVE-2026-09-08/MAIN/nvram-show.raw" \
  "$BASE_DIR/.tmp/CORR-PREDEP-LIVE-2026-09-08/MAIN/exact-target-keys.txt" 30
run_saved_live_case NODE1 "$BASE_DIR/.tmp/CORR-PREDEP-LIVE-2026-09-08/NODE1/nvram-show.raw" \
  "$BASE_DIR/.tmp/CORR-PREDEP-LIVE-2026-09-08/NODE1/exact-target-keys.txt" 34

expect_inventory_failure() {
  _eif_mode="$1"
  _eif_reason="$2"
  merv_nvram_inventory_invalidate || fail "$_eif_mode inventory invalidation failed"
  MANAGER_NVRAM_MODE="$_eif_mode"
  export MANAGER_NVRAM_MODE
  _case_failures=$FAILURES
  _eif_rc=0
  if merv_nvram_inventory_read; then
    fail "$_eif_mode inventory unexpectedly succeeded"
  else
    _eif_rc=$?
  fi
  [ "$_eif_rc" -eq 2 ] || fail "$_eif_mode inventory returned rc=$_eif_rc, expected 2"
  [ "${MERV_NVRAM_INVENTORY_STATUS:-}" = error ] || fail "$_eif_mode inventory did not publish error status"
  [ "${MERV_NVRAM_INVENTORY_REASON:-}" = "$_eif_reason" ] ||
    fail "$_eif_mode inventory reason=${MERV_NVRAM_INVENTORY_REASON:-unset}, expected $_eif_reason"
  [ -z "${MERV_NVRAM_INVENTORY_FILE:-}" ] || fail "$_eif_mode inventory retained a data path"
  case_pass "$_case_failures" "$_eif_mode selected target failed closed"
}

expect_inventory_failure malformed-key inventory-malformed
expect_inventory_failure unsafe-ssid inventory-malformed
expect_inventory_failure unsafe-ifname inventory-malformed
expect_inventory_failure duplicate inventory-malformed

# The record bound applies to the complete raw key/value inventory, not only
# selected targets.  The normal fixture has unrelated legal keys and must fail
# when the raw record budget is lower than that complete input.
merv_nvram_inventory_invalidate || fail 'record-bound inventory invalidation failed'
MANAGER_NVRAM_MODE=normal
MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS=2
export MANAGER_NVRAM_MODE MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'raw record bound unexpectedly accepted an oversized inventory'
else
  _record_bound_rc=$?
fi
[ "${_record_bound_rc:-0}" -eq 2 ] || fail "raw record bound returned rc=${_record_bound_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_STATUS:-}" = error ] || fail 'raw record bound did not publish error status'
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-malformed ] || fail 'raw record bound used the wrong failure class'
case_pass "$_case_failures" 'raw record bound covered unrelated input records'
MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS=32768

# The complete-output line budget is independent from the key=value record
# budget and rejects excessive framing/output even when individual lines are
# otherwise valid.
merv_nvram_inventory_invalidate || fail 'raw-line-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_RAW_LINES=100
export MERV_NVRAM_INVENTORY_MAX_RAW_LINES
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'raw line bound unexpectedly accepted an oversized inventory'
else
  _raw_line_bound_rc=$?
fi
[ "${_raw_line_bound_rc:-0}" -eq 2 ] || fail "raw line bound returned rc=${_raw_line_bound_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-malformed ] || fail 'raw line bound used the wrong failure class'
case_pass "$_case_failures" 'raw line bound covered the complete output'
MERV_NVRAM_INVENTORY_MAX_RAW_LINES=32768
export MERV_NVRAM_INVENTORY_MAX_RAW_LINES

# Byte bounds apply before filtering, so ignored legal keys still consume the
# raw input budget.
merv_nvram_inventory_invalidate || fail 'byte-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_RAW_BYTES=32
export MERV_NVRAM_INVENTORY_MAX_RAW_BYTES
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'raw byte bound unexpectedly accepted an oversized inventory'
else
  _byte_bound_rc=$?
fi
[ "${_byte_bound_rc:-0}" -eq 2 ] || fail "raw byte bound returned rc=${_byte_bound_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-too-large ] || fail 'raw byte bound used the wrong failure class'
case_pass "$_case_failures" 'raw byte bound covered unrelated input records'
MERV_NVRAM_INVENTORY_MAX_RAW_BYTES=1048576
export MERV_NVRAM_INVENTORY_MAX_RAW_BYTES

# Selected-target bounds remain independent from the generous complete-input
# budget.  The normal fixture is globally small enough but has two targets;
# one selected record must therefore fail closed.
merv_nvram_inventory_invalidate || fail 'selected-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS=1
export MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'selected record bound unexpectedly accepted multiple targets'
else
  _selected_bound_rc=$?
fi
[ "${_selected_bound_rc:-0}" -eq 2 ] || fail "selected record bound returned rc=${_selected_bound_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-malformed ] || fail 'selected record bound used the wrong failure class'
case_pass "$_case_failures" 'selected target bound stayed separate from raw input bounds'
MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS=128
export MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS

# Selected line/value/aggregate byte limits remain strict even though the raw
# limits carry a much larger live-derived safety margin.
merv_nvram_inventory_invalidate || fail 'selected-value-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES=4
export MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'selected value bound unexpectedly accepted the normal targets'
else
  _selected_value_rc=$?
fi
[ "${_selected_value_rc:-0}" -eq 2 ] || fail "selected value bound returned rc=${_selected_value_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-malformed ] || fail 'selected value bound used the wrong failure class'
case_pass "$_case_failures" 'selected target value bound failed closed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES=128
export MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES

merv_nvram_inventory_invalidate || fail 'selected-line-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES=10
export MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'selected line bound unexpectedly accepted the normal targets'
else
  _selected_line_rc=$?
fi
[ "${_selected_line_rc:-0}" -eq 2 ] || fail "selected line bound returned rc=${_selected_line_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-malformed ] || fail 'selected line bound used the wrong failure class'
case_pass "$_case_failures" 'selected target line bound failed closed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES=256
export MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES

merv_nvram_inventory_invalidate || fail 'selected-byte-bound inventory invalidation failed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES=16
export MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES
_case_failures=$FAILURES
if merv_nvram_inventory_read; then
  fail 'selected byte bound unexpectedly accepted the normal targets'
else
  _selected_bytes_rc=$?
fi
[ "${_selected_bytes_rc:-0}" -eq 2 ] || fail "selected byte bound returned rc=${_selected_bytes_rc:-unset}, expected 2"
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = inventory-selected-too-large ] || fail 'selected byte bound used the wrong failure class'
case_pass "$_case_failures" 'selected aggregate byte bound failed closed'
MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES=32768
export MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES

# Restore the normal fixture before the timeout and manager-preflight cases.
MANAGER_NVRAM_MODE=normal
export MANAGER_NVRAM_MODE

# Invalidate the successful cache, then make the actual `nvram show` hang.  A
# fresh process-scoped error must be published and subsequent reads must not
# retry the unbounded operation.
merv_nvram_inventory_invalidate || fail 'inventory invalidation failed'
: > "$TRACE"
MANAGER_NVRAM_MODE=stall
export MANAGER_NVRAM_MODE
_case_failures=$FAILURES
START_EPOCH=$(date +%s)
if merv_nvram_inventory_read; then
  fail 'stalled nvram show unexpectedly returned a valid inventory'
else
  _inventory_rc=$?
fi
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
[ "$_inventory_rc" -eq 2 ] || fail "stalled inventory returned rc=$_inventory_rc, expected 2"
[ "${MERV_NVRAM_INVENTORY_STATUS:-}" = error ] || fail 'stalled inventory did not publish error status'
[ "${MERV_NVRAM_INVENTORY_REASON:-}" = timeout ] || fail "stalled inventory reason=${MERV_NVRAM_INVENTORY_REASON:-unset}, expected timeout"
[ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 5 ] || fail "stalled nvram show exceeded bound (${ELAPSED}s)"
merv_nvram_inventory_read && fail 'memoized inventory error unexpectedly became success'
_show_count_after_timeout=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
[ "$_show_count_after_timeout" = 1 ] || fail "memoized inventory error retried nvram show (count=$_show_count_after_timeout)"
case_pass "$_case_failures" "stalled nvram show returned classified timeout rc=2 in ${ELAPSED}s and was memoized"

# Load the real manager main preflight and cleanup.  DRY_RUN skips lock/device
# setup but does not skip the NVRAM preflight.  Every mutation seam is marked;
# none may run before the failed inventory gate, and the completion phrase must
# not be emitted.  Cleanup is invoked with the real extracted function after
# the failed main return, preserving the EXIT-status handoff semantics.
MERV_MANAGER_MODE=normal
DRY_RUN=yes
LOCKDIR="$TEST_ROOT/locks"
SETTINGS_FILE="$TEST_ROOT/settings.json"
MANAGER_DHCP_TOKEN=manager-nvram-token
MANAGER_RUNTIME_OWNED=1
CHANGE_LOG="$TEST_ROOT/change.log"
MERV_ACTION_PROGRESS_ENABLED=1
MERV_ACTION_PROGRESS_FINAL=0
mkdir -p "$LOCKDIR" || exit 1
: > "$CHANGE_LOG"
export MERV_MANAGER_MODE DRY_RUN LOCKDIR SETTINGS_FILE MANAGER_DHCP_TOKEN
export MANAGER_RUNTIME_OWNED CHANGE_LOG MERV_ACTION_PROGRESS_ENABLED MERV_ACTION_PROGRESS_FINAL
_case_failures=$FAILURES

info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
merv_main_apply_memory_snapshot() { :; }
acquire_script_lock() { : > "$TEST_ROOT/acquire-lock-called"; return 0; }
merv_action_progress_update() { :; }
merv_observation_wait_idle() { :; }
merv_native_auth_snapshot() { :; }
validate_configuration() { :; }

# Mutation markers must remain absent when the preflight inventory fails.
cleanup_existing_config() { : > "$TEST_ROOT/topology-mutation"; return 0; }
merv_manager_arm_l2_before_mutation() { : > "$TEST_ROOT/l2-arm"; return 0; }
bind_configured_ssids() { : > "$TEST_ROOT/ssid-bind"; return 0; }
attach_to_bridge() { : > "$TEST_ROOT/attach"; return 0; }
show_configuration_summary() { info -c cli,vlan '=== CONFIGURATION APPLIED ==='; }

merv_dhcp_hold_abandon() { printf 'dhcp-abandon:%s:%s\n' "$1" "$2" >> "$TRACE"; return 0; }
merv_action_runtime_finish() { printf 'runtime-finish\n' >> "$TRACE"; return 0; }
release_script_lock() { printf 'manager-lock-release\n' >> "$TRACE"; return 0; }
merv_action_progress_complete() { printf 'progress-complete\n' >> "$TRACE"; }
merv_action_progress_fail() { printf 'progress-fail:%s\n' "$*" >> "$TRACE"; }

. "$EXTRACTED/main.sh" || fail 'manager main load'
. "$EXTRACTED/cleanup.sh" || fail 'manager cleanup load'

run_cleanup_with_status() {
  _run_status="$1"
  if [ "$_run_status" -eq 0 ]; then
    :
  else
    false
  fi
  cleanup_on_exit
}
run_manager_attempt() {
  main
  _main_rc=$?
  printf 'main-rc:%s\n' "$_main_rc" >> "$TRACE"
  run_cleanup_with_status "$_main_rc"
}

if run_manager_attempt; then
  _attempt_rc=0
else
  _attempt_rc=$?
fi
[ "$_attempt_rc" -eq 1 ] || fail "manager failure/cleanup status changed (rc=$_attempt_rc)"
grep -Fq 'main-rc:1' "$TRACE" || fail 'manager main did not propagate inventory failure rc=1'
grep -Fq 'NVRAM inventory preflight failed; aborting before topology mutation' "$TRACE" || fail 'manager did not log preflight inventory failure'
[ ! -e "$TEST_ROOT/topology-mutation" ] || fail 'topology mutation started after inventory failure'
[ ! -e "$TEST_ROOT/l2-arm" ] || fail 'L2 arming started after inventory failure'
[ ! -e "$TEST_ROOT/ssid-bind" ] || fail 'SSID binding started after inventory failure'
[ ! -e "$TEST_ROOT/attach" ] || fail 'bridge attachment started after inventory failure'
if grep -Fq 'CONFIGURATION APPLIED' "$TRACE"; then
  fail 'manager emitted CONFIGURATION APPLIED after inventory failure'
fi
grep -Fq 'dhcp-abandon:manager-nvram-token:' "$TRACE" || fail 'cleanup did not abandon manager DHCP ownership'
grep -Fq 'runtime-finish' "$TRACE" || fail 'cleanup did not release manager runtime ownership'
grep -Fq 'manager-lock-release' "$TRACE" || fail 'cleanup did not release manager lock ownership'
[ ! -e "$CHANGE_LOG" ] || fail 'cleanup left manager change log behind'
grep -Fq 'progress-fail:' "$TRACE" || fail 'cleanup did not publish failed terminal progress'
case_pass "$_case_failures" "manager propagated timeout before topology/configuration and cleanup released owned resources (elapsed=${ELAPSED}s)"

# Identity lookup failure must fail closed even when callers still hold a
# previously successful inventory pointer.  No new nvram show may be started.
MOCK_IDENTITY_FAIL=0
merv_identity_current_start() {
  [ "${MOCK_IDENTITY_FAIL:-0}" -eq 0 ] || return 1
  _identity_stat=$(cat "/proc/$$/stat" 2>/dev/null) || return 1
  case "$_identity_stat" in *") "*) _identity_stat=${_identity_stat##*) } ;; *) return 1 ;; esac
  printf '%s\n' "$_identity_stat" | awk '{print $20}'
}
IDENTITY_ROOT="$TEST_ROOT/identity-root"
mkdir -p "$IDENTITY_ROOT" || exit 1
MERV_NVRAM_INVENTORY_ROOT="$IDENTITY_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=identity
MANAGER_NVRAM_MODE=normal
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE MANAGER_NVRAM_MODE
MERV_NVRAM_INVENTORY_FILE="$TEST_ROOT/stale.data"
MERV_NVRAM_INVENTORY_STATUS=valid
MERV_NVRAM_INVENTORY_REASON=ok
MERV_NVRAM_INVENTORY_RC=0
MOCK_IDENTITY_FAIL=1
_case_failures=$FAILURES
_identity_before=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
if merv_nvram_inventory_read; then
  fail 'identity lookup failure unexpectedly returned valid inventory'
else
  _identity_rc=$?
fi
_identity_after=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
[ "$_identity_rc" -eq 2 ] || fail "identity lookup failure returned rc=$_identity_rc, expected 2"
[ "$_identity_after" = "$_identity_before" ] || fail 'identity lookup failure started nvram show'
[ "${MERV_NVRAM_INVENTORY_STATUS:-}" != valid ] || fail 'identity lookup failure retained valid inventory status'
[ -z "${MERV_NVRAM_INVENTORY_FILE:-}" ] || fail 'identity lookup failure retained stale inventory file'
case_pass "$_case_failures" 'identity lookup failure failed closed without reusing stale inventory'
MOCK_IDENTITY_FAIL=0

# A same-PID cache with a stale /proc start identity must be discarded and
# rebuilt; the stale derived data must never be accepted as current state.
STALE_ROOT="$TEST_ROOT/stale-cache"
mkdir -p "$STALE_ROOT" || exit 1
MERV_NVRAM_INVENTORY_ROOT="$STALE_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=stale
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE
merv_nvram_inventory_invalidate || fail 'stale-cache setup invalidation failed'
_stale_path=$(merv_nvram_inventory_path) || fail 'stale-cache path lookup failed'
_current_start=$(merv_nvram_inventory_process_start "$STALE_ROOT") || fail 'current identity lookup failed'
_stale_start=1
[ "$_current_start" = 1 ] && _stale_start=2
printf 'valid|%s|%s|0|ok\n' "$$" "$_stale_start" > "${_stale_path}.state"
printf 'wl0.1_ssid=Stale\nwl0.1_ifname=stale0.1\n' > "${_stale_path}.data"
_case_failures=$FAILURES
_stale_before=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
if ! merv_nvram_inventory_read; then
  fail 'same-PID stale cache was not rebuilt'
fi
_stale_after=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
[ "$(merv_nvram_inventory_value wl0.1_ssid 2>/dev/null)" = Guest ] || fail 'same-PID stale cache data was accepted'
[ "$_stale_after" -eq $((_stale_before + 1)) ] || fail 'same-PID stale cache did not trigger one rebuild'
case_pass "$_case_failures" 'same-PID stale cache identity was rejected and rebuilt'

# Malformed derived iface/VID rows are rejected before they can be rehydrated
# into the in-memory cache.
DERIVED_ROOT="$TEST_ROOT/derived-cache"
mkdir -p "$DERIVED_ROOT" || exit 1
MERV_NVRAM_INVENTORY_ROOT="$DERIVED_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=derived
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE
merv_nvram_inventory_invalidate || fail 'derived-cache setup invalidation failed'
_derived_path=$(merv_iface_vid_cache_path) || fail 'derived cache path lookup failed'
_derived_start=$(merv_nvram_inventory_process_start "$DERIVED_ROOT") || fail 'derived cache identity lookup failed'
printf 'valid|%s|%s|0|ok\n' "$$" "$_derived_start" > "${_derived_path}.state"
printf 'wl0.1 10 extra\n' > "${_derived_path}.data"
_MERV_IFACE_VID_CACHE_ON=1
_MERV_IFACE_VID_CACHE_STATUS=unset
_MERV_IFACE_VID_CACHE=''
_case_failures=$FAILURES
if merv_iface_vid_list >/dev/null 2>&1; then
  fail 'malformed derived cache row unexpectedly returned success'
else
  _derived_rc=$?
fi
[ "$_derived_rc" -eq 1 ] || fail "malformed derived cache row returned rc=$_derived_rc, expected 1"
[ "${_MERV_IFACE_VID_CACHE_STATUS:-}" = error ] || fail 'malformed derived cache row did not poison cache status'
[ -z "${_MERV_IFACE_VID_CACHE:-}" ] || fail 'malformed derived cache row leaked into memory'
case_pass "$_case_failures" 'malformed derived cache rows failed closed before rehydration'

# Cache invalidation must propagate an underlying inventory invalidation error
# instead of presenting a successful post-restart state to the manager.
INVALIDATE_ROOT="$TEST_ROOT/invalidate-cache"
mkdir -p "$INVALIDATE_ROOT" || exit 1
MERV_NVRAM_INVENTORY_ROOT="$INVALIDATE_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=invalidate
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE
_MERV_IFACE_VID_CACHE_ON=1
_MERV_IFACE_VID_CACHE_STATUS=valid
_MERV_IFACE_VID_CACHE='wl0.1 10'
_case_failures=$FAILURES
merv_nvram_inventory_invalidate() { return 1; }
if merv_iface_vid_cache_invalidate; then
  fail 'iface-to-VID invalidation swallowed underlying failure'
else
  _invalidate_rc=$?
fi
[ "$_invalidate_rc" -ne 0 ] || fail 'iface-to-VID invalidation returned zero after failure'
[ "${_MERV_IFACE_VID_CACHE_STATUS:-}" = error ] || fail 'failed invalidation did not leave cache in error state'
. "$EXTRACTED/inventory-invalidate.sh" || fail 'inventory invalidation restore failed'
case_pass "$_case_failures" 'iface-to-VID invalidation propagated underlying failure and stayed fail-closed'

# Both a symlinked cache root and a symlinked ancestor are untrusted paths.
# They must fail before mkdir or nvram show and must not reuse prior status.
SYMLINK_TARGET="$TEST_ROOT/symlink-target"
SYMLINK_ROOT="$TEST_ROOT/symlink-root"
mkdir -p "$SYMLINK_TARGET" || exit 1
ANCESTOR_TARGET="$TEST_ROOT/ancestor-target"
ANCESTOR_LINK="$TEST_ROOT/ancestor-link"
mkdir -p "$ANCESTOR_TARGET" || exit 1
SYMLINK_TESTS_BLOCKED=0
SYMLINK_BLOCKED_COUNT=0
if ln -s "$SYMLINK_TARGET" "$SYMLINK_ROOT" 2>/dev/null && [ -L "$SYMLINK_ROOT" ]; then
  MERV_NVRAM_INVENTORY_ROOT="$SYMLINK_ROOT"
  MERV_NVRAM_INVENTORY_SCOPE=symlink-root
  MERV_NVRAM_INVENTORY_STATUS=stale
  MERV_NVRAM_INVENTORY_FILE="$TEST_ROOT/stale-symlink.data"
  export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE
  _case_failures=$FAILURES
  _symlink_before=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
  _symlink_root_rc=0
  if merv_nvram_inventory_read; then
    _symlink_root_rc=0
    fail 'symlinked cache root unexpectedly returned success'
  else
    _symlink_root_rc=$?
  fi
  _symlink_after=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
  [ "$_symlink_root_rc" -eq 2 ] || fail "symlinked cache root returned rc=$_symlink_root_rc, expected 2"
  [ "$_symlink_after" = "$_symlink_before" ] || fail 'symlinked cache root invoked nvram show'
  [ "${MERV_NVRAM_INVENTORY_STATUS:-}" != valid ] || fail 'symlinked cache root retained valid status'
  case_pass "$_case_failures" 'symlinked cache root failed closed before inventory read'

  if ln -s "$ANCESTOR_TARGET" "$ANCESTOR_LINK" 2>/dev/null && [ -L "$ANCESTOR_LINK" ]; then
    MERV_NVRAM_INVENTORY_ROOT="$ANCESTOR_LINK/cache"
    MERV_NVRAM_INVENTORY_SCOPE=symlink-ancestor
    MERV_NVRAM_INVENTORY_STATUS=stale
    MERV_NVRAM_INVENTORY_FILE="$TEST_ROOT/stale-ancestor.data"
    export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE
    _case_failures=$FAILURES
    _ancestor_before=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
    _ancestor_rc=0
    if merv_nvram_inventory_read; then
      _ancestor_rc=0
      fail 'symlinked cache ancestor unexpectedly returned success'
    else
      _ancestor_rc=$?
    fi
    _ancestor_after=$(grep -c '^show-start$' "$TRACE" 2>/dev/null || printf 0)
    [ "$_ancestor_rc" -eq 2 ] || fail "symlinked cache ancestor returned rc=$_ancestor_rc, expected 2"
    [ "$_ancestor_after" = "$_ancestor_before" ] || fail 'symlinked cache ancestor invoked nvram show'
    [ "${MERV_NVRAM_INVENTORY_STATUS:-}" != valid ] || fail 'symlinked cache ancestor retained valid status'
    case_pass "$_case_failures" 'symlinked cache ancestor failed closed before inventory read'
  else
    SYMLINK_TESTS_BLOCKED=1
    SYMLINK_BLOCKED_COUNT=$((SYMLINK_BLOCKED_COUNT + 1))
    printf 'BLOCKED: harness cannot create a symlinked cache ancestor\n' >&2
  fi
else
  SYMLINK_TESTS_BLOCKED=1
  SYMLINK_BLOCKED_COUNT=$((SYMLINK_BLOCKED_COUNT + 2))
  printf 'BLOCKED: harness cannot create a symlinked cache root\n' >&2
fi

# Exercise the real main restart branch: a failed derived-cache invalidation
# must abort before post-restart eviction, quiet-wait, or shield re-arm work.
MERV_NVRAM_INVENTORY_ROOT="$INVENTORY_ROOT"
MERV_NVRAM_INVENTORY_SCOPE=manager
MANAGER_NVRAM_MODE=normal
export MERV_NVRAM_INVENTORY_ROOT MERV_NVRAM_INVENTORY_SCOPE MANAGER_NVRAM_MODE
. "$EXTRACTED/inventory-invalidate.sh" || fail 'inventory invalidation restore before restart case failed'
merv_nvram_inventory_invalidate || fail 'restart-case inventory setup invalidation failed'
merv_nvram_inventory_read || fail 'restart-case normal inventory setup failed'
MERV_MANAGER_MODE=normal
DRY_RUN=no
MERV_IS_NODE=0
NODE_ID=''
MODEL=fixture
PRODUCTID=fixture
WAN_IF=eth0
TOPOLOGY=fixture
PERSISTENT=no
MAX_SSIDS=0
ETH_PORTS=''
MERV_ACTION_PROGRESS_FINAL=0
MANAGER_DHCP_TOKEN=''
MERV_DHCP_HOLD_TOKEN=''
MANAGER_PARENT_RUN_ID=''
MANAGER_HANDOFF_ID=''
export MERV_MANAGER_MODE DRY_RUN MERV_IS_NODE NODE_ID MODEL PRODUCTID WAN_IF TOPOLOGY
export PERSISTENT MAX_SSIDS ETH_PORTS MERV_ACTION_PROGRESS_FINAL MANAGER_DHCP_TOKEN
export MERV_DHCP_HOLD_TOKEN
_case_failures=$FAILURES
boot_wait_for_configured_ssids() { return 0; }
merv_dhcp_hold_reconcile() { return 0; }
merv_dhcp_hold_acquire() { MERV_DHCP_HOLD_TOKEN=restart-case-token; return 0; }
merv_dhcp_hold_mark_mutating() { return 0; }
run_wan_native() { return 0; }
merv_iface_vid_cache_enable() { return 0; }
merv_iface_vid_cache_invalidate() { : > "$TEST_ROOT/restart-cache-invalidate"; return 1; }
restart_services() { : > "$TEST_ROOT/restart-services"; return 0; }
cleanup_existing_config() { : > "$TEST_ROOT/restart-cleanup"; return 0; }
bind_configured_ssids() { : > "$TEST_ROOT/restart-bind"; return 0; }
merv_soft_evict_wl_from_br0() { : > "$TEST_ROOT/post-restart-evict"; return 0; }
wait_for_rc_quiet() { : > "$TEST_ROOT/post-restart-quiet"; return 0; }
ebtables() { : > "$TEST_ROOT/post-restart-ebtables"; return 0; }
: > "$TRACE"
if main; then
  _restart_rc=0
else
  _restart_rc=$?
fi
[ "$_restart_rc" -eq 1 ] || fail "post-restart invalidation failure returned rc=$_restart_rc, expected 1"
[ -e "$TEST_ROOT/restart-cache-invalidate" ] || fail 'post-restart invalidation helper was not called'
[ -e "$TEST_ROOT/restart-services" ] || fail 'restart phase did not run before invalidation gate'
[ ! -e "$TEST_ROOT/post-restart-evict" ] || fail 'post-restart eviction ran after invalidation failure'
[ ! -e "$TEST_ROOT/post-restart-quiet" ] || fail 'post-restart quiet wait ran after invalidation failure'
[ ! -e "$TEST_ROOT/post-restart-ebtables" ] || fail 'post-restart shield re-arm ran after invalidation failure'
grep -Fq 'Post-restart iface-to-VID cache invalidation failed; aborting before post-restart guard work' "$TRACE" || fail 'post-restart invalidation failure was not logged'
case_pass "$_case_failures" 'post-restart invalidation failure aborted before guard work'

# Direct manager resolver/phase coverage.  The inventory reader is stubbed with
# a file-backed counter so the assertions survive command-substitution child
# shells.  This covers the manager-only reuse seam without changing the
# standalone inventory contract exercised above.
_case_failures=$FAILURES
if (
  set -u
  _ssid_root="$TEST_ROOT/ssid-manager"
  _ssid_inventory="$_ssid_root/published.data"
  _ssid_alternate="$_ssid_root/alternate.data"
  _ssid_symlink="$_ssid_root/published-link.data"
  _ssid_remap_pre="$_ssid_root/remap-pre.data"
  _ssid_remap_post="$_ssid_root/remap-post.data"
  _ssid_trace="$_ssid_root/trace"
  mkdir -p "$_ssid_root" || exit 1
  cat > "$_ssid_inventory" <<'EOF_SSID'
wl0.1_ssid=Guest
wl0.1_ifname=wl0.1
wl1.1_ssid=Guest
wl1.1_ifname=wl1.1
wl0.2_ssid=not-target
wl0.2_ifname=wl0.2
wl0.3_ssid=MiXeD
wl0.3_ifname=wl0.3
wl0.6_ssid=MiXeD
wl0.6_ifname=wl0.6
wl2.3_ssid=CaseOnly
wl2.3_ifname=wl2.3
wl0.4_ssid=Internal
wl0.4_ifname=wl0.5
wl0.5_ssid=
EOF_SSID
  printf '%s\n' 'wl9.9_ssid=Alternate' 'wl9.9_ifname=wl9.9' > "$_ssid_alternate" || exit 1
  printf '%s\n' 'wl0.1_ssid=SSID A' 'wl0.1_ifname=wl0.1' > "$_ssid_remap_pre" || exit 1
  printf '%s\n' 'wl1.2_ssid=SSID A' 'wl1.2_ifname=wl1.2' > "$_ssid_remap_post" || exit 1
  : > "$_ssid_trace" || exit 1

  for _manager_piece in \
    normalize_basic normalize_iface normalize_ssid to_lower \
    merv_manager_inventory_file_is_current merv_manager_inventory_prepare \
    ssid_configured_for_iface is_internal_vap find_if_by_ssid find_if_by_ssid_any \
    ssid_in_nvram boot_wait_for_configured_ssids nvram_base_for_ifname \
    set_ap_isolation attach_to_bridge bind_configured_ssids; do
    . "$EXTRACTED/$_manager_piece.sh" || exit 1
  done

  _phase_fail() { printf 'FAIL: SSID phase: %s\n' "$1" >&2; exit 1; }
  _phase_expect() { "$@" || _phase_fail "$*"; }
  _trace_count() {
    if grep -q "^$1$" "$_ssid_trace" 2>/dev/null; then
      grep -c "^$1$" "$_ssid_trace"
    else
      printf '0\n'
    fi
  }
  _trace_prefix_count() {
    if grep -q "^$1" "$_ssid_trace" 2>/dev/null; then
      grep -c "^$1" "$_ssid_trace"
    else
      printf '0\n'
    fi
  }

  info() { :; }
  warn() { :; }
  error() { :; }
  track_change() { :; }

  # Keep the test oracle independent of the production inventory reader while
  # retaining its key/value lookup shape.
  merv_nvram_inventory_read() {
    local _ssid_published="$_ssid_inventory"
    printf '%s\n' read >> "$_ssid_trace"
    if [ "${SSID_READ_FAIL:-0}" = 1 ]; then
      MERV_NVRAM_INVENTORY_FILE=''
      MERV_NVRAM_INVENTORY_STATUS=error
      MERV_NVRAM_INVENTORY_REASON=test-failure
      MERV_NVRAM_INVENTORY_RC=2
      return 2
    fi
    if [ "${SSID_REMAP_MODE:-}" = post ]; then
      _ssid_published="$_ssid_remap_post"
    elif [ "${SSID_REMAP_MODE:-}" = pre ]; then
      _ssid_published="$_ssid_remap_pre"
    fi
    MERV_NVRAM_INVENTORY_FILE="$_ssid_published"
    MERV_NVRAM_INVENTORY_STATUS=valid
    MERV_NVRAM_INVENTORY_REASON=ok
    MERV_NVRAM_INVENTORY_RC=0
    return 0
  }
  merv_nvram_inventory_value() {
    case "$1" in
      *_ifname) printf '%s\n' "lookup-ifname:$1" >> "$_ssid_trace" ;;
    esac
    awk -F= -v wanted="$1" \
      '$1 == wanted { print substr($0, index($0, "=") + 1); found=1; exit } END { exit(found ? 0 : 1) }' \
      "$MERV_NVRAM_INVENTORY_FILE"
  }
  # This counter-bearing classifier is intentionally deterministic: wl0.5 is
  # the internal VAP fixture, every other test interface is user-managed.
  is_internal_vap() {
    case " $BOUND_IFACES " in
      *" $1 "*) printf '%s\n' "class-bound:$1" >> "$_ssid_trace" ;;
      *) printf '%s\n' "class:$1" >> "$_ssid_trace" ;;
    esac
    [ "$1" = wl0.5 ]
  }
  iface_exists() { return 0; }
  is_wl_iface() { printf '%s\n' "wl-check:$1" >> "$_ssid_trace"; return 0; }
  is_ssid_slot_allowed() { [ "$1" = 1 ]; }
  get_ssid_slot_value() { [ "$1" = 1 ] && printf '%s\n' Guest; }
  get_vlan_slot_value() { [ "$1" = 1 ] && printf '%s\n' 10; }
  validate_vlan_id() { return 0; }
  ensure_vlan_bridge() { return 0; }
  is_native_radio() { return 1; }
  wait_for_interface() { return 0; }
  note_bound_iface() {
    BOUND_IFACES="$BOUND_IFACES $1"
    printf '%s\n' "bound:$1" >> "$_ssid_trace"
  }
  wl() { printf '%s\n' "wl:$*" >> "$_ssid_trace"; return 0; }
  nvram() { printf '%s\n' "nvram:$*" >> "$_ssid_trace"; return 0; }

  # Exact matches still return every radio, while unrelated SSIDs do not
  # resolve ifnames or invoke classification.  A single case-insensitive
  # fallback and an internal VAP retain their prior semantics.
  MERV_NVRAM_INVENTORY_FILE="$_ssid_inventory"
  MERV_NVRAM_INVENTORY_STATUS=valid
  MERV_NVRAM_INVENTORY_REASON=ok
  MERV_NVRAM_INVENTORY_RC=0
  BOUND_IFACES=''
  : > "$_ssid_trace"
  _resolved="$(find_if_by_ssid_any Guest "$_ssid_inventory")" || _resolved_rc=$?
  [ "${_resolved_rc:-0}" = 0 ] || _phase_fail "exact multi-radio lookup rc=${_resolved_rc:-unset}"
  [ "$_resolved" = "$(printf 'wl0.1\nwl1.1')" ] || _phase_fail "exact multi-radio result=$_resolved"
  [ "$(_trace_count read)" = 0 ] || _phase_fail 'current published inventory was reread for resolver reuse'
  [ "$(_trace_count lookup-ifname:wl0.1_ifname)" = 1 ] || _phase_fail 'first exact candidate ifname lookup count changed'
  [ "$(_trace_count lookup-ifname:wl1.1_ifname)" = 1 ] || _phase_fail 'second exact candidate ifname lookup count changed'
  [ "$(_trace_prefix_count lookup-ifname:)" = 2 ] || _phase_fail 'unrelated candidate reached ifname resolution'
  [ "$(_trace_prefix_count class:)" = 2 ] || _phase_fail 'unrelated candidate reached classification'

  : > "$_ssid_trace"
  _ambiguous_rc=0
  _resolved="$(find_if_by_ssid_any mixed "$_ssid_inventory")" || _ambiguous_rc=$?
  [ "$_ambiguous_rc" = 1 ] || _phase_fail "ambiguous case-insensitive fallback rc=$_ambiguous_rc"
  [ -z "$_resolved" ] || _phase_fail 'ambiguous case-insensitive fallback returned an interface'
  [ "$(_trace_prefix_count lookup-ifname:)" = 2 ] || _phase_fail 'ambiguous fallback did not inspect both matching interfaces'
  [ "$(_trace_prefix_count class:)" = 2 ] || _phase_fail 'ambiguous fallback classification count changed'

  : > "$_ssid_trace"
  _resolved="$(find_if_by_ssid_any caseonly "$_ssid_inventory")" || _resolved_rc=$?
  [ "${_resolved_rc:-0}" = 0 ] || _phase_fail "case-insensitive fallback rc=${_resolved_rc:-unset}"
  [ "$_resolved" = wl2.3 ] || _phase_fail "case-insensitive fallback result=$_resolved"
  [ "$(_trace_prefix_count lookup-ifname:)" = 1 ] || _phase_fail 'case-insensitive fallback resolved unrelated candidates'
  [ "$(_trace_prefix_count class:)" = 1 ] || _phase_fail 'case-insensitive fallback classification count changed'

  : > "$_ssid_trace"
  _internal_rc=0
  _resolved="$(find_if_by_ssid_any Internal "$_ssid_inventory")" || _internal_rc=$?
  [ "$_internal_rc" = 1 ] || _phase_fail "internal VAP lookup rc=$_internal_rc"
  [ -z "$_resolved" ] || _phase_fail 'internal VAP leaked into resolver result'
  [ "$(_trace_prefix_count lookup-ifname:)" = 1 ] || _phase_fail 'internal VAP did not resolve its matched ifname'
  [ "$(_trace_prefix_count class:)" = 1 ] || _phase_fail 'internal VAP classification count changed'

  # An unrelated regular path and a symlinked current path must never be
  # trusted as the published inventory; both fall back to the authoritative
  # reader and therefore use the fixture published by that reader.
  : > "$_ssid_trace"
  _resolved="$(find_if_by_ssid_any Guest "$_ssid_alternate")" || _resolved_rc=$?
  [ "${_resolved_rc:-0}" = 0 ] || _phase_fail 'alternate inventory path did not fail over to reader'
  [ "$_resolved" = "$(printf 'wl0.1\nwl1.1')" ] || _phase_fail 'alternate path was trusted over published inventory'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'alternate path did not force one authoritative read'

  if ln -s "$_ssid_inventory" "$_ssid_symlink" 2>/dev/null; then
    MERV_NVRAM_INVENTORY_FILE="$_ssid_symlink"
    MERV_NVRAM_INVENTORY_STATUS=valid
    MERV_NVRAM_INVENTORY_REASON=ok
    MERV_NVRAM_INVENTORY_RC=0
    : > "$_ssid_trace"
    _resolved="$(find_if_by_ssid_any Guest "$_ssid_symlink")" || _resolved_rc=$?
    [ "${_resolved_rc:-0}" = 0 ] || _phase_fail 'symlinked published path did not fail over to reader'
    [ "$_resolved" = "$(printf 'wl0.1\nwl1.1')" ] || _phase_fail 'symlinked path was trusted over published inventory'
    [ "$(_trace_count read)" = 1 ] || _phase_fail 'symlinked path did not force one authoritative read'
  fi

  # No-argument helpers retain the standalone fail-closed read behavior.
  SSID_READ_FAIL=1
  MERV_NVRAM_INVENTORY_FILE=''
  MERV_NVRAM_INVENTORY_STATUS=''
  MERV_NVRAM_INVENTORY_REASON=''
  MERV_NVRAM_INVENTORY_RC=''
  : > "$_ssid_trace"
  _standalone_rc=0
  _resolved="$(find_if_by_ssid_any Guest)" || _standalone_rc=$?
  [ "$_standalone_rc" = 2 ] || _phase_fail "standalone resolver failure rc=$_standalone_rc"
  [ -z "$_resolved" ] || _phase_fail 'standalone resolver emitted output after inventory failure'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'standalone resolver did not perform one fail-closed read'
  SSID_READ_FAIL=0

  # A restart invalidation must retire the prior derived/inventory state so a
  # remapped SSID is rebuilt from the post-restart NVRAM view.
  MERV_NVRAM_INVENTORY_ROOT="$_ssid_root/remap-cache"
  MERV_NVRAM_INVENTORY_SCOPE=ssid-remap
  mkdir -p "$MERV_NVRAM_INVENTORY_ROOT" || _phase_fail 'remap cache root setup failed'
  SSID_REMAP_MODE=pre
  BOUND_IFACES=''
  MERV_NVRAM_INVENTORY_FILE=''
  MERV_NVRAM_INVENTORY_STATUS=''
  MERV_NVRAM_INVENTORY_REASON=''
  MERV_NVRAM_INVENTORY_RC=''
  : > "$_ssid_trace"
  merv_manager_inventory_prepare '' || _phase_fail 'pre-restart inventory build failed'
  _resolved="$(find_if_by_ssid_any 'SSID A' "$MERV_NVRAM_INVENTORY_FILE")" || _phase_fail 'pre-restart SSID resolution failed'
  [ "$_resolved" = wl0.1 ] || _phase_fail "pre-restart SSID mapping=$_resolved"
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'pre-restart inventory was not read once'
  _remap_cache_path="$(merv_iface_vid_cache_path)" || _phase_fail 'restart cache path lookup failed'
  printf '%s\n' 'wl0.1 10' > "${_remap_cache_path}.data" || _phase_fail 'restart cache data setup failed'
  printf '%s\n' "valid|$$|1|0|ok" > "${_remap_cache_path}.state" || _phase_fail 'restart cache state setup failed'

  SSID_REMAP_MODE=post
  # The earlier main() restart-failure case deliberately overrides this
  # helper. Restore the extracted production implementation before proving
  # successful invalidation/remap behavior in the direct phase harness.
  . "$EXTRACTED/iface-cache-invalidate.sh" || _phase_fail 'restart cache invalidation helper restore failed'
  merv_iface_vid_cache_invalidate || _phase_fail 'restart cache invalidation failed'
  [ ! -e "${_remap_cache_path}.data" ] && [ ! -e "${_remap_cache_path}.state" ] ||
    _phase_fail 'restart cache artifacts survived invalidation'
  merv_manager_inventory_prepare '' || _phase_fail 'post-restart inventory rebuild failed'
  _resolved="$(find_if_by_ssid_any 'SSID A' "$MERV_NVRAM_INVENTORY_FILE")" || _phase_fail 'post-restart SSID resolution failed'
  [ "$_resolved" = wl1.2 ] || _phase_fail "post-restart SSID mapping=$_resolved"
  [ "$(_trace_count read)" = 2 ] || _phase_fail 'post-restart inventory did not rebuild once'

  # Bind validates once, reuses that path for resolution/classification, and
  # skips BOUND_SET members before the classifier during the unconfigured sweep.
  # Return the fixture reader to its ordinary published view after the remap
  # proof so this phase remains independent of the restart-only mapping.
  SSID_REMAP_MODE=''
  MERV_NVRAM_INVENTORY_FILE="$_ssid_inventory"
  MERV_NVRAM_INVENTORY_STATUS=valid
  MERV_NVRAM_INVENTORY_REASON=ok
  MERV_NVRAM_INVENTORY_RC=0
  MERV_MANAGER_MODE=normal
  MAX_SSIDS=1
  SETTINGS_FILE="$_ssid_root/settings.json"
  _SSID_FILTER_TOKEN=test
  SSID_FILTER_FATAL=0
  ENABLE_NATIVE_SSID=0
  PERSISTENT=no
  DRY_RUN=yes
  DEFAULT_BRIDGE=br0
  BOUND_IFACES=''
  : > "$_ssid_trace"
  _bind_output="$_ssid_root/bind-output"
  bind_configured_ssids > "$_bind_output" || _phase_fail 'bind phase failed'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'bind phase performed more than one inventory validation'
  [ "$(_trace_count class:wl0.1)" = 1 ] || _phase_fail 'bound wl0.1 was classified again during sweep'
  [ "$(_trace_count class:wl1.1)" = 1 ] || _phase_fail 'bound wl1.1 was classified again during sweep'
  [ "$(_trace_count class-bound:wl0.1)" = 1 ] || _phase_fail 'bound wl0.1 attach did not use the prepared inventory'
  [ "$(_trace_count class-bound:wl1.1)" = 1 ] || _phase_fail 'bound wl1.1 attach did not use the prepared inventory'
  grep -Fq 'class:wl0.2' "$_ssid_trace" || _phase_fail 'unconfigured wl0.2 was not classified'
  grep -Fq 'brctl addif br0 wl0.2' "$_bind_output" || _phase_fail 'unconfigured wl0.2 was not restored'
  ! grep -Fq 'brctl addif br0 wl0.1' "$_bind_output" || _phase_fail 'bound wl0.1 was swept into br0'

  # Boot readiness validates once, then reuses the same inventory for both
  # the SSID presence partition and multi-radio interface resolution.
  MERV_MANAGER_MODE=boot
  MAX_SSIDS=1
  : > "$_ssid_trace"
  boot_wait_for_configured_ssids 2 || _phase_fail 'boot readiness phase failed'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'boot readiness performed more than one inventory validation'
  [ "$(_trace_count lookup-ifname:wl0.1_ifname)" = 1 ] || _phase_fail 'boot readiness did not reuse resolver inventory'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'boot readiness resolver reread inventory'

  # AP isolation keeps standalone mapping fail-closed while an already
  # prepared path is reused for subsequent interfaces.
  MERV_MANAGER_MODE=normal
  DRY_RUN=no
  PERSISTENT=yes
  : > "$_ssid_trace"
  set_ap_isolation wl0.1 1 || _phase_fail 'standalone APISO mapping failed'
  set_ap_isolation wl1.1 0 "$_ssid_inventory" || _phase_fail 'reused APISO mapping failed'
  [ "$(_trace_count read)" = 1 ] || _phase_fail 'APISO mappings did not validate once then reuse'
  [ "$(_trace_prefix_count wl:)" = 2 ] || _phase_fail 'APISO interface update count changed'
  exit 0
); then
  case_pass "$_case_failures" 'manager SSID resolver and phase reuse contract'
else
  fail 'manager SSID resolver and phase reuse contract'
fi

if [ "$SYMLINK_TESTS_BLOCKED" -ne 0 ]; then
  _manager_executed=$MANAGER_CASES
  _manager_passed=$((_manager_executed - FAILURES))
  printf 'MANAGER_NVRAM_INVENTORY_CONTRACT_PARTIAL (%s executed: %s passed, %s failed; %s symlink cases blocked by harness)\n' \
    "$_manager_executed" "$_manager_passed" "$FAILURES" "$SYMLINK_BLOCKED_COUNT"
else
  printf 'MANAGER_NVRAM_INVENTORY_CONTRACT_%s (%s cases)\n' \
    "$( [ "$FAILURES" -eq 0 ] && printf OK || printf FAILED )" "$MANAGER_CASES"
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s manager NVRAM contract assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
