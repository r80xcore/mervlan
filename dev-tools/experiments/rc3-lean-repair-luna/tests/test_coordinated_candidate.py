#!/usr/bin/env python3
"""Synthetic integration checks for the RC3 Update-owned candidate path."""
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import time
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
CANDIDATE = REPO / "dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_RC3_coordinated.sh"
SUITE = HERE / "test_lean_repair.py"
spec = importlib.util.spec_from_file_location("lean_suite", SUITE)
lean = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(lean)


def source_fixture_files(fixture: lean.Fixture) -> None:
    for _mode, relative in lean.FILES:
        source = REPO / relative
        target = fixture.base / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if _mode == "0755" else 0o644)
    settings = fixture.base / "settings/settings.json"
    settings.write_text('{"General":{"BOOT_ENABLED":"0"},"SSH":{},"Nodes":[],"SSH_USER":"root","SSH_PORT":"22"}\n')
    settings.chmod(0o600)
    fixture.originals = {relative: (fixture.base / relative).read_bytes()
                         for _mode, relative in lean.FILES}
    fixture.original_modes = {relative: (fixture.base / relative).stat().st_mode & 0o777
                              for _mode, relative in lean.FILES}


def make_recovery_archive(fixture: lean.Fixture) -> tuple[Path, str, Path]:
    root = fixture.root
    backup = root / "mervlan_backups"
    backup.mkdir(mode=0o700)
    backup_id = "mervlan.backup.20261116-120000.tar.gz"
    archive = backup / backup_id
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(fixture.base, arcname="addon", recursive=True)
    checksum = hashlib.md5(archive.read_bytes()).hexdigest()
    (backup / (backup_id + ".meta")).write_text(
        f"format=1\narchive={backup_id}\nalgorithm=md5\nchecksum={checksum}\ncreated=fixture\n"
    )
    shutil.copyfile(REPO / "functions/mervlan_recover.sh", backup / "recover.sh")
    shutil.copyfile(REPO / "settings/lib_maintenance_recovery.sh", backup / "recovery_state.sh")
    shutil.copyfile(REPO / "settings/lib_update_state.sh", backup / "update_state.sh")
    (backup / "recover.sh").chmod(0o700)
    (backup / "recovery_state.sh").chmod(0o600)
    (backup / "update_state.sh").chmod(0o600)
    return backup, backup_id, archive


