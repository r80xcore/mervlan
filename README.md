
# MerVLAN

MerVLAN is an addon for Asuswrt‑Merlin focused on AP-mode deployments. It provides multi-node VLAN management with per-SSID and per‑Ethernet‑port tagging, a lightweight web UI, and boot/service-event integration so changes persist across reboots. Addon is placed under the "Tools" section on the UI.

# Important

Addon is in beta. Issues might be present.

## Features

- Per-SSID and per‑Ethernet‑port VLAN tagging
- Multi-node support: propagate actions to configured nodes over SSH
- Automatic boot integration via services-start and service-event
- Simple web UI served from the router under /www/user/mervlan
- Safe, variant-aware injection/removal for startup scripts (no blind overwrite)
- Structured logging to /tmp/mervlan_tmp/logs and optional syslog tagging
- First-install “full” workflow that lays out directories and downloads the addon

## Requirements

- Asuswrt‑Merlin firmware with addon support.
- SSH enabled on the router (Dropbear) and admin access
- Basic BusyBox utilities: sh, awk, sed, grep, tar, gzip, curl

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

## Logs

- Primary log dir: /tmp/mervlan_tmp/logs
- The UI exposes log views via symlinks under /www/user/mervlan/tmp/logs
- Logging behavior, colors, and syslog tagging are configured in settings/log_settings.sh

## License

See LICENSE for details.
