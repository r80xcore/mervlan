# Plan 01 — fail-closed security and node integrity

Priority: 1 — release/security gate

Audit items: #1 unverified SSH host keys, #2 shared locks/action markers, #3
MAC Shield mutation failures, #4 MAC/QT substring matching, #5 node settings
size mismatch, and #12 remote settings verification fail-open.

## Objective

Make every router-to-node trust, ownership, firewall mutation, and node
configuration verification path fail closed. A command that was not verified
must not be treated as successful, and a process that cannot be identified as
the owner must not be reclaimed or released.

## Owning code and contracts

Start by tracing the current callers and tests for:

- `settings/var_settings.sh` and `settings/lib_ssh.sh` for the persistent
  trust root, host-key probe/enrollment, known-host handling, timeout, and
  all shared SSH wrappers;
- `functions/execute_nodes.sh`, `functions/sync_nodes.sh`,
  `settings/mac_shield_snapshot.sh`, `functions/update_mervlan.sh`,
  `functions/mervlan_boot.sh`, `functions/mervlan_backup.sh`, and the node
  cleanup path in `uninstall.sh`; these include both wrapper calls and direct
  streaming `dbclient` calls that can bypass a command-only fix;
- `functions/dropbear_sshkey_gen.sh`, `install.sh`,
  `functions/mervlan_recover.sh`, and `uninstall.sh` for the distinction
  between the shared client authentication key and the main-router-owned
  node host-key trust records, including preservation and removal policy;
- a new dependency-light action worker, recommended as
  `functions/ssh_trust_action.sh`, for probe/enroll/update dispatch. Keep the
  service-event handler as a validator/launcher; do not put host-key parsing,
  record publication, or browser-result construction directly in its DHCP
  hot path;
- `mervlan.asp`, `www/index.html`, `www/settings/loading_actions.json`,
  `settings/lib_action_ack.sh`, `settings/lib_action_progress.sh`,
  `settings/lib_progress.sh`, `functions/save_settings.sh`, and
  `functions/service-event-handler.sh` for the browser prompt, correlated
  probe/enrollment actions, transport-field stripping, and terminal result
  transport;
- `settings/lib_mervqt.sh`, `settings/lib_action_runtime.sh`, and
  `functions/service-event-handler.sh`, `functions/mervlan_recover.sh`, and
  the maintenance fallback-lock paths in update/backup/recovery scripts;
- MAC/QT calls and the final security gate in
  `functions/mervlan_manager.sh`;
- `verify_file_on_node`, `verify_settings_conf_on_node`, and the callers that
  decide whether to chmod, activate, or start a node manager.

The project rules are part of the acceptance contract: exact ebtables matching,
PID plus `/proc` start identity, parent-owned locks, explicit terminal worker
results, and DHCP Hold release only after final verification.

## Implementation sequence

### 1. Establish one process-identity and ownership record

1. Reuse or extend the existing process-start helper rather than creating a
   second format. The owner record must contain at least `pid`, process start
   identity, a per-acquisition random/unique owner nonce, and creation or
   heartbeat time. Treat absent, malformed, or partially written metadata as
   unknown.
2. Keep `mkdir` as the atomic acquisition primitive. Write metadata through
   same-directory temporary files and atomic renames after the directory is
   claimed. Never make a live lock look stale solely because its age crossed a
   fixed threshold.
3. In `merv_lock_acquire`, reclaim only when the recorded owner is proven dead
   or the record is provably invalid and the documented recovery policy allows
   it. If the PID is alive but the start identity differs, treat it as PID
   reuse and quarantine/reclaim only the validated lock directory.
4. In `merv_lock_release`, require the current PID, start identity, and owner
   nonce to match the record. A child, a later owner, or a malformed record
   must not remove the lock. Return failure and leave the state for recovery
   when ownership cannot be proven.
5. Apply the same identity rules to `lib_action_runtime.sh` markers and the
   service-event handler's `.last`/lock cleanup. Replace time-only event
   reclamation with owner-aware state. For actions that may legitimately run
   longer than the old stale interval, refresh a heartbeat from the owner or
   use an explicit operation deadline; do not increase a stale interval as the
   only fix.
