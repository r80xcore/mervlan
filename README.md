
# MerVLAN

MerVLAN is an addon for Asuswrt‑Merlin focused on AP-mode deployments. It provides multi-node VLAN management with per-SSID and per‑Ethernet‑port tagging, a lightweight web UI, and boot/service-event integration so changes persist across reboots. Addon is placed under the "LAN" section on the UI.

# Important

Addon is in beta. Issues might be present. 

Addon is only for routers in **AP-mode**.
You need 

## Features

- Per-SSID and per‑Ethernet‑port VLAN tagging
- Multi-node support: propagate actions to configured nodes over SSH
- Automatic boot integration via services-start and service-event
- Simple web UI served from the router under /www/user/mervlan
- Safe, variant-aware injection/removal for startup scripts (no blind overwrite)
- Structured logging to /tmp/mervlan_tmp/logs and optional syslog tagging
- First-install “full” workflow that lays out directories and downloads the addon
- Easy updating with settings preserved through one command.

## Requirements

- **Asuswrt-Merlin firmware** with addon support (required on all  devices that is supposed to tag VLAN)
- **SSH enabled** on the main AP and standalone AP's (AiMesh-nodes share SSH keys)
- **JFFS enabled** for persistent storage
- (Important!) **AP-mode only for now**
- (Important!) **VLAN-aware upstream device** (e.g., managed switch and/or router such as OPNsense, pfSense, Asus Pro etc.) VLAN routing, rules, and DHCP must be handled **upstream**, MerVLAN only handles tagging and bridging at the AP level for the time being. (Investigations into alternative ways are being done.)
- (Important!) **Ethernet Backhaul ONLY** Wi-Fi backhaul is not capable of preserving VLANs. This is a know limitation and nothing i can affect. (Research of L3 tunneling via Wireguard is being done, but no promises here.)

## Install

SSH into the AP and run this command to install the addon. The addon will
be places under "Tools" in the GUI.
```
mkdir -p /jffs/addons/mervlan && /usr/sbin/curl -fsL --retry 3 "https://raw.githubusercontent.com/r80xcore/mervlan/refs/heads/main/install.sh" -o "/jffs/addons/mervlan/install.sh" && chmod 0755 /jffs/addons/mervlan/install.sh && /jffs/addons/mervlan/install.sh full
```

## Uninstall

- Standard uninstall: ./uninstall.sh
- Full uninstall (also removes addon directories and temp workspace):
	- ./uninstall.sh full
	- Removes /jffs/addons/mervlan and /tmp/mervlan_tmp

## Update

- To update the addon, SSH into the AP and run:
```/jffs/addons/mervlan/functions/update_mervlan.sh```
  This will preserve your settings and update the addon to the
  newest version. If you have any nodes connected, these will
  also be updated automatically.

## Logs

- Primary log dir: /tmp/mervlan_tmp/logs
- The UI exposes log views via symlinks under /www/user/mervlan/tmp/logs
- Logging behavior, colors, and syslog tagging are configured in settings/log_settings.sh

# Changelog

mervlan v0.46 (see changlog.txt for details)

## License

See LICENSE for details.
