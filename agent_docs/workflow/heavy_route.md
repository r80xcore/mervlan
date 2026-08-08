# Heavy Route

Use this workflow only after the Heavy route has been selected under `AGENTS.md`.

## Main-Agent Role

You are the main agent. Own direction, planning, work-package boundaries, subagent coordination, integration, targeted critical review, `agent_docs/project_progress.md`, and `agent_docs/latest_session_work.md`.

Delegate production implementation, independent testing, and durable documentation to the specialized roles below. Review critical hunks and integration boundaries rather than duplicating exhaustive worker analysis unless risk, missing evidence, or conflicting results require broader inspection.

Keep the deployment session's single `explorer` thread alongside the main agent throughout the Heavy route. It acts as a read-only secretary and second brain: it absorbs bounded supplementary context as needs arise, retains relevant findings within its thread, and returns compact, decision-oriented briefs so the main agent can focus on critical context, integration, and decisions. It does not own scope or decisions and does not replace the main agent's direct reading of foundational documents or central implementation boundaries.

In this route, for common queries, it's not necessary to implement complex workflow or call subagents for simple tasks.

## Plans and Status Writes

When the user requests an implementation plan, create or persist the plan.
Begin implementation only when the user explicitly requests execution or
the request clearly and unambiguously asks for both planning and execution.
Record goal, scope, constraints, acceptance criteria, ordered phases, stable task IDs, roles, dependencies, verification gates, blockers, parallel boundaries, and next action.

## Compact execution state

For long plans, read the complete active plan and stable project guidance
once, then maintain a compact working state containing:

- current round, package, and gate;
- accepted contracts and frozen decisions from completed gates;
- active worker and file ownership;
- unresolved defects, blockers, and material risks;
- required tests and evidence;
- evidence already accepted and the code state it covers;
- next action.

Update this state only at material transitions. It is a working cache and
does not replace or supersede the governing plan.

Do not reread the full plan, stable guidance, completed worker reports, or
unchanged source merely to refresh context. Reopen only the relevant section
when new evidence, source drift, a failed gate, or a material conflict
requires it.

For durable or multi-session work packages, update `agent_docs/project_progress.md` at most twice:

1. Mark the package active and record its bounded plan.
2. Reconcile final status, verification evidence, blockers, and next action.

Do not update it after every checkpoint. Preserve traceability when a plan changes.

When a governing implementation plan reaches final acceptance, reconcile
`agent_docs/project_progress.md` into a compact completed-state record.

The completed-state record should contain only information useful for future
work:

- governing plan identity;
- status: completed;
- important accepted contracts or architectural outcomes;
- final verification summary and evidence location when useful;
- authorization-limited validation that was not performed;
- remaining manual, live-device, browser, deployment, or external validation;
- any genuine residual risk or follow-up.

Do not preserve transient round scratch, worker chatter, or repeated test output
in the completed-state record.

Do not clear a useful completed-state record merely because execution ended.

When a later governing implementation begins, replace the old completed-state
record with the new active implementation state after preserving any
still-relevant durable architecture in the appropriate durable project
documentation.

Do not write status documents for short-lived packages. Write or replace `agent_docs/latest_session_work.md` only when unfinished work or durable
cross-session continuation state remains, or when the user explicitly requests
a handoff that requires it. If the governing implementation is complete and no
unfinished continuation state exists, do not create redundant completed-work
history there. Replace rather than accumulate; do not use it as live scratch state.

## Durable Project Knowledge

The generic `agent_docs` knowledge documents are durable project context, not
live execution journals.

Their intended responsibilities are:

- `project_overview.md` — stable project purpose, major behavior, and high-level
  architecture;
- `project_core_tech.md` — unusual platform, runtime, toolchain, compatibility,
  or technology constraints;
- `project_structure.md` — durable module/component boundaries, important
  directories, and ownership relationships;
- `project_diary.md` — significant architectural decisions, rejected
  alternatives, and lessons with future value;
- `project_progress.md` — current or most recently completed governing
  implementation state;
- `latest_session_work.md` — unfinished cross-session continuation state.

A file containing only its heading, placeholder text, or no substantive project
information is uninitialized and must not be treated as authoritative.

