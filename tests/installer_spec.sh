#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
MOCK_BIN="${TEST_DIR}/mock-bin"
MOCK_RESPONDER="${TEST_DIR}/mock-core-responder"
MOCK_CARGO_LOG="${TEST_DIR}/cargo.log"
MOCK_CURL_LOG="${TEST_DIR}/curl.log"
VERSION="$(bash "${ROOT_DIR}/scripts/core-contract.sh" --field version)"

cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "installer test failed: $*" >&2
  exit 1
}

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
}

make_fixture() {
  local destination="$1"
  mkdir -p "${destination}/scripts" "${destination}/rust"
  cp "${ROOT_DIR}/core-contract.json" "${destination}/core-contract.json"
  cp "${ROOT_DIR}/scripts/core-contract.sh" "${destination}/scripts/core-contract.sh"
  cp "${ROOT_DIR}/scripts/download-binary.sh" "${destination}/scripts/download-binary.sh"
  cp "${ROOT_DIR}/scripts/smoke-core-contract.sh" "${destination}/scripts/smoke-core-contract.sh"
  cp "${ROOT_DIR}/rust/Cargo.toml" "${destination}/rust/Cargo.toml"
  cp "${ROOT_DIR}/rust/Cargo.lock" "${destination}/rust/Cargo.lock"
  cp -R "${ROOT_DIR}/rust/src" "${destination}/rust/src"
  cp -R "${ROOT_DIR}/lua" "${destination}/lua"
}

initialize_repo() {
  local directory="$1"
  git -C "$directory" init -q
  git -C "$directory" config user.email "installer-test@example.com"
  git -C "$directory" config user.name "Installer Test"
  git -C "$directory" add .
  git -C "$directory" commit -qm "fixture"
}

run_installer() {
  local fixture="$1"
  local os="${2:-Linux}"
  local arch="${3:-x86_64}"
  local archive_mode="${4:-normal}"
  local rust_host="${5:-test-host}"
  : > "$MOCK_CARGO_LOG"
  : > "$MOCK_CURL_LOG"
  PATH="${MOCK_BIN}:${PATH}" \
    MOCK_ARCHIVE_MODE="$archive_mode" \
    MOCK_CARGO_LOG="$MOCK_CARGO_LOG" \
    MOCK_CURL_LOG="$MOCK_CURL_LOG" \
    MOCK_FIXTURE="$fixture" \
    MOCK_RESPONDER="$MOCK_RESPONDER" \
    MOCK_RUST_HOST="$rust_host" \
    MOCK_UNAME_M="$arch" \
    MOCK_UNAME_S="$os" \
    bash "${fixture}/scripts/download-binary.sh"
}

assert_no_sidecar() {
  local fixture="$1"
  if compgen -G "${fixture}/bin/*.contract.json" >/dev/null; then
    fail "${fixture} installed an unused contract sidecar"
  fi
}

assert_source_install() {
  local fixture="$1"
  local executable_name="${2:-i18n-status-core}"
  local rust_host="${3:-test-host}"
  local download_expected="${4:-no}"
  local fixture_realpath
  fixture_realpath="$(cd "$fixture" && pwd -P)"
  grep -Fq "built-from-checkout" "${fixture}/bin/${executable_name}" \
    || fail "${fixture} did not install its locally built core"
  assert_no_sidecar "$fixture"
  if [ "$download_expected" = yes ]; then
    [ -s "$MOCK_CURL_LOG" ] || fail "${fixture} did not attempt the expected release download"
  else
    [ ! -s "$MOCK_CURL_LOG" ] || fail "${fixture} attempted a network download"
  fi
  grep -Fq -- "--locked --release --manifest-path" "$MOCK_CARGO_LOG" \
    || fail "source build did not use the locked manifest"
  grep -Fq -- "--target ${rust_host}" "$MOCK_CARGO_LOG" \
    || fail "source build did not use an explicit host target"
  grep -Fq "target_dir=${fixture_realpath}/rust/target/i18n-status-installer" "$MOCK_CARGO_LOG" \
    || fail "source build did not use its controlled executable target directory"
  if grep -Fq "${TEST_DIR}/installer-target" "$MOCK_CARGO_LOG"; then
    fail "source build honored an unsafe inherited CARGO_TARGET_DIR"
  fi
}

