#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="$(bash "${ROOT_DIR}/scripts/core-contract.sh" --field version)"
TEST_DIR="$(mktemp -d)"
WORKFLOW="${ROOT_DIR}/.github/workflows/release.yaml"

cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "release contract test failed: $1" >&2
  exit 1
}

bash "${ROOT_DIR}/scripts/verify-release-contract.sh" "v${VERSION}" >/dev/null

global_permissions="$(sed -n '/^permissions:/,/^jobs:/p' "$WORKFLOW")"
if ! printf '%s\n' "$global_permissions" | grep -Fq 'contents: read' \
  || printf '%s\n' "$global_permissions" | grep -Fq 'contents: write'; then
  fail "workflow-wide contents permission is not read-only"
fi
release_job="$(sed -n '/^  release:/,$p' "$WORKFLOW")"
if ! printf '%s\n' "$release_job" | grep -Fq 'contents: write'; then
  fail "release job lacks its scoped write permission"
fi
checkout_count="$(grep -c 'uses: actions/checkout@' "$WORKFLOW")"
nonpersisting_checkout_count="$(grep -c 'persist-credentials: false' "$WORKFLOW")"
if [ "$checkout_count" -ne "$nonpersisting_checkout_count" ]; then
  fail "a checkout persists write-capable credentials"
fi

cross_step="$(sed -n '/      - name: Build (cross)/,/      - name: Package binary/p' "$WORKFLOW")"
if ! printf '%s\n' "$cross_step" \
  | grep -Fq 'cross build --locked --release --manifest-path rust/Cargo.toml --target'; then
  fail "cross build does not use the locked workspace manifest"
fi

# Every duplicate of a contract value has to drift-check against the manifest.
fixture="${TEST_DIR}/plugin[contract]&"
mkdir -p "${fixture}/scripts" "${fixture}/rust/src"
cp "${ROOT_DIR}/core-contract.json" "${fixture}/core-contract.json"
cp "${ROOT_DIR}/scripts/core-contract.sh" "${fixture}/scripts/core-contract.sh"
cp "${ROOT_DIR}/rust/Cargo.toml" "${fixture}/rust/Cargo.toml"
cp "${ROOT_DIR}/rust/src/contract.rs" "${fixture}/rust/src/contract.rs"
bash "${fixture}/scripts/core-contract.sh" --verify >/dev/null

reject_drift() {
  local description="$1"
  if bash "${fixture}/scripts/core-contract.sh" --verify >/dev/null 2>&1; then
    fail "$description"
  fi
}

sed -i.bak "s/^version = \"${VERSION}\"$/version = \"9.9.9\"/" "${fixture}/rust/Cargo.toml"
reject_drift "a Cargo version drifting from the contract was accepted"
cp "${ROOT_DIR}/rust/Cargo.toml" "${fixture}/rust/Cargo.toml"

sed -i.bak 's/^pub const PROTOCOL_VERSION: u32 = .*$/pub const PROTOCOL_VERSION: u32 = 99;/' \
  "${fixture}/rust/src/contract.rs"
reject_drift "a Rust protocol version drifting from the contract was accepted"
cp "${ROOT_DIR}/rust/src/contract.rs" "${fixture}/rust/src/contract.rs"

sed -i.bak 's/^pub const CLIENT_NAME: &str = .*$/pub const CLIENT_NAME: \&str = "other.nvim";/' \
  "${fixture}/rust/src/contract.rs"
reject_drift "a Rust client name drifting from the contract was accepted"
cp "${ROOT_DIR}/rust/src/contract.rs" "${fixture}/rust/src/contract.rs"

bash "${fixture}/scripts/core-contract.sh" --verify >/dev/null

# A manifest the Lua client cannot decode must never reach a release.
reject_manifest() {
  local description="$1"
  local manifest="$2"
  printf '%s' "$manifest" > "${fixture}/core-contract.json"
  if bash "${fixture}/scripts/core-contract.sh" --verify >/dev/null 2>&1; then
    fail "$description"
  fi
}

