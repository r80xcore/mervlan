# XT8 private-fixture qualification (prepared, not executed)

Status: **NOT RUN**. This procedure has not contacted a router. It qualifies
only the experimental cleanup candidate in a synthetic tree below `/tmp` on
MAIN running BusyBox 1.25.1. It never publishes to or writes below
`/jffs/addons/mervlan`.

The candidate itself requires all of these conditions before it can proceed:

- `MERV_REPAIR_TEST_ONLY=1`;
- `MERV_BASE` is beneath `/tmp/mervlan_lean_fixture.*`;
- the lock, temp root, process-scan root, and memory-info path are fixture
  paths, with the process-scan and memory-info paths different from `/proc`;
- the supplied curl replacement reads a local synthetic archive and makes no
  network request.

The candidate file must be the cleanup candidate with SHA-256
`89793250cfde003221e9748a6087287bc2d357eac57f1db5baca42b387f9220e`. The
accepted functional production Repair and the installed `/jffs` tree are not
test inputs.

## 1. Prepare a private synthetic bundle on the host

Run this from the repository root on the host. It uses the existing fixture
builder to make an addon tree with synthetic settings/SSH marker contents and
a valid 58-file archive. It makes a new, non-overwriting bundle under `/tmp`.

```sh
OUT="/tmp/mervlan_xt8_fixture_bundle.$(date +%s).$$"
export OUT
python3 - <<'PY'
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tarfile

sys.dont_write_bytecode = True
repo = Path.cwd()
test_file = repo / "dev-tools/experiments/rc3-lean-repair-luna/tests/test_lean_repair.py"
spec = importlib.util.spec_from_file_location("lean_repair_fixture_builder", test_file)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
out = Path(os.environ["OUT"])
out.mkdir(mode=0o700)
fixture = module.Fixture(realistic=True)
try:
    shutil.copytree(fixture.base, out / "addon-pristine")
    shutil.copyfile(fixture.archive, out / "snapshot.tar.gz")
    shutil.copyfile(module.CANDIDATE, out / "candidate.sh")
    (out / "candidate.sh").chmod(0o700)
    with (out / "SHA256SUMS").open("w") as sums:
        for name in ("candidate.sh", "snapshot.tar.gz"):
            digest = hashlib.sha256((out / name).read_bytes()).hexdigest()
            sums.write(f"{digest}  {name}\n")
    bundle = Path(str(out) + ".tar.gz")
    with tarfile.open(bundle, "w:gz") as archive:
        for path in sorted(out.iterdir()):
            archive.add(path, arcname=path.name, recursive=True)
    print(f"BUNDLE_DIR={out}")
    print(f"BUNDLE_TAR={bundle}")
    print((out / "SHA256SUMS").read_text(), end="")
finally:
    fixture.close()
PY
```

Inspect the printed hashes on the host. Confirm `candidate.sh` has the
specified SHA-256 before transfer. Transfer only the generated bundle to MAIN
using the already-approved administrative access path. For example, set
   `MAIN_IP` to the management IP and use
   `scp -O "$BUNDLE_TAR" "admin@$MAIN_IP:/tmp/"`. Do not copy any repository
directory or credential profile. On MAIN, unpack it into a new private
directory under `/tmp/mervlan_xt8_fixture_bundle.*`; stop if that directory
already exists:

```sh
BUNDLE_DIR="/tmp/mervlan_xt8_fixture_bundle.REPLACE"
umask 077
mkdir "$BUNDLE_DIR" && tar -xzf /tmp/mervlan_xt8_fixture_bundle.REPLACE.tar.gz -C "$BUNDLE_DIR"
```

## 2. Preflight on MAIN and on a Wi-Fi client

Before uploading/running the fixture, record the following without changing
router configuration:

1. On MAIN, record `date`, `uname -a`, the `nvram get productid` result, and
   `busybox | head -n 1`. Stop unless the model is XT8 and BusyBox reports
   exactly 1.25.1. Confirm `busybox ash -c 'exit 0'` works.
2. Probe the required applets/commands without running the candidate:
   `awk`, `busybox`, `cat`, `chmod`, `cmp`, `cp`, `cksum`, `date`, `df`,
   `du`, `find`, `grep`, `gzip`, `head`, `kill`, `ls`, `mkdir`, `mv`, `ps`,
   `readlink`, `rm`, `rmdir`, `sed`, `sha256sum` or `openssl`, `sleep`,
   `sort`, `tar`, `tr`, and `wc`.
   Stop if any command required by the runner/candidate is missing.
3. Record actual `MemAvailable` from `/proc/meminfo`, free `/tmp` blocks from
   `df -Pk /tmp`, and `ps w`. Stop if actual `MemAvailable` is below 98,304
   KiB or free `/tmp` is below 65,536 KiB. The candidate has the same strict
   preflight thresholds; do not lower them.
4. From the existing Wi-Fi client, record its current SSID/association and
   ping MAIN's management address five times. From the controller, set
   `MAIN_IP` and record `ssh -o BatchMode=yes -o ConnectTimeout=5
   "admin@$MAIN_IP" 'printf SSH_OK'`. These are reachability observations
   only.
   Do not restart Wi-Fi, alter the SSID, or change firewall/radio state.

