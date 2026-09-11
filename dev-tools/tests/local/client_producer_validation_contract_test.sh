#!/bin/sh
# Real client producer / real validator contract test
# Exercises the REAL functions/collect_local_clients.sh serializer against the
# REAL production json_validate_file() AWK parser from settings/lib_json.sh.
# Does NOT modify /usr/bin, /usr/sbin, or any host binaries.
# Uses in-shell brctl function for complete test isolation.

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
MERV_BASE="$BASE_DIR"
export MERV_BASE

TEST_ROOT="/tmp/mervlan_tmp/selftest.client-producer.$$"
umask 077
mkdir -p "$TEST_ROOT/fake_sys" "$TEST_ROOT/bin" "$TEST_ROOT/runtime" "$TEST_ROOT/logs" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

# Keep every Update lifecycle probe private to this contract fixture.  The
# collector must see an idle, verifiably absent maintenance namespace even
# when the host cannot provide the unshare-based mount isolation branch.
MERV_STATE_ROOT="$TEST_ROOT/runtime/state"
MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
MERV_UPDATE_MAINTENANCE_LOCK="$TEST_ROOT/runtime/maintenance/mervlan_maintenance.lock"
mkdir -p "$MERV_STATE_ROOT" "${MERV_UPDATE_MAINTENANCE_LOCK%/*}" || exit 1
export MERV_STATE_ROOT MERV_UPDATE_JOURNAL MERV_UPDATE_QUIESCE_FILE
export MERV_UPDATE_MAINTENANCE_LOCK

_FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _FAILURES=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Minimum libraries required by the outer test harness (contract parser + identity helpers)
[ -n "${LIB_JSON_LOADED:-}" ]     || . "$BASE_DIR/settings/lib_json.sh" 2>/dev/null || :
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$BASE_DIR/settings/lib_identity.sh" 2>/dev/null || :

# ---------------------------------------------------------------------------
# Setup isolated mock environment for brctl and sysfs
# ---------------------------------------------------------------------------
SYS_NET="$TEST_ROOT/fake_sys"
export MERV_SYS_CLASS_NET_ROOT="$SYS_NET"

create_mock_bridge() {
  _br="$1"; shift
  _bpath="$SYS_NET/$_br"
  mkdir -p "$_bpath/brif"
  printf '00:aa:bb:cc:dd:%02x\n' "${_br#br}" > "$_bpath/address"
  _port_idx=1
  for _iface in "$@"; do
    _ipath="$_bpath/brif/$_iface"
    mkdir -p "$_ipath"
    printf '%d\n' "$_port_idx" > "$_ipath/port_no"
    mkdir -p "$SYS_NET/$_iface"
    printf '00:aa:bb:cc:ee:%02x\n' "$_port_idx" > "$SYS_NET/$_iface/address"
    _port_idx=$((_port_idx + 1))
  done
}

# Standard topology matching live baseline:
# br187 (count 4), br188 (count 5), br189 (count 3)
create_mock_bridge br0 eth0 eth1
create_mock_bridge br187 wl0.1 wl0.2 eth0.187
create_mock_bridge br188 wl1.1 eth0.188
create_mock_bridge br189 wl2.1 eth0.189

# Mock brctl script
MOCK_BRCTL_SCRIPT="$TEST_ROOT/mock_brctl.sh"
cat > "$MOCK_BRCTL_SCRIPT" <<'EOF'
#!/bin/sh
if [ "$1" = "showmacs" ]; then
  case "$2" in
    br187)
      printf '1 00:aa:bb:cc:ee:01 yes 0\n'
      printf '1 10:20:30:40:50:01 no 5.2\n'
      printf '2 10:20:30:40:50:02 no 1.1\n'
      printf '3 10:20:30:40:50:03 no 8.5\n'
      printf '3 10:20:30:40:50:04 no 12.0\n'
      ;;
    br188)
      printf '1 20:20:30:40:50:01 no 2.0\n'
      printf '1 20:20:30:40:50:02 no 4.1\n'
      printf '2 20:20:30:40:50:03 no 0.5\n'
      printf '2 20:20:30:40:50:04 no 15.3\n'
      printf '2 20:20:30:40:50:05 no 22.0\n'
      ;;
    br189)
      printf '1 30:20:30:40:50:01 no 3.2\n'
      printf '2 30:20:30:40:50:02 no 6.4\n'
      printf '2 30:20:30:40:50:03 no 9.1\n'
      ;;
    br999)
      printf '1 99:20:30:40:50:01 no 1.0\n'
      printf '2 99:20:30:40:50:02 no 2.0\n'
      ;;
    *)
      ;;
  esac
fi
exit 0
EOF
chmod 755 "$MOCK_BRCTL_SCRIPT"

export FDB_RETRIES=1
export FDB_RETRY_SLEEP=0

# Source production libraries for validator in test harness
export MERV_BASE="$BASE_DIR"
. "$BASE_DIR/settings/var_settings.sh" || { fail "could not load var_settings"; exit 1; }
. "$BASE_DIR/settings/lib_json.sh" || { fail "could not load lib_json"; exit 1; }

COLLECTOR_FIXTURE="$TEST_ROOT/collector_fixture.sh"
cat > "$COLLECTOR_FIXTURE" <<'EOF'
#!/bin/sh
_sys_dir="$1"
_out_file="$2"
_n_name="$3"
_n_ip="$4"
_merv_root="$5"
_brctl_mock="$6"
_reject="$7"
_fail_id="$8"
_fail_scr="$9"
shift 9
_fail_cand="$1"
_fail_esc="$2"
_fail_m_chmod="$3"
_fail_m_mv="$4"
_fail_dir="${5:-0}"
_fail_hdr="${6:-0}"

