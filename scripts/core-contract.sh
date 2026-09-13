#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="${ROOT_DIR}/core-contract.json"
CARGO_MANIFEST="${ROOT_DIR}/rust/Cargo.toml"
RUST_CONTRACT="${ROOT_DIR}/rust/src/contract.rs"

usage() {
  echo "Usage: $0 --verify | --field FIELD" >&2
  exit 2
}

# The manifest is a fixed, hand-maintained shape, so each field is matched
# anchored to the end of its line. A loose match would let "1.5" read back as
# "1" here while the Rust core rejects it at runtime.
manifest_string_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\",\{0,1\}[[:space:]]*$/\1/p" "$MANIFEST"
}

manifest_number_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\),\{0,1\}[[:space:]]*$/\1/p" "$MANIFEST"
}

manifest_field() {
  local field="$1"
  case "$field" in
    schema_version|protocol_version) manifest_number_field "$field" ;;
    client_name|core_name|version) manifest_string_field "$field" ;;
    *) echo "Unknown contract field: $field" >&2; exit 2 ;;
  esac
}

cargo_package_field() {
  local field="$1"
  awk -v field="$field" '
    /^\[package\]$/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && $1 == field && $2 == "=" {
      gsub(/^"|"$/, "", $3)
      print $3
      exit
    }
  ' "$CARGO_MANIFEST"
}

rust_string_constant() {
  local name="$1"
  sed -n "s/^pub const ${name}: &str = \"\([^\"]*\)\";$/\1/p" "$RUST_CONTRACT"
}

rust_u32_constant() {
  local name="$1"
  sed -n "s/^pub const ${name}: u32 = \([0-9][0-9]*\);$/\1/p" "$RUST_CONTRACT"
}

# The manifest is the single authority. Every other copy of an identity value
# has to agree with it, because a release artifact is selected by that version
# alone and the startup handshake compares the values byte for byte.
verify_contract() {
  local client_name
  local core_name
  local version
  local protocol_version
  local actual

  [ -f "$MANIFEST" ] || {
    echo "Missing core contract manifest: $MANIFEST" >&2
    exit 1
  }

  # The manifest is one canonical object: "{", one line per field in a fixed
  # order with a separating comma on all but the last, then "}". Verifying the
  # shape keeps a manifest the Lua client cannot decode out of a release.
  local expected_keys="schema_version client_name core_name version protocol_version"
  local field_count=5
  local line_number=0
  local field_index=0
  local closed=0
  local expected_key
  local key
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    if [ "$line_number" -eq 1 ]; then
      [ "$line" = "{" ] || {
        echo "Core contract manifest must start with a lone '{'." >&2
        exit 1
      }
      continue
    fi
    if [ "$field_index" -lt "$field_count" ]; then
      field_index=$((field_index + 1))
      expected_key="$(printf '%s\n' $expected_keys | sed -n "${field_index}p")"
      key="$(printf '%s' "$line" | sed -n 's/^  "\([a-z_]*\)": .*$/\1/p')"
      [ "$key" = "$expected_key" ] || {
        echo "Core contract manifest expected \"${expected_key}\" on line ${line_number}: ${line}" >&2
        exit 1
      }
      if [ "$field_index" -lt "$field_count" ]; then
        case "$line" in
          *,) ;;
          *) echo "Core contract manifest field ${key} must end with a comma." >&2; exit 1 ;;
        esac
      else
        case "$line" in
          *,) echo "Core contract manifest field ${key} must not end with a comma." >&2; exit 1 ;;
        esac
      fi
      continue
    fi
    if [ "$closed" -eq 0 ] && [ "$line" = "}" ]; then
      closed=1
      continue
    fi
    echo "Core contract manifest has unexpected content on line ${line_number}: ${line}" >&2
    exit 1
  done < "$MANIFEST"

  [ "$field_index" -eq "$field_count" ] && [ "$closed" -eq 1 ] || {
    echo "Core contract manifest is incomplete." >&2
    exit 1
  }

  for field in $expected_keys; do
    [ -n "$(manifest_field "$field")" ] || {
      echo "Core contract field is not a well-formed value: ${field}" >&2
      exit 1
    }
  done

  [ "$(manifest_field schema_version)" = "1" ] || {
    echo "Unsupported core contract schema." >&2
    exit 1
  }

  client_name="$(manifest_field client_name)"
  core_name="$(manifest_field core_name)"
  version="$(manifest_field version)"
  protocol_version="$(manifest_field protocol_version)"

  if [[ ! "$client_name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || [[ ! "$core_name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Core contract manifest contains an unsupported identity value." >&2
    exit 1
  fi

  actual="$(cargo_package_field name)"
  [ "$actual" = "$core_name" ] || {
    echo "Cargo package name ${actual} does not match contract ${core_name}." >&2
    exit 1
  }
  actual="$(cargo_package_field version)"
  [ "$actual" = "$version" ] || {
    echo "Cargo package version ${actual} does not match contract ${version}." >&2
    exit 1
  }
  actual="$(rust_string_constant CLIENT_NAME)"
  [ "$actual" = "$client_name" ] || {
    echo "Rust CLIENT_NAME ${actual} does not match contract ${client_name}." >&2
    exit 1
  }
  actual="$(rust_u32_constant PROTOCOL_VERSION)"
  [ "$actual" = "$protocol_version" ] || {
    echo "Rust PROTOCOL_VERSION ${actual} does not match contract ${protocol_version}." >&2
    exit 1
  }

  printf '%s %s, protocol %s\n' "$core_name" "$version" "$protocol_version"
}

case "${1:-}" in
  --verify)
    [ "$#" -eq 1 ] || usage
    verify_contract
    ;;
  --field)
    [ "$#" -eq 2 ] || usage
    manifest_field "$2"
    ;;
  *) usage ;;
esac
