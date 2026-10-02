#!/usr/bin/env bash

set -euo pipefail

REPO="mhiro2/i18n-status.nvim"
BINARY_NAME="i18n-status-core"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="${PLUGIN_DIR}/bin"
CONTRACT_MANIFEST="${PLUGIN_DIR}/core-contract.json"
CONTRACT_TOOL="${SCRIPT_DIR}/core-contract.sh"
SMOKE_TOOL="${SCRIPT_DIR}/smoke-core-contract.sh"
# Pinned so an inherited override cannot reject a healthy core.
SMOKE_POLL_ATTEMPTS=50
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

bash "$CONTRACT_TOOL" --verify >/dev/null
CORE_VERSION="$(bash "$CONTRACT_TOOL" --field version)"
# The checkout names the core release it needs. "latest" is never consulted, so
# a plugin revision can only ever receive the core it was written against.
RELEASE_TAG="v${CORE_VERSION}"

build_from_source() {
  local host_target
  local built_binary
  local executable_name="$BINARY_NAME"
  # Keep build products off a potentially noexec temporary filesystem.
  local cargo_target_dir="${PLUGIN_DIR}/rust/target/i18n-status-installer"

  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
    echo "cargo and rustc are required to build the core for this platform." >&2
    exit 1
  fi

  host_target="$(rustc -vV | awk '/^host: / { print $2 }')"
  if [ -z "$host_target" ]; then
    echo "Unable to determine the host target triple." >&2
    exit 1
  fi
  case "$host_target" in
    *-windows-*) executable_name="${BINARY_NAME}.exe" ;;
  esac

  echo "Building ${BINARY_NAME} ${CORE_VERSION} from this checkout..."
  CARGO_TARGET_DIR="$cargo_target_dir" cargo build \
    --locked \
    --release \
    --manifest-path "${PLUGIN_DIR}/rust/Cargo.toml" \
    --target "$host_target"
  built_binary="${cargo_target_dir}/${host_target}/release/${executable_name}"
  if [ ! -f "$built_binary" ] || [ -L "$built_binary" ]; then
    echo "Cargo did not produce the expected regular executable: $built_binary" >&2
    exit 1
  fi

  I18N_STATUS_SMOKE_POLL_ATTEMPTS="$SMOKE_POLL_ATTEMPTS" \
    bash "$SMOKE_TOOL" "$built_binary" "$CONTRACT_MANIFEST"

  mkdir -p "$INSTALL_DIR"
  install -m 755 "$built_binary" "${INSTALL_DIR}/${executable_name}"
  echo "Installed ${BINARY_NAME} ${CORE_VERSION} to ${INSTALL_DIR}/${executable_name}"
}

release_platform() {
  local os
  local arch
  local os_tag
  local arch_tag

  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      if { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; } \
        || compgen -G '/lib/ld-musl-*.so.1' >/dev/null; then
        return 1
      fi
      os_tag="linux"
      ;;
    Darwin) os_tag="macos" ;;
    *) return 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch_tag="x86_64" ;;
    aarch64|arm64) arch_tag="aarch64" ;;
    *) return 1 ;;
  esac
  printf '%s-%s\n' "$os_tag" "$arch_tag"
}

# Prints the HTTP status, or nothing when the transfer itself failed.
fetch() {
  local url="$1"
  local output="$2"
  local status
  local curl_status=0

  status="$(curl -sSL --retry 2 --retry-all-errors -o "$output" -w '%{http_code}' "$url" 2>/dev/null)" \
    || curl_status="$?"
  [ "$curl_status" -eq 0 ] || return 0
  printf '%s' "$status"
}