if ! mount --bind "$_sys_dir" /sys/class/net 2>/dev/null; then
  get_bridges() {
    ls "$_sys_dir" 2>/dev/null | grep -E '^br[0-9]+$' | grep -v '^br0$' | sed 's/^br//' | sort -n | sed 's/^/br/'
  }
  get_bridge_members() {
    case "$1" in
      br999)
        printf '%s\n' 'wl0.1"test' 'eth0.999\backslash'
        ;;
      *)
        ls "$_sys_dir/$1/brif/" 2>/dev/null
        ;;
    esac
  }
  build_port_map() {
    local bridge="$1"
    local mapfile="$2"
    local d pn iface
    : > "$mapfile"
    for d in "$_sys_dir/$bridge/brif/"*; do
      [ -e "$d/port_no" ] || continue
      pn=$(cat "$d/port_no" 2>/dev/null)
      pn=$((pn))
      iface="${d##*/}"
      printf '%s %s\n' "$pn" "$iface" >> "$mapfile"
    done
  }
  get_trunk_ports() {
    ls "$_sys_dir" 2>/dev/null | grep -E '^eth[1-9][0-9]*\.[0-9]+$' | sed 's/\.[0-9]*$//' | sort | uniq -c | awk '$1 >= 1 {print $2}'
  }
  get_trunk_vlans() {
    ls "$_sys_dir" 2>/dev/null | grep -E "^${1}\.[0-9]+$" | sed "s/^${1}\.//" | sort -n | tr '\n' ',' | sed 's/,$//'
  }
  get_trunk_native_vlan() {
    for br in $(get_bridges) br0; do
      if [ -d "$_sys_dir/$br/brif/$1" ]; then
        vlan_id="${br#br}"
        [ "$vlan_id" = "0" ] && vlan_id="native"
        echo "$vlan_id"
        return 0
      fi
    done
    echo ""
  }
  build_own_mac_exclude() {
    local out="$1"
    local tmp="${out}.tmp"
    : > "$tmp" || return 0
    for p in "$_sys_dir"/*/address; do
      [ -f "$p" ] || continue
      append_own_mac_candidate "$(cat "$p" 2>/dev/null)" "$tmp"
    done
    sort -u "$tmp" > "$out" 2>/dev/null || cp "$tmp" "$out" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  }
fi
export MERV_BASE="$_merv_root"
export MERV_SYS_CLASS_NET_ROOT="$_sys_dir"

# Self-contained in-shell brctl function
brctl() {
  "$_brctl_mock" "$@"
}

if [ "$_fail_dir" = "1" ]; then
  mkdir() {
    return 1
  }
fi

if [ "$_fail_hdr" = "1" ]; then
  mkdir -p "$_out_file.new.$$" 2>/dev/null || :
fi

if [ "$_reject" = "1" ]; then
  . "$_merv_root/settings/var_settings.sh"
  . "$_merv_root/settings/log_settings.sh"
  . "$_merv_root/settings/lib_json.sh"
  LIB_JSON_LOADED=1
  json_validate_file() {
    case "$1" in
      *metadata.json*|*metadata.json.tmp*)
        _json_contract_validate_file "$1"
        ;;
      *)
        return 1
        ;;
    esac
  }
fi

if [ "$_fail_id" = "1" ]; then
  . "$_merv_root/settings/var_settings.sh"
  . "$_merv_root/settings/log_settings.sh"
  . "$_merv_root/settings/lib_identity.sh"
  LIB_IDENTITY_LOADED=1
  merv_identity_current_start() { return 1; }
fi

if [ "$_fail_scr" = "1" ]; then
  cp() {
    case "$*" in
      *portmap_br*.lst*) return 1 ;;
      *) /bin/cp "$@" ;;
    esac
  }
fi

if [ "$_fail_cand" = "1" ]; then
  cp() {
    case "$*" in
      *candidate.json*) return 1 ;;
      *) /bin/cp "$@" ;;
    esac
  }
fi

if [ "$_fail_esc" = "1" ]; then
  . "$_merv_root/settings/var_settings.sh"
  . "$_merv_root/settings/log_settings.sh"
  . "$_merv_root/settings/lib_json.sh"
  LIB_JSON_LOADED=1
  json_escape_string() { return 1; }
fi

if [ "$_fail_m_chmod" = "1" ]; then
  chmod() {
    case "$*" in
      *metadata.json*) return 1 ;;
      *) /bin/chmod "$@" ;;
    esac
  }
fi

if [ "$_fail_m_mv" = "1" ]; then
  mv() {
    case "$*" in
      *metadata.json*) return 1 ;;
      *) /bin/mv "$@" ;;
    esac
  }
fi

set -- "$_out_file" "$_n_name" "$_n_ip"
. "$_merv_root/functions/collect_local_clients.sh"
EOF
chmod 700 "$COLLECTOR_FIXTURE"

run_collector_sandboxed() {
  _out="$1"
  _node="$2"
  _ip="$3"
  _sys="$4"
  _force_reject="${5:-0}"
  _fail_identity="${6:-0}"
  _fail_scratch="${7:-0}"
  _fail_candidate="${8:-0}"
  _fail_escape="${9:-0}"
  _fail_meta_chmod="${10:-0}"
  _fail_meta_mv="${11:-0}"
  _fail_dir_create="${12:-0}"
  _fail_header_write="${13:-0}"

  if type unshare >/dev/null 2>&1; then
    unshare -m /bin/sh "$COLLECTOR_FIXTURE" "$_sys" "$_out" "$_node" "$_ip" "$BASE_DIR" "$MOCK_BRCTL_SCRIPT" "$_force_reject" "$_fail_identity" "$_fail_scratch" "$_fail_candidate" "$_fail_escape" "$_fail_meta_chmod" "$_fail_meta_mv" "$_fail_dir_create" "$_fail_header_write"
  else
    /bin/sh "$COLLECTOR_FIXTURE" "$_sys" "$_out" "$_node" "$_ip" "$BASE_DIR" "$MOCK_BRCTL_SCRIPT" "$_force_reject" "$_fail_identity" "$_fail_scratch" "$_fail_candidate" "$_fail_escape" "$_fail_meta_chmod" "$_fail_meta_mv" "$_fail_dir_create" "$_fail_header_write"
  fi
}

# ---------------------------------------------------------------------------
# Test Case 1: Baseline Real Production Output Validates with Real Validator
# ---------------------------------------------------------------------------
TARGET_JSON="$TEST_ROOT/clients_local.json"
PREV_JSON="$TEST_ROOT/clients_local.prev.json"
printf '{"generated":"previous","nodes":[]}\n' > "$PREV_JSON"
cp "$PREV_JSON" "$TARGET_JSON"

run_collector_sandboxed "$TARGET_JSON" "MockNode" "192.168.186.201" "$SYS_NET" 0 0 0 0 0 > "$TEST_ROOT/case1.log" 2>&1
RC_CASE1=$?

if [ "$RC_CASE1" -eq 0 ] && [ -s "$TARGET_JSON" ]; then
  if json_validate_file "$TARGET_JSON"; then
    pass "case1-real-producer-passes-real-validator"
  else
    fail "case1-real-producer-failed-real-validator"
  fi
else
  [ -f "$TEST_ROOT/case1.log" ] && cat "$TEST_ROOT/case1.log" >&2
  fail "case1-collector-execution-failed (rc=$RC_CASE1)"
fi

# ---------------------------------------------------------------------------
# Test Case 2: Candidate Forensic Preservation on Validator Rejection
# ---------------------------------------------------------------------------
FAULT_TARGET_JSON="$TEST_ROOT/fault_target.json"
cp "$PREV_JSON" "$FAULT_TARGET_JSON"
FAULT_DIR_ROOT="/tmp/mervlan_tmp/results/client_collection_faults"

# Clean any existing faults from previous test passes before case 2
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
FAULTS_BEFORE=0

run_collector_sandboxed "$FAULT_TARGET_JSON" "FaultNode" "192.168.186.201" "$SYS_NET" 1 0 0 0 0 > "$TEST_ROOT/case2.log" 2>&1
RC_CASE2=$?

# Collector must fail closed
if [ "$RC_CASE2" -ne 0 ]; then
  pass "case2-collector-returned-failure-on-rejection"
else
  fail "case2-collector-unexpectedly-succeeded-on-rejection"
fi

# Invariant: target artifact was NOT replaced
if cmp -s "$PREV_JSON" "$FAULT_TARGET_JSON" 2>/dev/null; then
  pass "case2-target-artifact-preserved-on-failure"
else
  fail "case2-target-artifact-overwritten-on-failure"
fi

# Invariant: candidate JSON preserved in fault directory
FAULTS_AFTER=$(find "$FAULT_DIR_ROOT" -type f -name "candidate.json" 2>/dev/null | wc -l)
if [ "$FAULTS_AFTER" -gt "$FAULTS_BEFORE" ]; then
  pass "case2-rejected-candidate-forensically-preserved"
else
  [ -f "$TEST_ROOT/case2.log" ] && cat "$TEST_ROOT/case2.log" >&2
  fail "case2-rejected-candidate-not-preserved"
fi

# Invariant (Correction 6): Portmap evidence survives until validation and is captured
PORTMAP_CAPTURED=$(find "$FAULT_DIR_ROOT" -type f -name "portmap_br*.lst" 2>/dev/null | wc -l)
if [ "$PORTMAP_CAPTURED" -gt 0 ]; then
  pass "case2-portmap-evidence-captured-in-fault-bundle"
else
  fail "case2-portmap-evidence-missing-from-fault-bundle"
fi

# Invariant (Hardening 1): Fault root & directory permissions mode 0700, files mode 0600
LATEST_FAULT=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)
if [ -n "$LATEST_FAULT" ]; then
  _root_mode=$(ls -ld "$FAULT_DIR_ROOT" 2>/dev/null | awk '{print $1}')
  case "$_root_mode" in
    drwx------*) pass "case2-fault-root-mode-0700" ;;
    *) fail "case2-fault-root-mode-insecure ($_root_mode)" ;;
  esac

  _dir_mode=$(ls -ld "$LATEST_FAULT" 2>/dev/null | awk '{print $1}')
  case "$_dir_mode" in
    drwx------*) pass "case2-fault-dir-mode-0700" ;;
    *) fail "case2-fault-dir-mode-insecure ($_dir_mode)" ;;
  esac

  _insecure_files=0
  for _test_f in "$LATEST_FAULT"/*; do
    [ -f "$_test_f" ] || continue
    _f_mode=$(ls -l "$_test_f" | awk '{print $1}')
    case "$_f_mode" in
      -rw-------*) ;;
      *) _insecure_files=$((_insecure_files + 1)) ;;
    esac
  done
  if [ "$_insecure_files" -eq 0 ]; then
    pass "case2-preserved-files-mode-0600"
  else
    fail "case2-preserved-files-insecure ($_insecure_files file(s))"
  fi
else
  fail "case2-fault-directory-missing"
fi

# Invariant (Hardening 2): Metadata JSON is valid and records truthful complete status
if [ -n "$LATEST_FAULT" ] && [ -f "$LATEST_FAULT/metadata.json" ]; then
  if json_validate_file "$LATEST_FAULT/metadata.json" 2>/dev/null; then
    pass "case2-metadata-json-valid"
  else
    fail "case2-metadata-json-syntax-invalid"
  fi
  if grep -Fq '"validator_result": "rejected"' "$LATEST_FAULT/metadata.json" && \
     grep -Fq '"candidate_preserved": true' "$LATEST_FAULT/metadata.json" && \
     grep -Fq '"scratch_preserved": true' "$LATEST_FAULT/metadata.json" && \
     grep -Fq '"metadata_complete": true' "$LATEST_FAULT/metadata.json" && \
     grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT/metadata.json"; then
    pass "case2-metadata-fields-accurate-and-complete"
  else
    fail "case2-metadata-fields-mismatched"
  fi
else
  fail "case2-metadata-file-missing"
fi

# ---------------------------------------------------------------------------
# Test Case 2b: Truthful Status on Scratch Evidence Copy Failure (Hardening 2)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
SCRATCH_FAIL_JSON="$TEST_ROOT/scratch_fail_target.json"
cp "$PREV_JSON" "$SCRATCH_FAIL_JSON"

run_collector_sandboxed "$SCRATCH_FAIL_JSON" "ScratchFailNode" "192.168.186.201" "$SYS_NET" 1 0 1 0 0 > "$TEST_ROOT/case2b.log" 2>&1
RC_CASE2B=$?
LATEST_FAULT_2B=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)

if [ "$RC_CASE2B" -ne 0 ] && [ -n "$LATEST_FAULT_2B" ] && [ -f "$LATEST_FAULT_2B/metadata.json" ]; then
  if grep -Fq '"scratch_preserved": false' "$LATEST_FAULT_2B/metadata.json" && \
     grep -Fq '"preservation_status": "partial"' "$LATEST_FAULT_2B/metadata.json" && \
     ! grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT_2B/metadata.json"; then
    pass "case2b-scratch-failure-truthfully-marked-partial"
  else
    fail "case2b-scratch-failure-not-marked-partial"
  fi
else
  fail "case2b-scratch-failure-test-failed (rc=$RC_CASE2B)"
fi

# ---------------------------------------------------------------------------
# Test Case 2c: Truthful Status on Candidate Copy Failure (Hardening 2)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
CAND_FAIL_JSON="$TEST_ROOT/cand_fail_target.json"
cp "$PREV_JSON" "$CAND_FAIL_JSON"

run_collector_sandboxed "$CAND_FAIL_JSON" "CandFailNode" "192.168.186.201" "$SYS_NET" 1 0 0 1 0 > "$TEST_ROOT/case2c.log" 2>&1
RC_CASE2C=$?
LATEST_FAULT_2C=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)

if [ "$RC_CASE2C" -ne 0 ] && [ -n "$LATEST_FAULT_2C" ] && [ -f "$LATEST_FAULT_2C/metadata.json" ]; then
  if grep -Fq '"candidate_preserved": false' "$LATEST_FAULT_2C/metadata.json" && \
     grep -Fq '"preservation_status": "partial"' "$LATEST_FAULT_2C/metadata.json" && \
     ! grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT_2C/metadata.json"; then
    pass "case2c-candidate-failure-truthfully-marked-partial"
  else
    fail "case2c-candidate-failure-not-marked-partial"
  fi
else
  fail "case2c-candidate-failure-test-failed (rc=$RC_CASE2C)"
fi

# ---------------------------------------------------------------------------
# Test Case 2d: Metadata Permission Failure Cannot Report Complete (Defect 1)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
META_CHMOD_FAIL_JSON="$TEST_ROOT/meta_chmod_fail_target.json"
cp "$PREV_JSON" "$META_CHMOD_FAIL_JSON"

run_collector_sandboxed "$META_CHMOD_FAIL_JSON" "MetaChmodFailNode" "192.168.186.201" "$SYS_NET" 1 0 0 0 0 1 0 > "$TEST_ROOT/case2d.log" 2>&1
RC_CASE2D=$?
LATEST_FAULT_2D=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)

if [ "$RC_CASE2D" -ne 0 ] && [ -n "$LATEST_FAULT_2D" ]; then
  if [ -f "$LATEST_FAULT_2D/metadata.json" ]; then
    if grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT_2D/metadata.json"; then
      fail "case2d-metadata-chmod-failure-falsely-reported-complete"
    else
      pass "case2d-metadata-chmod-failure-did-not-report-complete"
    fi
  else
    pass "case2d-metadata-chmod-failure-aborted-insecure-metadata"
  fi
else
  fail "case2d-metadata-chmod-failure-test-failed (rc=$RC_CASE2D)"
fi

# ---------------------------------------------------------------------------
# Test Case 2e: Metadata Publication Failure Cannot Report Complete (Defect 1)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
META_MV_FAIL_JSON="$TEST_ROOT/meta_mv_fail_target.json"
cp "$PREV_JSON" "$META_MV_FAIL_JSON"

run_collector_sandboxed "$META_MV_FAIL_JSON" "MetaMvFailNode" "192.168.186.201" "$SYS_NET" 1 0 0 0 0 0 1 > "$TEST_ROOT/case2e.log" 2>&1
RC_CASE2E=$?
LATEST_FAULT_2E=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)

if [ "$RC_CASE2E" -ne 0 ] && [ -n "$LATEST_FAULT_2E" ]; then
  if [ -f "$LATEST_FAULT_2E/metadata.json" ]; then
    if grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT_2E/metadata.json"; then
      fail "case2e-metadata-mv-failure-falsely-reported-complete"
    else
      pass "case2e-metadata-mv-failure-did-not-report-complete"
    fi
  else
    pass "case2e-metadata-mv-failure-aborted-unverified-metadata"
  fi
else
  fail "case2e-metadata-mv-failure-test-failed (rc=$RC_CASE2E)"
fi

# ---------------------------------------------------------------------------
# Test Case 3: Special Character Characterization & Fault Capture (Correction 4)
# ---------------------------------------------------------------------------
create_mock_bridge br999 'wl0.1"test' 'eth0.999\backslash'
SPECIAL_TARGET_JSON="$TEST_ROOT/special_target.json"
cp "$PREV_JSON" "$SPECIAL_TARGET_JSON"

# Clean faults before Case 3 to test isolated capture
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :

# Run collector with special-character bridge interface and special-character node name
run_collector_sandboxed "$SPECIAL_TARGET_JSON" 'Node"Quote\Test' "192.168.186.201" "$SYS_NET" 0 0 > "$TEST_ROOT/case3.log" 2>&1
RC_CASE3=$?

# 1. Collector exits nonzero because unescaped quote breaks real validator
if [ "$RC_CASE3" -ne 0 ]; then
  pass "case3-special-character-collector-exited-nonzero"
else
  fail "case3-special-character-collector-unexpectedly-succeeded"
fi

# 2. Target artifact remains untouched
if cmp -s "$PREV_JSON" "$SPECIAL_TARGET_JSON" 2>/dev/null; then
  pass "case3-special-character-target-untouched"
else
  fail "case3-special-character-target-modified"
fi

# 3. Round 1 forensic preservation captured the candidate
CASE3_FAULT=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)
if [ -n "$CASE3_FAULT" ] && [ -f "$CASE3_FAULT/candidate.json" ]; then
  # 4. Prove the intended special-character value reached the candidate
  if grep -Fq 'wl0.1"test' "$CASE3_FAULT/candidate.json"; then
    pass "case3-special-character-reached-candidate-json"
  else
    fail "case3-special-character-missing-from-candidate-json"
  fi

  # 5. Prove metadata with escaped node name is valid JSON (Correction 7)
  if json_validate_file "$CASE3_FAULT/metadata.json" 2>/dev/null; then
    pass "case3-special-character-metadata-escaped-valid-json"
  else
    fail "case3-special-character-metadata-invalid-json"
  fi
else
  fail "case3-special-character-candidate-not-preserved"
fi

# ---------------------------------------------------------------------------
# Test Case 3b: JSON Escaping Failure Handling & Safe Constant Fallback (Hardening 3)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
ESC_FAIL_JSON="$TEST_ROOT/esc_fail_target.json"
cp "$PREV_JSON" "$ESC_FAIL_JSON"

run_collector_sandboxed "$ESC_FAIL_JSON" 'Node"Unescaped\Test' "192.168.186.201" "$SYS_NET" 1 0 0 0 1 > "$TEST_ROOT/case3b.log" 2>&1
RC_CASE3B=$?
LATEST_FAULT_3B=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | head -n 1)

if [ "$RC_CASE3B" -ne 0 ] && [ -n "$LATEST_FAULT_3B" ] && [ -f "$LATEST_FAULT_3B/metadata.json" ]; then
  # 1. Metadata must remain valid JSON
  if json_validate_file "$LATEST_FAULT_3B/metadata.json" 2>/dev/null; then
    pass "case3b-escaping-failure-metadata-remains-valid-json"
  else
    fail "case3b-escaping-failure-metadata-invalid-json"
  fi

  # 2. Metadata complete must be false, status partial, dynamic fields safe constant
  if grep -Fq '"metadata_complete": false' "$LATEST_FAULT_3B/metadata.json" && \
     grep -Fq '"preservation_status": "partial"' "$LATEST_FAULT_3B/metadata.json" && \
     grep -Fq '"node_name": "unavailable"' "$LATEST_FAULT_3B/metadata.json"; then
    pass "case3b-escaping-failure-marked-partial-with-safe-constant"
  else
    fail "case3b-escaping-failure-missing-safe-constant-or-status"
  fi

  # 3. No lossy user/device string is fabricated
  if grep -Fq 'NodeUnescaped' "$LATEST_FAULT_3B/metadata.json" 2>/dev/null; then
    fail "case3b-lossy-fallback-string-fabricated"
  else
    pass "case3b-no-lossy-fallback-string-fabricated"
  fi

  # 4. Status is not falsely complete
  if grep -Fq '"preservation_status": "complete"' "$LATEST_FAULT_3B/metadata.json"; then
    fail "case3b-escaping-failure-falsely-marked-complete"
  else
    pass "case3b-escaping-failure-not-falsely-complete"
  fi
else
  fail "case3b-escaping-failure-test-execution-failed (rc=$RC_CASE3B)"
fi
# Clean up special-character bridge from Case 3/3b to restore clean baseline topology
rm -rf "$SYS_NET/br999" "$SYS_NET/wl0.1"* "$SYS_NET/eth0.999"* 2>/dev/null || :

# ---------------------------------------------------------------------------
# Test Case 4: Fault Identity Acquisition Failure (Correction 5)
# ---------------------------------------------------------------------------
# When canonical identity acquisition fails, helper must skip fault creation
# without manufacturing fake identity (start=1 / fake nonce), while collector
# continues fail-closed.
rm -rf "$FAULT_DIR_ROOT"/fault.* 2>/dev/null || :
IDENTITY_TARGET_JSON="$TEST_ROOT/identity_fail_target.json"
cp "$PREV_JSON" "$IDENTITY_TARGET_JSON"

run_collector_sandboxed "$IDENTITY_TARGET_JSON" "IdFailNode" "192.168.186.201" "$SYS_NET" 1 1 > "$TEST_ROOT/case4.log" 2>&1
RC_CASE4=$?

# 1. Collector must return failure
if [ "$RC_CASE4" -ne 0 ]; then
  pass "case4-identity-failure-collector-returned-failure"
else
  fail "case4-identity-failure-collector-succeeded"
fi

# 2. Target artifact must remain untouched
if cmp -s "$PREV_JSON" "$IDENTITY_TARGET_JSON" 2>/dev/null; then
  pass "case4-identity-failure-target-untouched"
else
  fail "case4-identity-failure-target-modified"
fi

# 3. No fault directory with fake identity created
FAULTS_CASE4=$(ls -dt "$FAULT_DIR_ROOT"/fault.* 2>/dev/null | wc -l)
if [ "$FAULTS_CASE4" -eq 0 ]; then
  pass "case4-identity-failure-no-manufactured-identity-created"
else
  fail "case4-identity-failure-manufactured-fault-directory-created"
fi

# ---------------------------------------------------------------------------
# Test Case 5: Bounded Retention Safety & Canonical Identity Validation (Defect 2)
# ---------------------------------------------------------------------------
rm -rf "$FAULT_DIR_ROOT" 2>/dev/null || :
mkdir -p "$FAULT_DIR_ROOT"

# 1. Create 7 simulated older fault directories with REAL canonical nonce structure:
# fault.<pid>.<start>.<now>.<pid>.<start>.<seq>
i=1
while [ $i -le 7 ]; do
  _d="$FAULT_DIR_ROOT/fault.100${i}.200${i}.1741266215.100${i}.200${i}.${i}"
  mkdir -p "$_d"
  printf '{"candidate":%d}\n' "$i" > "$_d/candidate.json"
  touch -t "2026010${i}1200" "$_d"
  i=$((i + 1))
done

# 2. Create adversarial malformed lookalikes that MUST NOT be deleted or counted:
MAL_SOME_NONCE="$FAULT_DIR_ROOT/fault.123.456.some.nonce"
MAL_PID_MISMATCH="$FAULT_DIR_ROOT/fault.123.456.1000.999.456.1"
MAL_START_MISMATCH="$FAULT_DIR_ROOT/fault.123.456.1000.123.999.1"
MAL_MISSING_COMP="$FAULT_DIR_ROOT/fault.123.456.1000.123.456"
MAL_EXTRA_COMP="$FAULT_DIR_ROOT/fault.123.456.1000.123.456.1.extra"
MALFORMED_1="$FAULT_DIR_ROOT/fault.1KEEP.2NOTNUM.3FOREIGN"
MALFORMED_2="$FAULT_DIR_ROOT/fault.x.123.some.nonce"
MALFORMED_3="$FAULT_DIR_ROOT/fault.123.x.some.nonce"
MALFORMED_4="$FAULT_DIR_ROOT/fault.123.456.bad!nonce"
MALFORMED_5="$FAULT_DIR_ROOT/fault.123.456"
SAFE_FOREIGN_DIR="$FAULT_DIR_ROOT/foreign_dir.keep"

mkdir -p "$MAL_SOME_NONCE" "$MAL_PID_MISMATCH" "$MAL_START_MISMATCH" "$MAL_MISSING_COMP" "$MAL_EXTRA_COMP" \
         "$MALFORMED_1" "$MALFORMED_2" "$MALFORMED_3" "$MALFORMED_4" "$MALFORMED_5" "$SAFE_FOREIGN_DIR"
touch "$SAFE_FOREIGN_DIR/keep.txt"
# Set old mtime on malformed lookalikes so they would be pruned if glob-matching:
touch -t "202501011200" "$MAL_SOME_NONCE" "$MAL_PID_MISMATCH" "$MAL_START_MISMATCH" "$MAL_MISSING_COMP" "$MAL_EXTRA_COMP" \
                        "$MALFORMED_1" "$MALFORMED_2" "$MALFORMED_3" "$MALFORMED_4" "$MALFORMED_5" "$SAFE_FOREIGN_DIR"

# 3. Create a symlink entry to test symlink protection:
SYMLINK_FAULT="$FAULT_DIR_ROOT/fault.9999.8888.symlink"
ln -s "$FAULT_DIR_ROOT/fault.1007.2007.1741266215.1007.2007.7" "$SYMLINK_FAULT" 2>/dev/null || :
_symlink_created=0
[ -L "$SYMLINK_FAULT" ] && _symlink_created=1

# Trigger a collection with rejection to invoke retention cleanup (creates 1 new valid fault bundle)
RETENTION_TARGET="$TEST_ROOT/retention_target.json"
cp "$PREV_JSON" "$RETENTION_TARGET"
run_collector_sandboxed "$RETENTION_TARGET" "RetentionNode" "192.168.186.201" "$SYS_NET" 1 0 > "$TEST_ROOT/case5.log" 2>&1

# Count valid bundles remaining using tightened canonical structural validation:
_valid_found=0
for _d in "$FAULT_DIR_ROOT"/fault.*; do
  [ -d "$_d" ] || continue
  [ ! -L "$_d" ] || continue
  _bn="${_d##*/}"
  _rst="${_bn#fault.}"
  _p="${_rst%%.*}"
  case "$_rst" in *.*) _rst="${_rst#*.}" ;; *) continue ;; esac
  _s="${_rst%%.*}"
  case "$_rst" in *.*) _n="${_rst#*.}" ;; *) continue ;; esac
  merv_identity_positive_uint "$_p" 2>/dev/null || continue
  merv_identity_positive_uint "$_s" 2>/dev/null || continue
  merv_identity_nonce_valid "$_n" 2>/dev/null || continue
  _nr="$_n"
  _ep="${_nr%%.*}"
  case "$_nr" in *.*) _nr="${_nr#*.}" ;; *) continue ;; esac
  _np="${_nr%%.*}"
  case "$_nr" in *.*) _nr="${_nr#*.}" ;; *) continue ;; esac
  _ns="${_nr%%.*}"
  case "$_nr" in *.*) _sq="${_nr#*.}" ;; *) continue ;; esac
  case "$_sq" in *.*) continue ;; esac
  case "$_ep" in ''|*[!0-9]*) continue ;; esac
  merv_identity_positive_uint "$_np" 2>/dev/null || continue
  merv_identity_positive_uint "$_ns" 2>/dev/null || continue
  merv_identity_positive_uint "$_sq" 2>/dev/null || continue
  [ "$_np" = "$_p" ] || continue
  [ "$_ns" = "$_s" ] || continue
  _valid_found=$((_valid_found + 1))
