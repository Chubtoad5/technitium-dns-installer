#!/bin/bash
# A5: install the last release (its source archive from GitHub) with a zones template, add a record in the console's API
# as a user would, then install the commit under test over it. The records, the admin password and the service survive.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
R=technitium-dns-installer
old=$(curl -sI -m 20 "https://github.com/Chubtoad5/$R/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p')
[[ "$old" =~ ^v[0-9]+(\.[0-9]+)+$ ]] && ok "the last release is $old" || { bad "couldn't find the last release: '$old'"; echo "=== exit 1"; exit 1; }
mkdir old new
curl -sfL -m 180 "https://github.com/Chubtoad5/$R/archive/refs/tags/$old.tar.gz" | tar -xz -C old --strip-components=1 && [ -x old/technitium_dns_installer.sh ] \
  && ok "download $old" || { bad "download $old"; echo "=== exit 1"; exit 1; }
cp "$REPO/technitium_dns_installer.sh" new/; chmod +x new/technitium_dns_installer.sh
printf '# test.lab\nweb 10.0.0.9\n' > zones.txt
PW=Test-Pass-1
export DNS_ADMIN_PASSWORD=$PW ZONES_TEMPLATE="$W/zones.txt"
console() { [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:5380/)" =~ ^[23] ]]; }
resolves() { [ "$(getent hosts "$1" | awk '{print $1}')" = "$2" ]; }
token() { curl -s -m 10 -G http://127.0.0.1:5380/api/user/login --data-urlencode user=admin --data-urlencode "pass=$PW" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p'; }

(cd old && ./technitium_dns_installer.sh install) > o1 2>&1 && ok "install $old" || { bad "install $old"; tail -8 o1 | cut -c1-170; echo "=== exit 1"; exit 1; }
within 90 console && ok "$old's console answers" || bad "$old's console doesn't answer"
within 90 resolves web.test.lab 10.0.0.9 && ok "$old serves the template's record" || bad "$old doesn't serve web.test.lab"
t=$(token)
if [ -n "$t" ]; then
  st=$(curl -s -m 10 -G http://127.0.0.1:5380/api/zones/records/add --data-urlencode "token=$t" --data-urlencode domain=manual.test.lab \
    --data-urlencode type=A --data-urlencode ipAddress=10.0.0.7 | sed -n 's/.*"status": *"\([^"]*\)".*/\1/p')
  [ "$st" = ok ] && ok "add a record through the API, as a user would in the console" || bad "couldn't add a record through the API: $st"
else
  bad "can't log in to $old's API"
fi
within 30 resolves manual.test.lab 10.0.0.7 && ok "the added record resolves" || bad "the added record doesn't resolve"

(cd new && ./technitium_dns_installer.sh install) > o2 2>&1 && ok "install the commit under test over $old" || { bad "install the commit under test over $old"; tail -10 o2 | cut -c1-170; }
systemctl is-active -q dns && ok "the service runs after the upgrade" || bad "the service isn't running after the upgrade"
within 90 console && ok "the console answers after the upgrade" || bad "the console doesn't answer after the upgrade"
within 90 resolves web.test.lab 10.0.0.9 && ok "the template's record still resolves" || bad "web.test.lab no longer resolves"
within 30 resolves manual.test.lab 10.0.0.7 && ok "the record added through the API survived" || bad "the record added through the API is gone"
[ -n "$(token)" ] && ok "the admin password still logs in" || bad "the admin password no longer logs in"
(cd new && PURGE_DATA=true ./technitium_dns_installer.sh uninstall) > o3 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 o3 | cut -c1-170; }
systemctl is-active -q dns && bad "the service is still running" || ok "the service is gone"
echo "=== exit $fail"; exit $fail
