# MerVLAN local SSH profile

Use this file as a template for the local SSH connection details used during
development and device testing.

## Setup

1. Copy this file to the exact path:
   `dev-tools/mervlan_ssh_credentials.md`
2. Replace every placeholder with the values for the current test network.
3. Keep the private key itself outside the repository.
4. Check the target host and account before every deployment or test.
5. Delete the populated file before committing, even though Git ignores it.

This profile contains connection metadata only. Never add a private key,
public-key contents, password, passphrase, token, or router configuration to
this file. The `SSH_KEY_PATH` value is only a path to a private key stored on
the development computer.

## Required profile format

```text
SSH_USER=
SSH_PORT=22
MAIN_ROUTER_HOST=192.168.x.x
NODE1_HOST=192.168.x.x
NODE2_HOST=none
NODE3_HOST=none
NODE4_HOST=none
NODE5_HOST=none
NODE6_HOST=none
NODE7_HOST=none
NODE8_HOST=none
NODE9_HOST=none
NODE10_HOST=none
SSH_KEY_PATH=
```

Use `none` for a node slot that is not configured. Do not leave a configured
host blank. `SSH_PORT` must be a numeric TCP port, normally `22`.

## Windows example

```text
SSH_USER=admin
SSH_PORT=22
MAIN_ROUTER_HOST=192.168.50.1
NODE1_HOST=192.168.50.2
NODE2_HOST=192.168.50.3
NODE3_HOST=none
NODE4_HOST=none
NODE5_HOST=none
NODE6_HOST=none
NODE7_HOST=none
NODE8_HOST=none
NODE9_HOST=none
NODE10_HOST=none
SSH_KEY_PATH=C:\Users\your-user\.ssh\mervlan_router_ed25519
```

Use a Windows path for `SSH_KEY_PATH`. In PowerShell, verify it exists with:

```powershell
Test-Path -LiteralPath 'C:\Users\your-user\.ssh\mervlan_router_ed25519'
```

## Linux or WSL2 example

```text
SSH_USER=admin
SSH_PORT=22
MAIN_ROUTER_HOST=192.168.50.1
NODE1_HOST=192.168.50.2
NODE2_HOST=192.168.50.3
NODE3_HOST=none
NODE4_HOST=none
NODE5_HOST=none
NODE6_HOST=none
NODE7_HOST=none
NODE8_HOST=none
NODE9_HOST=none
NODE10_HOST=none
SSH_KEY_PATH=/home/your-user/.ssh/mervlan_router_ed25519
```

Use a POSIX path when running from Linux or WSL2. Verify it exists and has
appropriate permissions with:

```sh
key_path="$HOME/.ssh/mervlan_router_ed25519"
test -f "$key_path" && test "$(stat -c '%a' "$key_path")" = 600
```

Replace `key_path` with the `SSH_KEY_PATH` value used by the current Linux or
WSL2 profile.

WSL2 and Windows do not always refer to the same key using the same path. Use
the path visible to the shell that will run `ssh` or `scp`.

## Key and trust guidance

The development computer key is used to connect to the main router and, when
needed, nodes. For router-to-node trust, use MerVLAN's **SSH Key Install**
flow: **Generate Keys**, then **Load**, and copy the complete `ssh-ed25519`
public-key line into the ASUS **Administration → System → Authorized Keys**
field. AiMesh nodes normally need a reboot for ASUS to propagate the key;
standalone APs need the public key installed in each AP's UI individually.

The addon uses `dropbearkey -t ed25519` on the main router for its
router-to-node key. If a separate development-PC key is needed, create an
Ed25519 pair with the platform's `ssh-keygen`; do not replace the addon's
Dropbear key without explicit approval. Do not manually replace
`authorized_keys` or overwrite an existing key without explicit approval.

Never commit this populated profile. Never copy a private key into the
repository, an evidence bundle, or a router log.
