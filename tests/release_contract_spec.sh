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

# Read the workflow as YAML so comments and step placement cannot satisfy the checks.
command -v ruby >/dev/null || fail "ruby is required to parse the release workflow"
check_workflow() {
  ruby -ryaml - "$1" <<'RUBY'
workflow = YAML.safe_load(File.read(ARGV.fetch(0)))
errors = []

global = workflow["permissions"]
unless global.is_a?(Hash) && global["contents"] == "read" &&
       global.values.all? { |value| %w[read none].include?(value) }
  errors << "workflow-wide permissions are not read-only"
end

jobs = workflow.fetch("jobs")
jobs.each do |name, job|
  writes = (job["permissions"] || {}).select { |_, value| value == "write" }.keys
  expected = name == "release" ? ["contents"] : []
  errors << "job #{name} has write permissions #{writes.inspect}" unless writes == expected
end

jobs.each do |name, job|
  (job["steps"] || []).each do |step|
    next unless step["uses"].to_s.start_with?("actions/checkout@")
    unless (step["with"] || {})["persist-credentials"] == false
      errors << "checkout in job #{name} persists credentials"
    end
  end
end

cross_runs = (jobs.dig("build", "steps") || []).map { |step| step["run"].to_s }
  .select { |run| run.match?(/^\s*cross build\b/) }
unless cross_runs.size == 1 &&
       cross_runs.first.include?("cross build --locked --release --manifest-path rust/Cargo.toml --target")
  errors << "cross build does not use the locked workspace manifest"
end

abort errors.join("\n") unless errors.empty?
RUBY
}

check_workflow "$WORKFLOW" || fail "release workflow violates its safety contract"

reject_workflow() {
  local description="$1"
  local mutation="$2"
  local mutated="${TEST_DIR}/release.yaml"
  perl -0pe "$mutation" "$WORKFLOW" > "$mutated"
  if cmp -s "$WORKFLOW" "$mutated"; then
    fail "workflow mutation did not apply: ${description}"
  fi
  if check_workflow "$mutated" >/dev/null 2>&1; then
    fail "$description"
  fi
}

# The mutations are Perl substitutions, so their capture references stay unexpanded.
# shellcheck disable=SC2016
reject_workflow "a workflow-wide write permission was accepted" \
  's/^permissions:\n  contents: read\n/permissions:\n  contents: write\n/m'
reject_workflow "a release job without its write permission was accepted" \
  's/^    permissions:\n      contents: write\n//m'
# shellcheck disable=SC2016
reject_workflow "a write permission outside the release job was accepted" \
  's/^(  build:\n)/$1    permissions:\n      contents: write\n/m'
reject_workflow "a commented-out persist-credentials setting was accepted" \
  's/^          persist-credentials: false\n          fetch-depth: 0\n/          # persist-credentials: false\n          fetch-depth: 0\n/m'
# shellcheck disable=SC2016
reject_workflow "persist-credentials on a non-checkout step was accepted" \
  's/^(      - name: Checkout\n        uses: actions\/checkout@.*\n        with:\n)          persist-credentials: false\n(      - name: Download native)/$1          fetch-depth: 1\n$2/m; s/^(          name: i18n-status-core-linux-x86_64\n)/$1          persist-credentials: false\n/m'
# shellcheck disable=SC2016
reject_workflow "a cross build without the locked workspace manifest was accepted" \
  's/^(        # With --manifest-path.*\n        run: cross build) --locked/$1/m'

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