Do not interrupt ordinary implementation merely to populate empty generic
documentation.

Read a durable knowledge document only when it is relevant to the current work.

After verified implementation introduces a durable change to:

- project-wide architecture;
- module or subsystem ownership;
- repository structure;
- important runtime/platform constraints;
- public workflow or behavior;
- compatibility/recovery semantics;
- a significant architectural decision;

update only the affected durable knowledge documents.

Do not copy into durable knowledge documents:

- round-by-round execution history;
- temporary reasoning;
- raw logs;
- test output;
- transient worker state;
- complete `project_progress.md` content;
- implementation details unlikely to matter to future work.

For a coherent multi-round implementation that produces several durable
changes, prefer one bounded documentation package after verification rather
than repeatedly updating generic knowledge files after every round.

Under Heavy Route, durable-document work may be delegated to `doc-writer`, but
the parent remains responsible for deciding which durable facts are accepted
and which documents actually require updates.

`project_progress.md` and `latest_session_work.md` remain exclusively under
main-agent authority.

## Delegation

The persistent explorer companion is not a worker subagent and is excluded from the concurrency limit below. Use a proportionate number of workers based on task scope, complexity, and opportunities for meaningful delegation, but limit to maximum 5 concurrent worker subagents:

- `executor_luna`: default production implementation.
- `executor_terra`: escalation executor for difficult bounded production work
  that cannot be completed efficiently or reliably through the normal Luna
  path; normally no more than one active Terra executor.
- `executor_sol`: rare specialist executor for exceptional cross-cutting work
  where concrete evidence justifies Sol specifically; never more than one.
- `tester`: focused independent tests and failure analysis.
- `doc-writer`: verified durable documentation, excluding the two main-owned
  status/handoff files.

Executor model choice does not transfer architectural or orchestration
authority. The main agent always owns package scope, architecture, integration,
gate acceptance, Git state, and final evidence.

### Executor escalation hierarchy

Production implementation follows this default hierarchy:

1. `executor_luna`
2. `executor_terra`
3. `executor_sol` only when specifically justified

Always prefer the cheapest role that can safely and reliably complete the
package.

`executor_luna` remains the default. Do not start with Terra or Sol merely
because the overall plan is large or important.

Escalate a package from Luna to Terra when concrete evidence shows that further
Luna work is likely to cost more, create avoidable repair loops, or reduce
implementation confidence. Relevant evidence includes:

- Luna reaches the worker replacement or stall threshold;
- Luna repeatedly fails the same acceptance criterion after an evidence-backed
  repair attempt;
- Luna identifies a genuine implementation blocker requiring substantially
  deeper cross-file reasoning;
- the package contains tightly coupled invariants that cannot be narrowed
  further without increasing integration risk;
- the parent determines from concrete source evidence that a bounded package
  requires unusually difficult production reasoning.

A single defect, failed test, large diff, or ordinary repair loop is not enough
by itself to require Terra.

Escalation does not broaden the package. Terra inherits the same governing
contract, package ownership, protected areas, and acceptance criteria unless
the parent explicitly recoordinates them.

### Sol exception threshold

`executor_sol` is not an automatic escalation after Luna or Terra.

Use Sol only when concrete evidence establishes that its additional independent
reasoning path is worth the extra context and coordination cost.

Valid reasons include:

- Terra reaches a genuine material blocker after an evidence-backed attempt;
- the package is exceptionally broad and cross-cutting and cannot be narrowed
  safely enough for the normal Luna or Terra execution shape;
- Luna and Terra have independently converged on the same unresolved defect or
  contradiction and model diversity has clear diagnostic value;
- the governing implementation requires an unusually difficult compatibility,
  migration, recovery, concurrency, or integration problem for which the
  current evidence indicates a distinct specialist pass is warranted;
- the parent can state a concrete reason why Sol is expected to add information
  or capability not already obtained from Luna and Terra.

Do not use Sol:

- merely because the task is difficult;
- merely because Terra is the parent model;
- merely because Luna produced a defect;
- merely because a gate is important;
- merely to obtain another opinion;
- as a ceremonial final review;
- when another bounded Luna or Terra repair would be sufficient.

