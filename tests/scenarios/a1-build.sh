#!/bin/bash
# A1, on the host that builds the bundle: save, then hand the archive to the next role.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/technitium_dns_installer.sh" .; chmod +x technitium_dns_installer.sh
if ./technitium_dns_installer.sh save > "$W/o" 2>&1 && [ -s technitium-save.tar.gz ]; then
  ok "save builds technitium-save.tar.gz ($(du -h technitium-save.tar.gz | cut -f1))"
  cp technitium-save.tar.gz "$CI_HANDOFF/" && ok "hand the bundle on" || bad "hand the bundle on"
else
  bad "save"; tail -6 "$W/o" | cut -c1-170
fi
echo "=== exit $fail"; exit $fail
