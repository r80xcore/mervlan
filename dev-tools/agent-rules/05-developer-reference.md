# Developer reference routing

Use for every non-trivial MerVLAN development task.

- Start with `dev-tools/docs/README.md` for the short navigation map.
- Read `dev-tools/docs/developing_notes.md` when new to the repository, when the
  architecture is unclear, or when the task crosses multiple subsystems. It is
  the compatibility overview for the focused developer documents.
- Read only the focused developer documents relevant to the task; do not load
  every file in `dev-tools/docs/` by default.
- Be token-conservative: read the route's first-level notes and exact code
  references first, then return for another note only when a contract,
  ownership boundary, or safety condition is unclear. Never omit a relevant
  safety check just to save context.
- The agent rules in `dev-tools/agent-rules/` are mandatory. Developer documents explain
  the system and provide routing; they do not weaken a safety rule.
- `dev-tools/` is development/test-branch material. Its documentation,
  planning, evidence, local tests, specifications, and agent-guidance content
  are PC-only. Development `Sync Nodes` copies only the router-capable
  executable tools.

## Task routing

Read the matching focused notes before editing:

- Shell, manager, worker, or library work: `dev-tools/docs/40-function-libraries.md`,
  `dev-tools/docs/80-code-limitations.md`, and the applicable shell/lock/orchestration rules.
- UI button, payload, progress, or loading work: `dev-tools/docs/20-runtime-flows.md`,
  `dev-tools/docs/50-ui-action-pipelines.md`, and `dev-tools/docs/60-state-and-data.md`.
- Apply, observation, client JSON, or MAC Shield work: `dev-tools/docs/20-runtime-flows.md`,
  `dev-tools/docs/60-state-and-data.md`, `dev-tools/docs/80-code-limitations.md`, and product/lock rules.
- Node, Sync Nodes, SSH, or deployment work: `dev-tools/docs/70-node-sync-and-ssh.md`,
  `dev-tools/docs/95-deployment-checklist.md`, and the SSH/device rules.
- Test, live validation, or evidence work: `dev-tools/docs/90-testing-and-evidence.md`,
  `dev-tools/docs/92-test-workflows.md`, `dev-tools/tests/`,
  `dev-tools/evidence/README.md`, and the testing/evidence rules.
- Unknown or cross-cutting work: read `dev-tools/docs/00-project-overview.md`,
  `dev-tools/docs/10-architecture.md`, and `dev-tools/docs/developing_notes.md`, then narrow the set.

After editing, update the relevant developer note when a durable workflow,
limitation, or ownership boundary has changed. Keep rules and reference notes
small, actionable, and free of duplicate explanations.
