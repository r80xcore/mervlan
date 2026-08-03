# Plan 02 — action serialization and liveness

Priority: 2 — operational safety and user-visible completion

Audit items: #7 indefinite local manager wait, #9 frontend second action, #10
stuck progress-backed actions, and #15 inherited stdin/job-directory cleanup.

Dependency: complete the ownership changes in Plan 1 first. The global action
gate must use the corrected owner-aware lock API.

## Objective

Ensure a mutating action has one authoritative owner, one bounded execution
lifecycle, one explicit terminal result, and one correct UI release path. A
browser timeout, a detached child, a missing PID, or a lost iframe must never
be interpreted as success or leave the system permanently “working”.

## Owning code and contracts

Trace each action from `www/index.html` through `mervlan.asp`,
`functions/service-event-handler.sh`, the action worker, progress/ack/result
writers, and the final UI poll. Include all three Apply modes, Save, Sync
Nodes, MAC refresh, hardware actions, maintenance actions, and observation
actions. Include the Plan 1 SSH trust probe/enrollment actions and the
`action_result.json` polling they use. The runtime flow requires one final
client refresh for Apply and an explicit terminal result for every asynchronous
operation.

## Implementation sequence

### 1. Define the backend serialization policy

1. Enumerate action identifiers from the service handler and loading
   configuration. Classify them as mutating, observation-only, or read-only.
   Mutating actions include settings/network changes, node sync/execute,
   maintenance/restore/update/delete, MAC/QT rebuild, and hardware changes.
2. Add one canonical backend global action lock or extend the corrected shared
   lock API. Acquire it at the documented position in the lock-order graph,
   before starting a mutating worker and before claiming the progress token.
   Read-only status and log operations may continue, but observation work must
   continue to use its own serialization contract. Before coding, record the
   complete graph with Plan 1. Do not assume this lock is always acquired
   first: preserve the existing observation ordering and ensure maintenance,
   manager, execute, sync, observation, and DHCP locks cannot be acquired in a
   cycle.
3. If the lock is busy, return a structured terminal “busy” response with no
   worker or mutation started. If the caller already supplied a progress token
   because the browser opened its loading state first, publish a terminal
   `busy` record for that exact token or return a response that the ASP bridge
   deterministically maps to the same terminal state. Never leave a supplied
   token active while claiming that no token exists. Do not make the UI infer
   busy from an empty response. Use the existing acknowledgement/progress
   response schema, including action, token/run identity where applicable,
   terminal state, and a user-safe message, so the ASP bridge and every
   JavaScript caller handle the result consistently.
4. Keep action-specific locks for deduplication where useful, but never treat
   them as a substitute for the global mutation gate. Update the service
   handler, ASP bridge, progress/ack code, and loading configuration together.
   For composite actions such as Save followed by an Apply-like follow-up,
   either hold the same parent-owned lock across the whole workflow or publish
   a terminal Save result before explicitly reacquiring the lock for the
   follow-up. Do not let the follow-up race the save or silently inherit a lock
   it does not own.
5. Ensure the parent owns the global lock and releases it only after worker
   reconciliation, final verification, final observation where required, and
   terminal progress publication. A worker or cleanup trap must not release it
   on behalf of the parent, and an ownership-check failure must not be silently
   converted into successful completion.

### 2. Make the frontend gate authoritative for interaction, not safety

1. Add a single browser-level action gate for mutating actions. Keep the
   existing per-action guard for duplicate-click UX, but have
   `queueServiceAction` stop immediately when `MerVLANLoading.start()` returns
   `null` or when another mutating token is active.
2. Do not submit a second action merely because it has a different action name.
   Show the existing busy/active message and leave the current token owned by
   the original action.
3. Associate every poll, completion, failure, timeout, and button release with
   its token. A late response from an older action must not complete or unlock
   a newer action.
4. Ensure every asynchronous poller has at most one request in flight. This
   includes progress polling, fresh-client polling, and Apply-guard polling.
   Use an in-flight flag, a completion-driven timer, or an equivalent bounded
   cancellation mechanism; do not leave `setInterval(async ...)` requests to
   overlap. A slow response must not consume multiple retry slots or publish
   out-of-order state.
5. Preserve the existing exception and navigation cleanup behavior. A frontend
   gate is only a user experience guard; backend serialization remains
   mandatory for refreshes, direct requests, and multiple browser tabs.
6. Include the update modal's separate spinner/log-polling flow in the same
   mutating-action gate. The encoded `MVM_updateRef` hidden-frame request must
   carry the action identity into transport-unknown and late-completion
   handling; `loading: false` must not make it invisible to serialization or
   allow Apply/Restore/Update overlap.

### 2a. Integrate the SSH trust prompt without holding a backend lock