validate_archive() {
  local archive="$1"
  local artifact="$2"
  local names
  local type

  names="$(tar tzf "$archive")"
  if [ "$names" != "$(printf '%s\n%s' "$artifact" "core-contract.json")" ] \
    && [ "$names" != "$(printf '%s\n%s' "core-contract.json" "$artifact")" ]; then
    echo "Release archive must contain only ${artifact} and core-contract.json." >&2
    return 1
  fi

  local listing
  listing="$(tar tvzf "$archive")" || return 1
  while IFS= read -r type; do
    case "$type" in
      -*) ;;
      *)
        echo "Release archive contains a non-regular member." >&2
        return 1
        ;;
    esac
  done <<< "$(printf '%s\n' "$listing" | awk '{ print substr($1, 1, 1) }')"
}

download_release() {
  local platform="$1"
  local artifact="${BINARY_NAME}-${platform}"
  local download_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${artifact}.tar.gz"
  local checksum_url="${download_url}.sha256"
  local archive="${TEMP_DIR}/${artifact}.tar.gz"
  local checksum="${archive}.sha256"
  local extract_dir="${TEMP_DIR}/extract"
  local actual_sha
  local expected_sha
  local smoke_status
  local status

  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "curl or tar is unavailable; building from source instead." >&2
    build_from_source
    return
  fi
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "A SHA256 tool is unavailable; building from source instead." >&2
    build_from_source
    return
  fi

  echo "Downloading ${BINARY_NAME} ${CORE_VERSION} (${platform})..."
  # Only a missing release means "build it yourself". A network or server
  # problem must not quietly turn into a source build on an unprepared host.
  status="$(fetch "$download_url" "$archive")"
  case "$status" in
    200)
      ;;
    404)
      echo "Release ${RELEASE_TAG} is not published yet; building from source instead." >&2
      build_from_source
      return
      ;;
    *)
      echo "Could not download ${artifact} (HTTP ${status:-none}). Retry once the network or GitHub recovers." >&2
      exit 1
      ;;
  esac
  status="$(fetch "$checksum_url" "$checksum")"
  if [ "$status" != "200" ]; then
    echo "Release ${RELEASE_TAG} has no usable checksum for ${artifact} (HTTP ${status:-none})." >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
  else
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  expected_sha="$(awk 'NR == 1 { print $1 }' "$checksum")"
  if [ -z "$expected_sha" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo "Checksum verification failed for ${artifact}." >&2
    exit 1
  fi

  validate_archive "$archive" "$artifact"
  mkdir -p "$extract_dir"
  tar xzf "$archive" -C "$extract_dir"
  if [ ! -f "${extract_dir}/${artifact}" ] || [ -L "${extract_dir}/${artifact}" ] \
    || [ ! -f "${extract_dir}/core-contract.json" ] || [ -L "${extract_dir}/core-contract.json" ]; then
    echo "Release archive did not extract to regular contract files." >&2
    exit 1
  fi
  if ! cmp -s "$CONTRACT_MANIFEST" "${extract_dir}/core-contract.json"; then
    echo "Release ${RELEASE_TAG} was published with a different core contract." >&2
    exit 1
  fi
  chmod +x "${extract_dir}/${artifact}"
  if I18N_STATUS_SMOKE_POLL_ATTEMPTS="$SMOKE_POLL_ATTEMPTS" \
    bash "$SMOKE_TOOL" "${extract_dir}/${artifact}" "${extract_dir}/core-contract.json"; then
    smoke_status=0
  else
    smoke_status="$?"
  fi
  if [ "$smoke_status" -eq 75 ]; then
    echo "Release binary cannot run on this host; building from source instead." >&2
    build_from_source
    return
  fi
  if [ "$smoke_status" -ne 0 ]; then
    exit "$smoke_status"
  fi

  mkdir -p "$INSTALL_DIR"
  install -m 755 "${extract_dir}/${artifact}" "${INSTALL_DIR}/${BINARY_NAME}"
  echo "Installed ${BINARY_NAME} ${CORE_VERSION} to ${INSTALL_DIR}/${BINARY_NAME}"
}

PLATFORM="$(release_platform || true)"
if [ -n "$PLATFORM" ]; then
  download_release "$PLATFORM"
  exit 0
fi

echo "No release artifact is published for this platform; building from source." >&2
build_from_source
