# Deployment checklist

## Before deployment

1. Inspect `git status` and `git diff`; preserve unrelated changes.
2. Run focused tests, shell syntax, and `git diff --check` locally.
3. Confirm the exact target, account, key, addon root, branch, and approval.
4. Verify the router is idle and no Apply/manager/node worker owns a lock.

## Stage and activate on the router

1. Create a unique staging directory below the approved addon root.
2. Upload explicit files with native Windows `scp.exe -O`.
3. Check size, mode/owner, hashes, and `/bin/sh -n` in staging.
4. Retain exact backups of live files.
5. Activate with same-filesystem `mv` only after validation.
6. Re-run `/bin/sh -n`, hashes, versions, and key non-disruptive tests on the
   active files.

## Roll out to nodes

1. Use the WebUI Sync Nodes action; do not make divergent direct node edits.
2. Verify sync completion in the router log and progress record.
3. Verify node hashes/versions, settings preservation, observation status,
   locks, and worker idleness.

## Human validation

1. Prepare the target and recovery expectations.
2. Run non-disruptive checks first.
3. Run each disruptive action one at a time with the human gate active.
4. Inspect router and node logs after each test.
5. Keep backups and evidence until the release is accepted.

Never overwrite user settings as part of a normal script/UI deployment. Do not
reboot, restore, synchronize, or run Apply without the appropriate approval.

## Developer-tool rollout checklist

When a development branch changes `dev-tools/tests/router` or
`dev-tools/safety`:

1. validate the source scripts locally and on the main router;
2. deploy normal addon/runtime changes to the main router;
3. run development Sync Nodes;
4. verify node hashes, modes, `sh -n`, and the focused node selftest;
5. confirm PC-only docs/plans/evidence/specs were not copied;
6. record the result before any human-controlled Apply test.

A source-to-router deployment and a router-to-node Sync Nodes rollout are two
different operations. Passing one does not prove the other.
