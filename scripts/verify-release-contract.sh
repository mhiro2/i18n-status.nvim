#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONTRACT_TOOL="${SCRIPT_DIR}/core-contract.sh"
RELEASE_TAG="${1:-}"

# --verify already cross-checks Cargo.toml and the Rust constants.
summary="$(bash "$CONTRACT_TOOL" --verify)"
manifest_version="$(bash "$CONTRACT_TOOL" --field version)"
core_tag="v${manifest_version}"
publish_core=true

if [ -n "$RELEASE_TAG" ] && [ "$RELEASE_TAG" != "$core_tag" ]; then
  # A Lua-only release reuses the existing core instead of publishing another
  # binary under a tag the installer will never request.
  if ! git -C "$ROOT_DIR" rev-parse --verify "refs/tags/${core_tag}^{commit}" >/dev/null 2>&1; then
    echo "Pinned core tag ${core_tag} is missing; fetch tags before verifying the release." >&2
    exit 1
  fi
  if ! git -C "$ROOT_DIR" diff --quiet "refs/tags/${core_tag}" HEAD -- core-contract.json rust; then
    echo "Core sources changed since ${core_tag}; bump the core contract and Cargo version to ${RELEASE_TAG#v}." >&2
    exit 1
  fi
  published_draft="$(gh release view "$core_tag" \
    --repo "${GITHUB_REPOSITORY:-mhiro2/i18n-status.nvim}" --json isDraft --jq '.isDraft')"
  if [ "$published_draft" != false ]; then
    echo "Pinned core release ${core_tag} must be published before ${RELEASE_TAG}." >&2
    exit 1
  fi
  publish_core=false
fi

grep -Fq 'core-contract.json' "${ROOT_DIR}/lua/i18n-status/core_contract.lua" \
  || { echo "Lua client does not load core-contract.json." >&2; exit 1; }
grep -Fq 'manifest.protocol_version' "${ROOT_DIR}/lua/i18n-status/core_contract.lua" \
  || { echo "Lua client does not consume the contract protocol version." >&2; exit 1; }

printf 'Release contract verified: %s\n' "$summary"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'publish_core=%s\n' "$publish_core" >> "$GITHUB_OUTPUT"
fi
