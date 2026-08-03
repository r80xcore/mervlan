# Plan 04 — UI, installer recovery, and lower-priority cleanup

Priority: 4 — hardening, recoverability, and maintainability

Audit items: #14 iframe/loading cleanup, #16 installer rollback, #18 HTML
status injection, #19 update-reference consumption order, and #20 unused
`RAW_NORM`.

Dependencies: Plan 2 for the authoritative UI/progress terminal lifecycle.
Plan 1 is required before treating status data from nodes as trusted.

Boundary: the host-key fingerprint modal and its Yes/No enrollment/update
semantics are owned by Plan 1, with the action-lock/result integration owned by
Plan 2. Changes in this plan to shared loading, iframe, status, or modal code
must preserve that security flow and must not add a second trust prompt path.

## Objective

Ensure browser loading state always has a bounded finalizer, failed installs
retain a recoverable active tree, status rendering treats all device-derived
values as untrusted text, update requests are transactional, and event-name
normalization is either implemented deliberately or removed.

## Implementation sequence

### 1. Make iframe and loading cleanup exactly-once and bounded

1. Refactor `mervlan.asp` progress-frame handling around one idempotent
   `finalize` function. It must remove listeners, clear timers, release the
   parent/loading guard once, and ignore late duplicate events.
2. Register both `load` and `error` handling and add a bounded timeout for a
   frame that never navigates. Wrap form submission and frame lookup in
   exception handling so a thrown browser error still reaches `finalize`.
3. Preserve the existing action token and backend terminal result contract. A
   frame timeout may show a transport failure, but must not claim backend
   success, release backend ownership, or unlock a newer mutating action while
   the original backend operation may still be running. The browser must enter
   an explicit transport-unknown state and rely on the backend result/lock for
   mutation safety.
   The same rule applies to a host-key probe or enrollment result: a missing,
   stale, or malformed result must never open an approval prompt or auto-trust
   a node. Reuse the Plan 1 modal's challenge and token checks rather than
   interpreting iframe or log text.
4. Test navigation/reload, blocked frame, network error, form-submit exception,
   duplicate load, late completion after timeout, a second action during
   transport-unknown state, and cleanup when the backend has already completed.

### 2. Make installer rollback transactional

1. Keep the old active tree in its validated rollback location until the new
   tree has passed required-file, settings, hook, public-asset, and projection
   validation. Do not delete the active tree and then assume the rollback move
   will succeed.
2. On failed installation, move the incomplete new tree to a validated
   quarantine path or otherwise preserve it for diagnostics, then move the
   known-good rollback tree into the active location. Verify the restored tree
   before reporting rollback success.
3. If any move fails, preserve both exact trees and report a recovery-required
   state; never broaden cleanup or silently leave the active path empty.
4. Delete old/quarantined trees only after successful validation and only with
   exact path checks under the installer-owned root. Preserve user settings and
   existing menu/public cleanup behavior.
5. Add failure injection for active-tree removal, rollback move, validation,
   cleanup, and disk-full/permission-like errors in the isolated installer
   test-run paths. Assert that no failure silently leaves the active path empty:
   if replacement cannot complete, the verified old tree must remain at an
   exact recovery path and the installer must report recovery-required. Cleanup
   must not remove an active, staged, rollback, or quarantine tree before
   replacement validation succeeds.

### 3. Render service status as data, not executable HTML

1. Inventory every value passed by `renderServiceStatusHtml`, including
   timestamp, IP, hardware label, boot/addon/cron/event/MAC states, title
   attributes, and CSS class decisions.
2. Prefer DOM construction plus `textContent`/`setAttribute` with allowlisted
   class names. If a small HTML template remains, apply one context-correct
   escaping function to every interpolated text and attribute value; do not use
   one generic replacement for both contexts.
3. Validate/allowlist fields that are logically enumerations or IP/MAC values,
   but still escape them because validation failure must not become HTML.
4. Keep the existing visible labels and status semantics. Add a test payload
   containing `<`, `>`, quotes, backslashes, and event-handler text in every
   device-derived field and assert that no attacker-controlled element, event
   handler, URL, style, or unsafe attribute is created. The values must appear
   only as text or safely escaped values inside the intended status elements.

### 4. Retain and harden the encoded update-reference path

