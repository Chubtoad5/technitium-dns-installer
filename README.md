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

**v1.2** hardens idempotence and safety: uninstall guards (never touches the resolver on a host that was
never installed on; double-uninstall no longer purges preserved config), resolver takeover only after the
service is confirmed up with rollback on failure, `DISABLE_SYSTEMD_RESOLVED=false` honoured online,
admin-password rotation (`DNS_ADMIN_CURRENT_PASSWORD`), A-record convergence for template names, firewall
handling (firewalld/UFW), SUSE ICU package resolution, a dependency preflight, and an air-gap archive whose
documented flow works verbatim. Passwords are kept out of logs and process command lines.

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

> Requirements: a systemd-based distro, `curl`/`tar` (a dependency preflight checks these and prints
> the distro-specific install command if anything is missing), and root (sudo). The installer pulls
> the ASP.NET Core runtime, the DNS Server package, and the `libicu` OS package automatically.
> On SUSE/openSUSE the ICU package is resolved by soname (e.g. `libicu76_1` on Leap 16).

The final banner does **not** print the admin password (and the install log never contains it); it
reminds you loudly if you left the default `changeme` in place.

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
| `DNS_ADMIN_PASSWORD` | `changeme` | Password set for the admin account on install. **Change this.** Never printed to the console or the install log, and never placed on a process command line. |
| `DNS_ADMIN_CURRENT_PASSWORD` | – | **Rotation:** when re-running with a *new* `DNS_ADMIN_PASSWORD`, pass the previous password here so the installer can authenticate and rotate it. Without it, a re-run with a changed password fails with a clear message. |
| `DNS_WEB_PORT` | `5380` | Web-console HTTP port. |
| `ENABLE_HTTPS` | `false` | Serve the web console over HTTPS with a self-signed certificate. |
| `DNS_HTTPS_PORT` | `53443` | HTTPS port (used only when `ENABLE_HTTPS=true`). |
| `DISABLE_SYSTEMD_RESOLVED` | `true` | Stop/disable `systemd-resolved` and point the host at `127.0.0.1` (mirrors upstream `install.sh`). Set `false` to leave the host resolver untouched — honoured on **both** online and offline installs (the upstream installer's own resolver takeover is undone when you ask for `false`). |
| `FORCE_ONLINE` | `false` | Ignore any air-gap bundle/sentinel next to the script and install online. |
| `PURGE_DATA` | `false` | On `uninstall`, also delete `/etc/dns` (all zones/config) and the logs. |
| `REMOVE_DOTNET` | `false` | On `uninstall`, also delete `/opt/dotnet` (the ASP.NET Core runtime). |
| `DEBUG` | `1` | `1` = verbose command tracing; `0` = quiet. |

Rotation example (previous install used `OldPass1!`, you want `NewPass2!`):

```bash
sudo DNS_ADMIN_CURRENT_PASSWORD='OldPass1!' DNS_ADMIN_PASSWORD='NewPass2!' \
     ./technitium_dns_installer.sh install
```

**Source/version override knobs** (rarely needed): `TECHNITIUM_INSTALL_URL`, `TECHNITIUM_UNINSTALL_URL`,
`TECHNITIUM_PACKAGE_URL`, `DOTNET_INSTALL_URL`, `DOTNET_VERSION`, `INSTALL_PACKAGES_URL`.

---

## DNS Configuration (zones, forwarders, DNSSEC, DHCP)

All of these are optional and applied through the Technitium HTTP API after the server is up. Leave them at
their defaults to skip a block entirely.

> **Additive semantics.** The config engine only acts on what you *pass in* — it creates/updates but does
> not garbage-collect. Removing a zone or record line from the template does **not** delete it on the
> server; setting `DNS_FORWARDERS` back to empty does **not** clear previously configured forwarders; and
> renaming `DHCP_SCOPE_NAME` creates a new scope without removing the old one. Clean up such leftovers in
> the web console. The one convergent piece: for a **name that appears in the template**, the A-record set
> is made to match the template exactly (see below).

### Primary zones + A records

Point `ZONES_TEMPLATE` at a file in the [`zones.template.txt`](zones.template.txt) format: `# <zone>` headers,
then `<name> <ipv4>` lines (label relative to the zone; `@` = apex; `*.x` = wildcard; the same name repeated =
round-robin). Each zone is created as a **Primary** zone; missing zones are created, existing ones reused.

For every name listed in the template, the server's A-record set for that name is **converged** to the
template: missing records are added and stale ones (an IP you changed or dropped from that name's lines)
are removed — a changed address no longer leaves behind accidental round-robin with a dead IP. Records at
names *not* mentioned in the template are never touched.

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

Extraction yields the installer script and the `technitium-save-version.txt` sentinel at the top level,
plus the `technitium-save/` bundle directory — the two commands above work verbatim from the extraction
directory. The installer auto-detects the bundle (via the sentinel next to the script, falling back to the
current directory) and installs entirely offline — extracting the bundled ASP.NET Core runtime and DNS
package, and installing the `libicu` package from the bundle via `install-packages`.

> The bundle is **OS-family / architecture specific**. Build it on a host matching the target.

If a sentinel is found without a usable bundle directory (e.g. leftover from an interrupted extraction),
the installer warns about the stale sentinel and proceeds **online** instead of silently half-air-gapping.
Set `FORCE_ONLINE=true` to ignore any bundle explicitly. A failed `save` cleans up its own partial
artifacts (sentinel, bundle dir, partial archive), and the archive is written atomically.

The bundle includes a `LICENSES/` directory: a third-party component manifest plus a GPL-3.0 **written offer** for
the redistributed Technitium DNS Server binary (Technitium is GPL-3.0; the installer scripts are Apache-2.0). Set
`LICENSE_OFFER_CONTACT` to override the contact named in that offer.

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
`systemd-resolved`, NetworkManager `dns=` setting) and removes exactly the firewall openings the
install recorded.

Safety guards:

- On a host where Technitium was **never installed**, `uninstall` exits cleanly without touching the
  resolver, NetworkManager, `systemd-resolved`, or the firewall.
- The resolver is only restored when there is evidence an install actually commandeered it (the
  installer's state marker, a resolver backup, or the installer-written `resolv.conf`).
- Running `uninstall` twice no longer purges the preserved `/etc/dns` config: the legacy-layout
  fallback only triggers when `/etc/dns` actually contains the application.
- Preserved `/etc/dns` and log directories are chowned back to `root:root` (the `dns-server` user is
  removed), and the stale systemd unit is cleaned up with a `daemon-reload`.

---

## What it changes on the host

- Installs the ASP.NET Core runtime to `/opt/dotnet` (symlink `/usr/bin/dotnet`) and the `libicu` package.
- Installs the DNS server to `/opt/technitium/dns`, config to `/etc/dns`, logs to `/var/log/technitium/dns`.
- Creates a `dns-server` system user and a `dns.service` systemd unit (listens on UDP/TCP 53 and the web port).
- When `DISABLE_SYSTEMD_RESOLVED=true` (default): disables `systemd-resolved`, sets NetworkManager
  `dns=none`, backs up `/etc/resolv.conf` (real file contents, symlinks dereferenced) to
  `/opt/technitium/dns/resolv.conf.bak`, and points the host at `127.0.0.1`. Because the server binds
  port 53, do not run it on a host already providing DNS.
- **Resolver takeover happens only after `dns.service` is confirmed up** (unit active + web console
  answering). If the install dies before that, an exit trap restores the pre-install resolver state, so
  a failed run never strands the host at `127.0.0.1` with nothing listening on port 53.
- **Firewall:** when firewalld (Rocky/RHEL/Leap) or UFW (Ubuntu) is *active*, the installer opens
  `53/udp`, `53/tcp`, and the web-console port(s), records exactly what it added, and `uninstall`
  removes exactly those. With no active firewall, nothing is changed.
- Writes a small state marker `/opt/technitium/.installer-state` (mode 0600, no secrets) recording the
  resolver/firewall changes; `uninstall` consumes and removes it.
- The install log (`technitium-dns-install.log`, written next to the script, mode 0600) never contains
  the admin password.

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
