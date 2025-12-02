# MerVLAN

MerVLAN is an addon for Asuswrt‑Merlin that adds a **graphical VLAN manager directly inside the stock Asus/Merlin web UI**.

It is designed for AP‑mode deployments and lets you:

- Assign VLANs per SSID (Wi‑Fi network)
- Assign VLANs per physical LAN port
- (Experimental) Configure trunk ports for daisy‑chained APs
- Synchronize VLAN config to other Asuswrt‑Merlin nodes over SSH

The addon installs under the normal Merlin web interface (LAN section) and handles the low‑level bridge/VLAN wiring for you.

> **MerVLAN is not a router or managed switch.** It tags and bridges traffic at the AP; you still need a VLAN‑aware upstream switch/firewall for routing, DHCP, and policy.

---

## Status / Beta Notes

- **Status:** Public beta – expect bugs and breaking changes.
- **Mode:** **AP‑mode only** (main and nodes must be running as APs, not routers).
- If you hit issues, collect logs and share them (Discord/SNB/PM):
  - CLI output:
    - `/tmp/mervlan_tmp/logs/cli_output.log` (also visible via the UI)
  - VLAN manager:
    - `/tmp/mervlan_tmp/logs/vlan_manager.log` (also visible via the UI)

---

## What MerVLAN Actually Does

High level:

- Adds a **VLAN configuration UI** into Asuswrt‑Merlin so you don’t need to maintain custom scripts by hand.
- Converts your choices into the right mix of **SSID ↔ interface mapping, bridges, and VLAN interfaces** for your device.
- Keeps configuration **persistent across reboots** and **repairs it if something breaks**.

Under the hood (simplified):

- Detects hardware capabilities (SSIDs, LAN ports, guest slots, etc.) via `functions/hw_probe.sh` and stores them in `settings/settings.json`.
- Maps each SSID and LAN port to VLANs based on your UI selections and writes a canonical JSON config.
- Applies VLAN tagging/bridging via `functions/mervlan_manager.sh` and friends.
- Hooks into `services-start` and `service-event` using templates in `templates/mervlan_templates.sh` so VLANs re‑apply automatically on boot and certain system events.
- Uses a health‑check/cron‑style script (`functions/heal_event.sh`) to detect if VLAN bridges go missing and re‑apply them.

This gives you a repeatable, UI‑driven way to deploy and maintain VLANs on Asuswrt‑Merlin APs.

---

## Key Features

**UI‑driven VLAN management**

- Per‑SSID VLAN tagging (up to the number of SSIDs supported by your device).
- Per‑LAN‑port VLAN tagging for access ports.
- **Experimental trunk support** for daisy‑chaining AP units via Ethernet backhaul.
- Built‑in “Clients Overview” panel to see which VLAN clients are active on each node.

**Multi‑AP / Multi‑node aware**

- Syncs configuration and scripts to other Asuswrt‑Merlin APs/nodes over SSH using `functions/sync_nodes.sh`.
- Supports mixed models as long as they run Asuswrt‑Merlin (or compatible) with addon support.
- Optional modes to run VLAN manager locally, on nodes only, or on both.

**Self‑healing behavior**

- `functions/heal_event.sh` and service hooks monitor VLAN bridges.
- If VLAN bridges disappear (e.g., you changed LAN/Wi‑Fi settings and Merlin wiped them), MerVLAN re‑applies the expected configuration.
- Health check runs on a short interval (worst‑case downtime roughly a few minutes); in testing, stable setups run for weeks without observed VLAN drops.

**Safe integration with Merlin**

- Uses templates in `templates/mervlan_templates.sh` instead of blindly overwriting `services-start`/`service-event`.
- Hooks are injected in a variant‑aware way and can be removed cleanly by the uninstall script.

**Logging and debugging**

- Structured logs in `/tmp/mervlan_tmp/logs/`:
  - `vlan_manager.log` – core apply pipeline
  - `cli_output.log` – what the UI shows in the command output panel
  - Additional logs for node sync, hardware probe, etc.
- Logs are also exposed via the UI under `/www/user/mervlan/tmp/logs`.

**Install/Update lifecycle**

- First‑install script lays out directories, installs hooks, and provisions the UI.
- Update script (`functions/update_mervlan.sh`) can refresh the addon in‑place while preserving `settings/settings.json` and SSH keys.
- A public copy of settings is kept under `/www/user/mervlan/settings/settings.json` for the SPA to read.

---

## Requirements

- **Asuswrt‑Merlin firmware** with addon support on every device that will tag VLANs.
- **AP‑mode only** on all participating routers/APs.
- **JFFS enabled** for persistent storage.
- **SSH enabled** on the main AP and any standalone APs/nodes (AiMesh nodes share SSH keys).
- **Ethernet backhaul only** between nodes/APs:
  - Wi‑Fi backhaul cannot preserve VLAN tags on Asus hardware/driver stacks.
  - Daisy‑chaining APs over Ethernet (switch → AP → AP) is supported and under active testing.
- **VLAN‑aware upstream device** (mandatory):
  - Managed switch and VLAN‑aware router/firewall (e.g., OPNsense, pfSense, Asus Pro, etc.).
  - MerVLAN does **not** provide routing, firewalling, or DHCP; those must be handled upstream.

