# MerVLAN project safety

Use for every task.

- Inspect current code and `git status` before editing; preserve unrelated changes.
- Make the smallest coherent change. Do not bundle unrelated refactors.
- Current code is evidence. If it conflicts with a written plan, stop and reconcile the difference.
- Do not commit, push, deploy, synchronize nodes, reboot, restore, or change backups without explicit approval.
- Preserve DHCP Hold, MAC Shield, healing, observation, settings, backups, client refresh, and node identity unless the approved task explicitly changes them.
- `dev-tools/` is developer/test-branch material. Never deploy its
  documentation, planning files, evidence, local tests, specifications, agent
  rules, or raw evidence. Development `Sync Nodes` may copy only its approved
  executable router test tools.
- Keep `dev-tools/` on development and test branches. Before preparing or
  merging a main/release branch, explicitly verify that the release does not
  include `dev-tools/` or other developer-only material. Do not assume a
  branch merge or archive operation excludes it automatically.
- Never print, commit, or place credentials/private keys in the repository.
- Bump version headers once for a completed implementation, not after each edit.
- At the end of every implementation round, run the relevant automated and
  static validations, inspect the results, and sweep the changed code and its
  callers for regressions introduced by that round before starting the next
  round. If a required test cannot run, record the reason and the needed
  human/device follow-up clearly.

## Living environment knowledge

- Treat this rule set as living project knowledge. When a materially important
  command, tool, shell capability, device behavior, or workflow is proven to
  fail or to be a safer/reliable replacement, update the appropriate rule in
  the same task; do not leave the next agent to rediscover it.
- Record the smallest useful evidence: date, environment/scope, command or
  capability tested, observed result, and the supported fallback or replacement.
  Keep the note short and actionable. Do not turn a transient failure or an
  unverified assumption into a rule.
- Separate portable project requirements from host-specific capabilities. Use
  conditional wording and capability probes (`Get-Command`, `wsl.exe
  --version`, `wsl.exe --list --verbose`, `ssh -V`, remote `command -v`, or an
  equivalent read-only check) before using a host/device-specific tool. If a
  capability is absent, adapt to the documented fallback instead of requiring
  installation or blocking the task.
- When shell or router-runtime debugging is performed on Windows, recommend
  WSL2 with Ubuntu for POSIX tests and local shell harnesses. `wsl.exe
  --version` verifies only the client. Confirm a registered distro with
  `wsl.exe --list --verbose`, confirm `VERSION 2`, and run a harmless command
  in the exact distro name returned by that listing. A `Stopped` distro is
  installed and valid; it may be started for the probe. `Default Version: 2`
  alone does not convert an existing distro.
- If the normal agent runner returns `E_ACCESSDENIED` from WSL enumeration or
  startup, classify it as `HOST_RUNNER_ACCESS_DENIED`, not as proof that WSL2
  is unavailable. Retry the same read-only probe through the approved
  host/elevated execution path when available. If the elevated probe works,
  use WSL2 and record the runner permission limitation. If no approved host
  path can access it, report WSL2 as present or unverified but inaccessible to
  the runner, continue static analysis, and mark POSIX tests `INCONCLUSIVE`.
  Do not report them as passed and do not claim Ubuntu is missing.
- Use PowerShell for Windows-side deployment/SSH workflows and WSL2 for POSIX
  checks. Treat WSL process exit status as authoritative and normalize
  NUL-padded Windows output before parsing. Do not automatically install,
  unregister, shut down, or reconfigure WSL while probing. WSL2 does not
  replace final ASUSWRT BusyBox validation on the router.
- Never generalize this host's WSL/virtualization, Windows tooling, network
  layout, SSH behavior, or installed utilities to another user's system. A
  different host must revalidate those facts and may keep the portable rule
  while replacing only the local implementation note.
- Lab coding-workspace observation (2026-07-27): with no `index.lock` and no
  Git process holding the repository, `git add` initially received a Windows
  permission error writing the worktree index. Retrying the same non-destructive
  Git command with approved filesystem escalation succeeded. Check for a live
  lock/process first; do not delete an index lock merely because staging fails.
- When a discovered fact changes safety, compatibility, or the allowed command
  sequence, treat the updated rule as binding for later work and mention the
  change in the task handoff. Do not silently weaken a rule to accommodate a
  failed command.
