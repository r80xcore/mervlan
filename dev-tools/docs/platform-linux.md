# Native Linux/Ubuntu development host

Native Linux/Ubuntu is the default host for MerVLAN development, local tests,
SSH deployment, and evidence collection. This host workflow does not require
WSL, PowerShell, Git Bash, or a Windows-mounted checkout.

## Host package baseline

Required for the maintained local gate and normal device work:

- `git`
- `openssh-client`
- `busybox-static` for an explicit BusyBox syntax check
- `nodejs` for the checked-in `.mjs` behavior tests
- `curl` and `openssl` for HTTP, transfer, and digest diagnostics
- `shellcheck` for optional POSIX shell linting
- `shfmt` for optional formatting checks

Recommended network diagnostics are `util-linux`, `iproute2`,
`iputils-ping`, `bind9-dnsutils`, and `tcpdump`.

On Ubuntu, install the baseline with APT:

```sh
sudo apt update
sudo apt install \
    git openssh-client busybox-static nodejs shellcheck shfmt \
    curl openssl util-linux iproute2 iputils-ping \
    bind9-dnsutils tcpdump
```

The current repository has no `package.json`, Makefile, native build, or
container requirement; `npm`, `gcc`, `make`, Docker, and `rsync` are not part
of the normal development gate.

## Preflight

From the repository root:

```sh
uname -a
cat /etc/os-release
for tool in sh busybox node ssh scp openssl; do
    type "$tool" >/dev/null 2>&1 || exit 1
done
```

Run the host gate with:

```sh
sh dev-tools/tests/local/run_all.sh
```

The gate runs maintained local shell tests and checked-in Node.js behavior
tests sequentially. Historical `deep_audit_*.sh` fixtures are excluded.

An installed `unshare` binary does not guarantee that mount namespaces are
allowed by the current kernel or runner. Tests must probe that capability and
use their safe fallback when it is denied.

## Device boundary

Ubuntu validates host-side syntax and deterministic contracts. Final runtime
proof still requires an authorized ASUSWRT target and its BusyBox `/bin/sh`,
because host packages cannot emulate `nvram`, `brctl`, `ebtables`, `wl`,
service-event hooks, `/jffs`, or physical VLAN/bridge behavior.
