#!/usr/bin/env bash
#
# Technitium DNS Server Installer
# Part of the Chubtoad5 automation tool family.
#
# Bare-metal (NOT containerized) installer for Technitium DNS Server. Wraps the
# upstream install.sh for online installs, replicates its steps from a bundle for
# air-gapped installs, and drives the Technitium HTTP API for post-install config.
#
# Usage:  sudo [VAR=value ...] ./technitium_dns_installer.sh [install|save|upgrade|uninstall|help]
#
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="1.2.0"
# Anchor to the script's own directory (TD-6): the air-gap bundle/sentinel are
# expected next to the script. air_gap_check keeps a compat fallback to $PWD.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
base_dir="$script_dir"

# ============================================================================ #
# -- USER DEFINED Configuration Variables (override at runtime) --             #
# ============================================================================ #
DEBUG=${DEBUG:-1}

# -- Upstream sources -- #
TECHNITIUM_INSTALL_URL=${TECHNITIUM_INSTALL_URL:-"https://download.technitium.com/dns/install.sh"}
TECHNITIUM_UNINSTALL_URL=${TECHNITIUM_UNINSTALL_URL:-"https://download.technitium.com/dns/uninstall.sh"}
TECHNITIUM_PACKAGE_URL=${TECHNITIUM_PACKAGE_URL:-"https://download.technitium.com/dns/DnsServerPortable.tar.gz"}
DOTNET_INSTALL_URL=${DOTNET_INSTALL_URL:-"https://dot.net/v1/dotnet-install.sh"}
DOTNET_VERSION=${DOTNET_VERSION:-"10.0"}
INSTALL_PACKAGES_URL=${INSTALL_PACKAGES_URL:-"https://raw.githubusercontent.com/Chubtoad5/install-packages/main/install_packages.sh"}

# -- Licensing (air-gap bundle GPL/AGPL source-offer contact) -- #
LICENSE_OFFER_CONTACT=${LICENSE_OFFER_CONTACT:-"the Chubtoad5 project via https://github.com/Chubtoad5"}

# -- Admin user / credentials -- #
DNS_ADMIN_USER=${DNS_ADMIN_USER:-"admin"}        # built-in admin account (rename not supported in v1.0)
DNS_ADMIN_PASSWORD=${DNS_ADMIN_PASSWORD:-"changeme"}
# Password rotation: when re-running with a NEW DNS_ADMIN_PASSWORD, pass the
# previous one here so the installer can authenticate and rotate it (TD-11).
DNS_ADMIN_CURRENT_PASSWORD=${DNS_ADMIN_CURRENT_PASSWORD:-""}

# -- Web console (DNS management) -- #
DNS_WEB_PORT=${DNS_WEB_PORT:-"5380"}             # upstream default is 5380
ENABLE_HTTPS=${ENABLE_HTTPS:-"false"}            # serve the web console over HTTPS
DNS_HTTPS_PORT=${DNS_HTTPS_PORT:-"53443"}        # only used when ENABLE_HTTPS=true (self-signed cert)

# -- Host integration -- #
DISABLE_SYSTEMD_RESOLVED=${DISABLE_SYSTEMD_RESOLVED:-"true"}  # mirrors upstream install.sh behaviour
FORCE_ONLINE=${FORCE_ONLINE:-"false"}            # ignore an air-gap sentinel and install online (TD-17)

# -- Uninstall behaviour -- #
PURGE_DATA=${PURGE_DATA:-"false"}                # also remove /etc/dns (all zones/config) on uninstall
REMOVE_DOTNET=${REMOVE_DOTNET:-"false"}          # also remove /opt/dotnet on uninstall

# ============================================================================ #
# -- Optional DNS configuration: zones/records, forwarders, DNSSEC, DHCP --    #
#    (all off/empty by default; applied via the Technitium HTTP API)           #
# ============================================================================ #
# -- Primary zones + A records, from a template file (see zones.template.txt) -- #
ZONES_TEMPLATE=${ZONES_TEMPLATE:-""}                      # path to a zone+record template file
DNS_RECORD_TTL=${DNS_RECORD_TTL:-"3600"}                  # TTL for A records created from the template

# -- DNS forwarders -- #
DNS_FORWARDERS=${DNS_FORWARDERS:-""}                      # e.g. "1.1.1.1, 8.8.8.8" (empty = root-hint recursion)
DNS_FORWARDER_PROTOCOL=${DNS_FORWARDER_PROTOCOL:-"Udp"}   # Udp | Tcp | Tls | Https

# -- DNSSEC: sign every primary zone created from ZONES_TEMPLATE -- #
ENABLE_DNSSEC=${ENABLE_DNSSEC:-"false"}
DNSSEC_ALGORITHM=${DNSSEC_ALGORITHM:-"ECDSA"}            # ECDSA | RSA | EDDSA
DNSSEC_CURVE=${DNSSEC_CURVE:-"P256"}                     # for ECDSA: P256 | P384

# -- DHCP scope (needs DHCP_START_ADDRESS + DHCP_END_ADDRESS when ENABLE_DHCP=true) -- #
ENABLE_DHCP=${ENABLE_DHCP:-"false"}
DHCP_SCOPE_NAME=${DHCP_SCOPE_NAME:-"Default"}
DHCP_START_ADDRESS=${DHCP_START_ADDRESS:-""}
DHCP_END_ADDRESS=${DHCP_END_ADDRESS:-""}
DHCP_SUBNET_MASK=${DHCP_SUBNET_MASK:-"255.255.255.0"}
DHCP_ROUTER=${DHCP_ROUTER:-""}
DHCP_DNS_SERVERS=${DHCP_DNS_SERVERS:-""}                  # empty = advertise this DNS server (useThisDnsServer)
DHCP_DOMAIN=${DHCP_DOMAIN:-""}
DHCP_DNS_SEARCH=${DHCP_DNS_SEARCH:-""}                    # comma list -> domainSearchList
DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS:-""}                  # comma list -> ntpServers
DHCP_DNS_UPDATES=${DHCP_DNS_UPDATES:-"true"}
DHCP_LEASE_DAYS=${DHCP_LEASE_DAYS:-"1"}
DHCP_SCOPE_ENABLED=${DHCP_SCOPE_ENABLED:-"true"}

# ============================================================================ #
# -- INTERNAL variables (do not edit) --                                       #
# ============================================================================ #
INSTALL_MODE=0
SAVE_MODE=0
UPGRADE_MODE=0
UNINSTALL_MODE=0
AIR_GAPPED_MODE=0

DNS_APP_DIR="/opt/technitium/dns"
DNS_CONFIG_DIR="/etc/dns"
DNS_LOG_DIR="/var/log/technitium/dns"
DOTNET_DIR="/opt/dotnet"
SYSTEMD_UNIT="/etc/systemd/system/dns.service"
SERVICE_USER="dns-server"

SAVE_SENTINEL="technitium-save-version.txt"
SAVE_ARCHIVE="technitium-save.tar.gz"
BUNDLE_DIR="technitium-save"
LOG_FILE="$base_dir/technitium-dns-install.log"

# Install-time facts consumed by uninstall (resolver/firewall restore) — TD-2/TD-8.
STATE_FILE="/opt/technitium/.installer-state"

API_TOKEN=""
API_BASE=""           # resolved by wait_for_webservice (http://127.0.0.1:<port>)

SERVICE_CONFIRMED=0   # set once the web console is confirmed reachable (TD-4)
RESOLVER_SNAP_DIR=""  # pre-install resolver snapshot (TD-3/TD-4/TD-14)
RESOLVER_TAKEN_OVER="false"
NM_HAD_DNS_LINE=""    # set by configure_host_resolver
NM_PREV_DNS_VALUE=""  # set by configure_host_resolver
FIREWALL_TYPE_DETECTED="none"
FIREWALL_PORTS_ADDED=""

# ============================================================================ #
# -- Helpers --                                                                #
# ============================================================================ #
log()  { echo "$*" | tee -a "$LOG_FILE"; }

