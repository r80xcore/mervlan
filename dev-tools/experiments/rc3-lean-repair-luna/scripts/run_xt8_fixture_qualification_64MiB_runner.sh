#!/bin/ash
set -u

BUNDLE="/tmp/mervlan_xt8_fixture_bundle.REPLACE"
PRODUCTION="/jffs/addons/mervlan"

fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
case "$(busybox 2>&1 | head -n 1)" in *"BusyBox v1.25.1"*) : ;; *) fail 'not BusyBox 1.25.1' ;; esac
case "$(nvram get productid 2>/dev/null || :)" in RT-AX95Q|*XT8*) : ;; *) fail 'unexpected target product ID' ;; esac
busybox ash -c 'exit 0' || fail 'BusyBox ash unavailable'
[ -f "$BUNDLE/candidate.sh" ] && [ -f "$BUNDLE/snapshot.tar.gz" ] &&
  [ -d "$BUNDLE/addon-pristine" ] || fail 'fixture bundle incomplete'

# Verify exactly the two artifacts. Do not require BusyBox sha256sum -c.
[ "$(wc -l <"$BUNDLE/SHA256SUMS")" -eq 2 ] || fail 'unexpected digest inventory length'
_seen_candidate=0; _seen_snapshot=0
while IFS=' ' read -r _expected _name; do
  case "$_name" in
    candidate.sh) [ "$_seen_candidate" -eq 0 ] || fail 'duplicate candidate digest'; _seen_candidate=1 ;;
    snapshot.tar.gz) [ "$_seen_snapshot" -eq 0 ] || fail 'duplicate archive digest'; _seen_snapshot=1 ;;
    *) fail 'unexpected digest-list path' ;;
  esac
  if type sha256sum >/dev/null 2>&1; then
    _digest=$(sha256sum "$BUNDLE/$_name" | awk '{print $1}') || fail 'sha256sum failed'
  elif type openssl >/dev/null 2>&1; then
    _digest=$(openssl dgst -sha256 "$BUNDLE/$_name" | awk '{print $NF}') || fail 'openssl digest failed'
  else
    fail 'no SHA-256 verifier available'
  fi
  [ "$_digest" = "$_expected" ] || fail "bundle digest mismatch: $_name"
done <"$BUNDLE/SHA256SUMS"
[ "$_seen_candidate" -eq 1 ] && [ "$_seen_snapshot" -eq 1 ] || fail 'incomplete digest inventory'
[ "$(sha256sum "$BUNDLE/candidate.sh" 2>/dev/null | awk '{print $1}')" = "88e9854aeacd3d03dd83041addcffdcbb2d8e2207688e7a4b21fd14bd54d55dc" ] || {
  if type openssl >/dev/null 2>&1; then
    [ "$(openssl dgst -sha256 "$BUNDLE/candidate.sh" 2>/dev/null | awk '{print $NF}')" = "88e9854aeacd3d03dd83041addcffdcbb2d8e2207688e7a4b21fd14bd54d55dc" ] || fail 'unapproved candidate bytes'
  else
    fail 'unapproved candidate bytes'
  fi
}

_available=$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)
_tmpfree=$(df -Pk /tmp | awk 'NR == 2 {print $4}')
case "$_available:$_tmpfree" in *[!0-9:]*|:*|*:) fail 'RAM or /tmp capacity unavailable' ;; esac
[ "$_available" -ge 65536 ] || fail 'less than 64 MiB available RAM for retained two-case fixture'
[ "$_tmpfree" -ge 65536 ] || fail 'less than 64 MiB free in /tmp for retained two-case fixture'