Plan 1 owns host-key semantics and the actual trust records. This plan owns
the action lifecycle around the user decision. Implement the following
contract in `www/index.html`, `mervlan.asp`,
`functions/service-event-handler.sh`, `settings/lib_action_ack.sh`, and
`www/settings/loading_actions.json`; coordinate transport-field stripping in
`functions/save_settings.sh` and the Plan 1
`functions/ssh_trust_action.sh` worker so a trust decision cannot become
persistent settings data:

1. Treat `ssh_trust_required` as a typed, terminal “blocked before mutation”
   result. It is not success, and it is not a generic transport failure. The
   result must include a server-created pending ID, one-use challenge IDs and
   sanitized node display data needed by the trust modal, the original action
   name, the node scope, and a safe user message. The immutable original action
   and payload remain on the router; they are not returned as browser-
   controlled retry data. If a node has only `auth_failed`, `unreachable`,
   `capability_unknown`, or `probe_failed`, return setup/capability guidance
   without an approval modal or fabricated challenge; only a valid presented
   key may reach Yes/No enrollment.
2. The Plan 1 parent-level preflight must run before any worker pool, local
   manager, operation-specific mutation guard, main-router change, or
   DHCP/VLAN/MAC Shield/cleanup/reprovisioning mutation. If a required node is
   not verified, the parent performs no such mutation, publishes the typed
   terminal result, exits any workers, releases every global and operation
   lock/guard it owns, and leaves no process waiting for browser input. The
   command/transfer wrapper checks remain defense in depth, not the lifecycle
   gate.
3. Before publishing the terminal result, persist the server-side immutable
   pending request described by Plan 1. The browser stores only the pending ID
   and challenge IDs needed to render/submit the modal. It submits a separate
   correlated enrollment/update action with decisions only; it must not
   reconstruct or modify the original action, node set, payload, endpoint, or
   fingerprint. The enrollment action has its own token and global
   serialization rules, revalidates every challenge on the router, and must
   release its lock before any later retry dispatch.
4. Enrollment is all-or-nothing across the complete required-node set. A
   failed re-probe, changed key, No decision, stale/duplicate challenge, or
   malformed result discards the staged trust database and leaves all existing
   pins unchanged. No partial node operation may start. On success, the
   backend returns a one-use resume ID; the browser submits only that ID to
   `sshtrustresume_vlanmgr`. The backend loads the stored original request,
   validates expiry/status/attempt count and the committed pins, increments
   the counter before dispatch, and creates a fresh action/progress token. It
   reconstructs the original action itself and permits at most one retry. On
   No, mismatch during the gap, stale challenge, busy backend, or enrollment
   error, cancel the pending intent and leave the original node operation
   unstarted. A late result from the cancelled intent must not unlock or
   complete a newer action.
5. Maintain one frontend `trustDecisionPending` state for the whole modal and
   enrollment lifecycle. While it is active, block every new mutating action
   from every button/form path, including Save, Apply, Sync, Update, Restore,
   and Auto-sync, while still permitting read-only status/log requests. A
   second tab or duplicate button must reuse the same server pending request
   or receive `ssh_trust_pending`; it must not create a competing challenge
   set or operation. Yes/No controls and resume submission are one-use, and a
   close/No path must explicitly cancel without changing pins.
6. Save completion must be terminal before its post-save trust probe starts.
   Auto-sync and other composite follow-ups must wait for the probe/modal
   outcome; they must not begin from a stale Save callback while the modal is
   open. A successful Save remains a successful settings save even when the
   optional probe reports unreachable nodes, but no dependent node mutation
   may start until trust is resolved.
7. Extend the correlated result poller used by the existing verified hardware
   and service actions so it can distinguish `ok`, `partial`, `error`,
   `ssh_trust_pending`, `expired`, and the
   `error_code=ssh_trust_required` result. Prevent overlapping fetches, reject
   old tokens, and make a missing or malformed result transport-unknown rather
   than an implicit approval. An `expired` or stale challenge must close the
   trust-decision state without enrollment or retry and require a fresh probe.
   The popup must be opened only from a matching backend result, never from a
   shell log string.

### 3. Add a bounded local-manager supervisor

1. Replace the unconditional local-manager `wait` in `execute_nodes.sh` with a
   portable supervisor using `MERV_MAIN_MANAGER_MAX_SEC` from Plan 3. Do not
   add GNU `timeout`, `wait -n`, or a Bash dependency.
2. Record the child PID and process start identity before supervision. Poll an
   absolute deadline using validated numeric values. If the manager exits,
   require and validate its return marker/result; an absent marker is failure.
3. On deadline: TERM only the matching process tree/known descendants, wait a
   bounded interval, KILL only while identity still matches, verify wrapper and
   tracked child exit, and publish one terminal failure. Reap the wrapper and
   keep the parent lock until reconciliation is complete.
4. Preserve DHCP Hold/MAC Shield/recovery behavior. A local-manager timeout
   must not release safety state or report a successful Apply. The final Apply
   observation must run only after a verified manager success.
