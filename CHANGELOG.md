# Changelog — technitium-dns-installer

## 1.2.0 — Idempotence release (feature/idempotence-phase2)

Idempotence, resolver-safety and secrets-hygiene pass. A failed install can no longer strand
the host without DNS, `uninstall` is safe to run on a host that was never installed on (and
safe to run twice), and the documented air-gap flow now works verbatim from the extraction
directory.

### Fixed
- **Resolver takeover happens only after `dns.service` is confirmed up** (unit active + web
  console answering). If the install dies before that, an exit trap restores the pre-install
  resolver state — a failed run never leaves the host pointed at `127.0.0.1` with nothing
  listening on port 53.
- **`uninstall` safety guards.** On a host where Technitium was never installed, `uninstall`
  exits cleanly without touching the resolver, NetworkManager, `systemd-resolved`, or the
  firewall. The resolver is restored only when there is evidence an install actually
  commandeered it. Running `uninstall` twice no longer purges the preserved `/etc/dns` config.
  Preserved config/log directories are chowned back to `root:root` and the stale systemd unit
  is cleaned up with a `daemon-reload`.
- **`uninstall` never leaves `dns=none` in `NetworkManager.conf`.** The installer no longer
  records its own `dns=none` as the "pre-install" value; when no trustworthy prior value
  exists the line is deleted, and NetworkManager is reloaded so `resolv.conf` self-heals
  without a reboot.
- **`DISABLE_SYSTEMD_RESOLVED=false` is honoured on both online and offline installs** — the
  upstream installer's own resolver takeover is undone when you ask for `false`.
- **Air-gap flow works as documented.** The script anchors on its own directory, produces
  usable archives, and detects install mode more safely. A sentinel found without a usable
  bundle directory now warns about the stale sentinel and proceeds **online** instead of
  silently half-air-gapping. A failed `save` cleans up its own partial artifacts, and the
  archive is written atomically.
- **SUSE ICU resolution** — the `libicu` package is resolved by soname (e.g. `libicu76_1` on
  Leap 16).
- **Secrets hygiene.** The admin password is never printed to the console, never written to
  the install log (mode 0600), and never placed on a process command line.

### Added
- **`DNS_ADMIN_CURRENT_PASSWORD`** — admin-password rotation. Re-running with a new
  `DNS_ADMIN_PASSWORD` authenticates with the previous one and rotates it; without it, a
  re-run with a changed password fails with a clear message instead of silently doing nothing.
- **A-record convergence.** For every name listed in the zones template, the server's A-record
  set for that name is converged to the template — missing records are added and stale ones
  removed, so a changed address no longer leaves accidental round-robin with a dead IP. Names
  *not* mentioned in the template are never touched.
- **Firewall handling.** When firewalld (Rocky/RHEL/Leap) or UFW (Ubuntu) is active, the
  installer opens `53/udp`, `53/tcp` and the web-console port(s), records exactly what it
  added, and `uninstall` removes exactly those. With no active firewall, nothing is changed.
- **`FORCE_ONLINE`** — ignore any air-gap bundle/sentinel next to the script and install online.
- **State marker** `/opt/technitium/.installer-state` (mode 0600, no secrets) recording the
  resolver and firewall changes; `uninstall` consumes and removes it.
- **Dependency preflight** for `curl`/`tar`, printing the distro-specific install command.
- README documentation of v1.2 behavior, rotation, additive config semantics, firewall
  handling and the air-gap flow.

### Semantics note
- The config engine is **additive**: it creates and updates what you pass in but does not
  garbage-collect. Removing a zone or record line from the template does not delete it on the
  server, emptying `DNS_FORWARDERS` does not clear existing forwarders, and renaming
  `DHCP_SCOPE_NAME` creates a new scope without removing the old one. The one convergent piece
  is the A-record set for names present in the template (above).

### Unchanged
- CLI surface (`install`, `save`, `upgrade`, `uninstall`, `help`), the zones template format,
  and the save-archive layout are unchanged.
