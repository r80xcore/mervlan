# Implementation Plan: Update Safety, Extraction Reliability, and Recovery

## Objective

Make MerVLAN Update resilient to transient node outages, low RAM/tmp space,
power loss, and interruption during extraction or activation. The update must
never leave the router in a state where its own guards prevent management or
network recovery. It must preserve the existing fail-closed protection during
VLAN mutation, regenerate the public hardware profile consistently, and leave
clear evidence when a node is temporarily unavailable.

This plan is based on a read-only audit of the current update flow. It is a
planning document; it does not authorize running Update, changing router
state, clearing recovery markers, or weakening DHCP Hold/MAC Shield behavior.

## Confirmed audit findings

### 1. Extraction uses RAM, but the space accounting is not transactional

`functions/update_mervlan.sh` uses:

- `TMP_BASE=/tmp/mervlan_tmp/updates.$$` for the archive and extracted tree;
- `stage/` for a second full copy of the extracted tree;
- `original/` for a full RAM rollback copy of the current installation;
- `updated_tree/` for another full copy after settings restoration; and
- a persistent JFFS activation stage before the final same-filesystem swap.

The updater checks available space at several individual steps, but the first
check is based mainly on the current installation size and later checks add
one projected copy at a time. It does not reserve the actual downloaded
archive, expanded archive, retained extracted tree, staging copies, metadata,
and rollback copies as one high-water transaction. The extracted tree also
remains present while the stage copy is made. A full `/tmp` or an unexpected
custom-branch archive size can therefore fail during `tar` extraction or a
subsequent copy even though an earlier space check passed.

The archive is correctly intended to be downloaded and extracted in RAM, not
directly into the live JFFS installation. The JFFS stage is created only after
the new tree has been validated and merged. The problem is the peak RAM/tmp
footprint and the lack of phase-specific evidence, not the decision to avoid
extracting directly into the live installation.

### 2. Node availability and SSH trust are currently conflated in user-facing
messages

The update performs a complete configured-node SSH preflight before mutation.
That is safe, but a powered-off or rebooting AiMesh node can be reported as a
generic trust-preflight failure. The later `nodeenable` and runtime checks can
also only report a broad failure even when the actual cause is temporary node
unreachability.

The safe default should remain: retry transient conditions before mutation and
do not silently create a main/node version split. If the bounded retry window
expires, Update should stop before destructive work unless an explicitly
selected, separately defined main-only policy exists.

Boot recovery is a separate concern. A node that was unavailable during boot
should be rechecked later through an owned, bounded retry/reconciliation path,
without delaying the main router indefinitely or launching an untracked
background shell process.

### 3. The normal installer can leave the public hardware profile missing

`www/index.html` and installer verification require
`www/settings/hardware_profiles.json`, but normal `install.sh` execution does
not consistently regenerate it. Reinstall mode reaches the public projection
verification, while normal recovery can report installation failure after a
partial/interrupted update because the generated profile is absent.

Hardware profile generation must be an explicit installer-owned phase before
final public projection verification. A missing or invalid profile must never
be reported as a successful installation.

### 4. Update does not have a complete runtime quiesce barrier

Update owns `mervlan_maintenance.lock`, disables main boot hooks, and removes
the setup hooks, but it does not establish a complete owner-aware barrier with
the manager, heal worker, observation work, boot watchdog, or DHCP Hold state.
The boot wrapper can arm the shield before install/manager work, and the
update path does not explicitly represent an update-quiesced state that blocks
new guard/heal work during the replacement window.

The fix must coordinate ownership and state transitions. It must not simply
remove safety rules while a manager or heal operation is still mutating VLAN
state.

### 5. DHCP boot handoff completion has a lifecycle race

The boot manager can publish verified handoff completion before all post-apply
observation/client-refresh work is finished. Reconciliation can then retire the
completed boot-watchdog parent while its process is still alive. Later cleanup
records `abandon-identity-mismatch` even though no DHCP Hold rule remains.

The handoff contract must keep ownership alive until the actual critical
section is complete, or make completed-parent cleanup explicitly idempotent and
identity-aware.

### 6. JFFS CRC errors need to be surfaced and separated by device