done

# Assert exactly 5 valid fault bundles remain (the 8th newly created + 4 newest older = 5):
if [ "$_valid_found" -eq 5 ]; then
  pass "case5-valid-bundles-bounded-to-5"
else
  fail "case5-valid-bundles-not-bounded-to-5 (found=$_valid_found)"
fi

# Assert the 3 oldest valid bundles were deleted:
if [ ! -d "$FAULT_DIR_ROOT/fault.1001.2001.1741266215.1001.2001.1" ] && \
   [ ! -d "$FAULT_DIR_ROOT/fault.1002.2002.1741266215.1002.2002.2" ] && \
   [ ! -d "$FAULT_DIR_ROOT/fault.1003.2003.1741266215.1003.2003.3" ]; then
  pass "case5-oldest-valid-bundles-pruned"
else
  fail "case5-oldest-valid-bundles-not-pruned"
fi

# Assert all adversarial lookalikes and unrelated directories survived:
if [ -d "$MAL_SOME_NONCE" ]; then
  pass "case5-grammar-valid-some-nonce-survived"
else
  fail "case5-grammar-valid-some-nonce-wrongly-deleted"
fi

if [ -d "$MAL_PID_MISMATCH" ]; then
  pass "case5-pid-mismatch-survived"
else
  fail "case5-pid-mismatch-wrongly-deleted"
