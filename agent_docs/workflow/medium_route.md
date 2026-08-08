# Medium Route

Use this workflow only after the Medium route has been selected under `AGENTS.md`.

## Main-Agent Role

You are the main agent and perform implementation, verification, and documentation directly without spawning or delegating to worker subagents.

The one exception is an optional persistent `explorer` companion, initialized
on the first bounded investigation where offloading context is useful. Once
initialized, keep the same explorer thread for the entire session. It is a read-only secretary and second brain, not a worker subagent. Use it to absorb bounded supplementary context as needs arise, returning compact briefs while you retain ownership of decisions and the work itself.

Use the full project workflow at a proportionate level: understand the relevant context, plan when needed, implement the requested changes, verify the result, and keep the work within scope. Inspect only what is useful for the current task and avoid unnecessary process overhead.

In this route, for common queries, it's not necessary to implement complex workflow for simple tasks.

## Stage Execution and Tool Batching

Divide work into bounded stages such as context loading, targeted inspection, implementation, verification, and final review.

At any stage, send focused investigation of peripheral, unfamiliar, or newly discovered context to the existing explorer thread. The assigned focus is a starting point, and the explorer may follow related read-only context when useful. Do not initialize another explorer. Foundational project documents, central implementation surfaces, and decision-critical evidence remain the main agent's direct responsibility.

Before each stage, collect all independent, already-known, non-conflicting tool operations and apply the shared batching rules from `AGENTS.md`. Evaluate the returned results together before deciding the next stage.

Typical Medium-route batches include:

- Reading several already-identified source, header, test, or configuration files.
- Searching several known symbols or call sites.
- Collecting independent repository metadata.
- Running isolated validation commands after a coherent implementation increment.

Keep implementation edits sequential when one edit depends on another, files overlap, or intermediate results determine subsequent changes.

Run validation concurrently only when commands do not share mutable build output, generated files, fixtures, databases, ports, devices, or other state. Required checks remain required regardless of whether they were batched.

Do not manufacture stages or extra commands merely to create a batch. Small tasks may remain a single inspection, edit, and validation sequence.

## Continuous Execution and Turn Completion

Medium Route is a continuous execution workflow for the user's requested task,
not a sequence of stages that require user reactivation between ordinary
transitions.

Completing any of the following is not by itself a reason to return control to
the user:

- context loading;
- targeted inspection;
- one implementation increment;
- one local validation command;
- one verification stage;
- one repair;
- one plan phase;
- one internal gate;
- one documentation update;
- one explorer investigation;
- a progress update;
- a bounded wait interval.

When another authorized action can proceed without user input, continue
directly to that action in the same active turn when runtime permits.

Do not voluntarily conclude the active turn merely to report that:

- implementation is underway;
- verification is running;
- a test or command is still running;
- an explorer investigation is still active;
- one stage completed;
- the next stage is about to begin.

When the optional persistent explorer is active and its result is required for
the current task, remain in the execution loop until the explorer produces its
result, reaches a genuine lifecycle/blocker condition, or the platform itself
terminates the active model turn.

After receiving explorer evidence, immediately process it and continue the
current Medium-route stage or next required stage when possible.

For locally running commands or validation, a bounded wait or polling interval
ending while useful work is still running is an intermediate execution state,
not task completion.

Return control to the user only when:

- the requested task is complete;
- explicit user authorization is required;
- a material decision or conflict requires user input;
- a genuine blocker cannot be resolved within authorized scope.

If the platform itself forcibly terminates the active model turn, preserve the
smallest useful continuation state so the next user continuation resumes from
the actual current stage. Do not reopen completed stages, repeat accepted
validation, or reconstruct unchanged context merely because the previous model
turn ended.

Do not deliberately emulate a runtime boundary merely to provide an interim
progress report.

## Plans and Status Writes

When the user requests an implementation plan, create or persist the plan.
Begin implementation only when the user explicitly requests execution or
the request clearly and unambiguously asks for both planning and execution.

Record:

* Goal and scope.
* Constraints and protected areas.
* Acceptance criteria.
* Major implementation steps when useful.
* Dependencies, verification approach, known blockers, and next action.

For durable or multi-session work packages, update `agent_docs/project_progress.md` at most twice:

1. Mark the package active and record its bounded plan.
2. Reconcile final status, verification evidence, blockers, and next action.

Do not update it after every checkpoint. Keep significant changes to the plan understandable and traceable.

When a governing implementation plan reaches final acceptance, reconcile
`agent_docs/project_progress.md` into a compact completed-state record containing:

- governing plan identity;
- completion status;
- important accepted contracts or architectural outcomes;
- final verification;
- validation not performed because authorization was unavailable;
- remaining manual or external validation;
- real residual risks or blockers.

Do not clear useful completed-state information merely because the implementation
or session ended.

When a later governing implementation begins, replace the previous completed
record with the new active state after durable architectural information has
been preserved in the appropriate project documentation.

## Durable Project Knowledge

Update durable documentation only when verified implementation changes
architecture, structure, workflow, public behavior, significant decisions,
module ownership, important runtime constraints, or module usage.

The generic `agent_docs` files are durable project context, not execution
journals.

Use:

