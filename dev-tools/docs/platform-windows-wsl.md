# Windows and WSL2 host appendix

This document applies only when the development computer runs Windows. Native
Linux/Ubuntu users should follow the normal host preflight in
`90-testing-and-evidence.md` and do not need WSL2.

## WSL2 preflight

Run these checks from the Windows host before using WSL for POSIX tests:

1. Verify `wsl.exe` exists and run `wsl.exe --version`.
2. Run `wsl.exe --list --verbose` and confirm the exact Ubuntu distro reports
   `VERSION 2`. A `Stopped` distro is installed and valid.
3. Run a harmless command in that exact distro:
   `wsl.exe -d <registered-distro-name> -- sh -lc 'uname -a; cat /etc/os-release'`.

`wsl.exe --version` verifies only the client. If enumeration or startup
returns `E_ACCESSDENIED` or `WSL/.../E_ACCESSDENIED`, classify it as
`HOST_RUNNER_ACCESS_DENIED` and retry the same read-only probe through the
approved host/elevated path. If no approved path can access WSL, mark POSIX
results `INCONCLUSIVE`, not `PASS`.

Keep WSL checkouts on the native Windows mount only for this Windows workflow;
give each test a dedicated path below `/tmp`. Never use `/`, `/etc`, `/usr`,
`/bin`, `/lib`, `/home`, or an unresolved variable as a test or cleanup root.

## Recovery of a damaged distro

Use this only after the host-level probe proves that the distro cannot start or
that critical paths such as `/etc`, `/bin/sh`, or `/bin/mount` are missing. A
mount-translation message alone is not sufficient. Stop all agents using the
distro and appoint one operator for recovery.

1. Record the WSL version, distro listing, exact startup error, and relevant
   system diagnostics.
2. Export the affected distro before deleting or replacing anything:

   ```powershell
   wsl.exe --terminate <broken-distro-name>
   New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\WSL-Backups"
   wsl.exe --export <broken-distro-name> "$env:USERPROFILE\WSL-Backups\<name>-damaged.vhdx" --format vhd
   Get-Item -LiteralPath "$env:USERPROFILE\WSL-Backups\<name>-damaged.vhdx"
   ```

   Keep the export outside the repository. Treat a nonzero or unexpectedly
   small export as a failed backup. Do not unregister until it is verified.
3. Preserve the original VHD and salvage only known user/project data. Do not
   copy damaged `/etc`, `/bin`, `/lib`, `/usr`, or root-level symlinks over a
   clean distro.
4. With explicit approval, remove only the proved-broken registration and
   restore a verified baseline into a new directory:

   ```powershell
   wsl.exe --unregister <broken-distro-name>
   wsl.exe --import <expected-name> <new-install-directory> <clean-baseline.vhdx> --vhd --version 2
   ```

   If no baseline exists, install the same known Ubuntu release instead:

   ```powershell
   wsl.exe --install <matching-Ubuntu-release> --name <expected-name> --version 2 --no-launch --web-download
   ```

   `--unregister` deletes the registration's root filesystem. Keep the
   verified export until the clean distro and recovered data are confirmed.
5. Use a normal unprivileged account for AI-driven test work. Use `-u root`
   only for an intentional, reviewed administration command.
6. Verify the rebuilt distro before restoring data or running tests:

   ```powershell
   wsl.exe --list --verbose
   wsl.exe -d <name> -- sh -lc 'id; getent passwd 0; test -x /bin/sh; test -x /bin/mount; cat /etc/os-release'
   wsl.exe -d <name> -- sh -lc 'test -d /mnt/c; cd /mnt/c/<checkout>; pwd; test -f dev-tools/docs/90-testing-and-evidence.md'
   ```

Do not run WSL installation, unregister, shutdown, or repair commands as an
automatic capability probe. WSL2 checks never replace final ASUSWRT BusyBox
validation on the router.
