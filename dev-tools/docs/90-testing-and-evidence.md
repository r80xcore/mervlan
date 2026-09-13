# Testing and evidence

## Local validation

On Windows, complete the WSL2 preflight before running POSIX shell tests:

1. Verify `wsl.exe` exists and run `wsl.exe --version`.
2. Run `wsl.exe --list --verbose` and confirm the exact Ubuntu distro reports
   `VERSION 2`. A `Stopped` distro is installed and valid.
3. Run a harmless command in that exact distro, such as
   `wsl.exe -d <registered-distro-name> -- sh -lc 'uname -a; cat /etc/os-release'`.

`wsl.exe --version` verifies only the client. If the normal agent runner
returns `E_ACCESSDENIED` or `WSL/.../E_ACCESSDENIED`, classify that as
`HOST_RUNNER_ACCESS_DENIED` and retry the read-only probe through the approved
host/elevated execution path. Do not classify WSL2 as unavailable unless the
host-level probe confirms that it is unavailable. If no approved host path can
access WSL, mark POSIX results `INCONCLUSIVE`, not `PASS`.

If the host-level harmless command instead reports `getpwuid(0) failed`,
`execvpe(/bin/sh) failed`, or a group of `/etc/fstab`, drive-mount, and Windows
path-translation failures, the registered distro is not usable for testing.
Treat the path-translation messages as secondary startup symptoms until the
distro root is verified: inspect the WSL system kernel log read-only with
`wsl.exe --system -- dmesg`, preserve or export any needed distro data, and
repair or rebuild the distro outside the test workflow. Do not run POSIX tests
or report them as passed until the harmless command, `getent passwd 0`, and a
Windows-drive checkout access check all succeed.

### Worst-case WSL2 recovery

Use this recovery only after the host-level probe proves that the registered
distro cannot start normally or that critical root paths such as `/etc`,
`/bin/sh`, or `/bin/mount` are missing. A mount-translation message by itself
is not enough. Stop all agents using the distro and appoint one operator for
the recovery; no other agent may start WSL or mutate its registration until
verification is complete.

1. Record `wsl.exe --version`, `wsl.exe --list --verbose`, the exact distro
   name/version, the startup error, and the relevant output from
   `wsl.exe --system -- sh -lc 'dmesg | tail -n 120'`.
2. Choose a backup path outside the repository with enough free space. Stop
   the affected distro and export it before deleting or replacing anything:

   ```powershell
   wsl.exe --terminate <broken-distro-name>
   New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\WSL-Backups"
   wsl.exe --export <broken-distro-name> "$env:USERPROFILE\WSL-Backups\<name>-damaged.vhdx" --format vhd
   Get-Item -LiteralPath "$env:USERPROFILE\WSL-Backups\<name>-damaged.vhdx"
   ```

   Replace every angle-bracket placeholder before running a command. A VHD
   may contain credentials and private files; keep it outside the repository
   in a user-private location and never attach it as test scratch space.
   If export reports a sharing violation, coordinate a full
   `wsl.exe --shutdown`, verify that no other distro work is active, and retry.
   Treat a nonzero exit or an unexpectedly small file as a failed backup. Do
   not unregister the distro until the export is verified.
3. Preserve the original VHD. For later salvage, import a *copy* into a
   separate recovery registration; never use `--import-in-place` on the only
   backup. Recover only known user/project data. Do not copy damaged `/etc`,
   `/bin`, `/lib`, `/usr`, or root-level symlinks over a clean distro.
4. With explicit approval, remove only the proved-broken registration. Restore
   a previously verified clean baseline, when available, into a new empty
   install directory:

   ```powershell
   wsl.exe --unregister <broken-distro-name>
   wsl.exe --import <expected-name> <new-install-directory> <clean-baseline.vhdx> --vhd --version 2
   ```

   Otherwise install the same known Ubuntu release under the expected name:

   ```powershell
   wsl.exe --install <matching-Ubuntu-release> --name <expected-name> --version 2 --no-launch --web-download
   ```

   `--unregister` deletes that registration's root filesystem. The verified
   export is the rollback/salvage artifact; keep it until the clean distro and
   all needed data are confirmed.
