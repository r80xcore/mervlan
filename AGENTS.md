# MerVLAN development guide

This file is the repository-level guide for normal MerVLAN development. It is
intentionally concise; detailed safety rules, routing, platform notes, and
test procedures live under `dev-tools/`.

It describes ordinary work in this checkout. Do not infer an external
orchestration protocol, worker system, or session-management workflow from it.

## Project context

MerVLAN is an Asuswrt-Merlin addon that manages VLAN placement for SSIDs and
Ethernet ports through the router's WebUI. It is intended for AP-mode
deployments, with an upstream VLAN-aware switch/firewall providing routing,
DHCP, and policy. The main router owns the WebUI, configuration orchestration,
node SSH operations, and merged client data. Nodes run a curated runtime
subset and publish local results.

Production code runs on ASUSWRT's BusyBox `/bin/sh`, not desktop Bash. Exact
bridge, VLAN, DHCP Hold, MAC Shield, ownership, recovery, and client-observation
behavior are safety-sensitive.

## Authority and safety

- User authorization and the project's safety invariants take precedence over
  convenience, stale notes, or a proposed refactor.
- Current source and executable tests are the behavioral authority. Update a
  developer note when a durable workflow or boundary changes; do not silently
  weaken a safety rule to match documentation.
- Inspect `git status --short` and relevant diffs before editing. Preserve
  unrelated modifications, untracked files, settings, backups, and evidence.
- Make the smallest coherent change. Do not split files, add abstractions, or
  refactor working code only to satisfy a structural preference.
- Do not commit, push, deploy, synchronize nodes, reboot, Apply, Update,
  Restore, or perform destructive operations unless the user explicitly
  authorizes that action and the required preparation/recovery gate is ready.
- Never print, commit, stage, or copy credentials, private keys, passwords, or
  tokens. The local `dev-tools/mervlan_ssh_credentials.md` profile is ignored,
  must remain local, should be mode `600`, and must reference a private key
  outside the repository.

## Start of a normal task

1. Read this file, then read [`dev-tools/RULES.md`](dev-tools/RULES.md).
2. Read `dev-tools/agent-rules/00-project-safety.md` and
   `dev-tools/agent-rules/05-developer-reference.md`.
3. Use [`dev-tools/docs/README.md`](dev-tools/docs/README.md) to select only
   the focused architecture, runtime, testing, SSH, or product notes needed.
   For unknown or cross-cutting work, inspect `dev-tools/agent-context.json`.
4. Use `rg` to locate the exact action, function, setting, path, caller, and
   test before opening large files.
5. If the task matches an item under `dev-tools/to-do/`, read that plan. Treat
   it as scope and implementation context, not as authorization for live or
   destructive actions.
6. Confirm the change boundary and acceptance checks before implementation.

More-specific `AGENTS.md` files, if added under a directory in the future,
apply to that directory in addition to this file. The focused rules under
`dev-tools/agent-rules/` remain mandatory for their subject areas.

## Implementation boundaries

- Runtime changes normally belong in `functions/`, `settings/`, `templates/`,
  `mervlan.asp`, `www/`, `install.sh`, `uninstall.sh`, or the update/runtime
  paths they call.
- `dev-tools/` contains development documentation, tests, specifications,
  safety helpers, and evidence. Production runtime must not depend on its
  documentation or local harnesses.
- On development branches, only explicitly approved executable tools under
  `dev-tools/tests/router/` and `dev-tools/safety/` may be copied by Sync
  Nodes. Do not hand-edit a node as a permanent fix.
- Preserve public action identifiers, persisted settings formats, file
  ownership, atomic publication, lock ownership, and terminal result markers
  unless the task explicitly changes that contract.

## Shell and runtime rules

- Write POSIX shell for ASUSWRT BusyBox. Do not use Bash arrays, process
  substitution, `wait -n`, `flock`, assumed GNU options, or unvalidated numeric
  input in arithmetic, sleep, timeout, PID, or path operations.
- Do not source markers, status files, or result files as shell code. Treat
  external and device output as untrusted text.
- Do not use `$$` alone for concurrent temporary names. Publish shared state
  through a temporary file and same-directory `mv`.
- Probe device capabilities before depending on a command or option; a host
  utility is not evidence that ASUSWRT provides the same utility.
- Preserve fail-closed behavior around DHCP Hold, MAC Shield, locks, bridge
  state, node identity, recovery, and observation ordering.

## Validation

For native Ubuntu host validation, use the documented baseline in
[`dev-tools/docs/platform-linux.md`](dev-tools/docs/platform-linux.md).

At minimum, run the checks relevant to the change:

```sh
git diff --check
```

For shell, runtime, or test changes, also run the complete maintained local
gate:

```sh
sh dev-tools/tests/local/run_all.sh
```

For documentation-only changes, do not run the full runtime suite merely to
fill a checklist; validate links/routes and keep `git diff --check` clean.
For every changed shell file, run both host `/bin/sh -n` and `busybox sh -n`.
After an authorized device deployment, run the router's `/bin/sh -n` and the
narrowest applicable focused selftest before broader or human-controlled
tests. Use [`dev-tools/docs/90-testing-and-evidence.md`](dev-tools/docs/90-testing-and-evidence.md)
and [`dev-tools/docs/92-test-workflows.md`](dev-tools/docs/92-test-workflows.md)
for test selection, evidence, and live-action gates.

An Ubuntu pass does not prove router behavior. Final runtime evidence requires
an authorized ASUSWRT target, its BusyBox environment, and a safe recovery
path. Use Linux `ssh` and staged `scp -O` transfers as described in
`dev-tools/agent-rules/30-ssh-and-device-operations.md`; do not deploy merely
because credentials are available.

## Completion handoff

Report what changed, the exact validations run, any skipped or inconclusive
checks and why, and any required user/device follow-up. Recheck the working
tree before handoff. Leave credentials and unrelated user files untouched.