assert_release_install() {
  local fixture="$1"
  grep -Fq '#!/usr/bin/env bash' "${fixture}/bin/i18n-status-core" \
    || fail "${fixture} did not install its release artifact"
  [ ! -s "$MOCK_CARGO_LOG" ] || fail "${fixture} built from source despite a usable release"
  grep -Fq "/releases/download/v${VERSION}/" "$MOCK_CURL_LOG" \
    || fail "${fixture} downloaded a release other than the contract version"
  assert_no_sidecar "$fixture"
}

mkdir -p "$MOCK_BIN"

# shellcheck disable=SC2016
write_executable "$MOCK_RESPONDER" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'manifest="${MOCK_FIXTURE:?}/core-contract.json"' \
  'name="$(sed -n '\''s/.*"core_name"[^\"]*"\([^\"]*\)".*/\1/p'\'' "$manifest")"' \
  'version="$(sed -n '\''s/.*"version"[^\"]*"\([^\"]*\)".*/\1/p'\'' "$manifest")"' \
  'protocol="$(sed -n '\''s/.*"protocol_version"[^0-9]*\([0-9]*\).*/\1/p'\'' "$manifest")"' \
  'IFS= read -r _request' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = hung-handshake ]; then sleep 30; exit 0; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = spoofed-handshake ]; then' \
  '  printf '\''{"jsonrpc":"2.0","id":1,"result":{"core":{"name":"wrong","version":"wrong"},"protocol_version":999},"name":"%s","protocol_version":%s,"version":"%s"}\n'\'' "$name" "$protocol" "$version"' \
  'else' \
  '  if [ "${MOCK_ARCHIVE_MODE:-normal}" = wrong-handshake ]; then version=9.9.9; fi' \
  '  printf '\''{"jsonrpc":"2.0","id":1,"result":{"core":{"name":"%s","version":"%s"},"protocol_version":%s}}\n'\'' "$name" "$version" "$protocol"' \
  'fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = wrong-handshake ]; then sleep 30; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = crash-after-handshake ]; then exit 3; fi' \
  'IFS= read -r _shutdown || true'

# shellcheck disable=SC2016
write_executable "${MOCK_BIN}/rustc" \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-vV" ]; then printf "rustc 1.95.0\nhost: %s\n" "${MOCK_RUST_HOST:?}"; else exit 1; fi'

# shellcheck disable=SC2016
write_executable "${MOCK_BIN}/cargo" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "target_dir=%s args=%s\n" "${CARGO_TARGET_DIR:?}" "$*" >> "${MOCK_CARGO_LOG:?}"' \
  '[ "$1" = "build" ]' \
  'target=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in --target) target="$2"; shift 2 ;; *) shift ;; esac' \
  'done' \
  '[ -n "$target" ]' \
  'executable=i18n-status-core' \
  'case "$target" in *-windows-*) executable=i18n-status-core.exe ;; esac' \
  'mkdir -p "${CARGO_TARGET_DIR}/${target}/release"' \
  'cp "${MOCK_RESPONDER:?}" "${CARGO_TARGET_DIR}/${target}/release/${executable}"' \
  'printf "# built-from-checkout\n" >> "${CARGO_TARGET_DIR}/${target}/release/${executable}"' \
  'chmod +x "${CARGO_TARGET_DIR}/${target}/release/${executable}"'

# shellcheck disable=SC2016
write_executable "${MOCK_BIN}/uname" \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in -s) printf "%s\n" "${MOCK_UNAME_S:?}" ;; -m) printf "%s\n" "${MOCK_UNAME_M:?}" ;; *) exit 1 ;; esac'

# shellcheck disable=SC2016
write_executable "${MOCK_BIN}/ldd" \
  '#!/usr/bin/env bash' \
  'if [ "${MOCK_MUSL:-0}" = 1 ]; then echo "musl libc"; else echo "GNU libc"; fi'

