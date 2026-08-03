# UI action pipelines

## Standard lifecycle

```text
button/event
  → input validation and payload preparation
  → action lock and loading task
  → parent/service dispatch with action name and optional progress token
  → backend script and terminal progress/acknowledgement
  → UI polling of authoritative state
  → complete, fail, timeout, and release button/refresh state
```

Every action needs explicit handling for rapid clicks, missing payload keys,
backend rejection, malformed status, timeout, and exceptions. A button must not
remain locked after a terminal failure, and it must not unlock while work is
still active.

The normal Save action is two-phase when automatic node synchronization is
needed: it first completes the local `save_vlanmgr` acknowledgement, then
queues `syncsettings_vlanmgr` as a separate progress-backed action. The second
action owns node preflight, SSH trust pause/resume, and terminal reporting; a
local-only settings change must not trigger an advisory SSH probe.

## Progress ownership

- The backend owns the progress file and terminal state.
- The loading controller owns the visible panel and its timers.
- The UI may display log or client freshness details, but those must not race or
  override the authoritative action terminal state.
- A progress-backed action must not call UI completion before its required
  post-action work is complete.

## Refresh suppression

Apply-owned refresh suppression is shared and reference-counted. An action may
acquire a refresh guard, but it may release only its own ownership. Overlapping
actions must not restore the original refresh handlers out of order.

## Apply-specific checks

Check all three paths separately: `apply_vlanmgr`, `executenodesonly_vlanmgr`,
and `executenodes_vlanmgr`. Confirm that the final client collection is part of
the Apply task, not a detached follow-up that can outlive loading completion.

## Payload and failure checklist

Before changing a button or action, locate all of these with `rg`:

- button/event binding and the disabled/spinner transition;
- payload construction, including optional keys and empty selections;
- action name in `mervlan.asp` and `service-event-handler.sh`;
- loading entry in `www/settings/loading_actions.json`;
- progress/ack/result writers and matching polling code;
- terminal success, failure, timeout, exception, and button-release paths.

The backend rejects malformed or missing required keys before mutation. The
frontend handles rejected requests, malformed status, network timeout, and a
late response after navigation. Use a request token to ignore stale responses;
do not unlock a newer action because an older request finished. Every terminal
branch releases the correct lock.

For Apply, the loading panel remains open through final client refresh for all
three modes. The user-facing phase is “Refreshing client inventory...”, not
“collecting final cluster information”.