5. Use a normal unprivileged account as the default for AI-driven test work.
   Use `wsl.exe -d <name> -u root -- ...` only for an intentional,
   reviewed administration command. If a clean image has only root, first
   confirm that UID 1000 is unused, then create and select the account:

   ```powershell
   wsl.exe -d <name> -u root -- getent passwd 1000
   wsl.exe -d <name> -u root -- useradd --create-home --uid 1000 --shell /bin/bash <user>
   wsl.exe --manage <name> --set-default-user <user>
   ```
6. Verify the rebuilt distro before restoring data or running tests:

   ```powershell
   wsl.exe --list --verbose
   wsl.exe -d <name> -- sh -lc 'id; getent passwd 0; test -x /bin/sh; test -x /bin/mount; cat /etc/os-release'
   wsl.exe -d <name> -- sh -lc 'test -d /mnt/c; cd /mnt/c/<checkout>; pwd; test -f dev-tools/docs/90-testing-and-evidence.md'
   ```

   Also check `wslpath` in both directions and run the focused test command
   from the Windows-mounted checkout. Keep the old VHD until these checks and
   any required data recovery pass. Deleting the backup requires a separate,
   explicit decision.

For prevention when several AI tools share WSL: keep source checkouts on the
Windows mount; give every test a dedicated path below `/tmp`; never use `/`,
`/etc`, `/usr`, `/bin`, `/lib`, `/home`, or an unresolved/empty variable as a
test root, staging root, or recursive cleanup target; resolve and validate the
exact target before any recursive delete or move; and do not let multiple
agents perform WSL administration concurrently. Create a known-good VHD
export after initial provisioning and after intentional toolchain changes:

```powershell
wsl.exe --shutdown
wsl.exe --export <healthy-distro-name> "$env:USERPROFILE\WSL-Backups\<name>-clean-baseline.vhdx" --format vhd
```

Run the narrow affected self-test first, then related contracts and shell
syntax. The maintained suite is:

```sh
sh dev-tools/tests/router/mervlan_selftest.sh <case>
sh dev-tools/tests/router/mervlan_selftest.sh shell-syntax
```

Relevant cases include `apply-observation`, `post-apply`,
`observation-concurrency`, `observation-generations`, `client-refresh-contract`,
`action-lifecycle`, `failure-propagation`, `logging-polling`, and
`shell-syntax`.

The full `all` suite is useful when justified, but a host timeout is
inconclusive. Preserve its output, check for leftover processes/state, and use
focused cases for the final reliable result.

## Router validation

After authorized deployment, run on the router:

```sh
/bin/sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh <case>
/bin/sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh shell-syntax
/bin/sh /jffs/addons/mervlan/functions/post_apply_worker.sh status
```

Also verify active hashes/versions, locks, workers, progress records, and
relevant CLI/VLAN logs. A successful self-test does not authorize Apply.

## Human-controlled tests

Apply, Restore, Undo Restore, Undo Update, and other disruptive operations need
human preparation. For Apply, test one mode at a time and record:

- target and management path;
- DHCP Hold, MAC Shield, healing, worker, and lock state;
- expected client placement;
- loading/progress behavior;
- router and node logs;
- client collection generation and final state;
- recovery behavior and any warning such as the intentional absent SSID case.

Stop on a bridge leak, outage, stale Hold/lock, inconsistent state, failed
recovery, or loss of management access. Physical recovery belongs to the user.

## Evidence format

Record target, command/action, expected result, actual result, duration,
PASS/FAIL/PARTIAL, before/during/after state, logs, and fixes/retests. Store
temporary router/AP evidence below
`/tmp/mervlan_tmp/evidence/<test-run-id>/`, download it to
`dev-tools/evidence/<test-run-id>/`, verify the local copy, and delete the
remote directory only afterward. Raw evidence is ignored by Git and is never
deployed.

For the command-by-command procedure and test selection guide, read
`92-test-workflows.md`. This file defines policy and evidence handling; the
workflow note defines how to execute each safe test.

## Test selection policy

Use this order: static inspection and local isolated harnesses; WSL2 preflight;
`sh -n` in a POSIX/BusyBox-capable shell; focused router selftests; Sync Nodes
and focused node checks; non-disruptive UI/API validation; then human-controlled
Apply/Restore/Update tests last, one action at a time, with preparation and
recovery evidence.

The test suite proves contracts; it does not authorize a disruptive action.
Do not treat a host timeout as a pass or fail until child processes, locks,
DHCP Hold, recovery markers, and evidence have been inspected.
