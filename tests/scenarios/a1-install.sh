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
export ADMIN_PASSWORD=Test-Pass-1 ZONES_TEMPLATE="$W/zones.txt"
./technitium_dns_installer.sh install > "$W/o" 2>&1 && ok "install with no route out" || { bad "install with no route out"; tail -8 "$W/o" | cut -c1-170; }
grep -q "Air-gap bundle detected" "$W/o" && ok "it installs from the bundle" || bad "it didn't say it used the bundle"
systemctl is-active -q dns && ok "the service runs" || bad "the service isn't running"
c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:5380/); [[ "$c" =~ ^[23] ]] && ok "the console answers" || bad "the console answered $c"
[ "$(getent hosts web.test.lab | awk '{print $1}')" = 10.0.0.9 ] && ok "the host resolves the zone's record through it" || bad "web.test.lab resolves to '$(getent hosts web.test.lab)'"
PURGE_DATA=true ./technitium_dns_installer.sh uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
systemctl is-active -q dns && bad "the service is still running" || ok "the service is gone"
echo "=== exit $fail"; exit $fail