6. Keep cleanup parent-owned. A worker may publish its result, but it must not
   release a parent lock or delete another worker's state.

7. Define and record the lock-order graph before changing any acquisition
   site. Include the global action, maintenance, manager/execute/sync,
   observation, and DHCP state locks. Use the existing observation-order
   contract as an input rather than assuming that the new global action lock
   is always acquired first. Add a deadlock-oriented test for every nested
   path that holds more than one lock.
8. The service-event handler is intentionally dependency-light because it runs
   in a DHCP-sensitive hot path. Do not solve identity checking by sourcing a
   large runtime library there. Extract a minimal safe process-identity helper,
   or keep an exact dependency-free implementation with shared fixtures. If
   `/proc` start identity is unavailable or malformed, treat ownership as
   unknown and do not reclaim or release the lock.
9. Audit every `merv_lock_release` caller and trap. A new ownership failure
   must not be hidden by `|| :` while the caller publishes success. A failed
   release should leave state for recovery and produce an explicit warning or
   inconclusive terminal result according to the action contract.
10. Inventory every ad hoc lock implementation with a static search for
    `mkdir` lock paths, `pid`/`created` metadata, age-based reclaim, and
    recursive lock deletion. Route recovery, update, backup, uninstall, and
    service-event fallback locks through the same ownership contract, or prove
    that a deliberately isolated lock has equivalent PID/start/nonce/release
    semantics.

### 2. Replace SSH host-key bypasses with explicit trust

1. Inventory every production SSH invocation, including Dropbear `dbclient`,
   OpenSSH fallback paths, boot actions, sync, execute, MAC snapshot,
   update/backup/restore, and uninstall cleanup. Route every invocation through
   `settings/lib_ssh.sh` or a narrowly documented adapter that supplies the
   configured identity, bounded noninteractive behavior, and the same host-key
   policy. No production caller may keep a private `dbclient` command line.
2. Define the durable path and record format before changing callers. Add a
   main-router-owned state root, preferably `/jffs/addons/mervlan_state`, with
   `MERV_SSH_TRUST_ROOT` below it, both overrideable for isolated tests. Keep
   this root outside the replaceable `/jffs/addons/mervlan` release tree. Use
   one authoritative BusyBox-safe trust database, for example
   `MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/nodes.tsv"`, with one canonical
   record per stable node identity. Keep server-owned pending requests,
   staging files, and bounded expired-entry quarantine in explicit child
   directories below this root; none is part of the authoritative database.
   The identity is the configured node slot
   plus its configured MAC when available; if no MAC exists, use the slot plus
   the validated endpoint and treat a later endpoint change as a new
   enrollment. Define the canonical file before implementing any parser:
   exactly one `MERV_SSH_TRUST_V1` header followed by tab-delimited records
   with these fields, in this order:
   `version`, `node_id`, `slot`, `mac`, `host`, `port`, `algorithm`,
   `public_key_b64`, `fingerprint_sha256`, `created_epoch`, and
   `updated_epoch`. The stored public key is the authoritative pin and is the
   complete SSH public key material represented by its canonical algorithm plus
   base64 body, with comments omitted. The fingerprint is also stored for
   display/audit, but every load must derive the canonical fingerprint from
   the stored public key and reject the database if the two disagree. Use a
   fixed `SHA256:<unpadded-base64>` fingerprint representation computed over
   the SSH public-key wire-format bytes; if the target cannot produce/verify
   that representation, fail closed rather than mixing fingerprint formats.

   Apply one escaping rule to every textual field: percent-encode UTF-8 bytes
   outside `[A-Za-z0-9._~-]`, use uppercase hexadecimal escapes, and reject raw
   tab, carriage-return, line-feed, or percent characters. Do not permit blank
   lines, comments, extra fields, or locale-dependent numeric formats. Store
   `port` and timestamps as canonical decimal integers; store algorithms in a
   lower-case allowlist with no aliases. Normalize MAC addresses as six
   uppercase hexadecimal octets separated by colons. Normalize the host part
   before it enters the record: IPv4 uses canonical dotted decimal with no
   leading zeroes, DNS names are lower-case with one trailing dot removed, and
   IPv6 is stored in lower-case RFC-5952 form without brackets. Validate ports
   from 1 through 65535 with no leading zeroes; when constructing an endpoint
   key or connection authority, re-add brackets around IPv6 and bind the
   normalized `host` plus `port` rather than the user's original spelling.
   The canonical `node_id` is derived from the validated slot plus normalized
   MAC, or slot plus normalized endpoint when no MAC exists; a later endpoint
   change in the fallback identity creates a new enrollment.

   Require one record per canonical node identity, sorted by that identity.
   Reject duplicate identities, duplicate record keys, conflicting versions,
   malformed escapes, noncanonical values, and duplicate active endpoint/port
   pairs in one required-node set. A malformed or ambiguous existing database
   is a trust failure, not a reason to choose one record. Stage a complete
   candidate database in the same directory, validate every line and the
   deterministic ordering, and atomically replace the whole file; never
   publish one record from a multi-node enrollment while another record is
   still pending. Create the root with mode 700 and the database/staging files
   with mode 600. This trust data is separate from the single shared client
   authentication private key: the client key proves access, while each record
   preserves the identity of that node's SSH server. If Dropbear needs a
   known-hosts file, derive a per-invocation copy from this database only after
   the database has been validated; do not make that derived file the source
   of truth.
