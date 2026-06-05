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
base_dir=$(pwd)

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

# -- Admin user / credentials -- #
DNS_ADMIN_USER=${DNS_ADMIN_USER:-"admin"}        # built-in admin account (rename not supported in v1.0)
DNS_ADMIN_PASSWORD=${DNS_ADMIN_PASSWORD:-"changeme"}

# -- Web console (DNS management) -- #
DNS_WEB_PORT=${DNS_WEB_PORT:-"5380"}             # upstream default is 5380
ENABLE_HTTPS=${ENABLE_HTTPS:-"false"}            # serve the web console over HTTPS
DNS_HTTPS_PORT=${DNS_HTTPS_PORT:-"53443"}        # only used when ENABLE_HTTPS=true (self-signed cert)

# -- Host integration -- #
DISABLE_SYSTEMD_RESOLVED=${DISABLE_SYSTEMD_RESOLVED:-"true"}  # mirrors upstream install.sh behaviour

# -- Uninstall behaviour -- #
PURGE_DATA=${PURGE_DATA:-"false"}                # also remove /etc/dns (all zones/config) on uninstall
REMOVE_DOTNET=${REMOVE_DOTNET:-"false"}          # also remove /opt/dotnet on uninstall

# ============================================================================ #
# -- v1.1 RESERVED variables (defined now for a stable contract; NOT yet      #
#    active in v1.0 -- setting any of these prints a notice and is ignored).   #
#    See specs/tools/technitium-dns-installer.spec.md "Roadmap" section.       #
# ============================================================================ #
DNS_FORWARDERS=${DNS_FORWARDERS:-""}                       # e.g. "1.1.1.1, 8.8.8.8"
DNS_FORWARDER_PROTOCOL=${DNS_FORWARDER_PROTOCOL:-"Udp"}    # Udp | Tcp | Tls | Https
ENABLE_DNSSEC=${ENABLE_DNSSEC:-"false"}                    # DNSSEC-sign created primary zones
ZONES_TEMPLATE=${ZONES_TEMPLATE:-""}                       # path to a zone+record template file
ENABLE_DHCP=${ENABLE_DHCP:-"false"}                        # create + enable a DHCP scope
DHCP_SCOPE_NAME=${DHCP_SCOPE_NAME:-"Default"}
DHCP_START_ADDRESS=${DHCP_START_ADDRESS:-""}
DHCP_END_ADDRESS=${DHCP_END_ADDRESS:-""}
DHCP_SUBNET_MASK=${DHCP_SUBNET_MASK:-"255.255.255.0"}
DHCP_ROUTER=${DHCP_ROUTER:-""}
DHCP_DNS_SERVERS=${DHCP_DNS_SERVERS:-""}
DHCP_DOMAIN=${DHCP_DOMAIN:-""}
DHCP_DNS_SEARCH=${DHCP_DNS_SEARCH:-""}
DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS:-""}
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

API_TOKEN=""
API_BASE=""           # resolved by wait_for_webservice (http://127.0.0.1:<port>)

# ============================================================================ #
# -- Helpers --                                                                #
# ============================================================================ #
log()  { echo "$*" | tee -a "$LOG_FILE"; }

usage() {
  cat << EOF
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

Common environment overrides (see README.md for the full list):
  DNS_ADMIN_PASSWORD   Admin password to set (default: changeme)
  DNS_WEB_PORT         Web console HTTP port (default: 5380)
  ENABLE_HTTPS         Serve the console over HTTPS self-signed (default: false)
  DNS_HTTPS_PORT       HTTPS port when ENABLE_HTTPS=true (default: 53443)
  PURGE_DATA           uninstall also removes $DNS_CONFIG_DIR (default: false)
  REMOVE_DOTNET        uninstall also removes $DOTNET_DIR (default: false)

Example:
  sudo DNS_ADMIN_PASSWORD='S3cret!' DNS_WEB_PORT=8053 ENABLE_HTTPS=true ./$SCRIPT_NAME install
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

# Resolve the best-available libicu package name for the running distro.
icu_package_name() {
  case "$OS_ID" in
    ubuntu|debian)
      if apt-cache show libicu74 >/dev/null 2>&1;   then echo "libicu74"
      elif apt-cache show libicu72 >/dev/null 2>&1; then echo "libicu72"
      elif apt-cache show libicu70 >/dev/null 2>&1; then echo "libicu70"
      else echo "libicu-dev"; fi ;;
    *) echo "libicu" ;;   # dnf/yum/zypper all ship a 'libicu' package
  esac
}

air_gap_check() {
  if [[ -f "$base_dir/$SAVE_SENTINEL" ]]; then
    AIR_GAPPED_MODE=1
    log "Air-gap bundle detected ($SAVE_SENTINEL) -> offline install."
  fi
}