Unpack the bundle only into a new `/tmp` directory whose name begins
`/tmp/mervlan_xt8_fixture_bundle.`. Verify its candidate hash using
`sha256sum -c SHA256SUMS`, or use `openssl dgst -sha256 candidate.sh` if
`sha256sum` is unavailable. Stop on any mismatch.

## 3. Run the two isolated candidate cases

Use a new fixture root for each run. The runner below checks the candidate's
three publication-related paths before invoking it, points its process scan at
an empty private fixture directory, snapshots real `/proc/meminfo` into a
private path for the candidate's preflight, and replaces curl with a local
copy-only helper. The installed production path is used only as a forbidden
string comparison; no command is issued against it.

Save this as `/tmp/run_xt8_fixture_qualification.sh`, edit only `BUNDLE`,
inspect the file, then run it with `busybox ash`. Keep the output
under the generated fixture root for review. The script deliberately has no
automatic `rm` cleanup: the retained synthetic logs and rollback ledger are
evidence and must be reviewed before any later manual cleanup.

```sh
#!/bin/ash
set -u

BUNDLE="/tmp/mervlan_xt8_fixture_bundle.REPLACE"
PRODUCTION="/jffs/addons/mervlan"

fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
case "$(busybox 2>&1 | head -n 1)" in *"BusyBox v1.25.1"*) : ;; *) fail 'not BusyBox 1.25.1' ;; esac
case "$(nvram get productid 2>/dev/null || :)" in *XT8*) : ;; *) fail 'target product is not XT8' ;; esac
busybox ash -c 'exit 0' || fail 'BusyBox ash unavailable'
[ -f "$BUNDLE/candidate.sh" ] && [ -f "$BUNDLE/snapshot.tar.gz" ] &&
  [ -d "$BUNDLE/addon-pristine" ] || fail 'fixture bundle incomplete'

if type sha256sum >/dev/null 2>&1; then
  ( cd "$BUNDLE" && sha256sum -c SHA256SUMS ) || fail 'bundle digest mismatch'
elif type openssl >/dev/null 2>&1; then
  while IFS=' ' read -r _expected _name; do
    case "$_name" in candidate.sh|snapshot.tar.gz) : ;; *) fail 'unexpected digest-list path' ;; esac
    _digest=$(openssl dgst -sha256 "$BUNDLE/$_name" | awk '{print $NF}') || fail 'bundle digest failed'
    [ "$_digest" = "$_expected" ] || fail "bundle digest mismatch: $_name"
  done <"$BUNDLE/SHA256SUMS"
else
  fail 'no SHA-256 verifier available'
fi

_available=$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)
_tmpfree=$(df -Pk /tmp | awk 'NR == 2 {print $4}')
case "$_available:$_tmpfree" in *[!0-9:]*|:*|*:) fail 'RAM or /tmp capacity unavailable' ;; esac
[ "$_available" -ge 98304 ] || fail 'less than 96 MiB available RAM'
[ "$_tmpfree" -ge 65536 ] || fail 'less than 64 MiB free in /tmp'

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

snapshot_tree() {
  _st_root=$1; _st_out=$2
  ( cd "$_st_root" && find . -type f -print | sort ) >"$_st_out.files" || return 1
  : >"$_st_out.checks"
  while IFS= read -r _st_rel; do
    _st_mode=$(ls -ld "$_st_root/$_st_rel" | awk '{print $1}') || return 1
    _st_sum=$(cksum "$_st_root/$_st_rel" | awk '{print $1 ":" $2}') || return 1
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
  (
    /bin/sh "$CASE/candidate.sh" main
    _candidate_rc=$?
    printf '%s\n' "$_candidate_rc" >"$CASE/evidence/runner.exit"
    exit "$_candidate_rc"
  ) >"$CASE/evidence/stdout.log" 2>"$CASE/evidence/result.log" &
  _pid=$!
  _peak_count=0; _peak_kb=0
  : >"$CASE/evidence/process.samples"
  while [ ! -f "$CASE/evidence/runner.exit" ]; do
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
```

Run:

```sh
busybox ash /tmp/run_xt8_fixture_qualification.sh
```

The `success` case must report exit 0, 58/58 verification, no owned
`mervlan_lean.*` workspace afterward, and no maintenance lock. The injected
`rollback` case must report a nonzero action status, `ROLLBACK verified
complete`, byte/mode snapshot equality for all fixture files, one retained
ledger workspace, and no held owner lock. Preserve its ledger and logs.
Any other result is STOP; do not retry over retained evidence.

## 4. Collect reachability and closeout evidence

After the runner completes, record actual `/proc/meminfo`, `df -Pk /tmp`, and
`ps w` again on MAIN. On the controller, repeat the same batch-mode SSH probe.
On the same Wi-Fi client, repeat the five-ping test to MAIN and record packet
loss/latency and association. Save the before/after controller output and the
complete fixture `evidence/` directories under a separately reviewed evidence
location. The run logs include elapsed time, candidate result, rollback
outcome, ownership/workspace state, sampled `MemAvailable`, free `/tmp`, peak
workspace size, and process snapshots. They do not prove radio behavior beyond
the independent reachability observation.

Do not remove the retained rollback workspace as part of this procedure. If
later cleanup is explicitly authorized, verify that the evidence copy is
complete first and remove only the exact synthetic `ROOT` printed by the
runner. Never use a broad `/tmp/mervlan*` glob.
