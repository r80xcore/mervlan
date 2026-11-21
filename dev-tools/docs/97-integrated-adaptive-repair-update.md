# RC3 — Integrated Adaptive Repair and Update

## Status

This note records the agreed target for the next integration milestone. These
requirements are not implemented behavior. The standalone Repair remains an
independent operation, and this plan does not change its accepted source
identity or publication and recovery design.

The existing Help description of repairing update/runtime components before
Update describes the current flow. It does not mean the combined Repair and
Update transaction below is available.

## Target behavior

- Standalone Repair accepts branches, tags, commits, and offline tarballs.
- Its modes are **Adaptive** (`FULL=0`) and **Full** (`FULL=1`); its default is
  Adaptive.
- The GUI offers recommended pre-update Repair enabled by default, with an
  option to disable it.
- The selected Update target is also the source for pre-update Repair. There is
  no separate Installed-mode selector.
- Before Repair publishes anything, Update establishes and verifies the
  rollback point for the pre-repair installation.
- Update owns the combined Repair/Update transaction and its recovery
  boundaries.
- The Update popup reports continuous, reconnectable progress through Repair,
  Update, and post-update actions.
- Prefer reliable, straightforward code and maintainable tests over further
  scanner optimization.

## Integration boundary

Keep standalone Repair independently usable. Implement the combined flow under
Update's transaction ownership, and do not present any target behavior above
as available until that work is implemented and qualified.
