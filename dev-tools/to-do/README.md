# MerVLAN audit remediation plans

These plans are based on the read-only audit of the `dev` branch at commit
`eea368f`. They are implementation plans, not runtime instructions. The
current source and the mandatory rules in `dev-tools/agent-rules/` remain the
authority if a plan conflicts with code or a safety invariant.

`dev-tools/` is developer-only material. Do not deploy these Markdown files to
the router or nodes. Do not run disruptive Apply, Sync, Update, Restore, or
recovery actions while implementing a plan unless the user separately gives
the required human test approval.

## Execution order

| Order | Plan | Audit items | Gate |
| --- | --- | --- | --- |
| 1 | [Fail-closed security and node integrity](01-fail-closed-security-and-node-integrity.md) | #1, #2, #3, #4, #5, #12 | Required before ordinary use on a known/trusted network. The current release does not promise hostile-network first-contact protection; unsupported capability results fail closed. |
| 2 | [Action serialization and liveness](02-action-serialization-and-liveness.md) | #7, #9, #10, #15 | Required before relying on long-running or concurrent actions. |
| 3 | [BusyBox compatibility and state durability](03-busybox-compatibility-and-state-durability.md) | #6, #8, #11, #13, #17 | Required for the supported firmware/platform matrix. |
| 4 | [UI, installer recovery, and cleanup](04-ui-installer-recovery-and-cleanup.md) | #14, #16, #18, #19, #20 | Post-Plan-3 implementation phase; required before release. |
| 5 | [Update safety, space, and recovery](05-update-safety-space-and-recovery.md) | Update extraction, runtime quiesce, node availability, hardware-profile recovery, DHCP handoff, and power-loss evidence | Required before another live Update test. |

Plan 04 is later in implementation order, not post-release work. Its
update-reference, installer-recovery, loading-cleanup, and output-escaping
fixes remain part of the release-readiness gate below.

## Shared implementation rules

- Read each owning function and all callers before editing. Keep ownership in
  the parent orchestration process; children publish isolated terminal state.
- Production shell is ASUSWRT BusyBox `/bin/sh`. Do not introduce Bash syntax,
  GNU-only options, `flock`, `wait -n`, or an assumption that `timeout`,
  `mktemp`, `scp`, or `command` exists on the router.
- Safety controls fail closed. An unknown, missing, malformed, stale, or
  contradictory result must become failure/inconclusive, never success.
- Use exact ebtables matching and PID plus `/proc` start identity before
  signaling, reclaiming, or releasing ownership. Do not use time alone to
  steal a live lock.
- Preserve user settings, DHCP Hold, MAC Shield, quarantine, healing,
  observation, and node identity. Do not change policy while fixing the
  implementation of the existing policy.
- Add focused deterministic tests before broad regression runs. Use fake
  ebtables, fake SSH, isolated runtime roots, injected command failures, and
  synthetic stale/PID-reuse state; do not require a live device for fault
  injection.
- After each implementation round, run the narrowest local tests, shell syntax
  checks, affected router selftest groups, and `git diff --check`. Record any
  unavailable BusyBox or live validation as `INCONCLUSIVE`, not `PASS`.

## Cross-plan contracts required for the coder handoff

The following contracts apply across all four plans. They must be written down
in the implementation change and tested as one system; implementing each plan
as an isolated local fix is not sufficient.

### Lock ownership and ordering

- Define one lock-order graph before adding the global action lock. At minimum,
  document the order among the global mutating-action lock, maintenance lock,
  manager/execute/sync locks, observation lock, and DHCP state lock.
- A parent orchestration process owns global locks. Workers publish isolated
  results and never release a parent lock or delete another worker's state.
- Every lock record uses PID, `/proc` process-start identity, acquisition
  nonce, and creation/heartbeat data. Release requires the current owner to
  match all ownership fields. Callers must not ignore an ownership failure and
  then report successful completion.
- A `SIGKILL` or missing parent cannot publish its own result. Boot/heal/service
  recovery or another bounded reaper must detect the dead owner and publish a
  stale/failed terminal result without reclaiming a live owner.

### Action and progress lifecycle

- The backend lock and terminal result are authoritative. The browser gate is
  only a user-experience guard and must not be the safety mechanism.
