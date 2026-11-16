# XT8 Controlled Installed-File Repair Trial

**Prepared, not executed.** This procedure is for MAIN only, after separate
maintainer authorization. It is not authorization to run Repair, Update,
Apply, Heal, Sync, Uninstall, restart networking, or reboot. Do not use it on
NODE.

The accepted XT8 result covers the isolated `/tmp` transaction engine only.
This candidate additionally depends on the canonical Update coordinator and
persistent recovery path. Host qualification does not prove the installed
router libraries or runtime behavior.

## Exact reviewed inputs

Candidate Repair SHA-256:

```text
587c002f36d1191bbcde4959a0c6d5256494abac522d82af2b8d85d0746856a1  update_mervlan_repair_RC3_coordinated.sh
```

Update coordinator SHA-256:

```text
499f939262acd166dac456d3c7445b5439d2dd4a6cad69fec996cacd121df1d2  update_mervlan.sh
```

Both files are uncommitted host candidates at the time this procedure was
prepared. Before any trial, use the exact reviewed files from an approved,
immutable commit and recheck both hashes. Set `SOURCE_COMMIT` to that full
40-character commit SHA. Do not use a moving branch or tag.

## 1. Read-only MAIN preflight

Keep the wired administration path available and open two SSH sessions. Record
the router identity and timestamp. In the first session, run only read-only
checks:

```sh
date
uname -a
busybox | head -n 1
grep '^MemAvailable:' /proc/meminfo
df -Pk /tmp /jffs/addons/mervlan /jffs/addons/mervlan_backups
for utility in awk busybox cat chmod cmp cp curl date df du grep gzip head kill ls md5sum mkdir mv ping ps readlink rm rmdir sed sh sleep tar tr wc; do
  if type "$utility" >/dev/null 2>&1; then
    printf 'available: %s\n' "$utility"
  else
    printf 'MISSING: %s\n' "$utility"
  fi
done
if type sha256sum >/dev/null 2>&1; then
  printf 'available: sha256sum\n'
elif type openssl >/dev/null 2>&1; then
  printf 'available: openssl\n'
else
  printf 'MISSING: sha256sum and openssl\n'
fi
```

Confirm BusyBox ash is the expected MAIN version, at least 32 MiB is available,
`/tmp` has at least 64 MiB free, and the destination has at least 8 MiB free.
Confirm the model/identity is MAIN, SSH is stable, and wired administrative
access is available independently of Wi-Fi. Record the starting SHA-256 of
`/jffs/addons/mervlan/functions/update_mervlan_repair.sh`.

Inspect existing recovery state without deleting or clearing anything:

```sh
ls -ld /tmp/mervlan_tmp/locks/mervlan_maintenance.lock \
  /jffs/addons/mervlan_state/update.quiesce \
  /jffs/addons/mervlan_state/update.journal
/jffs/addons/mervlan_backups/recover.sh list
for path in /tmp/mervlan_tmp/updates.* \
  /jffs/addons/mervlan_backups/.mervlan.new.* \
  /jffs/addons/mervlan_backups/.mervlan.old.*; do
  if ls -ld "$path" 2>/dev/null; then :; fi
done
```

`ls` reporting an absent lock or marker is expected; any live/unknown owner,
active quiesce state, unresolved journal, incomplete backup stage, or unexplained
`updates.*` workspace is a **STOP**. Preserve and investigate the recorded
state through the existing recovery path. Do not remove it to make the trial
pass. Ensure a separately verified off-router backup and a working recovery
route already exist. The candidate will create and validate an additional
persistent Update backup before publication.

Do not continue if any required utility is absent, the RAM/storage thresholds
fail, SSH or wired access is unstable, or router identity is uncertain.

## 2. Stage the private candidate files

After authorization, create one private directory on MAIN and transfer only
the two reviewed scripts with the documented staged `scp -O` workflow:

```sh
TRIAL=/tmp/mervlan_rc3_trial.<unique-token>
mkdir -m 700 "$TRIAL"
chmod 700 "$TRIAL"
```

Place the reviewed files at exactly:

```text
$TRIAL/update_mervlan.sh
$TRIAL/update_mervlan_repair_RC3_coordinated.sh
```

Then set modes and verify the paths, modes, and hashes on MAIN:

```sh
chmod 700 "$TRIAL/update_mervlan.sh" \
  "$TRIAL/update_mervlan_repair_RC3_coordinated.sh"
ls -ld "$TRIAL" "$TRIAL/update_mervlan.sh" \
  "$TRIAL/update_mervlan_repair_RC3_coordinated.sh"
sha256sum "$TRIAL/update_mervlan.sh" \
  "$TRIAL/update_mervlan_repair_RC3_coordinated.sh"
```

