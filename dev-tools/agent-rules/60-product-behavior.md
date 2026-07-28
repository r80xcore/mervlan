# Product behavior invariants

Use when changing VLAN behavior, client collection, UI data, node identity, cron, or observation work.

- Active VLAN Client node identity is `configured/custom name, ProductID (IP)`.
- A custom name overrides the default node name. Do not use OOMID as the primary visible node identity.
- Client collection is not a recurring cron task. It is requested by supported page/manual refresh and post-apply observation behavior.
- Keep normal successful collection logs concise:
  - `Refreshing client list started`
  - `Refreshing client list complete`
- Warnings/errors identify node, phase, cause, and recovery action.
- Observation work must defer/coalesce around configuration work rather than race it.
- Atomic publication exposes one coherent generation, never partial state.
- MAC Shield remains fail-closed during Apply, healing, wireless restart, boot, and recovery; clients must not escape to `br0`.
- Preserve settings and staged-sync rollback behavior.