3. Probe the actual ASUSWRT Dropbear build before selecting the enforcement
   mechanism. Prove, on every supported target firmware family, all of the
   following for the presented key: (a) the client can obtain and display the
   exact key/fingerprint before acceptance, (b) the fingerprint format can be
   normalized without ambiguity, (c) the displayed key can be correlated to
   the connection that is subsequently accepted, (d) a different key cannot
   be recorded accidentally during enrollment, and (e) no OpenSSH-only
   options are being relied upon. Also prove the known-host file location,
   host-key prompt output, and noninteractive options. Prefer the normal
   Dropbear known-host verification path backed by the persistent trust
   records, with no `-y` on ordinary command or transfer calls. If a temporary
   client home is still needed to avoid firmware write warnings, populate it
   only from the verified record and prove that the client cannot write or
   accept a different key unnoticed. If any of the five capability points
   cannot be proven, return the explicit capability/manual-verification-required
   result and fail closed in this release; do not add an unauthenticated
   free-form fingerprint input or ship an assumed first-contact mechanism. A
   future administrative enrollment path must define its own authenticated
   input and validation contract before it is enabled. Do not assume OpenSSH
   `-o` options work with `dbclient`.
4. Implement the normal user experience as explicit confirmation-based
   first-use trust, not silent first-key-wins. After a valid configuration and
   local SSH authentication key pair exist, a non-mutating probe may connect
   only far enough to obtain the presented host key/fingerprint and classify
   the node. The probe must not execute a node mutation or transfer. Return
   one of `verified`, `unverified`, `mismatch`, `auth_failed`, `unreachable`,
   `capability_unknown`, or `probe_failed`, together with node ID, MAC/IP,
   port, host-key type, presented fingerprint, and (for a mismatch) the
   previously pinned fingerprint. If the firmware cannot expose the presented
   key safely or cannot enforce a stored pin afterward, return
   `capability_unknown`/`INCONCLUSIVE` with manual-verification-required
   guidance and fail closed; never make ordinary SSH use unconditional. The
   current release has no browser fingerprint-entry path that can override
   this result.
