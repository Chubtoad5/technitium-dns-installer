# Technitium DNS Server Installer

A bash automation script that installs and configures [Technitium DNS Server](https://technitium.com/dns/)
on a Linux host, following the conventions of the Chubtoad5 automation tool family. It is a
**bare-metal** installer (no containers): online installs wrap Technitium's official `install.sh`,
air-gapped installs replicate those steps from a saved bundle, and post-install configuration is
driven through the Technitium HTTP API.

**v1.1** covers install / upgrade / uninstall / air-gap `save`, initial admin password, web-console port,
optional self-signed HTTPS, **plus** optional post-install configuration via the Technitium HTTP API:
primary zones + A records from a template, DNS forwarders, DNSSEC signing, and a DHCP scope. Every
configuration block is off/empty by default — the installer only touches what you ask it to.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Commands](#commands)
- [Core Environment Variables](#core-environment-variables)
- [DNS Configuration (zones, forwarders, DNSSEC, DHCP)](#dns-configuration-zones-forwarders-dnssec-dhcp)
- [Air-Gapped Install](#air-gapped-install)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [What it changes on the host](#what-it-changes-on-the-host)
- [Roadmap](#roadmap)

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

## Core Environment Variables

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

## DNS Configuration (zones, forwarders, DNSSEC, DHCP)

All of these are optional and applied through the Technitium HTTP API after the server is up. Leave them at
their defaults to skip a block entirely.

### Primary zones + A records

Point `ZONES_TEMPLATE` at a file in the [`zones.template.txt`](zones.template.txt) format: `# <zone>` headers,
then `<name> <ipv4>` lines (label relative to the zone; `@` = apex; `*.x` = wildcard; the same name repeated =
round-robin). Each zone is created as a **Primary** zone; missing zones are created, existing ones reused.

```bash
sudo DNS_ADMIN_PASSWORD='S3cret!' ZONES_TEMPLATE=./zones.txt ./technitium_dns_installer.sh install
```

| Variable | Default | Description |
|---|---|---|
| `ZONES_TEMPLATE` | – | Path to the zone/record template. |
| `DNS_RECORD_TTL` | `3600` | TTL for A records created from the template. |

### DNS forwarders

| Variable | Default | Description |
|---|---|---|
| `DNS_FORWARDERS` | – | Comma list of upstreams, e.g. `1.1.1.1, 8.8.8.8`. Empty = root-hint recursion. |
| `DNS_FORWARDER_PROTOCOL` | `Udp` | `Udp` / `Tcp` / `Tls` / `Https`. |

### DNSSEC

| Variable | Default | Description |
|---|---|---|
| `ENABLE_DNSSEC` | `false` | Sign every primary zone created from `ZONES_TEMPLATE`. |
| `DNSSEC_ALGORITHM` | `ECDSA` | `ECDSA` / `RSA` / `EDDSA`. |
| `DNSSEC_CURVE` | `P256` | For ECDSA: `P256` / `P384`. |

### DHCP scope

Set `ENABLE_DHCP=true` plus at least the start/end addresses. The scope advertises this DNS server unless you
override `DHCP_DNS_SERVERS`. Enabling the scope requires the server to have a NIC in the scope's subnet (otherwise
the scope is created but stays disabled with a warning).

```bash
sudo ENABLE_DHCP=true DHCP_SCOPE_NAME=lan \
     DHCP_START_ADDRESS=10.20.0.100 DHCP_END_ADDRESS=10.20.0.200 \
     DHCP_SUBNET_MASK=255.255.255.0 DHCP_ROUTER=10.20.0.1 \
     DHCP_DOMAIN=lan.example DHCP_DNS_SEARCH='lan.example' \
     DHCP_NTP_SERVERS='10.20.0.1' ./technitium_dns_installer.sh install
```

| Variable | Default | Description |
|---|---|---|
| `ENABLE_DHCP` | `false` | Create + (optionally) enable a DHCP scope. |
| `DHCP_SCOPE_NAME` | `Default` | Scope name. |
| `DHCP_START_ADDRESS` / `DHCP_END_ADDRESS` | – (required) | Address pool bounds. |
| `DHCP_SUBNET_MASK` | `255.255.255.0` | Subnet mask. |
| `DHCP_ROUTER` | – | Default gateway advertised to clients. |
| `DHCP_DNS_SERVERS` | – | Comma list; empty = advertise this DNS server. |
| `DHCP_DOMAIN` | – | Domain name option. |
| `DHCP_DNS_SEARCH` | – | Comma list → DNS search list. |
| `DHCP_NTP_SERVERS` | – | Comma list → NTP servers. |
| `DHCP_DNS_UPDATES` | `true` | Enable dynamic DNS updates from leases. |
| `DHCP_LEASE_DAYS` | `1` | Lease time (days). |
| `DHCP_SCOPE_ENABLED` | `true` | Enable the scope after creating it. |

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

## Roadmap

Shipped in v1.1: zones/records templating, forwarders, DNSSEC, and DHCP scopes (above). Possible future work:
reverse (PTR) zones from the template, secondary/stub/conditional-forwarder zones, additional record types
(CNAME/MX/TXT), DHCP reservations, and a dedicated `configure` subcommand to re-apply config without reinstalling.

---

## References

This installer wraps and configures [Technitium DNS Server](https://technitium.com/dns/), an open-source
authoritative + recursive DNS server by Technitium. All credit for the DNS server itself goes to its authors.

- Technitium DNS Server — <https://technitium.com/dns/>
- Running DNS Server on Ubuntu Linux (install + manual setup) — <https://blog.technitium.com/2017/11/running-dns-server-on-ubuntu-linux.html>
- HTTP API documentation — <https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md>
- Technitium DNS Server source — <https://github.com/TechnitiumSoftware/DnsServer>
- Support the upstream project (Patreon) — <https://www.patreon.com/technitium>

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE). (This installer is an
independent work that orchestrates Technitium DNS Server; the bundled Technitium binary remains GPL-3.0 — see NOTICE.)