fi

if [ -d "$MAL_START_MISMATCH" ]; then
  pass "case5-start-mismatch-survived"
else
  fail "case5-start-mismatch-wrongly-deleted"
fi

if [ -d "$MAL_MISSING_COMP" ]; then
  pass "case5-missing-component-survived"
else
  fail "case5-missing-component-wrongly-deleted"
fi

if [ -d "$MAL_EXTRA_COMP" ]; then
  pass "case5-extra-component-survived"
else
  fail "case5-extra-component-wrongly-deleted"
fi

if [ -d "$MALFORMED_1" ] && [ -d "$MALFORMED_2" ] && [ -d "$MALFORMED_3" ] && \
   [ -d "$MALFORMED_4" ] && [ -d "$MALFORMED_5" ]; then
  pass "case5-malformed-lookalikes-survived"
else
  fail "case5-malformed-lookalikes-wrongly-deleted"
fi

if [ -d "$SAFE_FOREIGN_DIR" ]; then
  pass "case5-unrelated-foreign-directory-survived"
else
  fail "case5-unrelated-foreign-directory-wrongly-deleted"
fi

if [ "$_symlink_created" = "1" ]; then
  if [ -L "$SYMLINK_FAULT" ]; then
    pass "case5-symlink-survived"
  else
    fail "case5-symlink-wrongly-deleted"
  fi