_stamp=$(date +%s) || fail 'date unavailable'
case "$_stamp" in ''|*[!0-9]*) fail 'invalid timestamp' ;; esac
ROOT="/tmp/mervlan_lean_fixture.xt8.${_stamp}.$$"
case "$ROOT" in /tmp/mervlan_lean_fixture.*) : ;; *) fail 'unsafe fixture root' ;; esac
[ "$ROOT" != "$PRODUCTION" ] || fail 'fixture root equals installed production path'
[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail 'fixture root already exists; preserve it and choose a new run'
umask 077
mkdir "$ROOT" || fail 'could not create private fixture root'
printf 'root=%s\nproduct=%s\nbusybox=%s\nmemavailable_before_kib=%s\ntmpfree_before_kib=%s\n' \
  "$ROOT" "$(nvram get productid 2>/dev/null || :)" "$(busybox 2>&1 | head -n 1)" \
  "$_available" "$_tmpfree" >"$ROOT/preflight.log"
ps w >>"$ROOT/preflight.log"

workspace_metrics() {
  _wm_root=$1; _wm_count=0; _wm_size=0
  for _wm_path in "$_wm_root"/mervlan_lean.*; do
    [ -e "$_wm_path" ] || [ -L "$_wm_path" ] || continue
    _wm_count=$((_wm_count + 1))
    _wm_kb=$(du -sk "$_wm_path" 2>/dev/null | awk 'NR == 1 {print $1}')
    case "$_wm_kb" in ''|*[!0-9]*) fail 'could not measure workspace size' ;; esac
    _wm_size=$((_wm_size + _wm_kb))
  done
  printf '%s %s\n' "$_wm_count" "$_wm_size"
}

# POSIX recursive inventory: no `find` command or BusyBox find applet required.
walk_fixture_files() (
  for _w_path in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$_w_path" ] || [ -L "$_w_path" ] || continue
    [ ! -L "$_w_path" ] || return 1
    if [ -d "$_w_path" ]; then
      walk_fixture_files "$_w_path" || return 1
    elif [ -f "$_w_path" ]; then
      printf '%s\n' "$_w_path" || return 1
    else
      return 1
    fi
  done
)
sha256_file() {
  _sf_path=$1
  if type sha256sum >/dev/null 2>&1; then
    _sf_output=$(sha256sum "$_sf_path" 2>/dev/null) || return 1
    _sf_digest=$(printf '%s\n' "$_sf_output" | awk '{print $1}') || return 1
  elif type openssl >/dev/null 2>&1; then
    _sf_output=$(openssl dgst -sha256 "$_sf_path" 2>/dev/null) || return 1
    _sf_digest=$(printf '%s\n' "$_sf_output" | awk '{print $NF}') || return 1
  else
    return 1
  fi
  case "$_sf_digest" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#_sf_digest}" -eq 64 ] || return 1
  printf '%s\n' "$_sf_digest"
}
snapshot_tree() {
  _st_root=$1; _st_out=$2
  ( cd "$_st_root" && walk_fixture_files . ) >"$_st_out.unsorted" || return 1
  sort "$_st_out.unsorted" >"$_st_out.files" || return 1
  rm -f "$_st_out.unsorted" || return 1
  : >"$_st_out.checks" || return 1
  while IFS= read -r _st_rel; do
    _st_mode=$(ls -ld "$_st_root/$_st_rel" | awk '{print $1}') || return 1
    _st_sum=$(sha256_file "$_st_root/$_st_rel") || return 1
    printf '%s %s %s\n' "$_st_rel" "$_st_mode" "$_st_sum" >>"$_st_out.checks" || return 1
  done <"$_st_out.files"
}

