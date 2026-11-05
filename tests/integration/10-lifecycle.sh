#!/bin/bash
# The real installer on a throwaway host, as root, from the repo root: install with a zone, re-run, uninstall.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# Test tools, on whichever package manager this host has. Named the way apt names them, with the other names in the case.
pkg_install() {
  if command -v apt-get >/dev/null; then
    apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null; then
    dnf install -y -q "${@/#dnsutils/bind-utils}" >/dev/null 2>&1
  else
    zypper -n -q install "${@/#dnsutils/bind-utils}" >/dev/null 2>&1
  fi
}
pkg_install dnsutils
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/technitium_dns_installer.sh" .; chmod +x technitium_dns_installer.sh
printf '# test.lab\nweb 10.0.0.9\n' > zones.txt
export ADMIN_PASSWORD=Test-Pass-1 ZONES_TEMPLATE="$W/zones.txt"
./technitium_dns_installer.sh install >"$W/o" 2>&1 && ok "install" || { bad "install"; tail -6 "$W/o" | cut -c1-170; }
[ "$(dig +short +time=3 @127.0.0.1 web.test.lab)" = 10.0.0.9 ] && ok "the zone's record resolves" || bad "the record doesn't resolve"
./technitium_dns_installer.sh install >"$W/o" 2>&1 && ok "same-settings re-run" || { bad "re-run"; tail -6 "$W/o" | cut -c1-170; }
PURGE_DATA=true ./technitium_dns_installer.sh uninstall >"$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
systemctl is-active --quiet dns && bad "the service is still running" || ok "the service is gone"
echo "=== exit $fail"; exit $fail
