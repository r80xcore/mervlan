# Testing and evidence

## Local validation

Native Linux/Ubuntu is the default host for local validation. See
`platform-linux.md` for the package baseline. From the repository root, verify
the host and the required tools:

```sh
uname -a
cat /etc/os-release
for tool in sh busybox node ssh scp openssl; do
    type "$tool" >/dev/null 2>&1 || exit 1
done
```

Run the complete maintained host gate:

```sh
sh dev-tools/tests/local/run_all.sh
```

For changed shell files, run both host `sh -n` and `busybox sh -n`. A host
check is useful syntax evidence, but it does not replace router-side BusyBox
validation.

Windows users should follow the separate
`platform-windows-wsl.md` appendix. WSL2 is not a prerequisite for native
Linux development.

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

Use this order: static inspection and local isolated harnesses; native Linux
preflight; `sh -n` and `busybox sh -n`; focused router selftests; Sync Nodes and
focused node checks; non-disruptive UI/API validation; then human-controlled
Apply/Restore/Update tests last, one action at a time, with preparation and
recovery evidence. Windows users substitute the WSL2 preflight from
`platform-windows-wsl.md` for the native Linux preflight.

The test suite proves contracts; it does not authorize a disruptive action.
Do not treat a host timeout as a pass or fail until child processes, locks,
DHCP Hold, recovery markers, and evidence have been inspected.
