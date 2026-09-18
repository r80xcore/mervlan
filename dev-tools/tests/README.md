# Developer tests

Tests are separated by execution target:

- `local/` — safe checkout/library tests.
- `router/` — executable test drivers that may be copied to development
  routers and nodes by `Sync Nodes`.
- `specs/` — test matrices and coverage requirements, never copied to
  devices.

Files named `deep_audit_*.sh` under `local/` are historical reproduction
fixtures. They preserve evidence for previously fixed defects and are not part
of the maintained green regression gate unless a current plan explicitly names
one as a reproduction diagnostic.

Run the narrowest applicable test first. Native Ubuntu is the default host for
local tests. A host-shell result does not prove ASUSWRT BusyBox compatibility;
affected shell files must also pass `busybox sh -n` and focused tests in the
router-capable environment.

## Native Linux preflight

See `dev-tools/docs/platform-linux.md` for the Ubuntu package baseline.

From the repository root, verify the host and required tools before running the
maintained local suite:

```sh
uname -a
cat /etc/os-release
for tool in sh busybox node ssh scp openssl; do
    type "$tool" >/dev/null 2>&1 || exit 1
done
```

Run `dev-tools/tests/local/run_all.sh` for the complete local gate. It runs the
maintained shell tests and the checked-in Node.js behavior tests sequentially;
it does not run historical `deep_audit_*.sh` fixtures.

## Windows/WSL2 preflight

Windows users should follow the conditional workflow in
`dev-tools/docs/platform-windows-wsl.md`. WSL2 is not a prerequisite for a
native Linux checkout, and a WSL2 or host-shell result still does not replace
router-side BusyBox validation.
