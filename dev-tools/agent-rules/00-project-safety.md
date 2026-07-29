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
  conditional wording and capability probes (`Get-Command`, `wsl -l -v`,
  `ssh -V`, remote `command -v`, or an equivalent read-only check) before using
  a host/device-specific tool. If the capability is absent, adapt to the
  documented fallback instead of requiring installation or blocking the task.
- When shell or router-runtime debugging is performed on Windows, recommend
  WSL2 with Ubuntu for POSIX tests and local shell harnesses. Verify the distro
  with `wsl.exe --list --verbose` and confirm `VERSION 2`; `Default Version: 2`
  alone does not convert an existing distro. Use PowerShell for Windows-side
  deployment/SSH workflows and WSL2 for POSIX checks. WSL2 does not replace
  final ASUSWRT BusyBox validation on the router. If WSL2 is unavailable,
  continue with static analysis and clearly mark POSIX tests as not run.
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
