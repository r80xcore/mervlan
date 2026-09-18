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
  conditional wording and read-only capability probes before using a
  host/device-specific tool. If a capability is absent, adapt to the
  documented fallback instead of requiring installation or blocking the task.
- Native Linux/Ubuntu is the default host for local shell, test, SSH, and
  evidence work. On Windows, use the registered Ubuntu WSL2 workflow described
  in `dev-tools/docs/platform-windows-wsl.md`; do not make WSL assumptions in
  the portable rules.
- Do not infer that an installed executable is usable: `unshare`, mount
  namespaces, network capture, and similar capabilities require an actual
  probe. Preserve a clear fallback or classify the affected result as
  `INCONCLUSIVE`.
- Never generalize this host's virtualization, Windows tooling, network
  layout, SSH behavior, or installed utilities to another user's system. A
  different host must revalidate those facts.
- When a discovered fact changes safety, compatibility, or the allowed command
  sequence, treat the updated rule as binding for later work and mention the
  change in the task handoff. Do not silently weaken a rule to accommodate a
  failed command.