1. The encoded `MVM_updateRef` service-event action already exists in the
   current branch. Treat it as the canonical path to preserve and harden, not
   as a new parallel protocol. The browser validates the ref, encodes it into
   the action name, and the service handler validates/decodes it before
   invoking `update_mervlan.sh update <ref> --logs=<policy>`. This path must
   remain independent of `custom_settings.txt` timing and must not consume a
   shared settings line.
2. Bound and canonicalize the encoded action at both ends. Reject an action
   whose complete name exceeds the ASUS service-event limit (use the existing
   120-character guard used by other encoded actions), whose hex is empty,
   odd-length, non-lowercase/non-hex, or decodes to an invalid ref. Apply the
   same branch/tag, traversal, suffix, and maximum decoded-name rules in
   JavaScript and `service-event-handler.sh`. Add encoder/decoder round-trip
   tests and malformed/oversized action tests.
3. Acquire the owner-checked maintenance lock before the encoded update begins.
   The decoded ref and log policy must remain action-local, validated, and
   bound to that locked update; do not reconstruct them from mutable global
   settings. The update modal and hidden-frame path must participate in the
   global mutation gate and transport-unknown lifecycle from Plan 2 even
   though the existing update flow uses its own spinner/log polling.
4. Keep `custom_settings.txt` only as a compatibility fallback for older parent
   pages that cannot encode the action. The service-event handler must not read
   or consume the fallback line before the maintenance lock; route the fallback
   to one explicit legacy-ref mode in `update_mervlan.sh`. Remove or restrict
   the current unconditional `consume_gui_update_ref` call so the handler and
   updater cannot read/consume the same request twice.
5. The external Merlin settings writer cannot be required to acquire the addon
   lock. Therefore the legacy fallback must never rewrite, delete, or replace
   `custom_settings.txt`. After owning the maintenance lock, read and validate
   the exact newest fallback line, compute a stable fingerprint of the source
   line/file snapshot, and atomically record that fingerprint in a small
   main-router-owned consumed-reference ledger under `MERV_STATE_ROOT`
   (separate from `MERV_SSH_TRUST_ROOT`) that
   survives active-tree replacement or has an explicit update/restore
   migration.
   Ignore an already-consumed fingerprint, process a newer fingerprint, and
   preserve every external settings line. If the required fingerprint
   capability is unavailable, fail the legacy fallback closed and direct the
   user to the encoded action; do not fall back to destructive rewriting.
6. If the external file changes while the fallback snapshot is being read,
   retry or use the exact captured snapshot without overwriting the file. A
   newer external line must remain available for a later request. Define
   behavior for multiple fallback lines, invalid lines, a repeated identical
   line, and a newer line arriving during an active update.
7. Test encoded valid/invalid refs, malformed/oversized action names,
   encoder/decoder round trips, log-policy encoding, update-modal global-gate
   behavior, lock-busy behavior, legacy fallback consumption through the
   service handler, duplicate-consumption prevention, concurrent/newer
   fallback values, and update startup failure cases. The canonical encoded
   path must never depend on the fallback ledger.

### 5. Resolve `RAW_NORM` deliberately

1. Trace the service-event parser and its documented action identifiers. Decide
   whether hyphen-to-underscore normalization is part of the supported input
   contract.
2. If it is supported, normalize at the single parser boundary, validate the
   normalized action against the canonical dispatch table, and add dashed and
   underscored tests without accepting ambiguous names.
3. If it is not supported, remove the unused variable and update the comment so
   future code does not imply an unavailable alias. Do not add compatibility
   behavior speculatively.

## Tests and acceptance criteria

Run the local loading/action tests, browser/static status-render tests, isolated
installer test-run and rollback tests, update/maintenance unit tests, service
event dispatch tests, and `git diff --check`. Add an atomic concurrent-writer
test for the update-reference claim. Run `sh -n` for changed shell files and
keep live Update/Restore/Apply validation behind the human gate.

The plan is complete only when a frame cannot strand the loading guard, a
failed install leaves a verified recoverable tree, hostile status text renders
as text, encoded update refs are bounded and round-trip validated, the update
modal participates in backend serialization, a busy maintenance lock does not
consume a valid encoded or legacy request, the legacy fallback never rewrites
the external settings file, and event normalization has an explicit tested
contract.
