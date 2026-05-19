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
  - Main log:
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

## Help wanted: LAN/ETH port mapping (device support)

To add official support for more routers, we need accurate LAN port mapping (LAN1 → LANX → ethX). The helper script below walks you through mapping and creates everything needed for upstream support.

### What the mapper does

- Detects the WAN/uplink interface.
- Guides you through mapping each physical LAN port.
- Generates a ready‑to‑use `hw_probe.sh` case snippet.
- Writes a full report to `/tmp/mervlan_tmp/results`.
- Provides a pre‑filled GitHub issue link for submission.
- Optionally patches a local MerVLAN install for temporary support.

### Run the mapper (one‑liner)

```sh
mkdir -p /tmp/mervlan_tmp && /usr/sbin/curl -fsL --retry 3 "https://raw.githubusercontent.com/r80xcore/mervlan/dev/functions/device_support_mapper.sh" -o "/tmp/mervlan_tmp/device_support_mapper.sh" && chmod 0755 /tmp/mervlan_tmp/device_support_mapper.sh && sh /tmp/mervlan_tmp/device_support_mapper.sh
```

### How to use it

1. **Start with only the WAN cable connected.**
2. **Unplug all LAN cables** before running the script.
3. **WAN detection (Step 1/2):** the script detects the WAN/uplink interface.
4. **LAN mapping (Step 2/2):**
   - Enter the number of physical LAN ports (excluding WAN).
   - For each LAN port (LAN1 → LANX):
     - Unplug the cable when prompted.
     - Plug into the requested LAN port.
     - Press Enter and confirm the detected interface.
   - You can retry, skip, or quit at any step.
5. **Report generation:** submit the pre‑filled GitHub issue link (add extra notes if needed).

### Important notes

- MerVLAN does **not** need to be installed to run the mapper.
- `/tmp` is cleared on reboot—save the report or submit the issue.
- Local patching is a stopgap; please submit the report for official support.
- Primary testing target is AP mode, but router‑mode validation is helpful too.

### Community‑added model support

Special thanks to everyone who contributed mappings.
```
| Model         | Contributor             | From    | Added in version |
| ------------- | ----------------------- | ------- | ---------------- |
| RT‑AC86U      | mistermoonlight1        | SNB     | v0.52.3          |
| RT‑AX86U      | mistermoonlight1        | SNB     | v0.52.4          |
| GT‑AX6000     | kstamand                | SNB     | v0.52.4          |
| RT‑AX86S      | bieniu                  | Github  | v0.52.3          |
| RT‑AX58U      | commodoro               | SNB     | v0.52.4          |
| RT‑AX82U      | pxdl                    | Github  | v0.52.93         |
| RT‑AX86U_PRO  | davittoncat             | Github  | v0.52.94         |
| RT‑AX88U**    | amplatfus               | SNB     | v0.52.4          |
| RT‑AX88U_PRO  | jksmurf                 | SNB     | v0.52.4          |
| RT‑AX92U      | RikshaDriver            | Github  | v0.52.94         |
| RT‑AX92U      | Mudcrab353              | Github  | v0.52.96         |
| RT‑AX92U      | franzatkiermeyereu      | Github  | v0.52.96         |
| RT‑AX95Q      | mdraco11                | Github  | v0.52.93         |
| RT‑AX5400     | tooty-1135              | Github  | v0.52.96         |
| RT‑BE92U**    | brzd                    | SNB     | v0.52.92         |
| TUF‑AX3000_V2 | piratak                 | Github  | v0.52.96         |
```
**RT‑AX88U:** LAN1–LAN4 map individually; LAN5–LAN8 are grouped as LAN5 for tagging.
**RT‑BE92U:** LAN1–LAN4 share one VLAN bridge — no per-port isolation.

### Manual template (if you already know the mapping)

Use the template below (text in brackets is informational):

```sh
RT-AX86U) MODEL="RT-AX86U"; ETH_PORTS="eth4 eth3 eth2 eth1 eth5"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4 LAN5"; MAX_ETH_PORTS=5; WAN_IF="eth0" ;;
[nvramname]     [ model  ]            [        interface       ]                  [        LAN ports       ] [ Max LAN ports ]    [wan port]
```

Example with a different nvram name than the commonly used name:

```sh
RT-AX95Q) MODEL="XT8"; ETH_PORTS="eth1 eth2 eth3"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth0" ;;
```

Example where WAN is not `eth0`:

```sh
RT-AX58U) MODEL="RT-AX58U"; ETH_PORTS="eth3 eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3 LAN4"; MAX_ETH_PORTS=4; WAN_IF="eth4" ;;
```

Find your nvramname with:

```sh
nvram get productid
```

MODEL= can either be the same name as the nvramname or another if the unit is commonly knows something else, as the XT8 shows.

### Models requiring testing

WiFi 7 / BE Series:

- RT‑BE58 Go
- RT‑BE86U
- RT‑BE88U
- RT‑BE92U
- RT‑BE96U
- GT‑BE98 Pro
- GT‑BE19000AI

ROG & high‑performance series:

- GT‑AX11000
- GT‑AX11000 Pro
- GT‑AXE11000
- GT‑AXE16000
- RT‑AX86U Pro

TUF Gaming series:

- TUF‑AX3000 v1
- TUF‑AX3000 v2
- TUF‑AX5400 v1

Standard RT‑AX series:

- RT‑AX5400
- RT‑AX58U v2
- RT‑AX68U
- RT‑AX82U v1
- RT‑AX82U v2
- RT‑AX92U
- DSL‑AX82U
- DSL‑AX5400

ZenWiFi (mesh) series:

- ZenWiFi ET8
- ZenWiFi Pro XT12

Models added to the support table are excluded from this list. Any help testing is appreciated.

---

## Install

Only install if you are comfortable with **beta software** and have a way to recover (including factory reset) if something goes wrong.

SSH into the AP and run this command. The addon will be placed under **LAN → MerVLAN** in the GUI:

```sh
mkdir -p /jffs/addons/mervlan && /usr/sbin/curl -fsL --retry 3 "https://raw.githubusercontent.com/r80xcore/mervlan/refs/heads/main/install.sh" -o "/jffs/addons/mervlan/install.sh" && chmod 0755 /jffs/addons/mervlan/install.sh && /jffs/addons/mervlan/install.sh full
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