require_internet_artifact() {
  # $1 = url, $2 = output path, $3 = description
  if ! curl -fsSL --retry 3 -o "$2" "$1"; then
    log "ERROR: failed to download $3 from: $1"
    exit 1
  fi
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

  # 5. systemd service + user + host DNS (mirrors upstream install.sh)
  if [[ "$(ps --no-headers -o comm 1 | tr -d '\n')" != "systemd" ]]; then
    log "ERROR: systemd was not detected; cannot install the dns.service unit."
    exit 1
  fi

  if [[ -f "$SYSTEMD_UNIT" ]]; then
    log "Existing dns.service found -> restarting."
    debug_run systemctl restart dns.service
  else
    id "$SERVICE_USER" &>/dev/null || useradd --system -M --shell /usr/sbin/nologin "$SERVICE_USER"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$DNS_APP_DIR" "$DNS_CONFIG_DIR" "$DNS_LOG_DIR"
    cp "$DNS_APP_DIR/systemd.service" "$SYSTEMD_UNIT"
    debug_run systemctl enable dns.service
    if [[ "$DISABLE_SYSTEMD_RESOLVED" == "true" ]]; then
      systemctl stop systemd-resolved >/dev/null 2>&1 || true
      systemctl disable systemd-resolved >/dev/null 2>&1 || true
      configure_host_resolver
    fi
    debug_run systemctl start dns.service
  fi
}

