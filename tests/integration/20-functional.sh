#!/bin/bash
# What Technitium is for, on a throwaway host, as root, from the repo root (spec 09's C3, in the chubtoad-automation
# project): forwarders resolve an outside name, DNSSEC signs a zone, HTTPS and a custom port work, and the host's resolver
# is back after uninstall. Runs after 10-lifecycle.sh, which leaves the host uninstalled. The test installs no tool of its
# own (a DNS client once pulled in libicu, which the installer needs, and hid that it was missing): it uses getent, curl,
# and Technitium's own API.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/technitium_dns_installer.sh" .; chmod +x technitium_dns_installer.sh
show() { tail -8 "$W/o" | cut -c1-170; }
# The host's own resolver before the install: the forwarder, and what uninstall has to put back
up=$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null)
[ -n "$up" ] || up=$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)
before=$(cat /etc/resolv.conf); resolved_before=$(systemctl is-active systemd-resolved 2>/dev/null)
printf '# test.lab\nweb 10.0.0.9\n' > zones.txt
P=Test-Pass-1 WEB=8053 TLS=58443
export DNS_ADMIN_PASSWORD=$P ZONES_TEMPLATE="$W/zones.txt" DNS_FORWARDERS="$up" ENABLE_DNSSEC=true ENABLE_HTTPS=true \
  DNS_WEB_PORT=$WEB DNS_HTTPS_PORT=$TLS
./technitium_dns_installer.sh install > "$W/o" 2>&1 && ok "install with a forwarder, DNSSEC, HTTPS and port $WEB" || { bad "install"; show; }
console() { [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WEB/")" =~ ^[23] ]]; }
within 90 console && ok "the console answers on port $WEB" || bad "nothing answers on port $WEB"
c=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$TLS/"); [[ "$c" =~ ^[23] ]] && ok "the console answers over HTTPS on $TLS" || bad "HTTPS on $TLS answered $c"
crt=$(openssl s_client -connect 127.0.0.1:$TLS </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
[ -n "$crt" ] && ok "HTTPS presents a certificate ($crt)" || bad "no certificate on $TLS"
c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:5380/); [ "$c" = 000 ] && ok "nothing answers on the default port 5380" || bad "5380 answered $c"
tok=$(curl -s -m 10 "http://127.0.0.1:$WEB/api/user/login" --data-urlencode user=admin --data-urlencode "pass=$P" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[ -n "$tok" ] && ok "the admin logs in with DNS_ADMIN_PASSWORD" || bad "the admin can't log in"
api() { curl -s -m 10 "http://127.0.0.1:$WEB/api/$1" --data-urlencode "token=$tok" "${@:2}"; }
fw=$(api settings/get | grep -o '"forwarders":\[[^]]*\]')
[[ -n "$up" && "$fw" == *"$up"* ]] && ok "the forwarder is $up, the host's own resolver" || bad "forwarders: '$fw' (wanted $up)"
outside() { [ -n "$(getent hosts github.com)" ]; }
within 30 outside && ok "an outside name resolves through it" || bad "github.com doesn't resolve"
grep -qE '^nameserver 127\.0\.0\.1' /etc/resolv.conf && ok "the host's resolver points at it" || bad "resolv.conf: $(grep nameserver /etc/resolv.conf | head -2 | tr '\n' ' ')"
[ "$(getent hosts web.test.lab | awk '{print $1}')" = 10.0.0.9 ] && ok "the zone's record resolves" || bad "web.test.lab doesn't resolve"
st=$(api zones/dnssec/properties/get --data-urlencode zone=test.lab | grep -o '"dnssecStatus":"[^"]*"')
[[ "$st" == *Signed* ]] && ok "DNSSEC signs the zone ($st)" || bad "the zone isn't signed: '$st'"
keys=$(api zones/dnssec/properties/get --data-urlencode zone=test.lab | grep -o '"keyType":"[A-Za-z]*"' | sort -u | tr '\n' ' ')
[[ "$keys" == *KeySigningKey* && "$keys" == *ZoneSigningKey* ]] && ok "it has a KSK and a ZSK" || bad "DNSSEC keys: $keys"
rr=$(api zones/records/get --data-urlencode domain=test.lab --data-urlencode zone=test.lab --data-urlencode listZone=true | grep -o '"type":"DNSKEY"' | head -1)
[ -n "$rr" ] && ok "the zone serves DNSKEY records" || bad "no DNSKEY records in the zone"
PURGE_DATA=true ./technitium_dns_installer.sh uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
systemctl is-active --quiet dns && bad "the service is still running" || ok "the service is gone"
[ "$(cat /etc/resolv.conf)" = "$before" ] && ok "resolv.conf is as it was" || bad "resolv.conf differs from before: $(grep nameserver /etc/resolv.conf | head -2 | tr '\n' ' ')"
[ "$(systemctl is-active systemd-resolved 2>/dev/null)" = "$resolved_before" ] && ok "systemd-resolved is $resolved_before again" || bad "systemd-resolved is $(systemctl is-active systemd-resolved 2>/dev/null), was $resolved_before"
within 30 outside && ok "the host resolves outside names again" || bad "the host can't resolve github.com after uninstall"
echo "=== exit $fail"; exit $fail
