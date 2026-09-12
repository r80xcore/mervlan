# Test workflows

This is the practical guide for choosing and running developer tests. Read
`90-testing-and-evidence.md` first for safety and evidence policy.

## 1. Local checkout tests

Use these for progress/loading lifecycle changes and deterministic logic that
does not require router state. They use temporary state and must not contact
hardware:

```sh
sh dev-tools/tests/local/action_progress_test.sh
sh dev-tools/tests/local/loading_progress_test.sh
```

Run both after changing action tokens, polling, terminal state, button locks,
or loading text. If a harness needs production paths, set an explicit
`MERV_BASE`; do not rely on the current directory.

## 2. Static shell checks

For every changed shell file, run `sh -n functions/changed_file.sh`. On a
device, use the installed path and the device's `/bin/sh`. Passing on
PowerShell, Bash, or a modern Linux shell does not prove ASUSWRT BusyBox
compatibility. Check command availability before adding a dependency.

For an ownership/lifecycle round, also sweep for duplicate identity/nonce,
v2 owner, unsafe trap, unsupported `stat`, and unvalidated lock-cleanup
mechanics. Remaining matches must be named compatibility or specialized DHCP,
node-job, Recovery, or observation policy rather than ignored.

For the development-only Developer Tools modal, also run:

```sh
sh dev-tools/tests/local/developer_tools_contract_test.sh
```

This confirms dev-only gating, the isolated handler boundary, the closed
selftest transport, and that frontend options still match the router dispatcher.

## 3. Router selftest

The maintained suite is:

```sh
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh shell-syntax
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh action-lifecycle
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh client-refresh-contract
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh signal-termination
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh nonce-uniqueness
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh owner-lock-contract
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh lock-publication
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh action-parent-ownership
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh direct-manager-save-overlap
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh update-exclusivity
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh action-lock-failure
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh dhcp-incomplete-lock
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh router-portability
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh maintenance-lock-interop
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh observation-lock
```

Use the narrowest case first. The suite uses fake ebtables and a state root
under `/tmp/mervlan_tmp/selftest.<run-id>`; it is not an Apply simulation and
does not mutate VLANs. Confirm exact case names in the script before invoking
a newly added case.

If `all` exceeds the host command limit, retain its output, check for children,
locks, recovery state, and leaked selftest directories, then run affected
focused cases. Report `INCONCLUSIVE`, not PASS.

The explicit `all` selector is a final broad gate, not a substitute for the
focused contract checks above. Do not run `all`, `live-audit`, Apply, Update,
or other disruptive paths as part of a non-disruptive documentation or static
round; retain the reason and focused evidence instead.

Useful focused groups are DHCP Hold/ownership (`dhcp-api`, `dhcp-owners`,
`dhcp-phases`), recovery/healing (`heal-handoff`, `boot-handoff`, `recovery`),
observation (`post-apply`, `observation-concurrency`,
`observation-generations`, `client-refresh-contract`), node operations
(`node-worker-pool`, `execute-node-runner`, `sync-node-pool`), UI action
contracts (`action-lifecycle`, `failure-propagation`, `logging-polling`), and
syntax/read-only audit (`shell-syntax`, `live-audit`). Choose the group that
matches the changed contract; do not run disruptive Apply merely because a
selftest case has the word “apply” in its name.

## 4. Node validation after Sync Nodes

Verify on the node:

```sh
sha256sum /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh
sha256sum /jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh
sh -n /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh shell-syntax
```

Compare hashes with the source/router and confirm Markdown, evidence, specs,
and agent files were not copied. A node-only check must not require the main
router's `execute_nodes.sh` orchestration script.

## 5. UI/API validation

For Save, Sync Nodes, Refresh Clients, Metadata, MAC Shield, key generation,
and hardware probe, first use a non-disruptive test. Record the action token,
initial/terminal progress JSON, relevant logs, and final UI state. Exercise
rejected input, empty/optional input, malformed or late status, and timeout/
release paths where the change affects them.

For Apply, run local, node-only, and main+nodes separately. Confirm all three
complete their final client refresh and the loading panel stays open until that
refresh completes. Use the phase label “Refreshing client inventory...”.

## 6. Human-controlled tests

Only after safe layers pass, ask the human to prepare and run one disruptive
action. Record mode, start/end time, affected node, connectivity, UI result,
and logs. Verify token/result, node markers, client generation, locks, DHCP
Hold/MAC Shield, and recovery state before the next test.

Stop for management loss, unexpected br0 exposure, persistent outage, stale
protection state, missing terminal result, or failed recovery.

For a prepared disruptive test, the guard interface is:

```sh
sh /jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh status
sh /jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh arm 300
# run exactly one prepared action
sh /jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh status
sh /jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh disarm
```

Arm only after the human preparation gate and disarm only after logs, safety
state, connectivity, and terminal results are verified. If the deadline fires,
stop normal testing and follow recovery; do not simply re-arm it.

## 7. Evidence lifecycle

On each device use a unique run ID and collect to:

```text
/tmp/mervlan_tmp/evidence/<run-id>/<device>/<stage>/
```

Download to `dev-tools/evidence/<run-id>/`, verify transfer and hashes, write a
sanitized summary, then remove the exact remote run directory. Do not leave
raw evidence on the router or AP; flash space is limited.
