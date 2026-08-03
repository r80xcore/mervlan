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

## WSL2 preflight

On Windows, perform the POSIX-capable local test phase in the registered
Ubuntu WSL2 distro. Do not use `wsl.exe --version` alone as proof: it verifies
only the client. Confirm the exact distro and `VERSION 2` with
`wsl.exe --list --verbose`, then run a harmless command in that named distro.

If the normal agent runner returns `E_ACCESSDENIED` or
`WSL/.../E_ACCESSDENIED`, classify it as `HOST_RUNNER_ACCESS_DENIED` and retry
the same read-only probe through the approved host/elevated execution path.
Do not report WSL2 as unavailable merely because the runner lacks access to
the WSL service. A distro listed as `Stopped` is installed and may be started
for the probe. If no approved host path can access WSL, mark POSIX tests
`INCONCLUSIVE` and state that the runner could not access WSL; never report
those tests as passed.
