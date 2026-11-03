#!/usr/bin/env bats
# What ap-tools relies on.
SCRIPT="$BATS_TEST_DIRNAME/../../technitium_dns_installer.sh"
@test "help lists the commands ap-tools calls" {
  run "$SCRIPT" help
  [ "$status" -eq 0 ]
  for c in install save uninstall; do [[ "$output" == *"$c"* ]]; done
}
@test "the sentinel and archive names stay the same" {
  grep -q 'technitium-save-version.txt' "$SCRIPT"
  grep -q 'technitium-save.tar.gz' "$SCRIPT"
}
@test "the settings ap-tools forwards are still read" {
  for v in ZONES_TEMPLATE ENABLE_HTTPS ENABLE_DNSSEC DISABLE_SYSTEMD_RESOLVED ENABLE_DHCP REMOVE_DOTNET PURGE_DATA; do
    grep -q "^$v=\${$v:-" "$SCRIPT"
  done
}