else
  pass "case5-symlink-unsupported-on-host"
fi

# Clean up simulated faults
rm -rf "$FAULT_DIR_ROOT" 2>/dev/null || :

# ---------------------------------------------------------------------------
# Test Case 6: Collection Starting with Absent Output/Collection Directory
# ---------------------------------------------------------------------------
CASE6_OUT_DIR="$TEST_ROOT/case6_absent_dir"
CASE6_TARGET_JSON="$CASE6_OUT_DIR/clients_local.json"
rm -rf "$CASE6_OUT_DIR" 2>/dev/null || :

# Confirm output directory does NOT exist prior to collection
if [ -d "$CASE6_OUT_DIR" ]; then
  fail "case6-setup-failed-dir-already-exists"
fi

run_collector_sandboxed "$CASE6_TARGET_JSON" "AbsentDirNode" "192.168.186.205" "$SYS_NET" 0 0 0 0 0 0 0 0 0 > "$TEST_ROOT/case6.log" 2>&1
RC_CASE6=$?

_case6_ok=1
if [ "$RC_CASE6" -ne 0 ] || [ ! -s "$CASE6_TARGET_JSON" ]; then
  _case6_ok=0
fi

# 1. Output directory must now exist
if [ ! -d "$CASE6_OUT_DIR" ]; then
  _case6_ok=0
