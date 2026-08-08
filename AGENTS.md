# AGENTS.md

## Project Context


## Authority and execution boundaries

Project safety invariants and explicit authorization limits take precedence.

The active implementation plan governs required behavior, scope, round order,
gates, acceptance criteria, and evidence requirements where it does not
conflict with project safety rules.

AGENTS.md, workflow routes, and role definitions govern orchestration
mechanics only. They must not broaden scope, weaken a required gate, override
the active plan, or authorize commits, deployment, rebooting, destructive
operations, or public-contract changes.

## Core Design Principles

Prefer proportionate modularity and the smallest coherent implementation
that satisfies the required behavior and safety invariants.

Preserve established APIs, persisted formats, ownership boundaries, and
working subsystem policy unless the active task authorizes a change.

Do not split files, introduce abstractions, or refactor working code solely
to satisfy structural preferences. Unify reusable generic mechanics when it
reduces duplication or risk, but do not force specialized subsystem policy
into a shared abstraction.

- Define proportionate acceptance and verification requirements before implementation.
- Keep related tests cohesive enough to avoid fragmented micro-tests, but never reduce meaningful coverage, weaken assertions, or hide failures merely to save tokens or execution time.


## Tool Execution and Batching

For each bounded work stage, identify independent, already-known, non-conflicting tool calls before invoking tools. When practical, execute them through one outer `functions.exec` or Code Mode `exec` call.

Use `Promise.allSettled()` when successful results remain useful even if another call fails. Inspect and attribute every returned result. Use `Promise.all()` only when any individual failure invalidates the entire batch.

Prefer batching for:

- Read-only file inspection.
- Independent symbol, text, and call-site searches.
- Repository metadata and status collection.
- Independent log or artifact inspection.
- Validation commands that do not share mutable state.

Keep operations sequential when they involve:

- A result that determines the next operation.
- Adaptive investigation where the next target is not yet known.
- Approvals or permission boundaries.
- Agent spawn, wait, resume, message, or replacement operations.
- Overlapping or order-sensitive writes.
- Git staging, commits, resets, or other Git-state mutations.
- Builds or tests sharing a build directory, generated output, database, port, fixture, device, or other mutable resource.

Do not split an otherwise batchable inspection across repeated outer tool calls. Do not create extra work, broaden scope, obscure failure attribution, or increase worker count merely to fill a batch.

Tool-call concurrency is local to one agent thread. It does not change route selection, worker ownership, scope boundaries, verification requirements, or subagent-concurrency limits. A stage requiring only one useful tool call should remain one call.

## Working State

At any given time, we will be in one of two working states:
- `deployment state`: beginning to plan a broad task or in the process of deploying a plan. A  deployment plan can span multiple sessions.
- `leaf state`: for tasks outside the plan being deployed by the `deployment state`, such as general queries, document editing, or performing operations to add, modify, or delete small files, modules, or tools.

## Project Documentation Framework

The main project documents are stored under `agent_docs/`:

- `agent_docs/project_overview.md`: goals, architecture, workflow, and major decisions.
- `agent_docs/project_core_tech.md`:A brief summary of special technologies or architectures of project.
- `agent_docs/project_structure.md`: directory layout, modules, components, and ownership boundaries.
- `agent_docs/project_progress.md`: active implementation plan and cross-session execution status.
- `agent_docs/project_diary.md`: durable architecture decisions, discarded approaches, and lessons.
- `agent_docs/latest_session_work.md`: Summarizing previous sessions along with any unfinished tasks.
- Module-specific documents, when present.

--------
`agent_docs/project_progress.md` and `agent_docs/latest_session_work.md` are two documents designed to ensure smooth and seamless deployment between multiple sessions in deployment mode. These two files can only be edited in `deployment state` or when the user explicitly requests it. The main agent is responsible for updating these two files, while subagents are not allowed to edit them.

Update documentation only with verified facts. Keep temporary reasoning, raw logs, and short-lived checkpoints out of durable project documents.

Never delete any main project document without warning the user and receiving a second explicit confirmation.

## Route Selection

There are three routes.
### Light route:
Use for light tasks which in the `leaf state`.
Performs tasks by yourself. Do not spawn subagents in this route.

### Medium route:
Use for deploying large tasks/plans in the `deployment state`.
Perform implementation, verification, and documentation by yourself. Do not spawn worker subagents in this route. The deployment session's persistent `explorer` companion is the only exception and is not counted as a subagent.
Read and follow `agent_docs/workflow/medium_route.md`.

### Heavy route:
You a orchestrator, coordinates subagents to deploy large tasks/plans in the `deployment state`.
Reuse the deployment session's persistent `explorer` companion to absorb bounded supplementary context and return concise findings to the main agent. It is not counted as a worker subagent.
Read and follow `agent_docs/workflow/heavy_route.md`.

### Route selection rules and state interpolation

The route will be specified by the user, like: "use Light/medium/heavy route...". Apply that route throughout the entire session until it ends or until the user indicates to switch to the other route. If the user does not specify a route, select the light route as the default. Do not guess and choose a route yourself.

If the light route is specified or choosed, it means we are in the `leaf state`.
If the medium route/heavy route is specified, it means we will proceed to the `deployment state`.

## Context Loading

- In the Light route (`leaf state`), read only the files relevant to the current task.
- Initialize the persistent explorer on the first bounded investigation where offloading supplementary context is likely to save main-agent context or improve independent review. Do not create an empty explorer merely because deployment state began. Once created, reuse the same thread for the session. The explorer is a read-only second brain for the main agent and is excluded from worker/subagent counts.
- An explorer assignment defines the investigation focus, not a hard reading boundary. The explorer may follow directly related files, symbols, call sites, documentation, dependencies, and configuration when needed, while remaining read-only and avoiding unrelated repository-wide exploration.
- Load the foundational project context in one bounded read-only batch:
  1. The real `dev-tools/RULES.md`.
  2. The active implementation plan, when one exists.
  3. `agent_docs/project_progress.md` only when continuing active work.
  4. `agent_docs/latest_session_work.md` only when continuing from another session.
  5. Architecture/structure documentation only when the current round touches those boundaries.
- After the batch returns, interpret project rules and the active plan first, then reconcile any loaded progress, handoff, architecture, or structure documents. This interpretation order does not require separate outer calls.
- Use the resulting status and ownership map to inspect the smallest relevant interfaces, call sites, tests, and configuration surface.
- Read only relevant module documentation. Expand source inspection only when repository evidence requires it.
- Reconstruct active tasks, dependencies, verification state, and blockers. Resolve contradictions with targeted evidence.
- Under the Heavy route, review only critical hunks and integration boundaries after delegation unless risk, missing evidence, or conflicting results require broader inspection.
- In final agent-usage statistics for a deployment session, always include the explorer's call count and label it as a `companion`, even though it is excluded from worker/subagent counts.

## Platform-specific paths

Paths in this workflow are written using `/` as a platform-neutral separator.
When running filesystem commands, use paths appropriate for the current operating system and shell:

* On Linux and macOS, use `/`.
* On Windows, use the equivalent Windows path format and `\` where required.

Do not treat the example path separator as a literal requirement. Resolve every path using the conventions of the current environment.
