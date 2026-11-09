#!/bin/bash
# A1, on a host with no route out: install from the bundle the build role made, check it answers, uninstall.
# Nothing here downloads, and the test installs no tool of its own: the host's resolver points at the new server.
set -uo pipefail
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
tar -xzf "$CI_HANDOFF/technitium-save.tar.gz" && ok "unpack the bundle" || { bad "unpack the bundle"; echo "=== exit 1"; exit 1; }
printf '# test.lab\nweb 10.0.0.9\n' > zones.txt
export DNS_ADMIN_PASSWORD=Test-Pass-1 ZONES_TEMPLATE="$W/zones.txt"
./technitium_dns_installer.sh install > "$W/o" 2>&1 && ok "install with no route out" || { bad "install with no route out"; tail -8 "$W/o" | cut -c1-170; }
grep -q "Air-gap bundle detected" "$W/o" && ok "it installs from the bundle" || bad "it didn't say it used the bundle"
systemctl is-active -q dns && ok "the service runs" || bad "the service isn't running"
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
console() { [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:5380/)" =~ ^[23] ]]; }
resolves() { [ "$(getent hosts web.test.lab | awk '{print $1}')" = 10.0.0.9 ]; }
# The install applies its web-service settings last, so the server can still be restarting when it returns.
within 90 console && ok "the console answers" || { bad "the console doesn't answer after 90 s"; ss -ltnp | grep -E ':(53|5380) ' | head -4; journalctl -u dns --no-pager -n 8 | cut -c1-170; }
within 90 resolves && ok "the host resolves the zone's record through it" || { bad "web.test.lab resolves to '$(getent hosts web.test.lab)'"; head -3 /etc/resolv.conf; }
PURGE_DATA=true ./technitium_dns_installer.sh uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
systemctl is-active -q dns && bad "the service is still running" || ok "the service is gone"
echo "=== exit $fail"; exit $fail
