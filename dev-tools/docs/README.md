# MerVLAN developer tools

This folder is the developer reference for understanding, changing, testing,
and deploying MerVLAN. It is intentionally split by topic so a developer can
read only the material relevant to a change.

## Token-conservative reading order

1. Read this file and follow the focused document route below.
2. Read one route below, normally two or three numbered notes.
3. Use `rg` for the exact action, function, path, or setting name before
   opening a large source file.
4. Return to `developing_notes.md`, `troubleshooting.md`, or another note only
   when the focused notes leave an ownership or safety question unanswered.

Do not load every note for a small edit. Do read another relevant note when a
change crosses a documented boundary; conserving tokens must not replace a
safety check.

## Start here

1. Read [Project overview](00-project-overview.md).
2. Read [Architecture](10-architecture.md) and the relevant [runtime flow](20-runtime-flows.md).
3. Use [Script tree](30-script-tree.md) and [Function libraries](40-function-libraries.md) to locate code.
4. Check [Code limitations](80-code-limitations.md) before editing runtime files.
5. Follow [Testing and evidence](90-testing-and-evidence.md), the [test workflows](92-test-workflows.md), then the [deployment checklist](95-deployment-checklist.md) when a live device is in scope.

## Reference map

| Document | Use it for |
|---|---|
| `00-project-overview.md` | Product scope, device roles, and the main mental model. |
| `10-architecture.md` | Components and ownership boundaries. |
| `20-runtime-flows.md` | Apply, Save, Sync, Refresh Clients, APMO, and maintenance flows. |
| `30-script-tree.md` | Entry points, callers, and script relationships. |
| `40-function-libraries.md` | Shared shell libraries and load-order contracts. |
| `50-ui-action-pipelines.md` | Button-to-backend-to-completion behavior. |
| `60-state-and-data.md` | Settings, locks, progress, observation, and result files. |
| `70-node-sync-and-ssh.md` | Router/node roles, sync, SSH, and staged transfer. |
| `80-code-limitations.md` | Product and platform constraints. |
| `90-testing-and-evidence.md` | Local, router, node, and human validation. |
| `92-test-workflows.md` | Exact commands and when/why to use each test layer. |
| `95-deployment-checklist.md` | Safe staged deployment and rollout. |
| `troubleshooting.md` | Symptoms, diagnostics, and safe next checks. |

## Documentation ownership

These documents explain the system and provide navigation. Runtime code and
the test workflows remain the authoritative sources for behavior and observed
results.

`dev-tools/to-do/` contains active or gated implementation plans.
Completed implementation records are archived outside the repository when
they are no longer needed for active development.
`dev-tools/evidence/` contains test evidence. Neither is part of the router runtime or
normal deployment payload. Development `Sync Nodes` copies only the two
router-capable executable tools; all Markdown, planning, evidence, local tests,
and specifications remain on the development computer.

## Quick task map

| Task | Read first |
|---|---|
| UI button, payload, progress | `20-runtime-flows.md`, `50-ui-action-pipelines.md`, `60-state-and-data.md` |
| Shell, manager, worker, library | `40-function-libraries.md`, `80-code-limitations.md` |
| Apply, clients, MAC Shield | `20-runtime-flows.md`, `60-state-and-data.md`, `80-code-limitations.md` |
| Sync Nodes, SSH, deployment | `70-node-sync-and-ssh.md`, `95-deployment-checklist.md` |
| Test or evidence | `90-testing-and-evidence.md`, `92-test-workflows.md` |
| Unknown/cross-cutting | `00-project-overview.md`, `10-architecture.md`, `developing_notes.md` |

The numbered notes are a navigation system, not independent specifications.
When they disagree with executable code, inspect the code, preserve the safety
rule, and update the affected note in the same change.
