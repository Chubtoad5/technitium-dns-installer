# Technitium DNS Server Installer

A bash automation script that installs and configures [Technitium DNS Server](https://technitium.com/dns/)
on a Linux host, following the conventions of the Chubtoad5 automation tool family. It is a
**bare-metal** installer (no containers): online installs wrap Technitium's official `install.sh`,
air-gapped installs replicate those steps from a saved bundle, and post-install configuration is
driven through the Technitium HTTP API.

This is **v1.0**, which covers install / upgrade / uninstall / air-gap `save`, initial admin password,
web-console port, and optional self-signed HTTPS. Zone & record templating, DHCP scopes, DNS
forwarders, and DNSSEC signing are planned for **v1.1** (the environment variables for them are already
defined for a stable contract, but are ignored in v1.0 — the installer prints a notice if you set them).

---

## Table of Contents

- [Quick Start](#quick-start)
- [Commands](#commands)
- [Environment Variables (v1.0)](#environment-variables-v10)
- [Air-Gapped Install](#air-gapped-install)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [What it changes on the host](#what-it-changes-on-the-host)
- [Roadmap (v1.1)](#roadmap-v11)

---

## Quick Start

On an internet-connected Ubuntu / RHEL / SLES host, as root:

```bash
git clone https://github.com/Chubtoad5/technitium-dns-installer.git
cd technitium-dns-installer
sudo DNS_ADMIN_PASSWORD='ChangeMe123!' ./technitium_dns_installer.sh install
```

When it finishes, open the printed web-console URL (default `http://<host-ip>:5380/`) and log in as
`admin` with the password you set.

A more customised install — different HTTP port and a self-signed HTTPS console:

```bash
sudo DNS_ADMIN_PASSWORD='ChangeMe123!' \
     DNS_WEB_PORT=8053 \
     ENABLE_HTTPS=true DNS_HTTPS_PORT=53443 \
     ./technitium_dns_installer.sh install
```

> Requirements: a systemd-based distro, `curl`, and root (sudo). The installer pulls the ASP.NET Core
> runtime, the DNS Server package, and the `libicu` OS package automatically.

---

## Commands

| Command | Description |
|---|---|
| `install` | Install the DNS server (default). Uses the upstream `install.sh` when online; runs fully offline if an air-gap bundle is present. Then applies the admin password and web-service settings. |
| `save` | Build an air-gap bundle (`technitium-save.tar.gz`) containing the DNS package, the ASP.NET Core runtime, the `libicu` package, and the installer. |
| `upgrade` | Upgrade an existing install to the latest DNS Server build. Online re-runs `install.sh`; offline extracts the bundled build. Config in `/etc/dns` is preserved. |
| `uninstall` | Stop and remove the DNS server (non-interactive). Honours `PURGE_DATA` and `REMOVE_DOTNET`. |
| `help` | Show usage. |

---

## Environment Variables (v1.0)

All variables are overridden at runtime, e.g. `sudo VAR=value ./technitium_dns_installer.sh install`.

| Variable | Default | Description |
|---|---|---|
| `DNS_ADMIN_USER` | `admin` | Built-in admin account name (renaming is not supported in v1.0). |
| `DNS_ADMIN_PASSWORD` | `changeme` | Password set for the admin account on install. **Change this.** |
| `DNS_WEB_PORT` | `5380` | Web-console HTTP port. |
| `ENABLE_HTTPS` | `false` | Serve the web console over HTTPS with a self-signed certificate. |
| `DNS_HTTPS_PORT` | `53443` | HTTPS port (used only when `ENABLE_HTTPS=true`). |
| `DISABLE_SYSTEMD_RESOLVED` | `true` | Stop/disable `systemd-resolved` and point the host at `127.0.0.1` (mirrors upstream `install.sh`). Set `false` to leave the host resolver untouched. |
| `PURGE_DATA` | `false` | On `uninstall`, also delete `/etc/dns` (all zones/config) and the logs. |
| `REMOVE_DOTNET` | `false` | On `uninstall`, also delete `/opt/dotnet` (the ASP.NET Core runtime). |
| `DEBUG` | `1` | `1` = verbose command tracing; `0` = quiet. |

**Source/version override knobs** (rarely needed): `TECHNITIUM_INSTALL_URL`, `TECHNITIUM_UNINSTALL_URL`,
`TECHNITIUM_PACKAGE_URL`, `DOTNET_INSTALL_URL`, `DOTNET_VERSION`, `INSTALL_PACKAGES_URL`.

---

## Air-Gapped Install

On an internet-connected build host **of the same distro family and CPU architecture** as the target:

```bash
sudo ./technitium_dns_installer.sh save      # produces technitium-save.tar.gz
```

Copy `technitium-save.tar.gz` to the air-gapped host, then:

```bash
tar -xzf technitium-save.tar.gz
sudo DNS_ADMIN_PASSWORD='ChangeMe123!' ./technitium_dns_installer.sh install
```

The installer auto-detects the bundle (via the `technitium-save-version.txt` sentinel) and installs
entirely offline — extracting the bundled ASP.NET Core runtime and DNS package, and installing the
`libicu` package from the bundle via `install-packages`.

> The bundle is **OS-family / architecture specific**. Build it on a host matching the target.

---

## Upgrade

```bash
sudo ./technitium_dns_installer.sh upgrade          # online
# air-gapped: extract a newer technitium-save.tar.gz first, then:
sudo ./technitium_dns_installer.sh upgrade
```

Upgrades preserve all configuration and zone data in `/etc/dns`.

---

## Uninstall

```bash
sudo ./technitium_dns_installer.sh uninstall                       # keep config + .NET runtime
sudo PURGE_DATA=true REMOVE_DOTNET=true ./technitium_dns_installer.sh uninstall   # full removal
```

Unlike the upstream interactive uninstaller, this is non-interactive and controlled entirely by the
`PURGE_DATA` / `REMOVE_DOTNET` flags. It restores the host resolver (`/etc/resolv.conf`,
`systemd-resolved`, NetworkManager `dns=` setting).

---

## What it changes on the host

- Installs the ASP.NET Core runtime to `/opt/dotnet` (symlink `/usr/bin/dotnet`) and the `libicu` package.
- Installs the DNS server to `/opt/technitium/dns`, config to `/etc/dns`, logs to `/var/log/technitium/dns`.
- Creates a `dns-server` system user and a `dns.service` systemd unit (listens on UDP/TCP 53 and the web port).
- When `DISABLE_SYSTEMD_RESOLVED=true` (default): disables `systemd-resolved`, sets NetworkManager
  `dns=none`, backs up `/etc/resolv.conf` to `/opt/technitium/dns/resolv.conf.bak`, and points the host at
  `127.0.0.1`. Because the server binds port 53, do not run it on a host already providing DNS.

---

## Roadmap (v1.1)

The following are planned and their environment variables are already reserved (defined but inert in v1.0):

- **Primary zones + A records** from a template file (`ZONES_TEMPLATE`). See [`zones.template.txt`](zones.template.txt) for the format.
- **DNS forwarders** (`DNS_FORWARDERS`, `DNS_FORWARDER_PROTOCOL`).
- **DNSSEC** signing of created zones (`ENABLE_DNSSEC`).
- **DHCP scope** creation + enable with domain name, DNS search list, DNS updates, router, and NTP
  (`ENABLE_DHCP`, `DHCP_*`).