5. Put the authoritative trust preflight in the parent orchestration layer,
   not only inside individual `dbclient` wrappers. For every action that can
   touch nodes, compute the complete required-node set once from the validated,
   immutable action request and current settings. The set must include each
   node's stable identity and the endpoint metadata used for the probe; worker
   discovery must not silently add a node after the gate has passed.
   Before starting a node worker pool, local manager, remote command/transfer,
   operation-specific mutation guard, main-router change, DHCP/VLAN change,
   MAC Shield change, cleanup, or reprovisioning mutation, call a parent-owned
   `merv_ssh_preflight_node_set` (or equivalent) for every required node. A
   node-mutating Apply-with-nodes must pass this gate before changing the main
   router as well as before contacting nodes. This explicitly covers
   Apply-with-nodes, Sync Nodes, execute, MAC Shield push/snapshot, and any
   update/restore/uninstall path with a node scope. Local-only actions have an
   empty node set and may skip the SSH portion of the gate.

   The authoritative preflight must be fresh for each node-mutating parent
   action. A bounded cache may be used only within the same pending action or
   its one backend-generated retry, only while its age is below a named limit
   such as `MERV_SSH_PREFLIGHT_MAX_AGE_SEC`, and only when identity, endpoint,
   port, host-key algorithm, and presented/pinned fingerprint metadata all
   match. An endpoint or key change always forces a new probe. The post-Save
   probe is advisory convenience only and never authorizes a later mutation.

   If any required node is `unverified`, `mismatch`, `unreachable`,
   `auth_failed`, `capability_unknown`, or otherwise inconclusive, the parent
   must perform no operation-specific mutation and must not start workers or
   the local manager. When every blocker is actionable (`unverified` or
   `mismatch`) and has a valid presented-key challenge, persist the server-side
   pending request/challenge and publish terminal `ssh_trust_required`. For an
   `auth_failed`, `unreachable`, `capability_unknown`, or `probe_failed` node,
   do not manufacture a Yes/No challenge; publish the same trust-blocked
   result with setup/capability guidance and require a fresh successful probe
   before enrollment. In every case, exit any already-started worker
   processes, release every operation lock/guard it owns, and leave no process
   waiting for browser input. The per-command/transfer wrappers still repeat
   the verification as defense in depth, but a wrapper check is not a
   substitute for this complete parent-level gate.
6. Add central helpers such as `merv_ssh_hostkey_probe`,
   `merv_ssh_hostkey_status`, `merv_ssh_hostkey_enroll`,
   `merv_ssh_hostkey_update`, and `merv_ssh_require_verified_node`. Make
   `merv_ssh_exec`, command helpers, and new file/stream transfer helpers call
   the requirement check before the remote command starts. Enrollment and key
   rotation must re-probe the endpoint and compare the one-time challenge to
   the currently presented key before atomically writing the record. The
   browser may submit only the challenge ID, node identity, and decision; it
   must never be allowed to submit a fingerprint that the backend trusts.