A power loss can explain a JFFS2 CRC warning, and an AiMesh node may have been
restarting independently. The warning must not automatically be attributed to
the main router or treated as proof that Update itself corrupted the system.
Nevertheless, current-mount/readability/free-space checks and a clear health
warning are needed before another disruptive update. Fresh, actionable JFFS
failures should block Update; historical kernel warnings should remain
diagnostic warnings unless the configured policy decides otherwise.

## Required end-state

The complete Update transaction should behave conceptually as follows:

1. Acquire maintenance ownership and write a durable update journal.
2. Check JFFS, RAM/tmp capacity, active locks, manager/heal/watchdog state,
   node reachability, SSH trust, and the current installation before mutation.
3. Retry transient node boot/reachability failures within a bounded window and
   report the exact node and cause.
4. Enter an explicit update-quiesced state that prevents new MerVLAN guards,
   healing, and manager mutations from starting.
5. Finish or safely stop existing mutating work, then verify guard ownership
   and DHCP/MAC/quarantine state before file replacement.
6. Download, validate, extract, and stage the archive with measured peak-space
   checks and phase journaling.
7. Preserve settings and identity data, regenerate hardware profiles, and
   validate the complete public projection before activation.
8. Atomically activate the validated JFFS tree, reprovision hooks, and verify
   the main router before touching nodes.
9. Synchronize reachable nodes with per-node terminal results. Keep an
   unreachable node on its last known-good installation and report it as a
   partial node result only when the main-update policy explicitly permits that
   outcome.
10. Restore the saved boot state, complete the guard/handoff lifecycle, clear
    the durable journal only after final verification, and retain enough logs
    to diagnose a reboot or power loss.

## Implementation rounds

### Round 0 — Re-audit contracts and build deterministic failure fixtures

Audit all callers and ownership boundaries before changing code:

- `functions/update_mervlan.sh`;
- `install.sh` and `uninstall.sh`;
- `functions/mervlan_boot.sh` and `functions/mervlan_boot_wrap.sh`;
- `functions/mervlan_manager.sh` and `functions/heal_event.sh`;
- `settings/lib_mervqt.sh` and lock/progress libraries;
- `functions/sync_nodes.sh` and SSH/trust helpers; and
- the Update UI/ASP/service-event path.

Document the lock order among maintenance, manager, heal, observation, node,
and DHCP state ownership. Confirm which process owns cleanup and which process
publishes terminal results.

Add or extend local fixtures for:

- archive extraction failure and partial extraction;
- insufficient RAM/tmp space at each copy phase;
- power loss/interruption before and after JFFS activation;
- one node booting, one node unreachable, trust missing, and key mismatch;
- hardware-profile generation failure;
- an active manager/heal/watchdog owner during Update; and
- completed boot handoff while the watchdog process is still alive.

Do not begin live Update testing until the fixtures can prove that each failure
stops safely and leaves recoverable state.

### Round 1 — Durable Update journal and interruption recovery

Add an addon-owned, atomically published update journal under the persistent
state/backup boundary. The journal should include at least:

- update run ID and selected ref/branch;
- current phase and phase start time;
- original installed version and boot-enabled state;
- archive, extracted-tree, staged-tree, and activation paths;
- whether the durable backup was validated;
- whether hooks/guards were quiesced;
- whether activation started or completed;
- whether nodes were touched; and
- last safe recovery action and failure reason.

Write the journal before the first destructive or guard-affecting operation,
update it at every phase boundary, and clear it only after final verification.
Never store credentials or private keys in it.

On boot, detect an incomplete journal before normal manager/shield startup.
Choose and document one safe recovery policy based on the actual activation
state:

- finish/verify an already complete activation;
- restore the validated previous tree when activation is incomplete; or
- enter a bounded maintenance-recovery state that keeps the management path
  available and requires a clear logged administrator action.

The recovery path must not blindly run the normal manager against an incomplete
public projection.

### Round 2 — Transactional RAM/tmp space and extraction hardening

Refactor the extraction/staging path after measuring real archive and tree
sizes on the supported router. The implementation may choose either a reduced
copy design or a carefully budgeted multi-copy design, but it must prove the
peak requirement before each phase.

Required behavior:

- record total, available, reserve, archive size, and measured tree sizes in
  the update log/journal;
- account for the compressed archive, expanded tree, stage copy, preserved
  user data, metadata, and any rollback copy together;