def run_case(shell: str, fail_at: str, expected_result: str) -> None:
    fixture = lean.Fixture(process_count=0)
    trial = None
    try:
        source_fixture_files(fixture)
        backup_root, backup_id, archive = make_recovery_archive(fixture)
        state = fixture.root / "state"
        update_tmp = fixture.root / "update_tmp/updates.fixture"
        update_tmp.mkdir(parents=True, mode=0o700)
        candidate_tmp = fixture.root / "repair_tmp"
        candidate_tmp.mkdir(mode=0o700)
        trial = Path(tempfile.mkdtemp(prefix="mervlan_rc3_trial.", dir="/tmp"))
        trial.chmod(0o700)
        candidate_copy = trial / CANDIDATE.name
        shutil.copyfile(CANDIDATE, candidate_copy)
        candidate_copy.chmod(0o700)
        result_file = update_tmp / "rc3-repair.result"
        lock = fixture.locks / "mervlan_maintenance.lock"
        ref = "refs/heads/pre_v0.53.29-RC3-repair-test"

        runner = fixture.root / "owner_and_candidate.sh"
        runner.write_text(r'''#!/bin/sh
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 80
. "$MERV_BASE/settings/lib_update_state.sh" || exit 81
if ! merv_owner_lock_acquire "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" 1800 2 mervlan_maintenance; then exit 82; fi
MERV_UPDATE_OWNER=1
MERV_UPDATE_OWNER_PID="$$"
MERV_UPDATE_OWNER_START="$MERV_LOCK_START"
MERV_UPDATE_OWNER_NONCE="$MERV_LOCK_NONCE"
MERV_MAINTENANCE_DELEGATION_KIND=update
export MERV_UPDATE_OWNER MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE MERV_MAINTENANCE_DELEGATION_KIND
TEST_RUN_ID=repair-test-$$
merv_update_quiesce_begin "$TEST_RUN_ID" || exit 83
merv_update_journal_write "$TEST_RUN_ID" durable-backup refs/heads/rc3-test 0 1 1 0 0 rc3_fixture "$MERV_REPAIR_UPDATE_TMP_BASE" "$MERV_REPAIR_UPDATE_BACKUP_ROOT/$MERV_REPAIR_UPDATE_BACKUP_ID" none none none none unknown unknown || exit 84
if MERV_REPAIR_UPDATE_CHILD=1 MERV_REPAIR_UPDATE_TEST_MODE=1 MERV_REPAIR_TEST_ONLY=1 \
  MERV_REPAIR_UPDATE_RUN_ID="$TEST_RUN_ID" MERV_REPAIR_UPDATE_BACKUP_ID="$MERV_REPAIR_UPDATE_BACKUP_ID" \
  MERV_REPAIR_UPDATE_BACKUP_ROOT="$MERV_REPAIR_UPDATE_BACKUP_ROOT" \
  MERV_REPAIR_UPDATE_TMP_BASE="$MERV_REPAIR_UPDATE_TMP_BASE" MERV_REPAIR_RESULT_FILE="$MERV_REPAIR_RESULT_FILE" \
  MERV_REPAIR_TMP_ROOT="$MERV_REPAIR_TMP_ROOT" MERV_REPAIR_PROC_ROOT="$MERV_REPAIR_PROC_ROOT" \
  MERV_REPAIR_MEMINFO="$MERV_REPAIR_MEMINFO" MERV_REPAIR_LOCK="$MERV_REPAIR_LOCK" \
  MERV_REPAIR_LEGACY_LOCK_ROOT="$MERV_REPAIR_LEGACY_LOCK_ROOT" \
  MERV_REPAIR_TEST_FAIL_AT="$TEST_FAIL_AT" MERV_REPAIR_TEST_PAUSE_AT= \
  MERV_REPAIR_CURL="$MERV_REPAIR_CURL" "$TEST_ENGINE" "$TEST_REF"; then
  child_rc=0
else
  child_rc=$?
fi
test "$child_rc" -eq "$TEST_EXPECTED_RC" || exit 85
merv_update_owner_context_valid && merv_update_quiesce_active && merv_update_journal_active || exit 86
test "$(merv_update_journal_get phase '')" = activation-started || exit 87
test -f "$MERV_REPAIR_RESULT_FILE" && test ! -L "$MERV_REPAIR_RESULT_FILE" || exit 88
printf 'CHILD_RESULT=%s CHILD_RC=%s OWNER_RETAINED=1 QUIESCE_RETAINED=1\n' "$TEST_EXPECTED_RESULT" "$child_rc"
merv_update_quiesce_clear || exit 89
merv_update_journal_clear || exit 90
merv_owner_lock_release "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" "$MERV_LOCK_NONCE" || exit 91
test ! -e "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" || exit 92
printf 'PARENT_FINALIZED=1 OWNER_RELEASED=1\n'
''')
        runner.chmod(0o700)

        env = fixture.env.copy()
        env.update({
            "MERV_BASE": str(fixture.base),
            "MERV_STATE_ROOT": str(state),
            "MERV_UPDATE_JOURNAL": str(state / "update.journal"),
            "MERV_UPDATE_QUIESCE_FILE": str(state / "update.quiesce"),
            "MERVLAN_MAINTENANCE_LOCK_OVERRIDE": str(lock),
            "MERVLAN_BACKUP_ROOT": str(backup_root),
            "MERVLAN_RECOVERY_BACKUP_ROOT": str(backup_root),
            "MERVLAN_RECOVERY_ACTIVE_ROOT": str(fixture.base),
            "MERVLAN_RECOVERY_TMP_ROOT": str(update_tmp),
            "MERVLAN_RECOVERY_STATE_ROOT": str(state),
            "MERV_REPAIR_UPDATE_BACKUP_ROOT": str(backup_root),
            "MERV_REPAIR_UPDATE_BACKUP_ID": backup_id,
            "MERV_REPAIR_UPDATE_TMP_BASE": str(update_tmp),
            "MERV_REPAIR_RESULT_FILE": str(result_file),
            "MERV_REPAIR_TMP_ROOT": str(candidate_tmp),
            "MERV_REPAIR_PROC_ROOT": str(fixture.proc),
            "MERV_REPAIR_MEMINFO": str(fixture.meminfo),
            "MERV_REPAIR_LOCK": str(lock),
            "MERV_REPAIR_LEGACY_LOCK_ROOT": str(fixture.locks),
            "MERV_REPAIR_CURL": str(fixture.fakebin / "curl"),
            "TEST_ARCHIVE": str(fixture.archive),
            "TEST_ENGINE": str(candidate_copy),
            "TEST_REF": ref,
            "TEST_FAIL_AT": fail_at,
            "TEST_EXPECTED_RC": "0" if expected_result == "published-verified" else "1",
            "TEST_EXPECTED_RESULT": expected_result,
        })
        if shell == "busybox":
            argv = ["busybox", "ash", str(runner)]
        else:
            argv = ["dash", str(runner)]
        try:
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=90)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"candidate timeout stdout={exc.stdout!r} stderr={exc.stderr!r}")
        if result.returncode != 0:
            raise AssertionError(f"{shell} {expected_result} rc={result.returncode}\n{result.stdout}\n{result.stderr[-4500:]}")
        if "OWNER_RETAINED=1 QUIESCE_RETAINED=1" not in result.stdout or "PARENT_FINALIZED=1 OWNER_RELEASED=1" not in result.stdout:
            raise AssertionError(f"coordinator lifecycle markers missing\n{result.stdout}\n{result.stderr[-1800:]}")
        rows = result_file.read_text().splitlines()
        assert rows[0] == "format=1"
        assert rows[1] == f"result={expected_result}"
        assert "verified=58" in rows and "eligible=57" in rows
        assert "rescue=unchanged" in rows
        rescue = "functions/update_mervlan_repair.sh"
        if expected_result == "published-verified":
            assert rows[4] == "published=57"
            with tarfile.open(fixture.archive, "r:gz") as source_archive:
                expected_files = {
                    relative: source_archive.extractfile(f"mervlan-main/{relative}").read()
                    for _mode, relative in lean.FILES
                    if relative != "functions/update_mervlan_repair.manifest"
                }
                expected_files["functions/update_mervlan_repair.manifest"] = (
                    source_archive.extractfile("mervlan-main/functions/update_mervlan_repair.manifest").read()
                )
            for _mode, relative in lean.FILES:
                target = fixture.base / relative
                if relative == rescue:
                    assert target.read_bytes() == fixture.originals[relative], "production Repair changed"
                else:
                    assert target.read_bytes() == expected_files[relative], f"published content mismatch: {relative}"
            assert not list(candidate_tmp.glob("mervlan_lean.*")), "successful candidate workspace was not removed"
        else:
            assert rows[4] == "published=12"
            assert fixture.all_old(), "rollback did not restore all 58 originals"
            retained = list(candidate_tmp.glob("mervlan_lean.*"))
            assert len(retained) == 1 and (retained[0] / "ledger").stat().st_size > 0
    finally:
        if trial and trial.exists():
            shutil.rmtree(trial)
        fixture.close()