7. Wire the browser flow through the existing action/result transport. Add
   explicit read-only probe, trust-decision, and backend-resume actions
   (recommended names: `sshtrustprobe_vlanmgr`, `sshtrustenroll_vlanmgr`, and
   `sshtrustresume_vlanmgr`) to the ASP allowlist, service-event dispatch
   table, and loading configuration. Dispatch them to
   `functions/ssh_trust_action.sh`, which sources the shared SSH helper and
   correlated acknowledgement/progress libraries. Reuse correlated
   `MVM_triggerVerified`/`action_result.json` semantics; return a typed
   `ssh_trust_required` error/result for an original node action rather than
   making the shell process wait for browser input. A probe result must carry
   short-lived, one-use challenge IDs and the node data needed for display.
   Give the loading configuration explicit probe (`capability`, `probe`,
   `publish`) and enrollment (`revalidate`, `commit`, `complete`) phases, but
   keep the modal decision itself browser-owned and never treat an iframe load
   event as proof that a trust record was written. Define the worker interface
   narrowly: `probe` reads the configured node set and publishes
   statuses/challenges; `enroll` accepts only a correlated request token plus
   challenge IDs and Yes/No decisions, re-probes each challenge, commits
   accepted records atomically, and returns per-node outcomes. It must not
   accept a raw host key from the browser.
   If the decision payload travels through `amng_custom`/
   `custom_settings.txt`, reserve and validate narrowly scoped
   `vlanmgr_sshtrust_*` transport fields and make `functions/save_settings.sh`
   strip them before settings persistence; never let a challenge or decision
   become a user setting or be left for a later unrelated action.

   Before the original action publishes `ssh_trust_required`, persist an
   immutable, mode-600 pending request under the main-router trust state. It
   must contain a pending ID, initiating action token/nonce, original action
   type, the exact validated original payload or a server-side request
   snapshot plus its canonical digest, the complete required-node set, and
   creation/expiry times. For every required node, bind the challenge to the
   stable node identity, endpoint, port, key algorithm, exact presented
   fingerprint, and the complete-set digest. Include a server-side attempt
   counter with a maximum of one retry. The browser receives only the pending
   ID, one-use challenge IDs, and sanitized display fields; it must not
   reconstruct the original request or submit a fingerprint, endpoint, node
   set, or action payload as trusted input.

   Enrollment must re-probe every required node, validate every challenge
   binding against the stored request, and stage a complete candidate
   `nodes.tsv` containing the existing pins plus all accepted decisions. If
   any node is unreachable, changed, rejected, malformed, or otherwise not
   revalidated, discard the stage and publish no pins at all; there is no
   partial enrollment and no partial operation retry. A No decision leaves the
   trust database byte-for-byte unchanged and cancels the pending request.
   Only after the complete set is atomically published may the backend issue
   a one-use resume ID. The browser may submit that resume ID to
   `sshtrustresume_vlanmgr`, but the backend must load the stored original
   request, verify expiry, pending status, trust records, and attempt count,
   increment the count before dispatch, and generate a fresh action/progress
   token. The backend, not JavaScript, reconstructs and dispatches the
   original action; a changed payload or a second retry is rejected. A stale,
   duplicate, or conflicting tab must reuse the existing challenge set or
   receive `ssh_trust_pending`/a terminal stale result, never create a second
   competing pending operation.

   Define bounded expiry and cleanup for pending trust state before coding.
   Use explicit settings such as `MERV_SSH_TRUST_PENDING_TTL_SEC` (initially
   300 seconds), `MERV_SSH_TRUST_RETENTION_SEC` (initially 86400 seconds),
   `MERV_SSH_TRUST_MAX_PENDING` (initially 64), and
   `MERV_SSH_TRUST_MAX_STAGING` (initially 64). The expiry timestamp is fixed in the
   server-side request and checked on every enrollment and resume attempt;
   expired requests can never be resumed, enrolled, or treated as an active
   duplicate even if the reaper has not run yet. At the start of every trust
   probe, enrollment, and resume worker, and from bounded boot/recovery
   maintenance outside the DHCP handler's hot path, for example from
   `functions/mervlan_boot.sh`/`functions/mervlan_recover.sh`, acquire the
   trust-state lock and run a BusyBox-safe reaper. The service-event handler
   may only launch the worker and must not perform the reaper inline. It must
   atomically mark expired pending
   requests as `expired`, invalidate their challenge/resume nonces, and remove
   or move their staging files to a bounded quarantine. After the retention
   period, remove only validated expired request/quarantine files under the
   exact trust root; prune oldest terminal entries when the count cap is
   reached. Never delete a live request, a current database, or an unvalidated
   path, and never let a malformed entry become an active trust challenge.
   A stale browser receives an explicit expired result and must start a fresh
   probe. Reaping must not hold an action lock while waiting for the browser
   and must not make cleanup failure look like successful enrollment.