If `sha256sum` is unavailable, use `openssl dgst -sha256` for both files. The
directory and scripts must be owned by root, mode `700`, regular files, and
not symlinks. The coordinator rejects a different candidate path, permission,
or candidate hash. Keep the files under this private `/tmp` directory; never
copy them to `/jffs/addons/mervlan`.

## 3. Record live resource and reachability observations

In the second SSH session, record timestamped samples every five seconds while
the trial runs. Keep this monitor read-only and write its output to
`$TRIAL/monitor.log`. Each sample should include:

- `MemAvailable` from `/proc/meminfo` and free `/tmp` and destination space
  from `df -Pk`;
- size of the active `/tmp/mervlan_tmp/updates.*` and `/tmp/mervlan_lean.*`
  workspaces (`du -sk`), plus the peak observed size;
- process count (`ps | wc -l`) and `/proc/loadavg`;
- whether the separate wired SSH session remains responsive and controller
  ping results.

Record the independent Wi-Fi client observation if available; it is
supplementary. Do not restart Wi-Fi or network services. If SSH is lost, wired
reachability fails, memory falls below 32 MiB, or any unexpected router state
appears, stop observation and follow the recovery section. Do not issue SIGKILL
to the trial process or retry.

## 4. Execute the one authorized trial

Use only the full immutable source commit SHA from the reviewed checkpoint:

```sh
SOURCE_COMMIT=<40-character-reviewed-commit-sha>
umask 077
START=$(date +%s)
MERV_BASE=/jffs/addons/mervlan /bin/sh "$TRIAL/update_mervlan.sh" \
  rc3-repair-candidate \
  "$TRIAL/update_mervlan_repair_RC3_coordinated.sh" \
  "$SOURCE_COMMIT" >"$TRIAL/update.log" 2>&1
RC=$?
END=$(date +%s)
printf 'exit=%s elapsed_seconds=%s\n' "$RC" "$((END - START))" \
  >"$TRIAL/summary.txt"
```

This command uses the private coordinator copy, but its `MERV_BASE` and all
canonical owner, runtime, recovery, backup, quiesce, and publication paths
must remain the installed MAIN paths. Do not set test-only variables or path
overrides. The coordinator refuses a noncanonical install context. The only
publication route is its hidden CLI mode; do not invoke the candidate directly.

Expected success is a truthful exit code `0`, a log stating `57 files` and
`58/58` content/mode verification, the pre-existing production Repair hash
unchanged, and the new durable backup ID recorded in the Update log. The
Update-owned temporary workspace and owner/quiesce/journal state should be
cleaned after verified success. Retain the durable backup and all logs.

A nonzero result can mean a verified complete rollback. Accept that only when
the log explicitly confirms complete 58-entry rollback. In that case the
owner/quiesce/journal are finalized by Update, the durable archive remains,
and the candidate's ledger-bearing rollback workspace is intentionally
retained. Preserve it and do not retry.

## 5. Interrupted or uncertain result

If the candidate reports `recovery-required`, exits unexpectedly during
publication, the coordinator is interrupted, or the host loses connection,
assume installed state is mixed. Do not clear the owner, quiesce marker, or
journal; do not delete either workspace; do not retry and do not run installed
Repair. Keep router access stable and collect the complete log, resource
samples, state files, process list, archive ID, and candidate ledger.

Use only the standalone persistent recovery helper for a read-only check:

```sh
MERVLAN_RECOVERY_BACKUP_ROOT=/jffs/addons/mervlan_backups \
MERVLAN_RECOVERY_ACTIVE_ROOT=/jffs/addons/mervlan \
MERVLAN_RECOVERY_TMP_ROOT=/tmp/mervlan_tmp \
MERVLAN_RECOVERY_STATE_ROOT=/jffs/addons/mervlan_state \
  /jffs/addons/mervlan_backups/recover.sh check <backup-id>
```

Preserve that output with the logs. A restore is a separate destructive
operation and requires separate maintainer authorization after confirming the
backup and wired/SSH recovery access. The manual recovery command is the
existing helper's `restore <backup-id> yes`; do not run it as part of this
trial procedure. A reboot or SIGKILL may discard volatile `/tmp` evidence, but
the Update journal, quiesce record, persistent archive, and copied recovery
helper provide the recovery route; they do not claim automatic rollback.

## 6. Final evidence record

Retain the two transferred scripts, their verified hashes, `update.log`,
`monitor.log`, `summary.txt`, before/after RAM and `df` readings, peak workspace
size, process/load samples, backup ID, result, rollback status, owner/quiesce/
journal status, the production Repair hash before/after, SSH continuity, wired
reachability, and optional Wi-Fi observation. Do not automatically delete the
private trial directory or retained recovery evidence.