def run_update_parent_case(shell: str, fail_at: str, expected_result: str, pause_at: str = "") -> None:
    fixture = lean.Fixture(process_count=0)
    trial = None
    recovery_lock_scope = None
    recovery_root_created = False
    try:
        source_fixture_files(fixture)
        update_tmp = fixture.root / "update_tmp"
        update_tmp.mkdir(mode=0o700)
        (update_tmp / "locks").mkdir(mode=0o700)
        (fixture.root / "mervlan_backups").mkdir(mode=0o700)
        var_settings = fixture.base / "settings/var_settings.sh"
        var_text = var_settings.read_text()
        assert 'readonly TMPDIR="/tmp/mervlan_tmp"' in var_text
        var_settings.write_text(var_text.replace(
            'readonly TMPDIR="/tmp/mervlan_tmp"',
            'readonly TMPDIR="${MERVLAN_TMP_ROOT_OVERRIDE:-/tmp/mervlan_tmp}"', 1))
        fixture.originals["settings/var_settings.sh"] = var_settings.read_bytes()
        state = fixture.root / "state"
        lock_root = fixture.root / "locks"
        lock = lock_root / "mervlan_maintenance.lock"
        repair_tmp = fixture.root / "repair_tmp"
        repair_tmp.mkdir(mode=0o700)
        trial = Path(tempfile.mkdtemp(prefix="mervlan_rc3_trial.", dir="/tmp"))
        trial.chmod(0o700)
        candidate_copy = trial / CANDIDATE.name
        shutil.copyfile(CANDIDATE, candidate_copy)
        candidate_copy.chmod(0o700)
        ebtables = fixture.fakebin / "ebtables"
        ebtables.write_text('''#!/bin/sh
case " $* " in
  *" -L FORWARD "*|*" -L INPUT "*) exit 0 ;;
  *) exit 1 ;;
esac
''')
        ebtables.chmod(0o700)
        settings = fixture.base / "settings/settings.json"
        settings.write_text('{"General":{"BOOT_ENABLED":"0"},"SSH":{},"Nodes":[],"SSH_USER":"root","SSH_PORT":"22"}\n')

        env = os.environ.copy()
        env.update({
            "MERV_BASE": str(fixture.base),
            "MERV_STATE_ROOT": str(state),
            "MERVLAN_MAINTENANCE_LOCK_OVERRIDE": str(lock),
            "MERVLAN_TMP_ROOT_OVERRIDE": str(update_tmp),
            "MERVLAN_BACKUP_DIR_OVERRIDE": str(fixture.root / "mervlan_backups"),
            "MERVLAN_PUBLIC_ROOT_OVERRIDE": str(fixture.root / "www/user/mervlan"),
            "MERVLAN_PUBLIC_RESULTS_OVERRIDE": str(fixture.root / "www/user/mervlan/tmp/results"),
            "MERVLAN_WWW_USER_ROOT_OVERRIDE": str(fixture.root / "www/user"),
            "MERVLAN_UNDO_DIR_OVERRIDE": str(fixture.root / "undo"),
            "MERV_SSH_TRUST_ROOT": str(state / "ssh_trust"),
            "MERV_SSH_TRUST_FILE": str(state / "ssh_trust/known_hosts.v1"),
            "LOGROOT": str(fixture.root / "logs"),
            "LOG_SYSLOG": "0",
            "MERV_TEST_MODE": "1",
            "MERV_UPDATE_RC3_TEST_ONLY": "1",
            "MERV_UPDATE_RC3_TEST_FAIL_AT": fail_at,
            "MERV_UPDATE_RC3_TEST_PAUSE_AT": pause_at,
            "MERV_UPDATE_RC3_TEST_ARCHIVE": str(fixture.archive),
            "MERV_UPDATE_RC3_TEST_CURL": str(fixture.fakebin / "curl"),
            "MERV_UPDATE_RC3_TEST_PROC_ROOT": str(fixture.proc),
            "MERV_UPDATE_RC3_TEST_MEMINFO": str(fixture.meminfo),
            "MERV_UPDATE_RC3_TEST_REPAIR_TMP_ROOT": str(repair_tmp),
            "MERV_REPAIR_TEST_ONLY": "0",
            "MERVLAN_PUBLIC_ROOT_OVERRIDE": str(fixture.root / "www/user/mervlan"),
            "MERVLAN_PUBLIC_RESULTS_OVERRIDE": str(fixture.root / "www/user/mervlan/tmp/results"),
            "MERVLAN_WWW_USER_ROOT_OVERRIDE": str(fixture.root / "www/user"),
            "PATH": f"{fixture.fakebin}:" + os.environ.get("PATH", "/usr/bin:/bin"),
        })
        argv = ["dash", str(fixture.base / "functions/update_mervlan.sh"),
                "rc3-repair-candidate", str(candidate_copy),
                "refs/heads/pre_v0.53.29-RC3-repair-test"]
        if shell == "busybox":
            argv[0:1] = ["busybox", "ash"]
        if pause_at:
            process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 45
            reached_pause = False
            while time.monotonic() < deadline:
                for workspace in repair_tmp.glob("mervlan_lean.*"):
                    ledger = workspace / "ledger"
                    if ledger.is_file() and len(ledger.read_text(errors="replace").splitlines()) >= int(pause_at):
                        reached_pause = True
                        break
                if reached_pause:
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.02)
            if not reached_pause:
                process.kill()
                stdout, stderr = process.communicate(timeout=30)
                log_dir = fixture.root / "logs"
                log_text = "\n".join(p.read_text(errors="replace") for p in log_dir.glob("*.log")) if log_dir.exists() else ""
                raise AssertionError(
                    f"Update parent {shell} did not reach interruption point\n"
                    f"{stdout}\n{stderr[-5000:]}\n{log_text[-5000:]}"
                )
            process.kill()
            process.wait(timeout=10)
            stdout, stderr = process.communicate(timeout=45)
            assert process.returncode == -9, f"Update parent was not SIGKILLed: rc={process.returncode}\n{stderr[-3000:]}"
            assert (state / "update.quiesce").is_file(), "SIGKILL path cleared quiesce unexpectedly"
            journal = state / "update.journal"
            assert journal.is_file() and "phase=activation-started" in journal.read_text(), "activation recovery journal missing"
            assert lock.is_dir() and (lock / "owner").is_file(), "SIGKILL path released Update ownership"
            archives = list((fixture.root / "mervlan_backups").glob("mervlan.backup.*.tar.gz"))
            assert len(archives) == 1, "durable Update backup missing after SIGKILL"
            workspaces = list(update_tmp.glob("updates.*"))
            assert len(workspaces) == 1, "Update workspace evidence was not retained after SIGKILL"
            results = list(workspaces[0].glob("rc3-repair.result"))
            assert len(results) == 1 and "result=recovery-required" in results[0].read_text(), "child did not report uncertain recovery"
            assert "rescue=unverified" in results[0].read_text(), "child overclaimed rescue verification"
            changed = [relative for _mode, relative in lean.FILES
                       if (fixture.base / relative).read_bytes() != fixture.originals[relative]]
            assert len(changed) == 12, f"unexpected partial publication count: {len(changed)} ({changed})"
            assert (fixture.base / "functions/update_mervlan_repair.sh").read_bytes() == fixture.originals[
                "functions/update_mervlan_repair.sh"], "production Repair entrypoint changed before its protected position"
            candidate_workspaces = list(repair_tmp.glob("mervlan_lean.*"))
            assert len(candidate_workspaces) == 1 and (candidate_workspaces[0] / "ledger").is_file(), "Repair rollback evidence missing"
            # The standalone helper permits only its canonical lock or a
            # private /tmp/mervlan_tmp/selftest.* path. Relocate only this
            # synthetic, dead-owner lock while preserving its exact record.
            recovery_root = Path("/tmp/mervlan_tmp")
            if recovery_root.is_symlink():
                raise AssertionError("synthetic recovery lock root must not be a symlink")
            recovery_root_created = not recovery_root.exists()
            recovery_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            recovery_lock_scope = recovery_root / ("selftest." + fixture.root.name)
            if recovery_lock_scope.exists() or recovery_lock_scope.is_symlink():
                raise AssertionError(f"synthetic recovery lock path already exists: {recovery_lock_scope}")
            recovery_lock_scope.mkdir(mode=0o700)
            recovery_lock = recovery_lock_scope / "mervlan_maintenance.lock"
            owner_before_restore = (lock / "owner").read_bytes()
            lock.rename(recovery_lock)
            assert not lock.exists() and (recovery_lock / "owner").read_bytes() == owner_before_restore, (
                "synthetic lock relocation did not preserve the Update owner record"
            )
            check_env = env.copy()
            check_env.update({
                "MERVLAN_RECOVERY_BACKUP_ROOT": str(fixture.root / "mervlan_backups"),
                "MERVLAN_RECOVERY_ACTIVE_ROOT": str(fixture.base),
                "MERVLAN_RECOVERY_TMP_ROOT": str(update_tmp),
                "MERVLAN_RECOVERY_STATE_ROOT": str(state),
                "MERVLAN_RECOVERY_LOCK_OVERRIDE": str(recovery_lock),
                "MERVLAN_RECOVERY_TEST_MODE": "1",
            })
            recovery_helper = str(fixture.root / "mervlan_backups/recover.sh")
            check = subprocess.run(["sh", recovery_helper, "check", archives[0].name],
                                   env=check_env, capture_output=True, text=True, timeout=30)
            assert check.returncode == 0, f"durable recovery check failed after SIGKILL\n{check.stdout}\n{check.stderr}"
            restore = subprocess.run(["sh", recovery_helper, "restore", archives[0].name, "yes"],
                                     env=check_env, capture_output=True, text=True, timeout=90)
            assert restore.returncode == 0, (
                f"standalone recover.sh restore failed after SIGKILL\n{restore.stdout}\n{restore.stderr}"
            )
            assert "Main-router recovery completed successfully." in restore.stdout, (
                f"restore success marker missing\n{restore.stdout}\n{restore.stderr}"
            )
            mismatches = []
            for _mode, relative in lean.FILES:
                target = fixture.base / relative
                if (not target.is_file() or target.is_symlink() or
                        target.read_bytes() != fixture.originals[relative] or
                        (target.stat().st_mode & 0o777) != fixture.original_modes[relative]):
                    mismatches.append(relative)
            assert not mismatches, f"standalone restore did not reinstate exact 58-file contents/modes: {mismatches}"
            assert not (state / "update.quiesce").exists(), "restore left Update quiesce active"
            assert not (state / "update.journal").exists(), "restore left Update journal active"
            assert not (fixture.root / "mervlan_backups/.mervlan.recovery").exists(), "restore left durable recovery marker"
            assert not recovery_lock.exists(), "restore did not release maintenance ownership"
            quarantines = list(recovery_lock.parent.glob("mervlan_maintenance.lock.quarantine.*"))
            assert len(quarantines) == 1 and (quarantines[0] / "owner").read_bytes() == owner_before_restore, (
                "dead Update ownership was not retained as exact quarantine evidence"
            )
            assert not list(update_tmp.glob("restore.*")), "standalone restore workspace was not cleaned"
            assert list(update_tmp.glob("updates.*")), "Update interruption workspace evidence was not retained"
            assert list(repair_tmp.glob("mervlan_lean.*")), "Repair interruption ledger evidence was not retained"
            post_restore_check = subprocess.run(
                ["sh", recovery_helper, "check", archives[0].name],
                env=check_env, capture_output=True, text=True, timeout=30)
            assert post_restore_check.returncode == 0, (
                f"persistent backup failed validation after restore\n"
                f"{post_restore_check.stdout}\n{post_restore_check.stderr}"
            )
            assert not list(update_tmp.glob("restore.*")), "recovery check workspace was not cleaned"
            print(f"PASS Update coordinator {shell} SIGKILL standalone restore reinstates exact 58-file contents/modes and clears active recovery state", flush=True)
            return
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
        expected_rc = 0 if expected_result == "published-verified" else 1
        if result.returncode != expected_rc:
            log_dir = fixture.root / "logs"
            log_text = "\n".join(p.read_text(errors="replace") for p in log_dir.glob("*.log")) if log_dir.exists() else ""
            raise AssertionError(f"Update parent {shell} {expected_result} rc={result.returncode}\n{result.stdout}\n{result.stderr[-5000:]}\n{log_text[-5000:]}")
        assert not (state / "update.quiesce").exists(), "Update parent did not clear quiesce"
        assert not (state / "update.journal").exists(), "Update parent did not clear lifecycle journal"
        assert not lock.exists(), "Update parent did not release maintenance owner"
        assert list((fixture.root / "mervlan_backups").glob("mervlan.backup.*.tar.gz")), "durable backup missing"
        rescue = "functions/update_mervlan_repair.sh"
        if expected_result == "published-verified":
            log_dir = fixture.root / "logs"
            log_text = "\n".join(p.read_text(errors="replace") for p in log_dir.glob("*.log")) if log_dir.exists() else ""
            assert "RC3 Repair published 57 files" in log_text
            with tarfile.open(fixture.archive, "r:gz") as source_archive:
                expected_files = {
                    relative: source_archive.extractfile(f"mervlan-main/{relative}").read()
                    for _mode, relative in lean.FILES
                }
            for _mode, relative in lean.FILES:
                target = fixture.base / relative
                if relative == rescue:
                    assert target.read_bytes() == fixture.originals[relative], "production Repair changed"
                else:
                    assert target.read_bytes() == expected_files[relative], f"published content mismatch: {relative}"
            assert not list(repair_tmp.glob("mervlan_lean.*")), "successful child workspace remains"
        else:
            log_dir = fixture.root / "logs"
            log_text = "\n".join(p.read_text(errors="replace") for p in log_dir.glob("*.log")) if log_dir.exists() else ""
            assert "complete 58-entry rollback verified" in log_text
            mismatches = [relative for _mode, relative in lean.FILES
                          if (fixture.base / relative).read_bytes() != fixture.originals[relative]]
            assert not mismatches, f"Update-owned rollback did not restore originals: {mismatches}"
            retained = list(repair_tmp.glob("mervlan_lean.*"))
            assert len(retained) == 1 and (retained[0] / "ledger").stat().st_size > 0
        assert not list(update_tmp.glob("updates.*")), "Update parent workspace was not cleaned"
        print(f"PASS Update coordinator {shell} {expected_result} owns quiescence, backup, result and release", flush=True)
    finally:
        if trial and trial.exists():
            shutil.rmtree(trial)
        fixture.close()
        if pause_at and recovery_lock_scope is not None and recovery_lock_scope.exists():
            shutil.rmtree(recovery_lock_scope)
        if recovery_root_created:
            try:
                Path("/tmp/mervlan_tmp").rmdir()
            except OSError:
                pass


def main() -> int:
    completed = 0
    if os.environ.get("MERV_TEST_PARENT_ONLY") != "1":
        for shell in ("dash", "busybox"):
            if shell == "busybox" and shutil.which("busybox") is None:
                raise SystemExit("BusyBox is required for the coordinated candidate test")
            run_case(shell, "", "published-verified")
            completed += 1
            print(f"PASS {shell} coordinated success preserves Update owner and rescue entrypoint", flush=True)
            run_case(shell, "13", "rollback-verified")
            completed += 1
            print(f"PASS {shell} coordinated rollback retains evidence and Update owner", flush=True)
    for shell in ("dash", "busybox"):
        run_update_parent_case(shell, "", "published-verified")
        completed += 1
        run_update_parent_case(shell, "13", "rollback-verified")
        completed += 1
        run_update_parent_case(shell, "", "recovery-required", pause_at="13")
        completed += 1
    print(f"COORDINATED_CANDIDATE_RESULT {completed}/{completed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
