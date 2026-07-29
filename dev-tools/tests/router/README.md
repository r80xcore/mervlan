# Router-capable tests

These scripts are copied by development `Sync Nodes` to:

```text
/jffs/addons/mervlan/dev-tools/tests/router/
```

They test the installed production runtime and must be run only with the
scope and safety controls described in the developer test workflow.
Use the evidence workflow before collecting router or AP diagnostics.

The maintained driver is `mervlan_selftest.sh`. Run the narrowest affected
case first, for example:

```sh
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh action-lifecycle
sh /jffs/addons/mervlan/dev-tools/tests/router/mervlan_selftest.sh all
```

It uses fake ebtables and isolated selftest state; it is not permission to run
Apply. See `dev-tools/docs/92-test-workflows.md` for the complete catalog and
the required post-test cleanup/evidence checks.