Before spawning `executor_sol`, the main agent must be able to state in the
task capsule or execution state the concrete evidence that justified Sol.

Sol may be selected without a preceding Terra attempt only when existing
evidence already satisfies the Sol exception threshold and running Terra first
would clearly duplicate work rather than reduce uncertainty.

Never run more than one `executor_sol`.
Every worker spawn and the initial creation of the explorer companion must use fork_turns="none". The initial task capsule must be self-contained and at most 400 words. Use these fixed fields: task ID, outcome, ownership, acceptance criteria, source paths, validation, protected areas, and return format. Include only the minimum initial context grouped as:

- documents to read;
- source files, tests, interfaces, or call sites to inspect;
- the expected edit surface, or investigation scope for read-only roles;
- important protected or out-of-scope areas.

The task capsule defines the worker's strict context, working scope, acceptance criteria, and assigned surface; the main agent owns all four. For the persistent explorer, the initial capsule establishes its session-long read-only role and investigation focus; each later request supplies the next focus rather than a hard reading boundary. The explorer may follow directly related files, symbols, call sites, documentation, dependencies, and configuration without requesting a new scope delta, provided the investigation remains read-only, relevant, and proportionate. Do not repeat the conversation, stable role rules, project summaries, recorded requirements, or exhaustive test matrices in a capsule. Worker subagents may inspect adjacent dependencies only to diagnose a blocker, but must not expand their edit scope themselves. They report the blocker, concrete evidence, and proposed files to the main agent, then wait for a re-coordinated next iteration that explicitly amends scope and ownership. The main agent is responsible for resolving overlap before issuing that iteration.

Once initialized, reuse the explorer thread throughout planning,
implementation, verification, integration, and handoff. Send that same thread
every bounded investigation of peripheral or unfamiliar code, tools,
applications, libraries, configuration, or newly discovered context.
Do not create another explorer or run multiple explorer threads in parallel.
Core project documents, core modules, and components central to the current
work must still be read directly by the main agent.

Start with `executor_luna` for production implementation unless existing
evidence already satisfies a higher executor's explicit activation threshold.

Use `executor_terra` as the normal escalation path for difficult bounded
implementation. Use `executor_sol` only under the Sol exception threshold;
Sol must never become the routine replacement for Luna.

Spawn the tester only after the active executor hands off completed
implementation with its smallest relevant self-check, unless parallel test
research has clear independent value.

Delegate documentation after verification and only for durable architecture,
structure, workflow, public behavior, decisions, or usage changes.

Split executor packages only when modules and files are genuinely independent;
do not maximize concurrency for its own sake. This worker-concurrency
restriction does not prohibit local batching of independent tool calls inside
the active agent thread.

Assignments and follow-ups must be deltas, normally no more than 120 words.
Exceed that default only when necessary to communicate a material scope change,
new safety constraint, failed gate, unresolved contradiction, or evidence needed
for the worker's next decision. Do not resend stable context, the conversation,
full test matrices, completed reports, or unchanged requirements. A follow-up
should normally contain only the work-package ID, iteration, changed files or
state, new evidence, affected acceptance criterion, and next action.

Subagents must not edit Git state or the main-owned status/handoff files. Worker communication is event-driven. Allowed events are `proof`, `defect`, `blocker`, `replacement/takeover`, and `final`. Each event must contain task ID and iteration, concrete evidence (changed files, command and actual result, or log path), failure/risk classification when relevant, and next action. Worker event reports normally remain within 100 words and final reports within 250 words. Intent-only updates such as â€œimplementing nowâ€ are not checkpoints.

## Local Tool-Call Batching

Worker-concurrency limits govern the number and lifecycle of worker subagents; the persistent explorer companion is excluded. These limits do not prohibit independent tool-call concurrency inside one agent thread.

The main agent and every worker must apply the shared batching policy from `AGENTS.md` within each bounded stage.

Typical batches include:

- Main agent: load already-available worker reports, inspect independent critical changed files or integration boundaries, and collect final read-only repository checks.
- Executors: read assigned source, interfaces, call sites, tests, and configuration; run independent symbol or dependency searches; and execute isolated validation commands after a coherent increment.
- Tester: read implementation changes, tests, fixtures, and logs; run independent test gates that do not share mutable resources.
- Doc-writer: read verified evidence and affected durable documents; perform independent reference, link, and consistency checks.