reject_manifest "a manifest missing its field separators was accepted" '{
  "schema_version": 1
  "client_name": "i18n-status.nvim"
  "core_name": "i18n-status-core"
  "version": "'"${VERSION}"'"
  "protocol_version": 1,
}
'
reject_manifest "a manifest with a trailing comma was accepted" '{
  "schema_version": 1,
  "client_name": "i18n-status.nvim",
  "core_name": "i18n-status-core",
  "version": "'"${VERSION}"'",
  "protocol_version": 1,
}
'
reject_manifest "a manifest with reordered fields was accepted" '{
  "client_name": "i18n-status.nvim",
  "schema_version": 1,
  "core_name": "i18n-status-core",
  "version": "'"${VERSION}"'",
  "protocol_version": 1
}
'
reject_manifest "a manifest with an extra field was accepted" '{
  "schema_version": 1,
  "client_name": "i18n-status.nvim",
  "core_name": "i18n-status-core",
  "version": "'"${VERSION}"'",
  "protocol_version": 1,
  "build_id": "x"
}
'
reject_manifest "a manifest with trailing content was accepted" '{
  "schema_version": 1,
  "client_name": "i18n-status.nvim",
  "core_name": "i18n-status-core",
  "version": "'"${VERSION}"'",
  "protocol_version": 1
}
{
'
reject_manifest "a fractional protocol version was accepted" '{
  "schema_version": 1,
  "client_name": "i18n-status.nvim",
  "core_name": "i18n-status-core",
  "version": "'"${VERSION}"'",
  "protocol_version": 1.5
}
'

cp "${ROOT_DIR}/core-contract.json" "${fixture}/core-contract.json"
bash "${fixture}/scripts/core-contract.sh" --verify >/dev/null

# Release tags may advance without a core bump only when reusing published,
# unchanged core sources. Keep these checks offline with a GitHub CLI stub.
release_fixture="${TEST_DIR}/release"
mock_bin="${TEST_DIR}/mock-bin"
release_output="${TEST_DIR}/release-output"
release_log="${TEST_DIR}/release-log"
mkdir -p "$release_fixture" "$mock_bin"
cp -R "${fixture}/scripts" "${fixture}/rust" "$release_fixture/"
cp "${ROOT_DIR}/core-contract.json" "$release_fixture/"
cp "${ROOT_DIR}/scripts/verify-release-contract.sh" "${release_fixture}/scripts/"
mkdir -p "${release_fixture}/lua/i18n-status"
cp "${ROOT_DIR}/lua/i18n-status/core_contract.lua" "${release_fixture}/lua/i18n-status/"
cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_RELEASE_LOG:?}"
case "${MOCK_RELEASE_STATE:-published}" in
  published) echo false ;;
  draft) echo true ;;
  missing) exit 1 ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "${mock_bin}/gh"
git -C "$release_fixture" init -q
git -C "$release_fixture" config user.email "release-test@example.com"
git -C "$release_fixture" config user.name "Release Test"
git -C "$release_fixture" add .
git -C "$release_fixture" commit -qm "core release"

verify_release() {
  : > "$release_output"
  : > "$release_log"
  PATH="${mock_bin}:${PATH}" GITHUB_OUTPUT="$release_output" \
    MOCK_RELEASE_LOG="$release_log" \
    bash "${release_fixture}/scripts/verify-release-contract.sh" "$1"
}

verify_release "v${VERSION}" >/dev/null
grep -Fxq 'publish_core=true' "$release_output" || fail "new core artifacts were skipped"
[ ! -s "$release_log" ] || fail "new core release required an existing GitHub release"

if verify_release v9.9.9 >/dev/null 2>&1; then
  fail "a missing pinned core tag was accepted"
fi
git -C "$release_fixture" tag "v${VERSION}"
printf '\n-- Lua-only release change.\n' >> "${release_fixture}/lua/i18n-status/core_contract.lua"
git -C "$release_fixture" add .
git -C "$release_fixture" commit -qm "Lua-only release"
verify_release v9.9.9 >/dev/null
grep -Fxq 'publish_core=false' "$release_output" || fail "Lua-only release rebuilt the core"
grep -Fq "release view v${VERSION} --repo" "$release_log" || fail "pinned core publication was not checked"

for state in draft missing; do
  if MOCK_RELEASE_STATE="$state" verify_release v9.9.9 >/dev/null 2>&1; then
    fail "a ${state} pinned core release was accepted"
  fi
done

printf '\n// Changed core implementation.\n' >> "${release_fixture}/rust/src/contract.rs"
git -C "$release_fixture" add .
git -C "$release_fixture" commit -qm "core change without version bump"
if verify_release v9.9.9 >/dev/null 2>&1; then
  fail "changed core sources were allowed to reuse an old release"
fi

echo "release contract tests passed"