fi

# 2. Resulting target must validate with real production validator
if ! json_validate_file "$CASE6_TARGET_JSON"; then
  _case6_ok=0
fi

# 3. Header fields must be present and well-formed
if ! grep -q '"generated":' "$CASE6_TARGET_JSON" || \
   ! grep -q '"router": "AbsentDirNode"' "$CASE6_TARGET_JSON" || \
   ! grep -q '"vlans": \[' "$CASE6_TARGET_JSON"; then
  _case6_ok=0
fi

# 4. Closing array and object must be present (no headerless or truncated JSON)
if ! tail -n 5 "$CASE6_TARGET_JSON" | grep -q '\]' || \
   ! tail -n 5 "$CASE6_TARGET_JSON" | grep -q '\}'; then
  _case6_ok=0
fi

if [ "$_case6_ok" -eq 1 ]; then
  pass "case6-collection-with-absent-directory-produces-valid-json"
else
  echo "CASE6_DEBUG: RC=$RC_CASE6 target_exists=$(test -f "$CASE6_TARGET_JSON" && echo yes || echo no) target_sz=$(wc -c < "$CASE6_TARGET_JSON" 2>/dev/null || echo 0) dir_exists=$(test -d "$CASE6_OUT_DIR" && echo yes || echo no)" >&2
  [ -f "$TEST_ROOT/case6.log" ] && cat "$TEST_ROOT/case6.log" >&2
  fail "case6-collection-with-absent-directory-failed (rc=$RC_CASE6)"