- Busy, failed, stale, malformed, missing, and transport-unknown states must
  use explicit result values. None may be interpreted as success or as
  permission to start a conflicting mutation.
- Every asynchronous poller must prevent overlapping requests and reject late
  responses from an older token/generation. A browser timeout may release only
  browser presentation state; it must not release backend ownership.

### SSH trust and persistence

- Host-key trust is owned by the main router, is never synchronized to nodes,
  and must survive active-tree replacement, update, backup, restore, and
  rollback. Do not place it only inside a replaceable release tree.
- Command execution and streaming transfer paths must use the same verified
  host identity, bounded noninteractive behavior, and stdin policy. The exact
  Dropbear host-key options supported by the target firmware must be verified;
  do not assume OpenSSH options apply to `dbclient`.
- The normal WebUI flow is explicit, confirmation-based first-use trust: show
  the node identity, address, host-key type, and presented fingerprint, then
  let the user choose Yes (trust) or No (stop). Store the accepted key as a
  per-node pin and do not prompt again while it still matches. This is a
  deliberate Termius-like usability choice, not full first-contact MITM
  prevention; a user who approves an attacker-controlled key can still be
  fooled at first contact. The UI must say enough for an informed decision.
- A key mismatch is never silently accepted. Show the old and new
  fingerprints and require an explicit Update trusted key decision. The
  current release does not implement a free-form manual expected-fingerprint
  input path and does not claim hostile-network first-contact protection. A
  user may compare the displayed fingerprint out of band, but the addon must
  not treat that comparison as proof unless a separately specified,
  authenticated administrative enrollment path is implemented. If the target
  Dropbear build cannot safely expose a presented key for the normal
  confirmation flow or enforce the stored pin afterward, return a
  capability/manual-verification-required result and fail closed rather than
  using unconditional `-y`.
- Before any node-mutating parent action changes the main router, starts a
  worker pool, creates a mutation guard, or performs a DHCP/VLAN/MAC Shield
  operation, the parent must preflight the complete required-node set. Every
  required node must already be verified or be accepted in that same
  preflight. A post-Save probe is advisory and cannot authorize a later
  mutation; any bounded cache is valid only for the same action and matching
  node identity, endpoint, port, key algorithm, and fingerprint metadata.
- The trust challenge is server-owned. It binds the complete required-node
  set, node identity and endpoint metadata, presented fingerprint, original
  action and immutable payload digest, initiating token/nonce, expiry, and a
  one-retry attempt counter. The browser submits challenge IDs and decisions,
  never a trusted fingerprint or reconstructed action payload. Enrollment
  re-probes and atomically stages only the explicitly selected pending keys;
  the router republishes any remaining challenge and never resumes the stored
  action until the full required set is trusted. An explicit abort or expiry
  cancels the residual request and prevents resume, while pins already
  explicitly accepted remain valid.

### Encoded update actions and legacy fallback

- The encoded `MVM_updateRef` action already exists and is the canonical update
  path. Preserve and harden it rather than introducing a duplicate protocol.
  Bound the complete action length, require canonical hex, and validate the
  decoded ref in both JavaScript and the service handler.
- The legacy `custom_settings.txt` fallback must be read only after the
  maintenance lock is owned, must not be read by the service handler before
  dispatch, and must never rewrite or delete the externally managed file. Use
  an addon-owned consumed-reference ledger or fail closed when a safe claim is
  impossible.

### Timeout matrix

- Keep separate, explicitly named budgets for SSH connection, node preparation,
  node runner launch, detached node completion, node synchronization, local
  manager execution, and final observation. Keep connection establishment
  separate from remote command/transfer execution. A timeout for one phase must
  never silently become the timeout for another phase.

### Release-readiness gate

The addon is not ready for real use until the implementation has passed the
focused tests for lock ordering/ownership, exact MAC/QT verification, SSH
trust enrollment and mismatch, canonical trust-record parsing and expiry
reaping, all-or-nothing multi-node preflight, strict node verification,
local-manager supervision, non-overlapping browser polling, BusyBox shell
behavior, progress permissions/retention, installer rollback failure
injection, and atomic update reference claiming. Any unavailable BusyBox or
live-device check remains
`INCONCLUSIVE` and must not be reported as a pass.