# Point the host at 127.0.0.1 and stop NetworkManager from clobbering resolv.conf
# (mirrors the upstream install.sh resolver handling).
configure_host_resolver() {
  if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
    if ! grep -qF "dns=" /etc/NetworkManager/NetworkManager.conf; then
      printf "\n[main]\ndns=none\n" >> /etc/NetworkManager/NetworkManager.conf
    elif ! grep -qF "dns=none" /etc/NetworkManager/NetworkManager.conf; then
      sed -i "s/^dns=.*/dns=none/g" /etc/NetworkManager/NetworkManager.conf
    fi
  fi
  [[ -f "$DNS_APP_DIR/resolv.conf.bak" ]] || cp -a /etc/resolv.conf "$DNS_APP_DIR/resolv.conf.bak" 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf "# Generated by Technitium DNS Server Installer\n\nnameserver 127.0.0.1\n" > /etc/resolv.conf
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

# api_call <endpoint> [--data-urlencode k=v ...]
# POST to the API with the session token added. All caller-supplied values must be
# passed as --data-urlencode: Technitium rejects unencoded special characters in
# passwords / values (verified against a live server).
api_call() {
  local endpoint="$1"; shift
  curl -fsSk "${API_BASE}/${endpoint}" --data-urlencode "token=${API_TOKEN}" "$@"
}

# Log in (handles both first-run admin/admin and an already-changed password),
# then ensure the password equals DNS_ADMIN_PASSWORD. Idempotent.
api_login_and_set_password() {
  local resp
  # 1. Try the desired password first (idempotent re-runs).
  resp=$(curl -fsSk "${API_BASE}/api/user/login" \
            --data-urlencode "user=${DNS_ADMIN_USER}" \
            --data-urlencode "pass=${DNS_ADMIN_PASSWORD}" \
            --data-urlencode "includeInfo=true" || true)
  if echo "$resp" | json_status_ok; then
    API_TOKEN=$(echo "$resp" | json_field token)
    log "Authenticated as ${DNS_ADMIN_USER} (password already set)."
    return 0
  fi
  # 2. Fall back to the factory default admin/admin and change the password.
  resp=$(curl -fsSk "${API_BASE}/api/user/login" \
            --data-urlencode "user=admin" \
            --data-urlencode "pass=admin" \
            --data-urlencode "includeInfo=true" || true)
  if ! echo "$resp" | json_status_ok; then
    log "ERROR: could not authenticate with the configured or factory-default credentials."
    exit 1
  fi
  API_TOKEN=$(echo "$resp" | json_field token)
  log "Authenticated with factory default; setting admin password..."
  # changePassword requires BOTH the current password (pass) and the new one (newPass).
  if api_call api/user/changePassword \
        --data-urlencode "pass=admin" \
        --data-urlencode "newPass=${DNS_ADMIN_PASSWORD}" | json_status_ok; then
    log "Admin password updated."
  else
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

# v1.0 config engine: password + web service. (v1.1 hooks invoked afterwards.)
configure_dns_server() {
  wait_for_webservice
  api_login_and_set_password
  api_configure_web_service
  v11_feature_notice
}

# v1.1 features are not active yet -- warn loudly if a user set them so the
# behaviour is never a silent no-op.
v11_feature_notice() {
  local set_flags=()
  [[ -n "$DNS_FORWARDERS" ]]      && set_flags+=("DNS_FORWARDERS")
  [[ -n "$ZONES_TEMPLATE" ]]      && set_flags+=("ZONES_TEMPLATE")
  [[ "$ENABLE_DNSSEC" == "true" ]] && set_flags+=("ENABLE_DNSSEC")
  [[ "$ENABLE_DHCP" == "true" ]]   && set_flags+=("ENABLE_DHCP")
  if (( ${#set_flags[@]} > 0 )); then
    log ""
    log "NOTICE: ${set_flags[*]} -> these configure zones/records/forwarders/DHCP/DNSSEC,"
    log "        which are planned for v1.1 and are NOT applied by this v1.0 release."
    log "        They were ignored. See the spec 'Roadmap' section."
  fi
}

# ============================================================================ #
# -- save (build the air-gap bundle) --                                        #
# ============================================================================ #
run_save() {
  log "# -- Building Technitium air-gap bundle - $(date) -- #"
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
  cp "$base_dir/$SCRIPT_NAME" "$b/"
  cat > "$base_dir/$SAVE_SENTINEL" << EOF
# Technitium DNS Server Installer - air-gap bundle manifest
# Created:        $(date)
# Built on OS:    ${OS_ID}
# DNS package:    ${TECHNITIUM_PACKAGE_URL}
# .NET runtime:   ASP.NET Core ${DOTNET_VERSION}
# ICU package:    ${icu}
#
# NOTE: this bundle is OS-family / architecture specific. Build it on the same
# distro family and CPU arch as the air-gapped target.
EOF
  cp "$base_dir/$SAVE_SENTINEL" "$b/"

  tar -czf "$base_dir/$SAVE_ARCHIVE" -C "$base_dir" "$BUNDLE_DIR" "$SAVE_SENTINEL"
  # The sentinel is preserved inside the archive; remove the loose copies from the
  # build host so a later 'install' here is not mistaken for an air-gapped run.
  rm -rf "$b"
  rm -f "$base_dir/$SAVE_SENTINEL"
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
  if [[ ! -f "$SYSTEMD_UNIT" ]]; then
    log "ERROR: no existing dns.service found. Run 'install' first."
    exit 1
  fi
  air_gap_check
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
  fi
  log "Upgrade complete."
}

# ============================================================================ #
# -- uninstall (non-interactive replica of upstream uninstall.sh) --           #
# ============================================================================ #
run_uninstall() {
  check_root_privileges
  log "# -- Uninstalling Technitium DNS Server - $(date) -- #"
  local dnsDir="$DNS_APP_DIR"
  [[ -d /etc/dns/config && ! -d "$DNS_APP_DIR" ]] && dnsDir="/etc/dns"

  if [[ "$(ps --no-headers -o comm 1 | tr -d '\n')" == "systemd" ]]; then
    systemctl disable dns.service >/dev/null 2>&1 || true
    systemctl stop dns.service    >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT"

    # Restore host resolver
    rm -f /etc/resolv.conf
    if [[ -f "$dnsDir/resolv.conf.bak" ]]; then
      cp -a "$dnsDir/resolv.conf.bak" /etc/resolv.conf
    else
      printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
    fi
    if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
      sed -i "s/^dns=none/dns=default/g" /etc/NetworkManager/NetworkManager.conf || true
    fi
    if [[ "$DISABLE_SYSTEMD_RESOLVED" == "true" ]]; then
      systemctl enable systemd-resolved >/dev/null 2>&1 || true
      systemctl start  systemd-resolved >/dev/null 2>&1 || true
    fi
    userdel -f "$SERVICE_USER" >/dev/null 2>&1 || true
  fi

  rm -rf "$dnsDir"
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
  else
    [[ -d "$DNS_CONFIG_DIR" ]] && chown -R root:root "$DNS_CONFIG_DIR" 2>/dev/null || true
    log "Config folder $DNS_CONFIG_DIR preserved (set PURGE_DATA=true to delete it)."
  fi
  log "Uninstall complete."
}

# ============================================================================ #
# -- install orchestrator --                                                   #
# ============================================================================ #
run_install() {
  check_root_privileges
  os_check
  : > "$LOG_FILE"
  log "# -- Technitium DNS Server Installer Started - $(date) -- #"
  air_gap_check
  if [[ "$AIR_GAPPED_MODE" -eq 1 ]]; then
    install_offline
  else
    install_online
  fi
  configure_dns_server

  log ""
  log "================================================================"
  log "Technitium DNS Server installed."
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    log "  Web console : https://$(hostname -I | awk '{print $1}'):${DNS_HTTPS_PORT}/ (self-signed)"
  fi
  log "  Web console : http://$(hostname -I | awk '{print $1}'):${DNS_WEB_PORT}/"
  log "  Username    : ${DNS_ADMIN_USER}"
  log "  Password    : ${DNS_ADMIN_PASSWORD}"
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

if [[ "$SAVE_MODE" -eq 1 ]];      then os_check; : > "$LOG_FILE"; run_save; fi
if [[ "$UPGRADE_MODE" -eq 1 ]];   then run_upgrade; fi
if [[ "$UNINSTALL_MODE" -eq 1 ]]; then run_uninstall; fi
if [[ "$INSTALL_MODE" -eq 1 ]];   then run_install; fi
