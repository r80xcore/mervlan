# Node sync and SSH

## Roles

The main router is the deployment source and cluster coordinator. Nodes receive
the curated runtime subset through Sync Nodes; do not make divergent direct
edits on a node.

## Sync flow

1. Validate configured node IDs, IPs, duplicates, and SSH reachability.
2. Verify the main-router source and settings before touching a node.
3. Create a node-local staging directory below the approved addon root.
4. Copy explicit files using the supported legacy SCP protocol when required.
5. Check file presence, mode/owner, and BusyBox `sh -n` in staging.
6. Activate with an exact same-filesystem move and retain rollback information.
7. Publish a validated per-node terminal result and aggregate the run.
8. Verify node hashes, versions, observation state, and idle workers afterward.

On development and test branches, the same staged pipeline also copies:

```text
dev-tools/tests/router/mervlan_selftest.sh
dev-tools/safety/mervlan_live_test_guard.sh
```

to the corresponding `dev-tools/` paths inside each node's addon. The
developer manifest is empty when these files are absent, so a production-style
tree without `dev-tools/` follows the normal runtime-only sync flow. Developer
documentation, planning, evidence, local tests, specifications, and agent
rules are never copied to devices.

## SSH limits

- Keep total simultaneous SSH sessions, including log monitoring, at two or
  fewer.
- Use bounded noninteractive connections and no host-key bypass.
- Use explicit paths, not wildcards or directory destinations.
- The router's shell may not provide `command`, `timeout`, or `mktemp`.
- Close/reap one validation or monitoring session before opening another when
  the session budget is uncertain.

## Deployment boundary

Router deployment and node synchronization are separate approvals. A
router-only deployment does not authorize Sync Nodes. Apply is disruptive and
requires a human-controlled gate with target, management access, locks, DHCP
Hold, MAC Shield, healing, workers, and expected client placement verified.

## Development-tool rollout

When the checkout is on the development branch, Sync Nodes may also copy the
curated executable tools to each node:

```text
/jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh
/jffs/addons/mervlan/dev-tools/safety/mervlan_live_test_guard.sh
```

The node must not receive Markdown, plans, raw evidence, local harnesses,
specifications, or PC-only guidance files. Verify files with size, mode, hash, and `sh -n`
on the node. A node-only selftest may omit `execute_nodes.sh`, because it is a
main-router orchestration helper; do not classify that omission as a node
runtime failure.

The router shell may not provide GNU `timeout`, `mktemp`, `scp`, or Bash. Keep
SSH calls bounded by existing worker controls, use explicit paths, and preserve
the maximum two concurrent node sessions.
