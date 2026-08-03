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
