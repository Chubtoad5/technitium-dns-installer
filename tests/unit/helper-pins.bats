#!/usr/bin/env bats
# Spec 12: save bundles install_packages.sh from an install-packages release, not main, and records which one.
load ../helpers

setup() {
  setup_stubs
  unset INSTALL_PACKAGES_REF INSTALL_PACKAGES_URL INSTALL_PACKAGES_SHA256
  load_script technitium_dns_installer.sh
  LOG_FILE=$BATS_TEST_TMPDIR/install.log
  U=$BATS_TEST_TMPDIR/bundle/utilities
  mkdir -p "$U"
  DEST=$U/install_packages.sh
  # A curl that writes a small script to its -o path
  stub curl 'out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
printf "#!/bin/bash\necho helper\n" > "$out"'
}
helper_sha() { printf '#!/bin/bash\necho helper\n' | sha256sum | cut -d' ' -f1; }
fetch() { fetch_helper "$DEST" "$INSTALL_PACKAGES_URL" "$INSTALL_PACKAGES_REF" "$INSTALL_PACKAGES_SHA256"; }

@test "the default is install-packages v1.1.2, by tag" {
  [ "$INSTALL_PACKAGES_REF" = v1.1.2 ]
  [ "$INSTALL_PACKAGES_URL" = "https://raw.githubusercontent.com/Chubtoad5/install-packages/v1.1.2/install_packages.sh" ]
}
@test "INSTALL_PACKAGES_REF sets the URL, and INSTALL_PACKAGES_URL still wins" {
  export INSTALL_PACKAGES_REF=v9.9.9
  unset INSTALL_PACKAGES_URL
  load_script technitium_dns_installer.sh
  [ "$INSTALL_PACKAGES_URL" = "https://raw.githubusercontent.com/Chubtoad5/install-packages/v9.9.9/install_packages.sh" ]
  export INSTALL_PACKAGES_URL=https://mirror.example/ip.sh
  load_script technitium_dns_installer.sh
  [ "$INSTALL_PACKAGES_URL" = https://mirror.example/ip.sh ]
}
@test "the helper is fetched from the URL, and the bundle records its ref" {
  run fetch
  [ "$status" -eq 0 ]
  called "https://raw.githubusercontent.com/Chubtoad5/install-packages/v1.1.2/install_packages.sh"
  [ -x "$DEST" ]
  [ "$(cat "$U/.install_packages.sh.ref")" = v1.1.2 ]
}
@test "a copy whose record names the same ref is reused, and another ref is fetched again" {
  fetch >/dev/null
  : > "$STUB_LOG"
  fetch >/dev/null
  ! called "curl" || false
  echo main > "$U/.install_packages.sh.ref"
  fetch >/dev/null
  called "curl"
}
@test "a matching checksum passes" {
  INSTALL_PACKAGES_SHA256=$(helper_sha)
  run fetch
  [ "$status" -eq 0 ]
}
@test "a checksum mismatch fails, and leaves no file behind" {
  INSTALL_PACKAGES_SHA256=$(printf '0%.0s' {1..64})
  run fetch
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match INSTALL_PACKAGES_SHA256"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$DEST.tmp" ]
}
@test "a failed download fails, and leaves no file behind" {
  stub curl 'exit 22'
  run fetch
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to download install_packages.sh"* ]]
  [ ! -e "$DEST" ]
}
@test "save uses the pinned fetch, and stops when it fails" {
  body=$(declare -f run_save)
  [[ "$body" == *'fetch_helper "$b/utilities/install_packages.sh" "$INSTALL_PACKAGES_URL" "$INSTALL_PACKAGES_REF" "$INSTALL_PACKAGES_SHA256" || exit 1'* ]]
}
@test "only save downloads install_packages.sh, so an offline install never does" {
  [ "$(grep -c 'INSTALL_PACKAGES_URL"' "$BATS_TEST_DIRNAME/../../technitium_dns_installer.sh")" -eq 1 ]
  ! grep -n 'install-packages/main/' "$BATS_TEST_DIRNAME/../../technitium_dns_installer.sh" || false
}