# Create/append the log with restrictive perms (it captures full command output).
init_log() { : >> "$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true; }

usage() {
  cat << EOF
Technitium DNS Server Installer v$SCRIPT_VERSION

Usage: $SCRIPT_NAME [command] [command ...]

Commands:
  install     Install Technitium DNS Server (default). Online uses the upstream
              install.sh; if a '$SAVE_SENTINEL' is present the install runs
              fully offline from the saved bundle.
  save        Build an air-gap bundle ($SAVE_ARCHIVE): the DNS package, the
              ASP.NET Core runtime, the libicu OS package, and the installer.
  upgrade     Upgrade an existing install to the latest DNS Server build.
              Online re-runs install.sh; offline extracts the bundled build.
              Config in $DNS_CONFIG_DIR is preserved.
  uninstall   Stop and remove the DNS server (non-interactive). Honours
              PURGE_DATA and REMOVE_DOTNET.
  help        Show this message.

Core environment overrides (see README.md for the full list):
  DNS_ADMIN_PASSWORD   Admin password to set (default: changeme)
  DNS_ADMIN_CURRENT_PASSWORD
                       Current password when rotating to a new DNS_ADMIN_PASSWORD
  DNS_WEB_PORT         Web console HTTP port (default: 5380)
  ENABLE_HTTPS         Serve the console over HTTPS self-signed (default: false)
  DNS_HTTPS_PORT       HTTPS port when ENABLE_HTTPS=true (default: 53443)
  FORCE_ONLINE         Ignore an air-gap bundle and install online (default: false)
  PURGE_DATA           uninstall also removes $DNS_CONFIG_DIR (default: false)
  REMOVE_DOTNET        uninstall also removes $DOTNET_DIR (default: false)

Optional DNS configuration (applied via the HTTP API after install):
  ZONES_TEMPLATE       Path to a zone+record template (see zones.template.txt)
  DNS_FORWARDERS       Comma list, e.g. "1.1.1.1, 8.8.8.8" (+ DNS_FORWARDER_PROTOCOL)
  ENABLE_DNSSEC        Sign every zone created from the template (default: false)
  ENABLE_DHCP          Create+enable a DHCP scope (+ DHCP_START_ADDRESS/DHCP_END_ADDRESS/...)

Examples:
  sudo DNS_ADMIN_PASSWORD='S3cret!' DNS_WEB_PORT=8053 ENABLE_HTTPS=true ./$SCRIPT_NAME install
  sudo DNS_ADMIN_PASSWORD='S3cret!' ZONES_TEMPLATE=./zones.txt \\
       DNS_FORWARDERS='1.1.1.1, 8.8.8.8' ENABLE_DNSSEC=true ./$SCRIPT_NAME install
EOF
  exit "${1:-1}"
}

debug_run() {
  if [ "$DEBUG" -eq 1 ]; then
    echo "--- DEBUG: Running '$*' ---"
    "$@"
    local status=$?
    echo "--- DEBUG: Finished '$*' with status $status ---"
    return $status
  else
    "$@" >/dev/null 2>&1
    return $?
  fi
}

check_root_privileges() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo or as the root user."
    exit 1
  fi
}

os_check() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-}"
  else
    echo "Unknown or unsupported OS: /etc/os-release not found."
    exit 1
  fi
  if [[ ! "$OS_ID" =~ ^(ubuntu|debian|rhel|centos|rocky|almalinux|fedora|sles|opensuse-leap|opensuse-tumbleweed)$ ]]; then
    echo "Unknown or unsupported OS: '$OS_ID'."
    echo "Supported: Ubuntu/Debian, RHEL/CentOS/Rocky/AlmaLinux/Fedora, SLES/openSUSE."
    exit 1
  fi
}

# Fail early with distro-specific hints when a required tool is missing —
# minimal cloud images often ship without curl (TD-15).
preflight_dependencies() {
  local -a required=(curl tar grep sed awk)
  local -a missing=()
  local c
  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) && return 0
  echo "ERROR: missing required command(s): ${missing[*]}"
  case "${OS_ID:-}" in
    ubuntu|debian)                          echo "  Install with: sudo apt-get update && sudo apt-get install -y ${missing[*]}" ;;
    rhel|centos|rocky|almalinux|fedora)     echo "  Install with: sudo dnf install -y ${missing[*]}" ;;
    sles|opensuse-leap|opensuse-tumbleweed) echo "  Install with: sudo zypper -n install ${missing[*]}" ;;
  esac
  exit 1
}

# Resolve the best-available libicu package name for the running distro.
icu_package_name() {
  case "$OS_ID" in
    ubuntu|debian)
      if apt-cache show libicu74 >/dev/null 2>&1;   then echo "libicu74"
      elif apt-cache show libicu72 >/dev/null 2>&1; then echo "libicu72"
      elif apt-cache show libicu70 >/dev/null 2>&1; then echo "libicu70"
      else echo "libicu-dev"; fi ;;
    sles|opensuse-leap|opensuse-tumbleweed)
      # SUSE names the ICU runtime by soname (libicu73_2, libicu76_1, ...);
      # plain 'libicu' has no provider on Leap 16 (TD-9). Prefer an already
      # installed package, then the newest zypper-resolvable candidate.
      local icu_pkg=""
      icu_pkg="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null \
                   | grep -E '^libicu[0-9]+(_[0-9]+)*$' | sort -V | tail -n1 || true)"
      if [[ -z "$icu_pkg" ]]; then
        icu_pkg="$(zypper --non-interactive search -t package 'libicu*' 2>/dev/null \
                     | awk -F'|' 'NF>=3 {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' \
                     | grep -E '^libicu[0-9]+(_[0-9]+)*$' | sort -V | tail -n1 || true)"
      fi
      if [[ -n "$icu_pkg" ]]; then echo "$icu_pkg"; else echo "libicu"; fi ;;
    *) echo "libicu" ;;   # dnf/yum ship a 'libicu' package
  esac
}

# Detect an air-gap bundle next to the script (TD-6), with a compat fallback to
# the current working directory. A sentinel without a usable bundle is treated
# as stale and reported instead of silently flipping install modes (TD-17).
air_gap_check() {
  if [[ "$FORCE_ONLINE" == "true" ]]; then
    log "FORCE_ONLINE=true -> ignoring any air-gap bundle; using the online path."
    return 0
  fi
  local -a candidates=("$script_dir")
  [[ "$PWD" != "$script_dir" ]] && candidates+=("$PWD")
  local d
  for d in "${candidates[@]}"; do
    [[ -f "$d/$SAVE_SENTINEL" ]] || continue
    if [[ -f "$d/$BUNDLE_DIR/DnsServerPortable.tar.gz" ]]; then
      AIR_GAPPED_MODE=1
      base_dir="$d"
      if [[ "$d" != "$script_dir" ]]; then
        log "NOTE: air-gap bundle found in the current directory ($d), not next to the script; using it (compat fallback)."
      fi
      log "Air-gap bundle detected ($SAVE_SENTINEL) -> offline install."
      return 0
    fi
    log "WARNING: found '$d/$SAVE_SENTINEL' but no usable bundle ('$BUNDLE_DIR/DnsServerPortable.tar.gz' missing) - stale sentinel?"
    log "         Continuing with an ONLINE install. Remove the stale sentinel or re-extract the full $SAVE_ARCHIVE for an offline install."
  done
  log "No air-gap bundle found -> online install."
  return 0
}

require_internet_artifact() {
  # $1 = url, $2 = output path, $3 = description
  if ! curl -fsSL --retry 3 -o "$2" "$1"; then
    log "ERROR: failed to download $3 from: $1"
    exit 1
  fi
}

# Read one KEY=value from the installer state file (empty when absent).
state_get() {
  local key="$1" v=""
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  v="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  echo "$v"
}

# ============================================================================ #
# -- Host resolver: snapshot / restore / takeover --                           #
# ============================================================================ #

# Snapshot the pre-install resolver state so a failed install — or an online
# install with DISABLE_SYSTEMD_RESOLVED=false, where the upstream install.sh
# does its own unconditional takeover — can restore it (TD-3/TD-4).
snapshot_resolver_state() {
  RESOLVER_SNAP_DIR="$(mktemp -d)"
  chmod 700 "$RESOLVER_SNAP_DIR"
  # Capture the *contents* (cat, not cp -a): /etc/resolv.conf is often a symlink
  # into systemd-resolved's runtime dir, and a preserved symlink dangles once
  # systemd-resolved is disabled or after a reboot (TD-14).
  if [[ -e /etc/resolv.conf ]]; then
    cat /etc/resolv.conf > "$RESOLVER_SNAP_DIR/resolv.conf" 2>/dev/null || true
  fi
  if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
    cp -a /etc/NetworkManager/NetworkManager.conf "$RESOLVER_SNAP_DIR/NetworkManager.conf"
  fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "active" > "$RESOLVER_SNAP_DIR/resolved.state"
  fi
  if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
    echo "enabled" > "$RESOLVER_SNAP_DIR/resolved.enabled"
  fi
}