8. Implement the exact WebUI interaction in `www/index.html`:
   - After Save completes, if nodes are configured and the local SSH key pair
     is present, schedule a non-mutating trust probe. If the local key pair is
     not ready, keep the existing key-generation/paste guidance and do not
     show a misleading host-key prompt. A local key file is not proof that its
     public half was pasted on every node: classify `auth_failed` separately
     and show the existing key-setup guidance rather than asking the user to
     trust a host that has not completed the SSH setup. The same probe must
     run defensively before every action that can SSH to a node, including
     automatic Save follow-ups such as Auto-sync. Treat this post-Save probe
     as advisory UI feedback; the node-mutating parent must still perform its
     own fresh authoritative complete-set preflight immediately before any
     mutation.
   - When the result contains `unverified` nodes, open one modal listing all
     affected units. Show node slot, configured MAC when available, endpoint,
     port, key type, and presented fingerprint. Use text-only DOM rendering.
     Keep the full fingerprint selectable/copyable so a user can compare it in
     Termius or against a label, but do not make that comparison mandatory.
     Offer explicit Yes/No controls: Yes means “Trust this node”; No means
     “Do not trust / stop”. Verified nodes are not shown and do not prompt.
   - When the result is `mismatch`, show the old and new fingerprints and a
     clear warning that the key may have been rotated or intercepted. The
     positive control must be labeled “Update trusted key” (or equivalent),
     and the negative control must preserve the old record. Never replace a
     trusted key automatically.
   - For multiple required nodes, do not start the pending remote operation
     until every required node has either remained verified or received an
     explicit accepted decision. If the user chooses No for any required node,
     leave every unaccepted record unchanged and cancel the pending operation;
     do not apply only a subset and create a partially configured mesh.
   - While the modal is open, the frontend's shared trust-decision-pending
     state must block all new mutating submissions while still permitting
     read-only status/log requests. The browser retains only the pending and
     challenge IDs needed to render/submit the decision; it is not the source
     of truth for the original action or payload. Yes/No controls are
     one-use, and duplicate clicks/tabs must be rejected or attached to the
     same pending request.
   - After a successful all-or-nothing enrollment/update, submit only the
     backend-issued resume ID. The backend reconstructs and retries the
     original intent once with a new action/progress token and re-checks the
     pins. A race or second key change opens a new decision or fails closed;
     JavaScript must not modify the action, payload, or node set. Do not keep a
     global action lock held while the modal is open.
9. On a key mismatch, stop the operation before any remote mutation and
   preserve the old record and node state until the explicit update decision
   succeeds. A user pressing No must receive a clear retry/instructions result,
   not a generic SSH failure. A first-use Yes is intentionally convenient
   confirmation-based TOFU; document that it detects later changes and blocks
   silent re-acceptance but cannot prove the first key was not presented by a
   man-in-the-middle. This normal flow is intended for a configured,
   known/trusted network and deliberately has Termius-like usability; it must
   not be described as protection against a hostile or untrusted network. The
   current release does not implement an advanced manual/out-of-band
   fingerprint-input path: users may compare the displayed value externally,
   but an unsupported capability or hostile-network requirement fails closed
   until an authenticated administrative enrollment path is separately
   specified and implemented.
10. Remove `StrictHostKeyChecking=no`, `/dev/null` known-host workarounds, and
   ordinary `-y` use from production and cleanup paths. A narrowly isolated
   enrollment command may use the target's first-contact acceptance mechanism
   only if the capability test proves that the displayed/presented key is the
   exact key being recorded and the action has an explicit user decision. If
   that proof is unavailable, fail closed with manual-verification-required
   guidance; do not silently fall back to an unverified manual-known-host
   import. Keep connection timeout separate from remote operation timeout and
   redirect stdin to `/dev/null` for ordinary command calls.
11. Route both remote-command calls and streaming transfer calls through the
    verified trust contract. Add wrappers for the existing `cat | dbclient`,
    tar, database pull, and database push paths so host verification completes
    before the transfer owns stdin. Preserve bounded execution, transfer exit
    status, and the caller's data stream. Direct callers to audit explicitly
    include `functions/execute_nodes.sh`, `functions/sync_nodes.sh`,
    `settings/mac_shield_snapshot.sh`, and the two database-transfer sites in
    `functions/update_mervlan.sh`.
12. Add migration and lifecycle behavior. Existing installations with no trust
   records must report `unverified`/enrollment required; prior installation
   alone is never proof of a node host key. `install.sh` must create/preserve
   the state root, `functions/update_mervlan.sh` and the backup/restore paths
   must preserve or explicitly migrate it, and `uninstall.sh` must use the
   verified cleanup path before removing the addon; it must load the shared
   trust-aware SSH helper while the active tree still exists and must not fall
   back to a private bypass if that helper cannot be loaded. Decide and document
   that normal reinstall/update preserves trust, a same-router restore preserves
   it, and a deliberate full uninstall removes it only after verified node
   cleanup. If cleanup fails, preserve the trust root for a retry and report
   the cleanup failure; do not erase the evidence and pin state. Any uninstall,
   restore, reprovision, or cleanup operation that can SSH to nodes must use
   the same complete parent-level trust preflight before changing either the
   nodes or the main router. Trust records must never be copied to nodes or
   silently imported into a different node identity.