- use a minimum free-space reserve appropriate to the firmware rather than a
  generic current-tree multiplier alone;
- remove the extracted source tree immediately after a validated stage copy if
  it is no longer needed;
- avoid retaining redundant full-tree copies where the durable backup and
  persistent old-tree activation copy already provide rollback;
- verify archive structure before extraction and verify the extracted tree
  after extraction;
- make gzip/tar fallback failures observable rather than allowing a pipeline
  status ambiguity to look successful;
- reject path traversal, unexpected top-level layout, missing required files,
  and incomplete copies before any activation; and
- clean only exact, run-owned temporary paths on failure.

Extraction failure must produce a terminal `extracting` result with the exact
available/required space and whether the archive was valid, partially
extracted, or not extracted. It must not proceed to settings merge, teardown,
or activation.

### Round 3 — Explicit maintenance quiesce and guard coordination

Introduce a shared update-maintenance state/ownership protocol rather than
relying on `disable` and `setupdisable` as an implicit barrier.

Before teardown:

1. Acquire the maintenance owner with PID/start identity and nonce.
2. Publish `update-quiesce-requested` so new manager, heal, observation, boot,
   and service-event mutations refuse or defer safely.
3. Wait for active manager/heal/observation workers and boot-watchdog handoffs
   using their real ownership records, not only elapsed time or missing PIDs.
4. If the critical owner cannot finish within its bounded budget, abort before
   destructive file work and leave the existing installation active.
5. Once no mutator owns the critical section, release or reconcile DHCP Hold
   and verify exact absence/presence of the expected ebtables rules.
6. Tear down MERV_QT/MERV_MAC only after the ownership transition is valid.
7. Publish `update-quiesced` and only then begin file replacement.

During the update window:

- the boot wrapper must recognize the update-quiesced state and not arm a new
  boot shield over the update;
- heal and service-event paths must not start new mutations;
- the update must not remove a guard owned by another valid mutator; and
- any failure must either restore the previous verified runtime or leave a
  clearly recorded safe recovery state with management access.

After activation, re-enable hooks and guards in an explicit order, verify
main-router topology and runtime state, then clear the quiesce state. Guard
protection remains fail-closed for normal Apply/manager mutation; only the
Update maintenance protocol may suppress it, and only after ownership and
state verification.

### Round 4 — Hardware-profile generation and installer projection recovery

Make generated hardware-profile creation an unconditional installer-owned
phase for normal installation/recovery and reinstall/public refresh where the
public WebUI is enabled.

The phase should:

- run after the target source and settings are installed but before final
  public verification;
- generate the profile on the main router using the target-version probe code;
- publish it atomically to the exact public `settings/` path;
- verify it is readable, structurally valid, and consistent with the active
  settings/hardware identity; and
- return a named failure that prevents a false successful installation.

Update's `refresh_public_install` and boot recovery must use the same projection
contract. Avoid fixing only the Update caller; a normal boot after an
interrupted Update must be able to repair the missing generated asset.

Ensure the final report distinguishes source installation, public projection,
hook installation, node propagation, and final verification. A node outage
must not be mislabeled as a missing WebUI asset, and a missing asset must not
be hidden behind “Installation complete.”

### Round 5 — Node reachability retry, result taxonomy, and boot reconciliation

Separate these outcomes throughout SSH preflight, `nodeenable`, Update, and
boot reporting:

- trusted and reachable;
- configured but still booting/unreachable;
- SSH key/authentication failure;
- host-key trust missing;
- host-key mismatch;
- malformed/incomplete node configuration; and
- remote MerVLAN runtime failure.

For Update:

- perform a bounded retry window before any destructive mutation;
- log node ID, address, phase, attempt number, and exact failure class;
- preserve the complete-set safety gate by default; and
- if the retry window expires, stop before teardown unless an explicit
  main-only policy is designed, surfaced, and tested as a separate operation.

For boot:

- let the main router complete its own safe boot path when a node is
  temporarily unavailable;
- record the node as pending reconciliation rather than as a generic trust
  failure;
- schedule one owned retry through the existing cron/service lifecycle after a
  bounded delay (approximately the requested five-minute recovery window);