5. Set and document a distinct local-manager deadline separate from node launch,
   node preparation, node completion, node synchronization, SSH connection, and
   final observation deadlines. Use the timeout matrix from Plan 3; never reuse
   the node preparation timeout as a local-manager or remote-launch timeout.

### 4. Give progress records a recoverable lifecycle

1. Extend the progress record with validated owner identity, `started_at`,
   `updated_at`, current phase, deadline, and terminal state. Keep writes
   atomic and reject wrong-token/wrong-action updates.
2. Every parent worker must publish `complete` or `failed` on normal exit,
   caught errors, timeout, missing child, and cleanup failure. A process killed
   with `SIGKILL` cannot publish from its own trap, so boot/heal/service
   recovery or a bounded reaper must detect the dead owner and publish a
   validated `stale`/`failed` terminal record. A missing PID or missing file is
   never normal completion.
3. Add a recovery/reaper path that marks a record `failed`/`stale` only after
   proving its owner is gone or its deadline has expired. Never mark a live
   long-running action stale merely because a fixed wall-clock interval passed.
4. In the browser, use a bounded fetch/poll timeout, handle malformed/missing
   status, and detect no-progress/expired-deadline state. Show a retry,
   transport-unknown, or failure state; do not auto-complete. A transport
   timeout may release only browser presentation state. It must not release the
   backend mutation lock or make a retry look safe while the original action
   may still be running. Release the UI action only after the authoritative
   terminal record is observed or an explicit transport-unknown state is shown,
   and require any later mutation to receive backend busy/in-progress state.
5. Keep Apply loading active through the required final client refresh. A
   progress record must not become complete before manager/node verification and
   the final observation generation are complete.

### 5. Make detached workers noninteractive and retain only safe state

1. Redirect stdin from `/dev/null` for every detached/background worker in
   `lib_node_jobs.sh`, `execute_nodes.sh`, `collect_clients.sh`,
   `mervlan_node_runner.sh`, and any caller found by `rg '\&$|nohup|merv_parallel'`.
   Redirect stdout/stderr to the worker’s isolated files before backgrounding.
2. Reset inherited `EXIT`, `INT`, and `TERM` traps in worker entrypoints before
   work begins. Keep wrapper and tracked-child identity in the job record.
3. Add execute-node and collection job-directory cleanup equivalent to the safe
   sync/node-runner retention model. Prune only validated, terminal, old runs
   below the approved runtime root. Never delete live, malformed, unknown, or
   unverified state. On timeout, explicitly reconcile and reap the wrapper and
   tracked descendants before releasing the parent lock.
4. On cleanup failure, retain the evidence and publish a warning/failure rather
   than broadening the deletion path.

## Tests and acceptance criteria

Add or extend tests for:

- two different mutating action names submitted concurrently from one or two
  browser contexts; only one starts and the other receives structured busy;
- a second action after `MerVLANLoading.start()` returns `null`; no ASP/backend
  submission occurs;
- late poll/completion responses, malformed progress, overlapping slow poll
  requests, fetch timeout, browser navigation, backend busy, transport-unknown
  state, and stale owner state;
- update-modal encoded-ref submission while Apply/Restore/another Update is
  active, including late hidden-frame completion and log-polling cleanup;
- SSH trust-required action results that release every backend lock before the
  modal, preserve the immutable pending request on the router, reject
  stale/foreign/duplicate challenge tokens, serialize the Yes/No enrollment
  action, cancel on No, and retry the original node action once only after all
  required nodes are accepted;
- the frontend trust-decision-pending state blocks mutating actions from
  duplicate buttons/tabs while allowing read-only status, and a resume
  request containing only the backend-issued resume ID reconstructs the
  original action server-side; modified action/payload/node-set data and a
  second retry are rejected;
- expired/stale results close the modal, release browser presentation state,
  invalidate enrollment/resume, and require a fresh probe without leaving a
  backend lock or pending operation behind;
- Save followed by trust preflight and Auto-sync, proving Save reaches a
  terminal result first and Auto-sync cannot race the modal or start on a
  partially trusted node set;
- local manager normal completion, nonzero exit, missing result, hung child,
  deadline, TERM/KILL reconciliation, PID reuse, and lock retention;
- worker stdin that would block if inherited; assert detached workers exit and
  own separate output/result files;
- live, terminal, malformed, wrong-run, and old execute-node job directories;
  only validated terminal directories may be pruned; and timeout cleanup must
  prove wrapper/descendant exit before ownership is released.

Run the local action/progress tests, loading tests, action lifecycle and failure
propagation selftests, observation concurrency tests, node-worker timeout tests,
and `sh -n` for all changed shell files. Validate the browser behavior with a
non-disruptive fake backend before any live action.

## Completion gate

Do not mark this plan complete while any mutating action can start without the
backend global lock, while a local manager can wait beyond its deadline without
a terminal result, while pollers can overlap, or while the UI can unlock/complete
from a missing or stale progress record. A browser transport timeout must also
leave the backend action distinguishable as running, failed, or unknown.