### 3. Make MAC Shield and QT mutations transactional and exact

1. Refactor `ebtables` helpers so every required create, flush, jump, append,
   delete, and restore command returns an error. Increment “armed rule” counts
   only after the command succeeds. Preserve best-effort logging only for
   optional cleanup after the safety state has already been secured. Do not
   describe the firewall operation as atomically transactional: implement an
   explicit partial-failure sequence that preserves DHCP Hold/quarantine,
   records completed mutations, attempts a validated rebuild or rollback, and
   leaves the system in failure/inconclusive state if final safety cannot be
   proven.
2. Add exact verification helpers for the existing policy. Verify the expected
   chain declarations, parent-chain jumps, interfaces, logical bridge/VLAN
   fields, targets, and rule arguments as complete normalized records. Do not
   use prefix or substring tests such as `grep -F 'MERV_QT'` as proof.
3. Make the manager final security check call both MAC Shield and QT exact
   verifiers in addition to the existing DHCP/bridge checks. The check must
   fail if any required rule is missing, duplicated unexpectedly, attached to
   the wrong parent/interface, or cannot be inspected. The expected rule set
   must be derived from the existing policy/database and normalized into exact
   records; do not freeze one router's dynamic interfaces or client MACs into
   the verifier.
4. Keep DHCP Hold and any existing quarantine/failsafe state until the entire
   final verification succeeds. On uncertainty, publish terminal failure and
   enter the existing recovery path; never log “armed” or release protection
   based on a command count alone.
5. Do not change the intended rule policy in this plan. Capture the expected
   rule set from the current apply/restore code and make the verifier prove
   that exact set.

### 4. Make node settings verification fail closed

1. In `verify_file_on_node`, make any size mismatch a hard failure. If a
   digest is required, require both the expected size and digest to match; do
   not activate a file because it is merely nonempty.
2. In `verify_settings_conf_on_node`, define a small exact result protocol
   (for example, one validated `OK` record with the expected path, size, and
   digest). Missing output, unexpected output, command failure, malformed
   output, and unknown status must return nonzero. The protocol must be
   independent of human log text and must distinguish a verified `OK` from a
   transport/utility failure.
3. Audit every caller so a failed or uncertain result prevents chmod, activation,
   manager launch, and success aggregation. Preserve the old installation or
   staged file on failure.
4. Keep the stronger batch verifier and make the settings-file path use the
   same contract rather than maintaining a weaker special case. Require exact
   size plus digest when the selected digest utility is available; if the
   required verification capability is unavailable, fail closed rather than
   accepting a size-only or nonempty file.

## Tests and acceptance criteria

Add or extend deterministic tests for:

- `dev-tools/tests/router/mervlan_selftest.sh` and
  `dev-tools/tests/specs/BOUNDED_NODE_OPERATIONS_TEST_MATRIX.md` for fake
  SSH host-key states, transfer-wrapper coverage, node-action preflight, and
  the no-partial-mutation contract; use the existing local action/loading
  tests for correlated browser result polling rather than creating a second
  test transport;
- lock acquisition by two owners; live owner past the old stale interval; dead
  PID; PID reuse; wrong nonce; malformed metadata; wrong-owner release; and
  child release attempts; lock-order/deadlock paths; and callers that receive a
  release failure; plus the recovery/update/backup fallback lock paths;
- fake SSH that rejects absent/mismatched host keys, accepts only an enrolled
  fingerprint, proves all production callers use the shared verified helper,
  proves streaming transfers use the same trust path, and proves `-y` is used
  only by the separately gated enrollment path after the exact presented key
  has been captured and the user has explicitly accepted it, rejects enrollment
  mismatch, and proves ordinary execution has no `-y` or
  `StrictHostKeyChecking=no`; also prove the
  confirmation-based first-use flow, one-time challenges, Yes/No decisions,
  mismatch old/new fingerprint display data, server-side challenge binding,
  one-shot backend-generated retry behavior, and the explicit
  capability/manual-verification-required fail-closed result when Dropbear
  capability is not proven;
