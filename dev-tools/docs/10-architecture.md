# Architecture and ownership

## Components

```text
www/index.html
    │ UI state, payloads, loading panel, client rendering
    ▼
mervlan.asp / service-event-handler.sh
    │ parent-frame actions and validated dispatch
    ├── mervlan_manager.sh       local configuration mutation
    ├── execute_nodes.sh         main-router/node orchestration
    ├── sync_nodes.sh            staged node rollout
    ├── post_apply_worker.sh     serialized observation coordinator
    └── maintenance helpers      backup, update, restore, keys, metadata

settings/*.sh
    shared parsing, logging, locks, SSH, progress, MAC Shield, and node jobs
        │
        ├── /tmp/mervlan_tmp/     volatile locks, progress, logs, workers
        └── /jffs/addons/mervlan/ persistent settings, scripts, and databases
```

## Ownership boundaries

- Only the parent orchestration process owns global aggregation, orchestration
  locks, shared cleanup, and final summaries.
- Node workers own isolated job directories and terminal result records; they
  do not write shared parent logs directly.
- The observation worker owns snapshot/collection serialization and generation
  completion. Callers request work through it instead of invoking collection
  scripts directly.
- `settings/settings.json` is user data. Runtime code must preserve it unless
  the approved change explicitly includes a migration.

## Safety boundary

The manager's DHCP Hold, MAC Shield, quarantine, and bridge guards protect the
mutation window. Final placement and exact rule state must be verified before
protection is released. An uncertain result becomes a failsafe/recovery state,
not a reported success.

## Data boundary

The main router merges local and node observation artifacts into the public
client JSON. Publication is atomic, so the WebUI sees either the previous
complete generation or the new complete generation, never a partial merge.

## Request-to-result sequence

1. The browser validates visible input and sends an action/payload through the
   ASP bridge.
2. `service-event-handler.sh` validates the action and starts or dispatches
   the correct worker, returning an action token where asynchronous.
3. The parent owns the action lock, progress token, global DHCP/MAC safety
   state, and final aggregation. A node worker owns only its local operation
   and result marker.
4. Workers write logs and atomic result/progress artifacts. Missing, stale,
   malformed, or contradictory artifacts are failure/inconclusive.
5. The UI polls the same authoritative token until terminal state, performs
   the documented final refresh, and releases the interaction lock.

The service wrapper's return code is not completion. Background workers can
still run after the wrapper returns, and an action is incomplete until its
verification and post-action observation finish.

## Layer ownership

| Layer | Owns | Must not own |
|---|---|---|
| UI/ASP bridge | interaction, payload, display, polling | firewall truth or final client JSON |
| service handler | routing and validation boundary | duplicated worker policy |
| parent workers | locks, safety, aggregation, publication | node-specific global state |
| node workers | local operation and markers | merged cluster JSON |
| observation worker | serialized collection and generations | VLAN mutation |
| dev-tools | tests, plans, evidence, diagnostics | production dependency unless explicitly copied |