# shellcheck disable=SC2016
write_executable "${MOCK_BIN}/curl" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'url=""' \
  'output=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) output="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac' \
  'done' \
  'printf "%s\n" "$url" >> "${MOCK_CURL_LOG:?}"' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = missing-release ]; then printf 404; exit 0; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = server-error ]; then printf 503; exit 0; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = network-down ]; then exit 6; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = missing-checksum ] && [[ "$url" == *.sha256 ]]; then printf 404; exit 0; fi' \
  'if [[ "$url" == *.sha256 ]]; then' \
  '  archive="${output%.sha256}"' \
  '  if command -v sha256sum >/dev/null 2>&1; then digest="$(sha256sum "$archive")"; else digest="$(shasum -a 256 "$archive")"; fi' \
  '  digest="${digest%% *}"' \
  '  if [ "${MOCK_ARCHIVE_MODE:-normal}" = corrupt-download ]; then digest="${digest//a/b}"; fi' \
  '  printf "%s  %s\n" "$digest" "$(basename "$archive")" > "$output"' \
  '  printf 200' \
  '  exit 0' \
  'fi' \
  'artifact="$(basename "$url" .tar.gz)"' \
  'payload="${output}.payload"' \
  'mkdir -p "$payload"' \
  'cp "${MOCK_FIXTURE:?}/core-contract.json" "${payload}/core-contract.json"' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = mismatched-contract ]; then sed -i.bak "s/\"protocol_version\": [0-9]*/\"protocol_version\": 99/" "${payload}/core-contract.json"; rm -f "${payload}/core-contract.json.bak"; fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = symlink ]; then' \
  '  ln -s core-contract.json "${payload}/${artifact}"' \
  'elif [ "${MOCK_ARCHIVE_MODE:-normal}" = unspawnable ]; then' \
  '  printf "not a host executable\n" > "${payload}/${artifact}"' \
  '  chmod +x "${payload}/${artifact}"' \
  'elif [ "${MOCK_ARCHIVE_MODE:-normal}" = crash-before-handshake ]; then' \
  '  printf "#!/usr/bin/env bash\nexit 3\n" > "${payload}/${artifact}"' \
  '  chmod +x "${payload}/${artifact}"' \
  'elif [ "${MOCK_ARCHIVE_MODE:-normal}" = glibc-mismatch ]; then' \
  '  printf "#!/usr/bin/env bash\necho \"core: /lib/libc.so.6: version '\''GLIBC_2.39'\'' not found (required by core)\" >&2\nexit 1\n" > "${payload}/${artifact}"' \
  '  chmod +x "${payload}/${artifact}"' \
  'elif [ "${MOCK_ARCHIVE_MODE:-normal}" = startup-error ]; then' \
  '  printf "#!/usr/bin/env bash\necho \"core: initialization failed\" >&2\nexit 1\n" > "${payload}/${artifact}"' \
  '  chmod +x "${payload}/${artifact}"' \
  'else' \
  '  cp "${MOCK_RESPONDER:?}" "${payload}/${artifact}"' \
  '  chmod +x "${payload}/${artifact}"' \
  'fi' \
  'if [ "${MOCK_ARCHIVE_MODE:-normal}" = extra-member ]; then' \
  '  printf extra > "${payload}/extra"' \
  '  tar czf "$output" -C "$payload" "$artifact" core-contract.json extra' \
  'else' \
  '  tar czf "$output" -C "$payload" "$artifact" core-contract.json' \
  'fi' \
  'rm -rf -- "$payload"' \
  'printf 200'

# An ordinary lazy.nvim checkout tracks a branch and carries no tag. It still
# gets the core release its contract names, which is the whole point.
untagged_fixture="${TEST_DIR}/untagged"
make_fixture "$untagged_fixture"
initialize_repo "$untagged_fixture"
run_installer "$untagged_fixture"
assert_release_install "$untagged_fixture"

# A source archive has no git metadata at all, and is treated identically.
archive_fixture="${TEST_DIR}/source-archive"
make_fixture "$archive_fixture"
run_installer "$archive_fixture"
assert_release_install "$archive_fixture"

# A checkout whose contract names an unpublished core falls back to its source.
unreleased_fixture="${TEST_DIR}/unreleased-version"
make_fixture "$unreleased_fixture"
initialize_repo "$unreleased_fixture"
CARGO_TARGET_DIR="${TEST_DIR}/installer-target" \
  run_installer "$unreleased_fixture" Linux x86_64 missing-release