- revalidate the same node set and host keys before retrying; and
- record success, continued outage, or trust/action-required terminal state.

The retry must be idempotent, bounded, lock-aware, and safe across reboot. Do
not use an untracked `sleep 300 &` process or silently keep retrying forever.

### Round 6 — DHCP handoff and watchdog lifecycle fix

Fix the confirmed completed-parent race in the shared DHCP/guard state
library.

Audit the exact transitions between:

- boot-watchdog acquisition;
- manager child publication;
- manager final security and observation completion;
- handoff acknowledgement/completion;
- parent retirement; and
- watchdog cleanup/release.

Select and document one canonical contract:

- the manager publishes completion only after the complete protected critical
  section, including the required post-apply verification; or
- reconciliation retains a completed boot parent while its validated PID/start
  identity and lifecycle marker remain active.

In either design, cleanup of an already-retired, successfully completed
handoff with no active DHCP rules must be idempotent and must not create a
misleading `abandon-identity-mismatch` fault. Genuine identity mismatches with
active or ambiguous rules must still fail closed and remain visible.

Add deterministic tests for normal completion, manager failure, watchdog
timeout, reboot, SIGTERM, SIGKILL, stale PID reuse, duplicate reconciliation,
and update-quiesce interaction.

### Round 7 — Rollback, final verification, and durable evidence

Review `fail_update`, activation swap, public reprovisioning, node rollback,
MAC Shield preservation, and boot-state restoration as one state machine.

Required outcomes:

- extraction/validation failure leaves the live installation untouched;
- pre-swap teardown failure restores the original hooks/guards;
- post-swap failure restores the previous tree or enters the documented
  persistent recovery path;
- a power loss cannot make the boot wrapper run an incomplete tree as if it
  were valid;
- an offline node retains its last known-good tree and is named in the final
  result;
- main runtime verification is required before node synchronization;
- node partial results do not get reported as full success; and
- the update journal and logs survive reboot long enough to explain the last
  failed phase.

Do not reset the only diagnostic logs at the beginning of a normal recovery
boot. Preserve the previous update journal/phase log or copy it to the durable
backup/evidence area before starting a new recovery attempt.

### Round 8 — Validation and controlled live rollout

Run in this order:

1. Shell syntax and static checks for every changed runtime file.
2. Focused local extraction/space/journal/rollback tests.
3. Focused lock, DHCP handoff, guard, and quiesce selftests.
4. Focused SSH classification and retry tests with fake reachable,
   unreachable, untrusted, and mismatched nodes.
5. Installer projection tests, including missing and regenerated hardware
   profiles.
6. Full applicable local/router selftest groups.
7. Read-only router inspection of current space, JFFS health indicators,
   locks, guards, journals, and backups.
8. A human-approved live update test with the node available.
9. A separate controlled test with the node temporarily unavailable, only
   after recovery and rollback evidence is ready.

For each live test record the selected branch/ref, archive size, available
RAM/tmp and JFFS space, node state, guard state, update phase, final runtime
reports, and whether the management path remained reachable. Any unavailable
platform or device check is `INCONCLUSIVE`, not a pass.

## Planning decisions required before implementation

The implementation planner must resolve these choices from the audited code
and tests, rather than assuming them:

1. Whether the updater can eliminate `original/` and/or `updated_tree/` safely
   after durable backup and JFFS-old activation are proven, or whether it must
   keep them and budget their full peak size.
2. The exact bounded node retry duration and attempt schedule for Update and
   boot recovery.
3. Whether main-only Update is ever allowed. The safe default is no automatic
   main-only continuation when configured nodes cannot be verified.
4. The exact persistent journal/recovery location and boot ordering, including
   behavior when JFFS itself is unhealthy.
5. Whether historical JFFS CRC warnings are warning-only while current mount,
   write, or fresh CRC failures block Update.
6. The precise point at which the boot watchdog handoff is considered complete
   relative to manager post-apply observation.

## Completion gate

This plan is complete only when a failed extraction, insufficient tmp space,
node reboot, missing SSH trust, missing hardware profile, guard owner
contention, watchdog interruption, power loss before activation, and power
loss after activation all produce a safe, recoverable, clearly logged result.
The normal router and node paths must remain protected by their existing
fail-closed guards outside the explicitly owned Update maintenance window.