# True when the live resolver state differs from the pre-install snapshot.
resolver_state_changed() {
  [[ -n "$RESOLVER_SNAP_DIR" && -d "$RESOLVER_SNAP_DIR" ]] || return 1
  local now snap
  now="$(cat /etc/resolv.conf 2>/dev/null || true)"
  snap="$(cat "$RESOLVER_SNAP_DIR/resolv.conf" 2>/dev/null || true)"
  [[ "$now" != "$snap" ]] && return 0
  if [[ -f "$RESOLVER_SNAP_DIR/resolved.state" ]] && ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    return 0
  fi
  return 1
}

restore_resolver_snapshot() {
  [[ -n "$RESOLVER_SNAP_DIR" && -d "$RESOLVER_SNAP_DIR" ]] || return 0
  if [[ -f "$RESOLVER_SNAP_DIR/resolv.conf" ]]; then
    rm -f /etc/resolv.conf
    cat "$RESOLVER_SNAP_DIR/resolv.conf" > /etc/resolv.conf
  fi
  if [[ -f "$RESOLVER_SNAP_DIR/NetworkManager.conf" ]]; then
    cp -a "$RESOLVER_SNAP_DIR/NetworkManager.conf" /etc/NetworkManager/NetworkManager.conf
  fi
  if [[ -f "$RESOLVER_SNAP_DIR/resolved.enabled" ]]; then
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
  fi
  if [[ -f "$RESOLVER_SNAP_DIR/resolved.state" ]]; then
    systemctl start systemd-resolved >/dev/null 2>&1 || true
  fi
}

# TD-3: the upstream install.sh commandeers the resolver unconditionally on the
# online path. When the user asked for DISABLE_SYSTEMD_RESOLVED=false, undo it.
online_resolver_compensate() {
  [[ "$DISABLE_SYSTEMD_RESOLVED" == "true" ]] && return 0
  if resolver_state_changed; then
    log "DISABLE_SYSTEMD_RESOLVED=false: upstream install.sh modified the host resolver; restoring the pre-install state..."
    restore_resolver_snapshot
    log "Host resolver restored."
  fi
}

# Point the host at 127.0.0.1 and stop NetworkManager from clobbering resolv.conf
# (mirrors the upstream install.sh resolver handling). Idempotent.
configure_host_resolver() {
  if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
    # Only an *active* 'dns=' line counts — a commented '#dns=' line must not
    # stop us from setting dns=none (TD-19).
    if grep -qE '^[[:space:]]*dns=' /etc/NetworkManager/NetworkManager.conf; then
      NM_HAD_DNS_LINE="true"
      NM_PREV_DNS_VALUE="$(grep -E '^[[:space:]]*dns=' /etc/NetworkManager/NetworkManager.conf | head -n1 | cut -d= -f2- || true)"
      sed -i 's/^[[:space:]]*dns=.*/dns=none/' /etc/NetworkManager/NetworkManager.conf
    elif grep -qE '^\[main\]' /etc/NetworkManager/NetworkManager.conf; then
      NM_HAD_DNS_LINE="false"
      sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
    else
      NM_HAD_DNS_LINE="false"
      printf "\n[main]\ndns=none\n" >> /etc/NetworkManager/NetworkManager.conf
    fi
  fi
  # Persistent backup for uninstall: real file contents, never a symlink (TD-14).
  # Refresh it when it is missing, a symlink, or already-clobbered with the
  # takeover content (the upstream install.sh overwrites it on every online
  # run) — provided the pre-install snapshot holds something better.
  local bak="$DNS_APP_DIR/resolv.conf.bak"
  local bak_unusable=0
  if [[ ! -e "$bak" || -L "$bak" ]]; then
    bak_unusable=1
  elif grep -q '127\.0\.0\.1' "$bak" 2>/dev/null; then
    bak_unusable=1
  fi
  if (( bak_unusable )) && [[ -f "${RESOLVER_SNAP_DIR:-/nonexistent}/resolv.conf" ]] \
       && ! grep -q '127\.0\.0\.1' "$RESOLVER_SNAP_DIR/resolv.conf" 2>/dev/null; then
    rm -f "$bak"
    cp "$RESOLVER_SNAP_DIR/resolv.conf" "$bak"
  elif [[ ! -e "$bak" && ! -L "$bak" ]]; then
    cat /etc/resolv.conf > "$bak" 2>/dev/null || true
  fi
  rm -f /etc/resolv.conf
  printf "# Generated by Technitium DNS Server Installer\n\nnameserver 127.0.0.1\n" > /etc/resolv.conf
}

# Resolver policy: runs AFTER dns.service is confirmed up (TD-4), on every
# install run including re-runs (TD-13).
apply_resolver_policy() {
  if [[ "$DISABLE_SYSTEMD_RESOLVED" == "true" ]]; then
    log "Commandeering host resolver -> 127.0.0.1 (DISABLE_SYSTEMD_RESOLVED=true)..."
    local resolved_was_running=0
    systemctl is-active --quiet systemd-resolved 2>/dev/null && resolved_was_running=1
    systemctl stop systemd-resolved >/dev/null 2>&1 || true
    systemctl disable systemd-resolved >/dev/null 2>&1 || true
    configure_host_resolver
    RESOLVER_TAKEN_OVER="true"
    if (( resolved_was_running )); then
      # systemd-resolved held (127.0.0.53):53 until now; restart so the DNS
      # server can (re)bind port 53 cleanly.
      log "Restarting dns.service to bind port 53 now that systemd-resolved is stopped..."
      debug_run systemctl restart dns.service
    fi
  else
    if [[ "$AIR_GAPPED_MODE" -eq 1 ]]; then
      log "DISABLE_SYSTEMD_RESOLVED=false: host resolver left untouched."
    else
      log "DISABLE_SYSTEMD_RESOLVED=false: host resolver left as before the install (upstream takeover compensated)."
    fi
  fi
}

# ============================================================================ #
# -- Firewall handling (TD-8) --                                               #
# ============================================================================ #

# Open DNS + web-console ports when a host firewall is active (firewalld on
# Rocky/Leap, UFW on Ubuntu). Records exactly what was added in the state file
# so uninstall removes only that.
configure_firewall() {
  local -a wanted=("53/udp" "53/tcp" "${DNS_WEB_PORT}/tcp")
  [[ "$ENABLE_HTTPS" == "true" ]] && wanted+=("${DNS_HTTPS_PORT}/tcp")
  local prev_added added="" p
  prev_added="$(state_get FIREWALL_PORTS_ADDED)"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL_TYPE_DETECTED="firewalld"
    log "firewalld is active; ensuring DNS/web-console ports are open..."
    for p in "${wanted[@]}"; do
      if firewall-cmd --permanent --query-port="$p" >/dev/null 2>&1; then
        log "  firewalld: $p already open"
      else
        firewall-cmd --permanent --add-port="$p" >/dev/null
        added="$added $p"
        log "  firewalld: opened $p"
      fi
    done
    firewall-cmd --reload >/dev/null
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    FIREWALL_TYPE_DETECTED="ufw"
    log "UFW is active; ensuring DNS/web-console ports are open..."
    for p in "${wanted[@]}"; do
      if ufw status | grep -qE "^${p}[[:space:]].*ALLOW"; then
        log "  ufw: $p already allowed"
      else
        ufw allow "$p" >/dev/null
        added="$added $p"
        log "  ufw: allowed $p"
      fi
    done
  else
    log "No active host firewall (firewalld/UFW) detected; no firewall changes made."
    # Keep any previously recorded type so uninstall can still clean up.
    local prev_type; prev_type="$(state_get FIREWALL_TYPE)"
    [[ -n "$prev_type" ]] && FIREWALL_TYPE_DETECTED="$prev_type"
  fi
  # Union of previously recorded + newly added ports (re-runs must not lose the record).
  # shellcheck disable=SC2086
  FIREWALL_PORTS_ADDED="$(printf '%s\n' $prev_added $added | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"
}

# Remove exactly the firewall openings this installer recorded as added (TD-8).
remove_firewall_rules() {
  local fw_type="$1" fw_ports="$2" p
  [[ -z "$fw_ports" || -z "$fw_type" || "$fw_type" == "none" ]] && return 0
  log "Removing firewall openings added at install time ($fw_type): $fw_ports"
  case "$fw_type" in
    firewalld)
      if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for p in $fw_ports; do
          firewall-cmd --permanent --remove-port="$p" >/dev/null 2>&1 || true
          log "  firewalld: closed $p"
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
      fi ;;
    ufw)
      if command -v ufw >/dev/null 2>&1; then
        for p in $fw_ports; do
          ufw --force delete allow "$p" >/dev/null 2>&1 || true
          log "  ufw: removed allow $p"
        done
      fi ;;
  esac
}