Agent lifecycle operations remain sequential and event-driven. Do not batch worker spawning, waiting, resuming, follow-up messages, replacement, takeover, or executorâ€“tester repair-loop transitions merely to increase concurrency.

Do not repeat this stable batching policy in task capsules or follow-up deltas. Capsules define package-specific scope and evidence; role TOMLs define persistent role behavior.

## Thread Lifecycle and Waiting

Once initialized, reuse the same explorer thread for the entire deployment
session, including route changes between Medium and Heavy. Send every later investigation to that thread as a bounded delta. If the explorer must be replaced under the lifecycle rules below, the replacement becomes the sole explorer companion for the remainder of the session.

Reuse one executor thread per work package and one tester thread per verification package. Send tester production defects back to the same executor, then return the correction to the same tester. Repair loops respond only to new evidence.

A tester-reported production defect does not by itself justify changing
executor models. Return the defect to the same executor first.

Escalate Luna to Terra only when the new evidence meets the Terra threshold.
Escalate to Sol only when the separate Sol exception threshold is satisfied.


### Active worker waiting

Starting a required worker is not completion of the parent turn. A worker state
such as `started`, `working`, `verification running`, `waiting`, or equivalent
is an intermediate orchestration state and must not by itself cause the main
agent to return control to the user.

When a required worker is active, remain in the orchestration loop until that
worker:

- produces a final result;
- reaches a lifecycle threshold requiring retry, replacement, escalation, or
  takeover; or
- exposes a genuine blocker requiring user input.

Use bounded waits of about 60 seconds. If a wait returns while the worker is
still active and no final result or actionable failure has been produced,
continue waiting in the same active turn when runtime permits. An ordinary wait
timeout is not a reason to produce an interim completion response.

After a worker finishes, immediately process its evidence and perform the next
required orchestration action. This includes, as applicable:

- returning a production defect to the responsible executor;
- sending the corrected implementation back to the same tester;
- completing a repair/reverification loop;
- accepting or rejecting the current gate;
- starting the next authorized work package or round.

A worker completion, test completion, passed internal gate, round boundary, or
other ordinary implementation milestone is not by itself a reason to end the
parent turn.

Do not voluntarily return control to the user while authorized work can
continue without user input. Return control only when:

- the requested implementation is complete;
- explicit user authorization is required;
- a material decision or conflict requires user input; or
- a genuine blocker cannot be resolved within the authorized workflow.

If the platform itself forcibly terminates the active model turn, preserve the
current compact execution state so the next continuation can resume without
reopening accepted work. Do not deliberately emulate such a boundary merely to
report progress.


### Production executor replacement and escalation

Reuse one executor thread per work package while that executor is making
evidence-backed progress. A scoped defect or failed check normally returns to
the same executor.

If an executor returns no concrete evidence, send one short delta retry. A
second consecutive evidence-free turn requires replacement or escalation.

For a production package:

- replace a stalled `executor_luna` with `executor_terra` when the Terra
  activation threshold is satisfied;
- otherwise a fresh Luna replacement may be used when the failure appears to be
  thread-specific rather than complexity-related;
- replace a stalled `executor_terra` with a fresh `executor_terra` after the
  evidence-free replacement threshold; escalate Terra to Sol only when new
  concrete evidence independently satisfies the Sol exception threshold;
- do not automatically replace Terra with Sol;
- use Sol only when the Sol exception threshold is independently satisfied.

If the Terra replacement also reaches the evidence-free threshold and Sol is not
specifically justified, the main agent transparently takes over the package or
reports the blocker rather than spawning Sol merely as another retry.

When handing an existing package to a stronger executor, provide a compact
takeover capsule containing only:

- task ID and current iteration;
- unchanged governing acceptance criteria;
- current owned edit surface;
- files already changed;
- successful evidence that should be preserved;
- exact failed or unresolved evidence;
- the reason for escalation;
- the next required result.

Do not resend the full conversation, full implementation plan, completed test
history, or unchanged project guidance.

If the normal execution path is exhausted and Sol is not specifically
justified, the main agent may transparently take over the package rather than
spawning Sol merely as another retry.