Multi‑AP notes:

- All APs must connect to **VLAN‑aware switches**.
- LAN port VLAN tagging is currently **global** – the same per‑port mapping is applied to all synced APs.
  - Per‑device LAN port settings are planned but not yet available; for now, any per‑device tweaks must be applied manually via SSH.

SSH key behavior:

- On typical AiMesh setups, the **main AP’s SSH key** (installed via MerVLAN’s “SSH Key Install” flow) is shared with AiMesh nodes by the firmware.
- For **standalone APs used as nodes** (non‑AiMesh), you must **manually install the same public key** on each unit, just as you did on the main AP, before MerVLAN can sync and execute remotely on them.

---

## Limitations

- Maximum number of VLANs is effectively bounded by the number of SSID slots on your hardware (e.g., if the AP supports 5 SSIDs, you can’t have 12 actively used VLANs mapped to SSIDs).
- Mesh behavior is constrained by Asus firmware:
  - Some models support more guest SSIDs than they can actually mesh; non‑mesh SSIDs will only broadcast from the main node.
  - Devices on VLANs use standard band steering; per‑VLAN steering is not supported.
- Wi‑Fi backhaul cannot carry VLAN tags; only Ethernet backhaul is supported for VLAN‑aware nodes.
- MerVLAN does not: route traffic, run DHCP, or replace a firewall.

---

## Install

Only install if you are comfortable with **beta software** and have a way to recover (including factory reset) if something goes wrong.

SSH into the AP and run this command. The addon will be placed under **LAN → MerVLAN** in the GUI:

```sh
mkdir -p /jffs/addons/mervlan \
  && /usr/sbin/curl -fsL --retry 3 "https://raw.githubusercontent.com/r80xcore/mervlan/refs/heads/main/install.sh" \
       -o "/jffs/addons/mervlan/install.sh" \
  && chmod 0755 /jffs/addons/mervlan/install.sh \
  && /jffs/addons/mervlan/install.sh full
```

This will:

- Create `/jffs/addons/mervlan` and required subdirectories.
- Install the core scripts under `functions/` and configs under `settings/`.
- Install the web UI under `/www/user/mervlan`.
- Inject the required `services-start` / `service-event` hooks.

If the web UI ever looks out of sync or partially broken after manual file changes, you can use a quick uninstall + reinstall as a **manual flush/refresh** of the public UI and addon files:

```sh
/jffs/addons/mervlan/uninstall.sh && /jffs/addons/mervlan/install.sh
```

---

## Uninstall

From `/jffs/addons/mervlan` on the AP:

- **Standard uninstall** (leave addon data directories in place):

  ```sh
  ./uninstall.sh
  ```

- **Full uninstall** (also removes addon directories and temp workspace):

  ```sh
  ./uninstall.sh full
  ```

  This will remove `/jffs/addons/mervlan` and `/tmp/mervlan_tmp` and attempt to clean up the service hooks.

---

## Update

You can update the addon in‑place while preserving your settings and SSH keys.

On the main AP, run:

```sh
/jffs/addons/mervlan/functions/update_mervlan.sh
```

The updater will:

- Download the latest snapshot from GitHub.
- Validate required files and directories.
- Stage the new version, copy over `settings/settings.json` and SSH keys, and swap atomically.
- Re‑run the hardware probe and resync files to nodes (when SSH keys and nodes are configured).
- Refresh the public web copy and reinstall hooks.

Node/remote APs that are configured and reachable over SSH will also be synced automatically.

Updating the addon directly from the GUI (without SSH) is planned and under active development.

---

## Logs & Debugging

Primary log directory:

- `/tmp/mervlan_tmp/logs`

Common logs:

- `vlan_manager.log` – VLAN apply pipeline and health checks.
- `cli_output.log` – mirrored output of commands run from the UI.
- Additional logs for node sync, hardware probe, and other helpers.

You can tail these over SSH, for example:

```sh
tail -f /tmp/mervlan_tmp/logs/cli_output.log
tail -f /tmp/mervlan_tmp/logs/vlan_manager.log
```

These same logs are exposed via the web UI using symlinks under:

- `/www/user/mervlan/tmp/logs`

Log formatting, colors, and syslog tagging are configurable in:

- `settings/log_settings.sh`

---

## Development / Testing Notes

- Developed on an **ASUS XT8** mesh system in AP‑mode.
- Intended to work with most newer Asuswrt‑Merlin / Gnuton‑supported routers and mesh AP systems when used as APs.
- Daisy‑chained AP topologies (switch → AP → AP) are under active testing; experimental trunk options are exposed in the UI.

For structured beta testing and discussion, see the SNBForums thread and Discord (links below)

- **MerVLAN on Discord:** <https://discord.gg/8c3C8q54hn>
- **MerVLAN on SNBForums:** <https://www.snbforums.com/threads/mervlan-v0-50-simple-and-powerful-vlan-management-beta.95936/#post-972292>

---

## Changelog

See `changelog.txt` in this repository for detailed version history and notes.

---

## License

See `LICENSE` for full license details.