# Persist install-time facts consumed by uninstall. First-run values win on
# re-runs (they describe the true pre-install state of the host).
write_state_file() {
  local prev_takeover prev_nm_had prev_nm_val prev_resolved_active
  prev_takeover="$(state_get RESOLVER_TAKEOVER)"
  prev_nm_had="$(state_get NM_HAD_DNS_LINE)"
  prev_nm_val="$(state_get NM_PREV_DNS_VALUE)"
  prev_resolved_active="$(state_get RESOLVED_WAS_ACTIVE)"

  local takeover="$RESOLVER_TAKEN_OVER"
  [[ "$prev_takeover" == "true" ]] && takeover="true"
  local nm_had="${prev_nm_had:-$NM_HAD_DNS_LINE}"
  local nm_val="${prev_nm_val:-$NM_PREV_DNS_VALUE}"
  local resolved_active="false"
  [[ -f "${RESOLVER_SNAP_DIR:-/nonexistent}/resolved.state" ]] && resolved_active="true"
  [[ -n "$prev_resolved_active" ]] && resolved_active="$prev_resolved_active"

  mkdir -p /opt/technitium
  {
    echo "# Technitium DNS installer state - consumed by 'uninstall'. Do not edit."
    echo "STATE_SCRIPT_VERSION=$SCRIPT_VERSION"
    echo "INSTALLED_AT=$(date)"
    echo "RESOLVER_TAKEOVER=$takeover"
    echo "NM_HAD_DNS_LINE=$nm_had"
    echo "NM_PREV_DNS_VALUE=$nm_val"
    echo "RESOLVED_WAS_ACTIVE=$resolved_active"
    echo "FIREWALL_TYPE=$FIREWALL_TYPE_DETECTED"
    echo "FIREWALL_PORTS_ADDED=$FIREWALL_PORTS_ADDED"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# ============================================================================ #
# -- Install: online (wrap upstream install.sh) --                            #
# ============================================================================ #
install_online() {
  log "Installing Technitium DNS Server (online) via upstream install.sh..."
  local tmp_installer
  tmp_installer="$(mktemp)"
  require_internet_artifact "$TECHNITIUM_INSTALL_URL" "$tmp_installer" "Technitium install.sh"
  debug_run bash "$tmp_installer"
  rm -f "$tmp_installer"
}

# ============================================================================ #
# -- Install: offline (replicate upstream install.sh from the bundle) --      #
# ============================================================================ #
install_offline() {
  log "Installing Technitium DNS Server (offline) from bundle..."
  local b="$base_dir/$BUNDLE_DIR"
  if [[ ! -d "$b" ]]; then
    log "ERROR: bundle directory '$b' not found. Did you transfer the full $SAVE_ARCHIVE and extract it here?"
    exit 1
  fi

  mkdir -p "$DNS_APP_DIR" "$DNS_CONFIG_DIR" "$DNS_LOG_DIR"

  # 1. ASP.NET Core runtime -> /opt/dotnet
  if dotnet --list-runtimes 2>/dev/null | grep -q "Microsoft.AspNetCore.App ${DOTNET_VERSION}."; then
    log "ASP.NET Core Runtime ${DOTNET_VERSION} already present."
  else
    log "Installing bundled ASP.NET Core Runtime..."
    mkdir -p "$DOTNET_DIR"
    tar -xzf "$b/dotnet-runtime.tar.gz" -C "$DOTNET_DIR"
    [[ -e /usr/bin/dotnet ]] || ln -s "$DOTNET_DIR/dotnet" /usr/bin/dotnet
  fi

  # 2. libicu (offline, via install-packages.sh)
  log "Installing bundled libicu package..."
  ( cd "$b/utilities" && debug_run ./install_packages.sh offline "$(cat icu-package.txt)" )

  # 3. DNS server package -> /opt/technitium/dns
  log "Extracting Technitium DNS Server package..."
  tar -xzf "$b/DnsServerPortable.tar.gz" -C "$DNS_APP_DIR"

  # 4. ICU sanity check
  if ! dotnet "$DNS_APP_DIR/DnsServerApp.dll" --icu-test >>"$LOG_FILE" 2>&1; then
    log "ERROR: ICU self-test failed after offline install. Check $LOG_FILE."
    exit 1
  fi

  # 5. systemd service + user (mirrors upstream install.sh). The host-resolver
  #    takeover deliberately does NOT happen here: it runs only after the
  #    service is confirmed up (apply_resolver_policy, TD-4).
  if [[ "$(ps --no-headers -o comm 1 | tr -d '\n')" != "systemd" ]]; then
    log "ERROR: systemd was not detected; cannot install the dns.service unit."
    exit 1
  fi

  id "$SERVICE_USER" &>/dev/null || useradd --system -M --shell /usr/sbin/nologin "$SERVICE_USER"
  # Re-runs re-extract the package as root, so ownership must be reasserted on
  # every run, not just the first (TD-13).
  chown -R "$SERVICE_USER:$SERVICE_USER" "$DNS_APP_DIR" "$DNS_CONFIG_DIR" "$DNS_LOG_DIR"

  if [[ -f "$SYSTEMD_UNIT" ]]; then
    log "Existing dns.service found -> restarting."
    debug_run systemctl restart dns.service
  else
    cp "$DNS_APP_DIR/systemd.service" "$SYSTEMD_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    debug_run systemctl enable dns.service
    debug_run systemctl start dns.service
  fi
}

# Verify the install actually produced a live service before anything gets
# commandeered (TD-4) — and fail loudly when the fully-delegated upstream
# install.sh path did not deliver (TD-20).
verify_service_install() {
  if [[ ! -f "$SYSTEMD_UNIT" ]]; then
    log "ERROR: $SYSTEMD_UNIT not found after install - the install did not complete."
    exit 1
  fi
  local tries=0
  while (( tries < 30 )); do
    systemctl is-active --quiet dns.service && break
    sleep 2; tries=$((tries+1))
  done
  if ! systemctl is-active --quiet dns.service; then
    log "ERROR: dns.service is not active after install. Check 'journalctl -u dns.service'."
    exit 1
  fi
  log "dns.service is active."
}

# ============================================================================ #
# -- Technitium HTTP API helpers --                                            #
# ============================================================================ #

# Block until the web console answers, trying the default and configured ports.
wait_for_webservice() {
  local ports=("5380" "$DNS_WEB_PORT") p tries
  for p in "${ports[@]}"; do
    tries=0
    while (( tries < 30 )); do
      if curl -fsS -o /dev/null "http://127.0.0.1:${p}/api/user/login?user=x&pass=x" 2>/dev/null; then
        API_BASE="http://127.0.0.1:${p}"
        SERVICE_CONFIRMED=1
        log "Web console reachable on port ${p}."
        return 0
      fi
      sleep 2; tries=$((tries+1))
    done
  done
  log "ERROR: DNS web console did not become reachable on ports ${ports[*]}."
  exit 1
}

json_field()     { grep -oP "\"$1\"\s*:\s*\"\K[^\"]+" | head -n1; }
json_status_ok() { grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; }
# Extract the IPv4 addresses of type-A records from a zones/records/get response.
json_a_record_ips() { grep -oP '"type"\s*:\s*"A"[^{]*\{\s*"ipAddress"\s*:\s*"\K[0-9.]+' || true; }

# Write a secret to a root-only temp file for curl's --data-urlencode name@file
# form, keeping credentials off the process argv (TD-7). Caller must rm -f it.
secret_tmp_file() {
  local f
  f="$(mktemp)"
  chmod 600 "$f"
  printf '%s' "$1" > "$f"
  echo "$f"
}

# api_call <endpoint> [--data-urlencode k=v ...]
# POST to the API with the session token added. All caller-supplied values must be
# passed as --data-urlencode: Technitium rejects unencoded special characters in
# passwords / values (verified against a live server).
api_call() {
  local endpoint="$1"; shift
  curl -fsSk "${API_BASE}/${endpoint}" --data-urlencode "token=${API_TOKEN}" "$@"
}

# Log in and ensure the admin password equals DNS_ADMIN_PASSWORD. Idempotent.
# Tries, in order: the desired password (re-runs), DNS_ADMIN_CURRENT_PASSWORD
# (rotation, TD-11), and the factory default admin/admin (first install).
# Passwords travel via 600-perm temp files, never on curl's argv (TD-7).
api_login_and_set_password() {
  local resp pw_file cur_file
  pw_file="$(secret_tmp_file "$DNS_ADMIN_PASSWORD")"

  # 1. Try the desired password first (idempotent re-runs).
  resp=$(curl -fsSk "${API_BASE}/api/user/login" \
            --data-urlencode "user=${DNS_ADMIN_USER}" \
            --data-urlencode "pass@${pw_file}" \
            --data-urlencode "includeInfo=true" || true)
  if echo "$resp" | json_status_ok; then
    API_TOKEN=$(echo "$resp" | json_field token)
    rm -f "$pw_file"
    log "Authenticated as ${DNS_ADMIN_USER} (password already set)."
    return 0
  fi

  # 2. Rotation: authenticate with the previous password, then set the new one.
  if [[ -n "$DNS_ADMIN_CURRENT_PASSWORD" ]]; then
    cur_file="$(secret_tmp_file "$DNS_ADMIN_CURRENT_PASSWORD")"
    resp=$(curl -fsSk "${API_BASE}/api/user/login" \
              --data-urlencode "user=${DNS_ADMIN_USER}" \
              --data-urlencode "pass@${cur_file}" \
              --data-urlencode "includeInfo=true" || true)
    if echo "$resp" | json_status_ok; then
      API_TOKEN=$(echo "$resp" | json_field token)
      log "Authenticated with DNS_ADMIN_CURRENT_PASSWORD; rotating the admin password..."
      if api_call api/user/changePassword \
            --data-urlencode "pass@${cur_file}" \
            --data-urlencode "newPass@${pw_file}" | json_status_ok; then
        log "Admin password rotated."
        rm -f "$pw_file" "$cur_file"
        return 0
      fi
      rm -f "$pw_file" "$cur_file"
      log "ERROR: authenticated with DNS_ADMIN_CURRENT_PASSWORD but failed to set the new password."
      exit 1
    fi
    rm -f "$cur_file"
  fi

  # 3. Fall back to the factory default admin/admin and change the password.
  resp=$(curl -fsSk "${API_BASE}/api/user/login" \
            --data-urlencode "user=admin" \
            --data-urlencode "pass=admin" \
            --data-urlencode "includeInfo=true" || true)
  if ! echo "$resp" | json_status_ok; then
    rm -f "$pw_file"
    log "ERROR: could not authenticate with the configured, rotation (DNS_ADMIN_CURRENT_PASSWORD), or factory-default credentials."
    log "       If the admin password was changed earlier (e.g. a previous run used a different DNS_ADMIN_PASSWORD),"
    log "       re-run with: DNS_ADMIN_CURRENT_PASSWORD='<old password>' DNS_ADMIN_PASSWORD='<new password>'"
    exit 1
  fi
  API_TOKEN=$(echo "$resp" | json_field token)
  log "Authenticated with factory default; setting admin password..."
  # changePassword requires BOTH the current password (pass) and the new one (newPass).
  if api_call api/user/changePassword \
        --data-urlencode "pass=admin" \
        --data-urlencode "newPass@${pw_file}" | json_status_ok; then
    log "Admin password updated."
    rm -f "$pw_file"
  else
    rm -f "$pw_file"
    log "ERROR: failed to change the admin password."
    exit 1
  fi
}

# Apply the web-service settings (HTTP port and optional self-signed TLS/HTTPS).
# NOTE: the Technitium setting keys are webServiceEnableTls / webServiceTlsPort /
# webServiceUseSelfSignedTlsCertificate (NOT the "...Https..." names).
api_configure_web_service() {
  local args=( --data-urlencode "webServiceHttpPort=${DNS_WEB_PORT}" )
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    args+=( --data-urlencode "webServiceEnableTls=true"
            --data-urlencode "webServiceTlsPort=${DNS_HTTPS_PORT}"
            --data-urlencode "webServiceUseSelfSignedTlsCertificate=true" )
  else
    args+=( --data-urlencode "webServiceEnableTls=false" )
  fi
  # Changing the HTTP port makes the web service rebind, which can cut the response
  # mid-flight; treat a non-ok result as a soft warning and let the smoke test confirm.
  if api_call api/settings/set "${args[@]}" | json_status_ok; then
    log "Web service settings applied (HTTP port ${DNS_WEB_PORT}, TLS=${ENABLE_HTTPS})."
  else
    log "NOTE: web service settings response not confirmed (expected if the port changed); verify on the new port."
  fi
}

# Config engine. The web-service port/TLS change runs LAST so all other API calls
# use a stable API_BASE (changing the HTTP port rebinds the listener mid-flight).
configure_dns_server() {
  CREATED_ZONES=()
  wait_for_webservice
  api_login_and_set_password
  configure_forwarders
  configure_zones_and_records
  configure_dnssec
  configure_dhcp
  api_configure_web_service
}

csv_clean() { echo "$1" | tr -d '[:space:]'; }

# -- DNS forwarders -- #
configure_forwarders() {
  [[ -z "$DNS_FORWARDERS" ]] && return 0
  local fwd; fwd="$(csv_clean "$DNS_FORWARDERS")"
  log "Configuring DNS forwarders: ${fwd} (${DNS_FORWARDER_PROTOCOL})..."
  if api_call api/settings/set \
        --data-urlencode "forwarders=${fwd}" \
        --data-urlencode "forwarderProtocol=${DNS_FORWARDER_PROTOCOL}" | json_status_ok; then
    log "  Forwarders set."
  else
    log "  WARNING: failed to set forwarders."
  fi
}

# -- Primary zones + A records from ZONES_TEMPLATE -- #
# Format: '# <zone>' headers; '<name> <ipv4>' records (relative label; '@' apex;
# '*.x' wildcard; repeated name = round-robin). ';' lines and non-domain '#' lines
# are comments.
#
# Convergence (TD-10): for every name that appears in the template, the A-record
# set is made to EQUAL the template (stale IPs at that name are removed, so a
# changed address does not become accidental round-robin with a dead IP).
# Names NOT mentioned in the template are never touched (additive semantics).
configure_zones_and_records() {
  [[ -z "$ZONES_TEMPLATE" ]] && return 0
  if [[ ! -f "$ZONES_TEMPLATE" ]]; then
    log "WARNING: ZONES_TEMPLATE '$ZONES_TEMPLATE' not found; skipping zone creation."
    return 0
  fi
  log "Creating zones + records from ${ZONES_TEMPLATE}..."
  local zone="" line hdr name ip domain
  local token_re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  # Pass 1: parse the template, create zones as headers are encountered, and
  # collect the full desired A-record set per name.
  local -a rec_domains=()
  local -A rec_zone=() rec_ips=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"     # ltrim
    line="${line%"${line##*[![:space:]]}"}"     # rtrim
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == ";" ]] && continue
    if [[ "${line:0:1}" == "#" ]]; then
      hdr="${line#\#}"
      hdr="${hdr#"${hdr%%[![:space:]]*}"}"; hdr="${hdr%"${hdr##*[![:space:]]}"}"
      if [[ "$hdr" == *.* && "$hdr" =~ $token_re ]]; then
        zone="$hdr"; zone_create "$zone"
      fi
      continue
    fi
    name="$(echo "$line" | awk '{print $1}')"
    ip="$(echo "$line" | awk '{print $2}')"
    if [[ -z "$zone" ]]; then
      log "  WARNING: record '$line' before any '# <zone>' header; skipped."; continue
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      log "  WARNING: '$line' is not '<name> <ipv4>'; skipped."; continue
    fi
    if [[ "$name" == "@" ]]; then domain="$zone"; else domain="${name}.${zone}"; fi
    if [[ -z "${rec_ips[$domain]:-}" ]]; then
      rec_domains+=("$domain")
      rec_zone[$domain]="$zone"
      rec_ips[$domain]="$ip"
    elif [[ " ${rec_ips[$domain]} " != *" $ip "* ]]; then
      rec_ips[$domain]="${rec_ips[$domain]} $ip"
    fi
  done < "$ZONES_TEMPLATE"
  # Pass 2: converge each name's A-record set to the template.
  local d
  for d in "${rec_domains[@]}"; do
    # shellcheck disable=SC2086
    record_sync_a "${rec_zone[$d]}" "$d" ${rec_ips[$d]}
  done
}

zone_create() {
  local z="$1" resp
  resp=$(api_call api/zones/create --data-urlencode "zone=${z}" --data-urlencode "type=Primary" 2>/dev/null || true)
  if echo "$resp" | json_status_ok; then
    log "  Zone created: $z"; CREATED_ZONES+=("$z")
  elif echo "$resp" | grep -qiE 'already exists'; then
    log "  Zone exists: $z (reusing)"; CREATED_ZONES+=("$z")
  else
    log "  WARNING: could not create zone '$z'."
  fi
}

# Converge the A-record set for one name (TD-10): remove A records at this name
# that are not in the desired set, then add the missing ones.
record_sync_a() {
  local zone="$1" domain="$2"; shift 2
  local -a desired=("$@") existing=()
  local ip d keep
  mapfile -t existing < <(api_call api/zones/records/get \
        --data-urlencode "domain=${domain}" \
        --data-urlencode "zone=${zone}" 2>/dev/null | json_a_record_ips)
  for ip in "${existing[@]}"; do
    keep=0
    for d in "${desired[@]}"; do [[ "$ip" == "$d" ]] && { keep=1; break; }; done
    if (( ! keep )); then
      if api_call api/zones/records/delete \
            --data-urlencode "domain=${domain}" \
            --data-urlencode "zone=${zone}" \
            --data-urlencode "type=A" \
            --data-urlencode "ipAddress=${ip}" | json_status_ok; then
        log "    A  ${domain} -x ${ip} (removed - not in template)"
      else
        log "    WARNING: could not remove stale A ${domain} -> ${ip}"
      fi
    fi
  done
  for ip in "${desired[@]}"; do
    keep=0
    for d in "${existing[@]}"; do [[ "$ip" == "$d" ]] && { keep=1; break; }; done
    if (( keep )); then
      log "    A  ${domain} -> ${ip} (exists)"
    else
      record_add_a "$domain" "$ip"
    fi
  done
}

record_add_a() {
  local domain="$1" ip="$2"
  if api_call api/zones/records/add \
        --data-urlencode "domain=${domain}" --data-urlencode "type=A" \
        --data-urlencode "ipAddress=${ip}" --data-urlencode "ttl=${DNS_RECORD_TTL}" | json_status_ok; then
    log "    A  ${domain} -> ${ip}"
  else
    log "    (skip) A ${domain} -> ${ip} (exists or invalid)"
  fi
}

# -- DNSSEC: sign each primary zone created from the template -- #
configure_dnssec() {
  [[ "$ENABLE_DNSSEC" != "true" ]] && return 0
  if (( ${#CREATED_ZONES[@]} == 0 )); then
    log "ENABLE_DNSSEC=true but no template zones were created; nothing to sign."
    return 0
  fi
  local z args
  for z in "${CREATED_ZONES[@]}"; do
    args=( --data-urlencode "zone=${z}" --data-urlencode "algorithm=${DNSSEC_ALGORITHM}" )
    [[ "$DNSSEC_ALGORITHM" == "ECDSA" ]] && args+=( --data-urlencode "curve=${DNSSEC_CURVE}" )
    if api_call api/zones/dnssec/sign "${args[@]}" | json_status_ok; then
      log "  DNSSEC signed: $z (${DNSSEC_ALGORITHM}${DNSSEC_CURVE:+/$DNSSEC_CURVE})"
    else
      log "  WARNING: DNSSEC sign failed (or already signed) for $z."
    fi
  done
}

# -- DHCP scope -- #
configure_dhcp() {
  [[ "$ENABLE_DHCP" != "true" ]] && return 0
  if [[ -z "$DHCP_START_ADDRESS" || -z "$DHCP_END_ADDRESS" ]]; then
    log "WARNING: ENABLE_DHCP=true but DHCP_START_ADDRESS/DHCP_END_ADDRESS unset; skipping DHCP."
    return 0
  fi
  log "Configuring DHCP scope '${DHCP_SCOPE_NAME}' (${DHCP_START_ADDRESS}-${DHCP_END_ADDRESS})..."
  local args=(
    --data-urlencode "name=${DHCP_SCOPE_NAME}"
    --data-urlencode "startingAddress=${DHCP_START_ADDRESS}"
    --data-urlencode "endingAddress=${DHCP_END_ADDRESS}"
    --data-urlencode "subnetMask=${DHCP_SUBNET_MASK}"
    --data-urlencode "leaseTimeDays=${DHCP_LEASE_DAYS}"
    --data-urlencode "dnsUpdates=${DHCP_DNS_UPDATES}"
  )
  [[ -n "$DHCP_ROUTER" ]]      && args+=( --data-urlencode "routerAddress=${DHCP_ROUTER}" )
  [[ -n "$DHCP_DOMAIN" ]]      && args+=( --data-urlencode "domainName=${DHCP_DOMAIN}" )
  [[ -n "$DHCP_DNS_SEARCH" ]]  && args+=( --data-urlencode "domainSearchList=$(csv_clean "$DHCP_DNS_SEARCH")" )
  [[ -n "$DHCP_NTP_SERVERS" ]] && args+=( --data-urlencode "ntpServers=$(csv_clean "$DHCP_NTP_SERVERS")" )
  if [[ -n "$DHCP_DNS_SERVERS" ]]; then
    args+=( --data-urlencode "useThisDnsServer=false" --data-urlencode "dnsServers=$(csv_clean "$DHCP_DNS_SERVERS")" )
  else
    args+=( --data-urlencode "useThisDnsServer=true" )
  fi
  if api_call api/dhcp/scopes/set "${args[@]}" | json_status_ok; then
    log "  DHCP scope set."
  else
    log "  WARNING: failed to set DHCP scope '${DHCP_SCOPE_NAME}'."; return 0
  fi
  if [[ "$DHCP_SCOPE_ENABLED" == "true" ]]; then
    if api_call api/dhcp/scopes/enable --data-urlencode "name=${DHCP_SCOPE_NAME}" | json_status_ok; then
      log "  DHCP scope enabled."
    else
      log "  WARNING: could not enable scope (the server needs a NIC in the scope's subnet)."
    fi
  fi
}

# Drop a LICENSES/ directory into the air-gap bundle: a version-pinned third-party
# manifest plus a GPLv3-compliant written offer for the bundled copyleft component
# (Technitium DNS Server, GPL-3.0). This satisfies the GPL requirement to accompany
# a redistributed binary with the corresponding source OR a written offer for it.
# ($icu is a local of run_save; visible here via bash dynamic scope.)
generate_bundle_licenses() {
  local b="$1"
  mkdir -p "$b/LICENSES"
  cat > "$b/LICENSES/THIRD_PARTY_NOTICES.txt" << EOF
Third-party components redistributed in this Technitium DNS air-gap bundle
Generated: $(date)

Component                         License      Upstream source
--------------------------------  -----------  ---------------------------------------------
Technitium DNS Server (binary)    GPL-3.0      https://github.com/TechnitiumSoftware/DnsServer
  DnsServerPortable.tar.gz from ${TECHNITIUM_PACKAGE_URL}
.NET / ASP.NET Core ${DOTNET_VERSION} runtime    MIT          https://github.com/dotnet/runtime
  (LICENSE.txt + ThirdPartyNotices.txt ship inside dotnet-runtime.tar.gz)
libicu (${icu})                   Unicode/ICU  your OS distribution
technitium_dns_installer.sh,
install_packages.sh               Apache-2.0   https://github.com/Chubtoad5

The copyleft component (Technitium DNS Server, GPL-3.0) is covered by WRITTEN_OFFER.txt.
All others are permissive; their copyright/license notices are retained with the artifact.
EOF
  cat > "$b/LICENSES/WRITTEN_OFFER.txt" << EOF
WRITTEN OFFER FOR CORRESPONDING SOURCE CODE (GPL-3.0)

This air-gap bundle redistributes Technitium DNS Server in binary form
(DnsServerPortable.tar.gz). Technitium DNS Server is licensed under the GNU
General Public License, version 3.

In accordance with GPLv3 section 6, the distributor of this bundle hereby makes a
written offer, valid for three (3) years from the date this bundle was created
($(date +%Y-%m-%d)), to give any third party who possesses this bundle a complete
machine-readable copy of the corresponding source code, for a charge no more than
the cost of physically performing the source distribution.

The corresponding source is also publicly available from the upstream project at:
    https://github.com/TechnitiumSoftware/DnsServer

To request the source on a physical medium, contact: ${LICENSE_OFFER_CONTACT}

This offer is extended by whoever distributes this bundle, and is independent of
the Apache-2.0 license that covers the installer scripts themselves.
EOF
  log "  Wrote LICENSES/ (third-party manifest + GPL written offer for Technitium DNS)."
}

# ============================================================================ #
# -- save (build the air-gap bundle) --                                        #
# ============================================================================ #

# A failed save must not leave a loose sentinel behind: it would flip the next
# 'install' on this host into air-gap mode (TD-17), and a partial archive could
# be mistaken for a good one (W4).
on_save_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    log "ERROR: save did not complete (exit $rc); cleaning up partial artifacts."
    rm -rf "${base_dir:?}/$BUNDLE_DIR"
    rm -f "$base_dir/$SAVE_SENTINEL" "$base_dir/$SAVE_ARCHIVE.partial"
  fi
  exit "$rc"
}

run_save() {
  check_root_privileges          # install-packages 'save' needs root (TD-16)
  os_check
  preflight_dependencies
  init_log
  log "# -- Building Technitium air-gap bundle - $(date) -- #"
  trap on_save_exit EXIT
  local b="$base_dir/$BUNDLE_DIR"
  rm -rf "$b"; mkdir -p "$b/utilities"

  # 1. Installer scripts (for reference / offline upgrade)
  require_internet_artifact "$TECHNITIUM_INSTALL_URL"   "$b/install.sh"   "Technitium install.sh"
  require_internet_artifact "$TECHNITIUM_UNINSTALL_URL" "$b/uninstall.sh" "Technitium uninstall.sh"

  # 2. DNS server package
  require_internet_artifact "$TECHNITIUM_PACKAGE_URL" "$b/DnsServerPortable.tar.gz" "DnsServerPortable.tar.gz"

  # 3. ASP.NET Core runtime (materialise then tar; dotnet-install.sh handles arch)
  log "Fetching ASP.NET Core Runtime ${DOTNET_VERSION}..."
  local dotnet_install; dotnet_install="$(mktemp)"
  require_internet_artifact "$DOTNET_INSTALL_URL" "$dotnet_install" "dotnet-install.sh"
  rm -rf "$b/_dotnet"; mkdir -p "$b/_dotnet"
  debug_run bash "$dotnet_install" -c "$DOTNET_VERSION" --runtime aspnetcore --no-path --install-dir "$b/_dotnet"
  tar -czf "$b/dotnet-runtime.tar.gz" -C "$b/_dotnet" .
  rm -rf "$b/_dotnet" "$dotnet_install"

  # 4. install-packages.sh + the libicu OS package (offline-installable)
  require_internet_artifact "$INSTALL_PACKAGES_URL" "$b/utilities/install_packages.sh" "install_packages.sh"
  chmod +x "$b/utilities/install_packages.sh"
  local icu; icu="$(icu_package_name)"
  echo "$icu" > "$b/utilities/icu-package.txt"
  log "Saving OS package '$icu' for offline install..."
  ( cd "$b/utilities" && debug_run ./install_packages.sh save "$icu" )

  # 5. The installer itself + sentinel/manifest
  cp "$script_dir/$SCRIPT_NAME" "$b/"
  chmod +x "$b/$SCRIPT_NAME"
  cat > "$base_dir/$SAVE_SENTINEL" << EOF
# Technitium DNS Server Installer - air-gap bundle manifest
# Created:        $(date)
# Built on OS:    ${OS_ID}
# DNS package:    ${TECHNITIUM_PACKAGE_URL}
# .NET runtime:   ASP.NET Core ${DOTNET_VERSION}
# ICU package:    ${icu}
# Licenses:       see LICENSES/ (third-party manifest + GPL source offer)
#
# NOTE: this bundle is OS-family / architecture specific. Build it on the same
# distro family and CPU arch as the air-gapped target.
EOF
  cp "$base_dir/$SAVE_SENTINEL" "$b/"

  # 6. LICENSES/ — third-party manifest + GPL written offer (compliance)
  generate_bundle_licenses "$b"

  # The installer + sentinel sit at the TOP level of the archive so the documented
  # flow ('tar -xzf ...; sudo ./technitium_dns_installer.sh install') works
  # verbatim (TD-5). The copies inside $BUNDLE_DIR are kept for compatibility.
  # Build atomically: write to a temp name, then move into place (W4).
  tar -czf "$base_dir/$SAVE_ARCHIVE.partial" -C "$base_dir" "$BUNDLE_DIR" "$SAVE_SENTINEL" "$SCRIPT_NAME"
  mv -f "$base_dir/$SAVE_ARCHIVE.partial" "$base_dir/$SAVE_ARCHIVE"
  # The sentinel is preserved inside the archive; remove the loose copies from the
  # build host so a later 'install' here is not mistaken for an air-gapped run.
  rm -rf "$b"
  rm -f "$base_dir/$SAVE_SENTINEL"
  trap - EXIT
  log ""
  log "Bundle ready: $base_dir/$SAVE_ARCHIVE"
  log "Transfer it to the air-gapped host, extract it ('tar -xzf $SAVE_ARCHIVE'),"
  log "then run: sudo ./$SCRIPT_NAME install"
}

# ============================================================================ #
# -- upgrade --                                                                #
# ============================================================================ #
run_upgrade() {
  check_root_privileges
  os_check
  preflight_dependencies
  init_log
  if [[ ! -f "$SYSTEMD_UNIT" ]]; then
    log "ERROR: no existing dns.service found. Run 'install' first."
    exit 1
  fi
  air_gap_check
  snapshot_resolver_state
  if [[ "$AIR_GAPPED_MODE" -eq 1 ]]; then
    log "Upgrading (offline) from bundle..."
    local b="$base_dir/$BUNDLE_DIR"
    [[ -d "$b" ]] || { log "ERROR: bundle '$b' not found."; exit 1; }
    tar -xzf "$b/DnsServerPortable.tar.gz" -C "$DNS_APP_DIR"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$DNS_APP_DIR"
    debug_run systemctl restart dns.service
  else
    log "Upgrading (online) via upstream install.sh (config in $DNS_CONFIG_DIR is preserved)..."
    install_online
    online_resolver_compensate
  fi
  verify_service_install
  rm -rf "$RESOLVER_SNAP_DIR"
  log "Upgrade complete."
}

# ============================================================================ #
# -- uninstall (non-interactive replica of upstream uninstall.sh) --           #
# ============================================================================ #

# Evidence that an install commandeered the host resolver: the state marker, a
# resolver backup, the installer-written resolv.conf header, or (heuristic for
# pre-marker installs) a live unit plus resolv.conf pointing at 127.0.0.1.
resolver_takeover_evident() {
  local dnsDir="$1" unit_present="$2" st_takeover="$3"
  [[ "$st_takeover" == "true" ]] && return 0
  [[ -e "$dnsDir/resolv.conf.bak" || -L "$dnsDir/resolv.conf.bak" ]] && return 0
  grep -qs "Generated by Technitium DNS Server Installer" /etc/resolv.conf && return 0
  if (( unit_present )) && grep -qsE '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1' /etc/resolv.conf; then
    return 0
  fi
  return 1
}

restore_resolver_on_uninstall() {
  local dnsDir="$1" nm_had="$2" nm_val="$3" resolved_was_active="$4"
  local bak="$dnsDir/resolv.conf.bak"
  rm -f /etc/resolv.conf
  if [[ -f "$bak" ]] && ! grep -q '127\.0\.0\.1' "$bak" 2>/dev/null; then
    # Regular backup (or symlink to an existing file): restore its contents as
    # a real file — never re-create a symlink that may dangle (TD-14).
    cat "$bak" > /etc/resolv.conf
  elif [[ -f "$bak" ]]; then
    # Backup was clobbered with the takeover content (upstream online re-runs
    # overwrite it) — restoring it would restore 127.0.0.1 with no server.
    log "resolv.conf backup contains the takeover content; falling back to public nameservers."
    printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
  elif [[ -L "$bak" ]]; then
    # Dangling symlink backup from a pre-fix install (TD-14).
    log "resolv.conf backup is a dangling symlink; falling back to public nameservers."
    printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
  else
    printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
  fi

  if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
    if [[ "$nm_had" == "true" && -n "$nm_val" ]]; then
      sed -i "s/^dns=none/dns=${nm_val}/" /etc/NetworkManager/NetworkManager.conf || true
    elif [[ "$nm_had" == "false" ]]; then
      sed -i '/^dns=none$/d' /etc/NetworkManager/NetworkManager.conf || true
    else
      sed -i "s/^dns=none/dns=default/g" /etc/NetworkManager/NetworkManager.conf || true
    fi
  fi

  # Re-enable systemd-resolved when the state marker says it was active before
  # install, when the restored resolv.conf needs the resolved stub, or (legacy,
  # no state marker) per the DISABLE_SYSTEMD_RESOLVED env as before.
  local reenable=0
  [[ "$resolved_was_active" == "true" ]] && reenable=1
  grep -qs '127\.0\.0\.53' /etc/resolv.conf && reenable=1
  [[ -z "$resolved_was_active" && "$DISABLE_SYSTEMD_RESOLVED" == "true" ]] && reenable=1
  if (( reenable )); then
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl start  systemd-resolved >/dev/null 2>&1 || true
  fi
  log "Host resolver restored."
}

run_uninstall() {
  check_root_privileges
  init_log
  log "# -- Uninstalling Technitium DNS Server - $(date) -- #"

  local dnsDir="$DNS_APP_DIR"
  # Legacy-layout fallback: only when /etc/dns actually CONTAINS the app.
  # Otherwise a second uninstall run would select the preserved config dir and
  # purge it despite PURGE_DATA=false (TD-1).
  if [[ ! -d "$DNS_APP_DIR" && -f "$DNS_CONFIG_DIR/DnsServerApp.dll" ]]; then
    dnsDir="$DNS_CONFIG_DIR"
  fi

  local unit_present=0
  [[ -f "$SYSTEMD_UNIT" ]] && unit_present=1

  # TD-2: never touch the resolver or firewall on a host this installer (or the
  # upstream scripts) never installed on.
  if [[ ! -f "$SYSTEMD_UNIT" && ! -d "$DNS_APP_DIR" && ! -f "$DNS_CONFIG_DIR/DnsServerApp.dll" && ! -f "$STATE_FILE" ]]; then
    log "No Technitium DNS Server installation found (no dns.service unit, app directory, or installer state)."
    log "Nothing to uninstall; host resolver and firewall left untouched."
    return 0
  fi

  local st_takeover st_fw_type st_fw_ports st_nm_had st_nm_val st_resolved_active
  st_takeover="$(state_get RESOLVER_TAKEOVER)"
  st_fw_type="$(state_get FIREWALL_TYPE)"
  st_fw_ports="$(state_get FIREWALL_PORTS_ADDED)"
  st_nm_had="$(state_get NM_HAD_DNS_LINE)"
  st_nm_val="$(state_get NM_PREV_DNS_VALUE)"
  st_resolved_active="$(state_get RESOLVED_WAS_ACTIVE)"

  if [[ "$(ps --no-headers -o comm 1 | tr -d '\n')" == "systemd" ]]; then
    systemctl disable dns.service >/dev/null 2>&1 || true
    systemctl stop dns.service    >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true   # drop the stale unit (TD-18)

    # Restore the host resolver only on evidence that an install actually
    # commandeered it (TD-2).
    if resolver_takeover_evident "$dnsDir" "$unit_present" "$st_takeover"; then
      restore_resolver_on_uninstall "$dnsDir" "$st_nm_had" "$st_nm_val" "$st_resolved_active"
    else
      log "No evidence the installer commandeered the host resolver; leaving /etc/resolv.conf, NetworkManager and systemd-resolved untouched."
    fi
    userdel -f "$SERVICE_USER" >/dev/null 2>&1 || true
  fi

  remove_firewall_rules "$st_fw_type" "$st_fw_ports"

  rm -rf "$dnsDir"
  rm -f "$STATE_FILE"
  # Drop the now-empty /opt/technitium parent (upstream leaves it behind).
  [[ "$dnsDir" == "$DNS_APP_DIR" ]] && rmdir /opt/technitium 2>/dev/null || true

  if [[ "$REMOVE_DOTNET" == "true" && -d "$DOTNET_DIR" ]]; then
    log "Removing .NET runtime ($DOTNET_DIR)..."
    rm -f /usr/bin/dotnet; rm -rf "$DOTNET_DIR"
  else
    log ".NET runtime left in place (set REMOVE_DOTNET=true to remove $DOTNET_DIR)."
  fi

  if [[ "$PURGE_DATA" == "true" && -d "$DNS_CONFIG_DIR" ]]; then
    log "Purging config/zone data ($DNS_CONFIG_DIR)..."
    rm -rf "$DNS_CONFIG_DIR" "$DNS_LOG_DIR"
    rmdir /var/log/technitium 2>/dev/null || true
  else
    # Reset preserved dirs to root ownership — the dns-server user is gone and
    # orphan-UID files would linger otherwise (TD-18).
    [[ -d "$DNS_CONFIG_DIR" ]] && chown -R root:root "$DNS_CONFIG_DIR" 2>/dev/null || true
    [[ -d "$DNS_LOG_DIR" ]]    && chown -R root:root "$DNS_LOG_DIR"    2>/dev/null || true
    log "Config folder $DNS_CONFIG_DIR preserved (set PURGE_DATA=true to delete it)."
  fi
  log "Uninstall complete."
}

# ============================================================================ #
# -- install orchestrator --                                                   #
# ============================================================================ #

# EXIT trap while installing (TD-4): if the run dies before the DNS service was
# confirmed up, put the resolver back the way it was — never strand the host
# with 'nameserver 127.0.0.1' and nothing answering on :53.
on_install_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    log "ERROR: install did not complete (exit $rc)."
    if (( SERVICE_CONFIRMED == 0 )) && resolver_state_changed; then
      log "Restoring the pre-install resolver state (the DNS service was never confirmed up)..."
      restore_resolver_snapshot
      log "Resolver restored."
    fi
  fi
  [[ -n "${RESOLVER_SNAP_DIR:-}" ]] && rm -rf "$RESOLVER_SNAP_DIR"
  exit "$rc"
}

run_install() {
  check_root_privileges
  os_check
  preflight_dependencies
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  log "# -- Technitium DNS Server Installer v${SCRIPT_VERSION} Started - $(date) -- #"
  air_gap_check
  snapshot_resolver_state
  trap on_install_exit EXIT
  if [[ "$AIR_GAPPED_MODE" -eq 1 ]]; then
    install_offline
  else
    install_online
    online_resolver_compensate   # TD-3: honour DISABLE_SYSTEMD_RESOLVED=false online
  fi
  verify_service_install         # TD-20: don't trust the delegated path blindly
  configure_dns_server
  apply_resolver_policy          # TD-4: takeover only after the service is confirmed up
  configure_firewall             # TD-8: after config, so the final web port is known
  write_state_file
  trap - EXIT
  rm -rf "$RESOLVER_SNAP_DIR"

  log ""
  log "================================================================"
  log "Technitium DNS Server installed."
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    log "  Web console : https://$(hostname -I | awk '{print $1}'):${DNS_HTTPS_PORT}/ (self-signed)"
  fi
  log "  Web console : http://$(hostname -I | awk '{print $1}'):${DNS_WEB_PORT}/"
  log "  Username    : ${DNS_ADMIN_USER}"
  if [[ "$DNS_ADMIN_PASSWORD" == "changeme" ]]; then
    log "  Password    : the default 'changeme' - CHANGE IT (set DNS_ADMIN_PASSWORD)"
  else
    log "  Password    : (set from DNS_ADMIN_PASSWORD - not logged)"
  fi
  log "================================================================"
}

# ============================================================================ #
# -- argument dispatch --                                                      #
# ============================================================================ #
[[ $# -eq 0 ]] && usage 1
while [[ $# -gt 0 ]]; do
  case "$1" in
    install)   INSTALL_MODE=1; shift ;;
    save)      SAVE_MODE=1; shift ;;
    upgrade)   UPGRADE_MODE=1; shift ;;
    uninstall) UNINSTALL_MODE=1; shift ;;
    help|-h|--help) usage 0 ;;
    *) echo "Invalid argument: $1"; usage 1 ;;
  esac
done

if [[ "$SAVE_MODE" -eq 1 ]];      then run_save; fi
if [[ "$UPGRADE_MODE" -eq 1 ]];   then run_upgrade; fi
if [[ "$UNINSTALL_MODE" -eq 1 ]]; then run_uninstall; fi
if [[ "$INSTALL_MODE" -eq 1 ]];   then run_install; fi