assert_source_install "$unreleased_fixture" i18n-status-core test-host yes

platform_fixture="${TEST_DIR}/unsupported-platform"
make_fixture "$platform_fixture"
CARGO_TARGET_DIR="${TEST_DIR}/installer-target" run_installer "$platform_fixture" Plan9 mystery
assert_source_install "$platform_fixture"

musl_fixture="${TEST_DIR}/musl"
make_fixture "$musl_fixture"
MOCK_MUSL=1 CARGO_TARGET_DIR="${TEST_DIR}/installer-target" run_installer "$musl_fixture"
assert_source_install "$musl_fixture"

windows_fixture="${TEST_DIR}/windows"
make_fixture "$windows_fixture"
CARGO_TARGET_DIR="${TEST_DIR}/installer-target" \
  run_installer "$windows_fixture" MINGW64_NT-10.0 x86_64 normal x86_64-pc-windows-gnu
assert_source_install "$windows_fixture" i18n-status-core.exe x86_64-pc-windows-gnu

# A release that cannot run here is a platform problem, not an integrity one.
unspawnable_fixture="${TEST_DIR}/unspawnable-release"
make_fixture "$unspawnable_fixture"
CARGO_TARGET_DIR="${TEST_DIR}/installer-target" \
  run_installer "$unspawnable_fixture" Linux x86_64 unspawnable
assert_source_install "$unspawnable_fixture" i18n-status-core test-host yes

# A glibc version failure exits with 1 before the core can initialize.
glibc_fixture="${TEST_DIR}/glibc-mismatch"
make_fixture "$glibc_fixture"
run_installer "$glibc_fixture" Linux x86_64 glibc-mismatch
assert_source_install "$glibc_fixture" i18n-status-core test-host yes

# Integrity failures never fall back; a tampered release must stop the install.
assert_hard_failure() {
  local fixture="$1"
  local mode="$2"
  local description="$3"
  make_fixture "$fixture"
  if run_installer "$fixture" Linux x86_64 "$mode"; then
    fail "$description"
  fi
  [ ! -s "$MOCK_CARGO_LOG" ] || fail "${description} (fell back to a source build)"
  [ ! -e "${fixture}/bin/i18n-status-core" ] || fail "${description} (installed anyway)"
}

assert_hard_failure "${TEST_DIR}/corrupt-download" corrupt-download \
  "a release failing its checksum was accepted"
assert_hard_failure "${TEST_DIR}/symlink-archive" symlink \
  "a symlink archive member was accepted"
assert_hard_failure "${TEST_DIR}/extra-member-archive" extra-member \
  "an archive with an unexpected member was accepted"
assert_hard_failure "${TEST_DIR}/mismatched-contract" mismatched-contract \
  "a release published with a different contract was accepted"
assert_hard_failure "${TEST_DIR}/wrong-handshake" wrong-handshake \
  "a release with a mismatched live handshake was accepted"
assert_hard_failure "${TEST_DIR}/spoofed-handshake" spoofed-handshake \
  "a release with identity strings outside the initialize result was accepted"
assert_hard_failure "${TEST_DIR}/hung-handshake" hung-handshake \
  "a release that never answered its handshake was accepted"
assert_hard_failure "${TEST_DIR}/crash-before-handshake" crash-before-handshake \
  "a release that died before its handshake was accepted"
assert_hard_failure "${TEST_DIR}/startup-error" startup-error \
  "a status-1 core error was treated as a glibc mismatch"
assert_hard_failure "${TEST_DIR}/crash-after-handshake" crash-after-handshake \
  "a release that crashed after its handshake was accepted"
assert_hard_failure "${TEST_DIR}/missing-checksum" missing-checksum \
  "a release published without its checksum was accepted"

# A reachable-but-broken network is not a reason to demand a Rust toolchain.
assert_hard_failure "${TEST_DIR}/server-error" server-error \
  "a server error was treated as a missing release"
assert_hard_failure "${TEST_DIR}/network-down" network-down \
  "an unreachable network was treated as a missing release"

echo "installer tests passed"