- unknown-node enrollment where No leaves the trust store byte-for-byte
  unchanged and starts no remote command; Yes stores only the backend-probed
  key; a subsequent same-key action is silent; a changed key blocks until an
  explicit update; and a second changed key during enrollment is rejected;
- multiple-node preflight where verified nodes are omitted, every required
  node is shown, one No prevents partial remote mutation, and a successful
  all-Yes decision retries the original action exactly once with a new token;
  prove that enrollment re-probes and atomically publishes the complete set or
  publishes no pins, and that no worker, local manager, main-router,
  DHCP/VLAN, MAC Shield, cleanup, or reprovisioning mutation begins before the
  parent preflight passes;
- trust persistence across install preserve/reinstall, update replacement,
  backup/restore, rollback, and full-uninstall policy; prove records are
  private, atomically written, bound to the node identity, and never included
  in node synchronization;
- canonical trust-record fixtures covering full public-key storage plus the
  derived SHA-256 fingerprint, percent escaping, algorithm casing, MAC/IPv4/
  DNS/IPv6 normalization, bracketed IPv6 connection authorities, deterministic
  ordering, duplicate identities/endpoints, corrupt fingerprints, malformed
  fields, and fail-closed parsing;
- expired pending requests, stale challenge/resume rejection, atomic reaper
  invalidation, staging cleanup, retention expiry, count caps, malformed-path
  quarantine, concurrent enrollment/reaper ownership, and proof that an
  expired request cannot block a fresh enrollment or accumulate indefinitely;
- fake ebtables failures at chain creation, flush, jump, append, delete, and
  restore; missing/duplicate rules; similarly named foreign chains; missing
  ebtables; partial mutation recovery; and dynamic interface/MAC rule sets;
- settings size mismatch, digest mismatch, missing remote verifier output,
  malformed output, and command-not-found cases, with no activation after any
  failure; and preservation of the staged/previous installation after each
  failure.

Required checks before this plan is complete:

1. `sh -n` on every changed production shell file in a POSIX/BusyBox-capable
   environment.
2. Focused DHCP/ownership, recovery/healing, MAC/QT, node-worker, and
   `sync-node-pool` selftests.
3. An auditable static inventory confirming no production SSH host-key bypass
   remains and no approximate ebtables verification remains. The inventory
   must scan every direct `dbclient`, `ssh`, `scp`, and remote stream call in
   `functions/`, `settings/`, installer/uninstaller scripts, and any generated
   action/template source, including update, MAC snapshot, execute, sync, and
   uninstall. Only the approved SSH adapter and the separately gated,
   capability-proven enrollment path may contain such transport; a new direct
   caller must fail the inventory test.
4. A staged, non-disruptive router validation of all five Dropbear capability
   points, the exact host-key probe, first-use Yes/No enrollment, ordinary
   verified connection, mismatch warning/update, explicit
   manual-verification-required fail-closed handling, and missing-key failure.
   A real Apply or node mutation requires the separate human gate and is not
   implied by this plan.
5. A migration/update/restore fixture proving the trusted host-key records are
   preserved and never included in node synchronization.
6. A browser/static fixture proving Save completion and every node-action
   entrypoint reaches the same trust probe/modal contract, that the modal uses
   text-only rendering, that the global trust-decision-pending state blocks
   mutating duplicates while allowing read-only status, and that a transport
   timeout, stale challenge, duplicate decision, or browser-modified payload
   cannot auto-accept a key or submit a remote mutation. It must also prove
   that `capability_unknown` cannot be bypassed through a free-form browser
   fingerprint input in this release.

## Completion gate

Do not proceed to Plan 2 as a release claim until an operation with a forced
MAC/QT command failure, a forced node verification mismatch, an unknown SSH
host key, and a stale/foreign lock all produces failure or inconclusive state
without releasing safety protection or corrupting another owner's state. Also
prove that an ownership-check failure during cleanup cannot be ignored while
the action is reported complete.