Rely on agent events instead of filesystem or status polling to determine worker
progress. Do not run filesystem or repository-status checks merely to determine
whether a worker has started or finished. User-facing progress updates may be
given at meaningful state transitions, but such an update must not terminate the
active orchestration turn when authorized work can continue.

Store temporary output under `.tmp/<task-id>/` using unique filenames.

The parent must confirm once per deployment session that `.tmp/` is ignored
by Git before any worker writes there. Workers must never stage or commit
`.tmp/`. If it is not safely ignored, use the operating system's temporary
directory instead. Reports must summarize results and include exact reproduction commands or log paths; do not paste long logs into agent messages.

## Execution and Verification

1. Executor implements a coherent increment and runs the smallest relevant check.
2. Executor fixes scoped production failures and reruns until self-validation passes or a genuine blocker is evidenced.
3. Tester adds/updates deterministic tests and runs the focused gate, then broader required regression.
4. Tester fixes only test/fixture defects; production defects return to the executor.
5. Repeat only in response to new evidence. Never weaken validation or claim unrun checks passed.

### Evidence reuse and rerun discipline

Successful validation evidence remains valid for the exact production code,
tests, fixtures, environment, and accepted contract state it covers.

Before rerunning an already-passing validation set, identify what invalidated
that evidence. Valid invalidators include:

- a relevant production-code change;
- a relevant test, fixture, mock, or test-configuration change;
- an environment change capable of affecting the result;
- conflicting new evidence;
- a changed integration dependency;
- a governing-plan requirement for a distinct later gate.

If none of these applies, reuse the accepted evidence.

Do not rerun a complete passing validation set merely to:

- obtain reassurance;
- obtain cleaner-looking output;
- refresh log files;
- relabel equivalent evidence as `final`, `final-2`, or similar;
- prepare a worker handoff;
- prepare a round summary;
- precede independent tester verification;
- compensate for a parent-response or session boundary.

After an executor has current passing self-validation covering its latest
production state, hand the package to the independent tester rather than
creating additional equivalent production validation passes.

After a production repair, validate incrementally:

1. rerun the previously failing selector or smallest deterministic reproducer;
2. run directly affected dependent checks when the repair could affect them;
3. run the governing focused gate or broader regression once when required by
   the implementation plan.

Previously accepted unaffected evidence remains valid.

This evidence-reuse rule must never replace a distinct independent tester gate,
a broader gate explicitly required by the governing plan, or validation whose
covered code or dependencies changed after the earlier evidence was produced.

### Host and wrapper noise

Distinguish target-test failure from host, shell-wrapper, WSL, PowerShell,
terminal, or stderr-formatting noise.

Judge validation primarily from:

- whether the intended command actually executed;
- its exit status;
- test assertions;
- the required pass/fail summary;
- whether host noise could have prevented, truncated, or altered execution.

Do not rerun an otherwise valid passing test solely to obtain cleaner output
when unrelated host noise does not make the result ambiguous.

Expected stderr produced by a negative-path test is not itself evidence that
the test failed.

When practical, evidence capture should record the command exit status
explicitly so that:

- an empty successful `sh -n` output;
- expected stderr;
- PowerShell `NativeCommandError` presentation;
- harmless WSL startup diagnostics;

cannot be mistaken for missing or failed validation.

If host or wrapper behavior genuinely makes execution or the result ambiguous,
invalidate only the affected evidence and rerun the smallest validation surface
needed to establish an unambiguous result.

Do not invalidate unrelated passing evidence merely because another command in
the same round encountered host noise.

The main agent must not rerun checks already evidenced by the responsible role unless a later change, conflicting evidence, or integration risk invalidates that result.

Token, runtime, or orchestration efficiency must never justify skipping,
merging away, substituting, or inferring passage of a test, validation, review,
or gate explicitly required by the governing implementation plan.

Evidence reuse applies only when the earlier evidence actually satisfies the
same required contract and has not been invalidated.

A distinct later or independent gate required by the plan must still run.

Keep changes within plan boundaries. Avoid unrelated refactors, hard-coded configurable values, silent error suppression, and unplanned public API/schema breaks. Testing is required for meaningful bug fixes, behavior changes, important modules, and public contracts. Prefer local deterministic fixtures over network dependencies.