run_case() {
  _name=$1; _fail_at=$2
  CASE="$ROOT/$_name"
  case "$CASE" in "$ROOT"/*) : ;; *) fail 'case escaped fixture root' ;; esac
  mkdir "$CASE" "$CASE/tmp" "$CASE/proc" "$CASE/locks" "$CASE/bin" "$CASE/evidence" || fail 'case directories'
  cp -R "$BUNDLE/addon-pristine" "$CASE/addon" || fail 'copy synthetic addon'
  cp "$BUNDLE/candidate.sh" "$CASE/candidate.sh" || fail 'copy candidate'
  cp /proc/meminfo "$CASE/meminfo.snapshot" || fail 'snapshot actual memory info'
  # 140 ordinary synthetic process entries exercise the actual sequential
  # /proc scanner under target BusyBox without consulting live process cmdlines.
  _synthetic_pid=1
  while [ "$_synthetic_pid" -le 140 ]; do
    mkdir "$CASE/proc/$_synthetic_pid" || fail 'synthetic process directory'
    printf '/bin/sh\000ordinary_fixture_process\000' >"$CASE/proc/$_synthetic_pid/cmdline" || fail 'synthetic cmdline'
    _synthetic_pid=$((_synthetic_pid + 1))
  done
  snapshot_tree "$CASE/addon" "$CASE/evidence/before" || fail 'baseline snapshot'

  # Fixed local-only replacement: it accepts only an output path inside this
  # case's candidate workspace and copies the prebuilt archive.
  cat >"$CASE/bin/fake-curl" <<'CURL'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 70
case "$out" in "${MERV_TEST_CASE}/tmp"/mervlan_lean.*/*) : ;; *) exit 71 ;; esac
cp "$MERV_TEST_SNAPSHOT" "$out"
CURL
  chmod 700 "$CASE/bin/fake-curl" || fail 'fake curl mode'

  MERV_BASE="$CASE/addon"
  MERV_REPAIR_TMP_ROOT="$CASE/tmp"
  MERV_REPAIR_PROC_ROOT="$CASE/proc"
  MERV_REPAIR_LOCK="$CASE/locks/mervlan_maintenance.lock"
  MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks"
  MERV_REPAIR_MEMINFO="$CASE/meminfo.snapshot"
  MERV_REPAIR_CURL="$CASE/bin/fake-curl"
  MERV_REPAIR_SNAPSHOT_BASE='https://codeload.github.com/r80xcore/mervlan/tar.gz'
  MERV_REPAIR_TEST_ONLY=1
  export MERV_BASE MERV_REPAIR_TMP_ROOT MERV_REPAIR_PROC_ROOT MERV_REPAIR_LOCK
  export MERV_REPAIR_LEGACY_LOCK_ROOT MERV_REPAIR_MEMINFO MERV_REPAIR_CURL
  export MERV_REPAIR_SNAPSHOT_BASE MERV_REPAIR_TEST_ONLY
  MERV_TEST_CASE="$CASE" MERV_TEST_SNAPSHOT="$BUNDLE/snapshot.tar.gz"
  export MERV_TEST_CASE MERV_TEST_SNAPSHOT
  case "$MERV_BASE" in "$CASE"/addon) : ;; *) fail 'MERV_BASE guard failed' ;; esac
  case "$MERV_BASE" in "$PRODUCTION"|"$PRODUCTION"/*|/jffs/*) fail 'production path rejected' ;; esac
  case "$MERV_REPAIR_LOCK" in "$CASE"/locks/*) : ;; *) fail 'lock escaped fixture' ;; esac
  case "$MERV_REPAIR_TMP_ROOT" in "$CASE"/tmp) : ;; *) fail 'workspace escaped fixture' ;; esac
  case "$MERV_REPAIR_PROC_ROOT" in "$CASE"/proc) : ;; *) fail 'proc scan escaped fixture' ;; esac
  [ "$MERV_REPAIR_TEST_ONLY" = 1 ] || fail 'test-only gate missing'

  if [ -n "$_fail_at" ]; then MERV_REPAIR_TEST_FAIL_AT=$_fail_at; export MERV_REPAIR_TEST_FAIL_AT
  else unset MERV_REPAIR_TEST_FAIL_AT; fi
  _before=$(workspace_metrics "$CASE/tmp")
  _start=$(date +%s)
  printf 'workspace_before=%s\n' "$_before" >"$CASE/evidence/metrics.log"
  busybox ash "$CASE/candidate.sh" main >"$CASE/evidence/stdout.log" 2>"$CASE/evidence/result.log" &
  _pid=$!
  _peak_count=0; _peak_kb=0
  : >"$CASE/evidence/process.samples"
  # Avoid an infinite sampler if the candidate exits abnormally or stalls.
  while kill -0 "$_pid" 2>/dev/null; do
    _watch_now=$(date +%s) || fail 'monitor clock unavailable'
    if [ "$((_watch_now - _start))" -ge 120 ]; then
      printf '%s\n' 'STOP: fixture candidate exceeded 120s; requesting TERM' >>"$CASE/evidence/metrics.log"
      kill -TERM "$_pid" 2>/dev/null || :
      sleep 3
      if kill -0 "$_pid" 2>/dev/null; then
        kill -KILL "$_pid" 2>/dev/null || :
      fi
      wait "$_pid" 2>/dev/null || :
      fail 'candidate timed out; preserve fixture evidence and stop'
    fi
    _sample_time=$(date +%s)
    _sample_mem=$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)
    _sample_tmp=$(df -Pk /tmp | awk 'NR == 2 {print $4}')
    _sample_ws=$(workspace_metrics "$CASE/tmp")
    _sample_count=${_sample_ws%% *}; _sample_kb=${_sample_ws#* }
    case "$_sample_mem$_sample_tmp$_sample_count$_sample_kb" in *[!0-9]*) fail 'invalid sampler output' ;; esac
    [ "$_sample_count" -le "$_peak_count" ] || _peak_count=$_sample_count
    [ "$_sample_kb" -le "$_peak_kb" ] || _peak_kb=$_sample_kb
    _process_count=$(ps w | awk 'NR > 1 {n++} END {print n+0}')
    printf '%s memavailable_kib=%s tmpfree_kib=%s workspace_count=%s workspace_kib=%s process_count=%s\n' \
      "$_sample_time" "$_sample_mem" "$_sample_tmp" "$_sample_count" "$_sample_kb" "$_process_count" \
      >>"$CASE/evidence/metrics.log"
    ps w >>"$CASE/evidence/process.samples"
    sleep 1
  done
  wait "$_pid"; _rc=$?
  _end=$(date +%s)
  _after=$(workspace_metrics "$CASE/tmp")
  _mem_after=$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)
  _tmp_after=$(df -Pk /tmp | awk 'NR == 2 {print $4}')
  case "$_start:$_end:$_mem_after:$_tmp_after" in *[!0-9:]*|:*|*:) fail 'invalid final metrics' ;; esac
  _elapsed=$((_end - _start))
  printf 'exit=%s elapsed_seconds=%s workspace_after=%s peak_workspace_count=%s peak_workspace_kib=%s memavailable_after_kib=%s tmpfree_after_kib=%s\n' \
    "$_rc" "$_elapsed" "$_after" "$_peak_count" "$_peak_kb" "$_mem_after" "$_tmp_after" \
    >>"$CASE/evidence/metrics.log"
  if grep -Fq 'ROLLBACK elapsed=' "$CASE/evidence/result.log"; then
    grep -F 'ROLLBACK elapsed=' "$CASE/evidence/result.log" >"$CASE/evidence/rollback.outcome"
  else
    printf '%s\n' 'rollback=not-triggered' >"$CASE/evidence/rollback.outcome"
  fi
  if [ -e "$MERV_REPAIR_LOCK" ] || [ -L "$MERV_REPAIR_LOCK" ]; then
    printf '%s\n' 'owner=RETAINED' >>"$CASE/evidence/metrics.log"
  else
    printf '%s\n' 'owner=RELEASED' >>"$CASE/evidence/metrics.log"
  fi
  snapshot_tree "$CASE/addon" "$CASE/evidence/after" || fail 'after snapshot'
  if [ "$_name" = rollback ]; then
    cmp "$CASE/evidence/before.files" "$CASE/evidence/after.files" >/dev/null || fail 'rollback changed fixture file list'
    cmp "$CASE/evidence/before.checks" "$CASE/evidence/after.checks" >/dev/null || fail 'rollback did not restore all fixture contents and modes'
    [ "$_rc" -ne 0 ] || fail 'injected publication failure unexpectedly succeeded'
    grep -Fq 'ROLLBACK elapsed=' "$CASE/evidence/result.log" || fail 'rollback log missing'
    grep -Fq 'verified complete' "$CASE/evidence/result.log" || fail 'rollback was not verified complete'
    [ "${_after%% *}" -eq 1 ] || fail 'rollback evidence workspace not retained'
    [ ! -e "$MERV_REPAIR_LOCK" ] || fail 'rollback left maintenance owner held'
    _ledger_found=0
    for _ledger in "$CASE/tmp"/mervlan_lean.*/ledger; do
      [ -s "$_ledger" ] || continue
      _ledger_found=1
    done
    [ "$_ledger_found" -eq 1 ] || fail 'rollback ledger evidence missing'
  else
    [ "$_rc" -eq 0 ] || fail 'success case returned failure'
    grep -Fq 'verified=58/58' "$CASE/evidence/result.log" || fail 'success case did not verify all 58 destinations'
    [ "${_after%% *}" -eq 0 ] || fail 'successful Repair left its workspace'
    [ ! -e "$MERV_REPAIR_LOCK" ] || fail 'successful Repair left maintenance owner held'
  fi
  printf 'CASE=%s\nEVIDENCE=%s/evidence\n' "$_name" "$CASE"
  cat "$CASE/evidence/metrics.log"
}

run_case success ''
run_case rollback 13

printf 'Fixture roots and evidence are retained under %s\n' "$ROOT"
printf 'The installed path %s was not targeted. Review evidence before any manual cleanup.\n' "$PRODUCTION"