fi

# ---------------------------------------------------------------------------
# Test Case 7: Failure Injection on Directory Creation and Header Publication
# ---------------------------------------------------------------------------
# Subcase 7a: Output directory creation failure injection
# When directory creation fails, collector must exit nonzero and leave target untouched.
CASE7A_DIR="$TEST_ROOT/case7a_conflict"
rm -rf "$CASE7A_DIR" 2>/dev/null || :
touch "$CASE7A_DIR"
CASE7A_TARGET="$CASE7A_DIR/clients_local.json"

run_collector_sandboxed "$CASE7A_TARGET" "Case7aNode" "192.168.186.206" "$SYS_NET" 0 0 0 0 0 0 0 1 0 > "$TEST_ROOT/case7a.log" 2>&1
RC_CASE7A=$?

if [ "$RC_CASE7A" -ne 0 ] && [ ! -f "$CASE7A_TARGET" ]; then
  pass "case7a-directory-creation-failure-fails-closed"
else
  fail "case7a-directory-creation-failure-did-not-fail-closed"
fi

# Subcase 7b: Initial candidate header write failure injection
# When header creation fails, collector exits nonzero, old target remains untouched,
# and no fragmented candidate is treated as valid.
CASE7B_DIR="$TEST_ROOT/case7b_dir"
mkdir -p "$CASE7B_DIR"
CASE7B_TARGET="$CASE7B_DIR/clients_local.json"
printf '{"generated":"case7b-prev","vlans":[]}\n' > "$CASE7B_TARGET"
cp "$CASE7B_TARGET" "$TEST_ROOT/case7b_expected.json"