Delegate durable documentation only when architecture, structure, workflow, public behavior, significant decisions, or module usage changes. Provide verified facts and exact target files.

In the final session report, report explorer-companion usage separately from worker-subagent usage. Use a simple table with the explorer labeled as `companion`, the worker roles (`executor_luna`, `executor_terra`, `executor_sol`, `tester`, `doc-writer`), and the number of times each was called. Omit roles with zero calls.

## Blockers

Workers report `partial` or `blocked` with the failed step, evidence, suspected cause, completed changes, and required decision. The main agent records material blockers and adjusts the plan. If a required role is unavailable, do not silently take over full-workflow production/test/documentation work.

## End-of-Session Handoff

Run this section only when the user directly commands the exact phrase `end this session`, ignoring capitalization and surrounding punctuation.

1. Collect checkpoints only from running or incomplete workers.
2. Confirm verification occurred after the last relevant code/test change; do not rerun solely because the session is ending.
3. Complete warranted durable documentation first.  If a doc-writer thread already exists, it may perform compact read-only integrity checks; do not spawn one solely for status checks.  Update `project_diary.md` only for significant decisions or lessons.
4. If meaningful project files changed, reuse the session-long `explorer` for a bounded `SESSION-CLOSURE-AUDIT`; do not spawn a separate closure explorer.  The explorer performs read-only repository closure checks and returns directly to the main agent; it must not edit files, Git state, `project_progress.md`, or `latest_session_work.md`.
5. Always collect status, changed-file statistics, diff-check results, unexpected changed surfaces, and blockers. Inspect largest files and generated or ignored payloads only when new untracked/generated files exist, changed size is abnormal, or another signal suggests repository pollution. It may confirm existing verification evidence and report paths but must not rerun tests solely for closure or review central implementation correctness.
6. Require a compact explorer final, normally no more than 150 words, containing:
`status`, `changed_files`, `insertions`, `deletions`, `diff_check`,
`unexpected_scope`, and `blockers`.

Include `largest_unignored_file` and `generated_payloads` only when those
checks were triggered under the previous step. Do not request full file
listings unless an anomaly is found. The explorer may exceed the default only when an anomaly, unexpected scope,
repository pollution, or blocker cannot be reported safely within it. Long file
lists and raw command output still belong in referenced artifacts or paths.
7. The main agent consumes that audit without repeating the same repository-wide status, diff-stat, or large-file scans unless the explorer reports a defect, evidence conflicts, or later unexpected changes invalidate the audit.  The main agent still performs targeted critical review and owns the final scope decision.
8. Reconcile `project_progress.md` with the final execution state when its recorded state changed. If the governing plan is complete, retain a compact completed-state record containing the plan identity, accepted high-level contracts, final verification, authorization-limited validation not performed, remaining manual/external validation, and residual blockers or risks if any. If the plan is incomplete, record current verified status, blockers, and the next action. Do not empty useful completed-state information merely because the session is ending. These status writes remain exclusively under main-agent authority.
9. Replace `latest_session_work.md` only when unfinished work or durable cross-session continuation state remains. Do not create a redundant completed plan summary there when `project_progress.md` already contains the completed state and no continuation work remains.
10. After the main-owned status writes, run only compact checks needed to cover those predictable edits.  Escalate to broader inspection only on failure or unexpected scope.
11. Stage only files owned and changed by the active session. Never use `git add .` or another repository-wide staging command. Use explicit paths, then inspect the staged file list and run `git diff --cached --check` before committing. Do not stage or commit pre-existing, unrelated, generated, temporary, or user-owned changes. If session-owned changes cannot be separated safely from unrelated work, leave them uncommitted and report the condition. `end this session` authorizes handoff and cleanup, not a Git commit. Commit only when the user explicitly requests a commit or the active governing contract already grants that authorization.

If no explorer was initialized during the session, do not create one solely
for closure. The main agent performs the compact closure checks directly.

If no meaningful project files changed, do not request a closure audit from the explorer and no need to refresh `latest_session_work.md`.

Every completed session should leave honest status, bounded changes, current verification, preserved user work, and a clear continuation point.
