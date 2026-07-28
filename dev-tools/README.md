# MerVLAN Developer Tools

This directory exists on development and test branches. It contains developer
documentation, test drivers, safety helpers, planning files, and local test
evidence. It is not part of the production runtime contract.

Start here:

- `docs/` — architecture, runtime flow, limitations, deployment, and
  troubleshooting notes.
- `tests/local/` — safe tests that run against the checkout and production
  libraries without router hardware.
- `tests/router/` — router-capable test drivers copied by development
  `Sync Nodes`.
- `tests/specs/` — test matrices and coverage requirements.
- `safety/` — safety helpers for controlled live testing.
- `to-do/` — implementation plans and development work records.
- `evidence/` — locally downloaded test evidence; raw contents are ignored by
  Git.

The router-capable tools test the installed production runtime. They must not
become a runtime dependency. A development `Sync Nodes` run copies only the
executable router tools to each configured node under the node's own
`/jffs/addons/mervlan/dev-tools/` directory. Documentation, planning files,
evidence, local tests, and test specifications remain on the
development computer.

## Evidence rule

Router and AP test evidence belongs under a unique directory below:

```text
/tmp/mervlan_tmp/evidence/<test-run-id>/
```

Download it to `dev-tools/evidence/<test-run-id>/`, verify the download, then
delete the remote evidence directory. Never delete remote evidence before the
local copy has been checked. Do not commit secrets, raw client identifiers, or
large device dumps.

See `docs/90-testing-and-evidence.md` and `evidence/README.md` for the full
workflow.

Use `docs/README.md` as the navigation map and `docs/92-test-workflows.md` as
the command-by-command test guide. The numbered notes are intentionally
focused; read only the route relevant to the change, then return for another
note if an ownership or safety contract remains unclear.