run_collector_sandboxed "$CASE7B_TARGET" "Case7bNode" "192.168.186.207" "$SYS_NET" 0 0 0 0 0 0 0 0 1 > "$TEST_ROOT/case7b.log" 2>&1
RC_CASE7B=$?

_case7b_ok=1
if [ "$RC_CASE7B" -eq 0 ]; then
  _case7b_ok=0
fi

# Old target must remain completely untouched
if ! cmp -s "$CASE7B_TARGET" "$TEST_ROOT/case7b_expected.json"; then
  _case7b_ok=0
fi

# No fragmented candidate left behind or treated as valid
for _f in "$CASE7B_DIR"/clients_local.json.new.*; do
  if [ -f "$_f" ]; then
    _case7b_ok=0
  fi
done

if [ "$_case7b_ok" -eq 1 ]; then
  pass "case7b-header-write-failure-leaves-target-untouched"
else
  [ -f "$TEST_ROOT/case7b.log" ] && cat "$TEST_ROOT/case7b.log" >&2
  fail "case7b-header-write-failure-did-not-fail-closed"
fi

if [ "$_FAILURES" -eq 0 ]; then
  printf 'CLIENT_PRODUCER_VALIDATION_CONTRACT_OK\n'
  exit 0
else
  printf 'CLIENT_PRODUCER_VALIDATION_CONTRACT_FAIL: observed defects (%s failure(s))\n' "$_FAILURES" >&2
  exit 1
fi