- `project_overview.md` for stable project purpose and high-level architecture;
- `project_core_tech.md` for unusual platform/runtime/toolchain constraints;
- `project_structure.md` for durable modules, components, directories, and
  ownership boundaries;
- `project_diary.md` for significant architectural decisions, discarded
  approaches, and lessons with lasting value;
- `project_progress.md` for active or most recently completed governing
  implementation state;
- `latest_session_work.md` only for unfinished cross-session continuation state.

A document containing only its heading or placeholder content is uninitialized,
not authoritative.

Do not interrupt implementation merely to populate empty generic documents.

When verified work creates a durable change, update only the affected documents
once at a natural post-verification boundary.

Do not copy raw logs, round history, temporary reasoning, repeated test output,
or transient implementation state into durable documentation.

Use verified implementation and test results as the source of truth.

## Evidence Reuse and Rerun Discipline

Successful validation evidence remains valid for the exact production code,
tests, fixtures, environment, and accepted contract state it covers.

Before rerunning an already-passing validation set, identify what invalidated
the earlier evidence:

- a relevant production change;
- relevant test/fixture/configuration change;
- environment change capable of affecting the result;
- conflicting new evidence;
- changed integration dependency;
- a distinct broader gate required by the governing plan.

If no invalidator exists, reuse the accepted evidence.

Do not rerun a complete passing suite merely for reassurance, cleaner logs,
handoff preparation, a stage boundary, final labeling, or because a previous
model turn ended.

After a repair:

1. rerun the failing selector or smallest reproducer;
2. run directly affected dependent checks when needed;
3. run the broader governing gate once when required.

Required plan gates must still run even when narrower earlier evidence passed.

## Host and Wrapper Noise

Distinguish target validation failure from unrelated host, shell-wrapper, WSL,
PowerShell, terminal, or stderr-formatting noise.

Determine validity from whether the intended command executed, its exit status,
test assertions, required summary, and whether the host issue could have
altered execution.

Do not rerun a passing test merely to obtain cleaner output when unrelated host
noise leaves the actual result unambiguous.

Expected stderr from a deliberately exercised failure path is not itself a test
failure.

When practical, capture explicit exit status with validation evidence.

If host behavior makes the result genuinely ambiguous, invalidate and rerun only
the smallest affected validation surface.

Token, runtime, or orchestration efficiency must never justify skipping,
merging away, substituting, or inferring passage of a test, validation, review,
or gate explicitly required by the governing implementation plan.

Evidence reuse applies only when the earlier evidence actually satisfies the
same required contract and has not been invalidated.

A distinct later or independent gate required by the plan must still run.

## Working Rules

Keep changes focused and preserve unrelated user work. Perform verification appropriate to the risk and scope of the task. Do not claim unrun checks passed, hide blockers, or broaden the task without a clear need.

Prefer one targeted inspection batch over a sequence of independent single-file or single-search outer calls. After implementation begins, repeat inspection only when a changed state, failure, or newly discovered dependency provides a concrete reason.

## Blockers

When blocked, record:

- The failed step and exact evidence.
- The suspected cause.
- Completed changes and current repository state.
- The affected acceptance criterion.
- The decision, dependency, or external input required.

Do not disguise partial work as completion. Adjust the plan and preserve a clear continuation point.

## End-of-Session Handoff

Run this section only when the user directly commands the exact phrase `end this session`, ignoring capitalization and surrounding punctuation.

1. Confirm verification occurred after the last relevant code or test change; do not rerun solely because the session is ending.
2. If meaningful project files changed, reuse the session-long explorer for bounded final read-only closure checks—concise status, diff statistics, whitespace or error checks, and unexpected changed surfaces. Do not spawn a separate closure explorer. The main agent still owns targeted critical review, status-document writes, Git staging, and the commit.
3. Reconcile `project_progress.md` with the final execution state if its
recorded state changed. If the governing plan is complete, retain a compact
completed-state record containing the plan identity, accepted high-level
outcomes, final verification, authorization-limited validation not performed,
remaining manual/external validation, and residual risks or blockers if any.
If incomplete, record current verified status, blockers, and next action. Do
not empty useful completed-state information merely because the session ended.
4. Replace `latest_session_work.md` only when unfinished work or durable
cross-session continuation state remains. Do not create a redundant completed
plan summary there when `project_progress.md` already contains the completed
state and no continuation work remains.
5. Update durable docs only when warranted and `project_diary.md` only for significant decisions or lessons.
6. Stage only files owned and changed by the active session. Never use `git add .` or another repository-wide staging command. Use explicit paths, then inspect the staged file list and run `git diff --cached --check` before committing. Do not stage or commit pre-existing, unrelated, generated, temporary, or user-owned changes. If session-owned changes cannot be separated safely from unrelated work, leave them uncommitted and report the condition. `end this session` authorizes handoff and cleanup, not a Git commit. Commit only when the user explicitly requests a commit or the active governing contract already grants that authorization.
7. Include the persistent explorer in the final agent-usage table as a `companion` with its call count, even though no worker subagents were used. Omit roles with zero calls.

If no explorer was initialized during the session, do not create one solely
for closure. The main agent performs the compact closure checks directly.

If no meaningful project files changed, do not request a closure audit from the explorer and there is no need to refresh `latest_session_work.md`.

Every completed session must leave honest status, bounded changes, current verification, preserved user work, and a clear continuation point.
