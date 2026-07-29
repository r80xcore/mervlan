# Developer tests

Tests are separated by execution target:

- `local/` — safe checkout/library tests.
- `router/` — executable test drivers that may be copied to development
  routers and nodes by `Sync Nodes`.
- `specs/` — test matrices and coverage requirements, never copied to
  devices.

Run the narrowest applicable test first. A shell result on Windows does not
prove ASUSWRT BusyBox compatibility; affected shell files must also pass
`sh -n` and focused tests in a POSIX/BusyBox-capable environment.
