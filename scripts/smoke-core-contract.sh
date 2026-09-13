#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 CORE_BINARY CONTRACT_MANIFEST" >&2
  exit 2
fi

BINARY="$1"
MANIFEST="$2"
TEMP_DIR="$(mktemp -d)"
REQUEST_FILE="${TEMP_DIR}/request.jsonl"
RESPONSE_FILE="${TEMP_DIR}/response.jsonl"
STDERR_FILE="${TEMP_DIR}/stderr.log"
RUNTIME_UNAVAILABLE_EXIT=75
# Each attempt waits 0.1s. Callers that drive this directly can shorten the
# wait; the installer always pins it so an inherited value cannot make a good
# binary look unresponsive.
POLL_ATTEMPTS="${I18N_STATUS_SMOKE_POLL_ATTEMPTS:-50}"
if [[ ! "$POLL_ATTEMPTS" =~ ^[1-9][0-9]?[0-9]?$ ]]; then
  echo "I18N_STATUS_SMOKE_POLL_ATTEMPTS must be an integer between 1 and 999." >&2
  exit 2
fi

cleanup() {
  if [ -n "${core_pid:-}" ] && kill -0 "$core_pid" >/dev/null 2>&1; then
    kill "$core_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

string_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*$/\1/p" "$MANIFEST"
}

number_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*$/\1/p" "$MANIFEST"
}

client_name="$(string_field client_name)"
core_name="$(string_field core_name)"
version="$(string_field version)"
protocol_version="$(number_field protocol_version)"

if [[ ! "$client_name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || [[ ! "$core_name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || [[ ! "$version" =~ ^[A-Za-z0-9.+-]+$ ]] \
  || [[ ! "$protocol_version" =~ ^[0-9]+$ ]]; then
  echo "Core contract manifest contains an unsupported identity value." >&2
  exit 1
fi

expected_response="$(printf \
  '{"jsonrpc":"2.0","id":1,"result":{"core":{"name":"%s","version":"%s"},"protocol_version":%s}}' \
  "$core_name" "$version" "$protocol_version")"

printf '%s\n%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"client\":{\"name\":\"${client_name}\",\"version\":\"${version}\"},\"protocol_version\":${protocol_version}}}" \
  '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}' > "$REQUEST_FILE"
: > "$RESPONSE_FILE"
: > "$STDERR_FILE"

# Keep loader diagnostics stable so ABI failures can be distinguished from crashes.
LC_ALL=C "$BINARY" < "$REQUEST_FILE" > "$RESPONSE_FILE" 2> "$STDERR_FILE" &
core_pid="$!"
response=""
response_ready=0
for _attempt in $(seq 1 "$POLL_ATTEMPTS"); do
  if IFS= read -r response < "$RESPONSE_FILE"; then
    response_ready=1
    break
  fi
  response=""
  if ! kill -0 "$core_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if [ "$response_ready" -ne 1 ]; then
  response="$(head -n 1 "$RESPONSE_FILE")"
fi
if [ "$response_ready" -ne 1 ] && [ -n "$response" ]; then
  if kill -0 "$core_pid" >/dev/null 2>&1; then
    kill "$core_pid" >/dev/null 2>&1 || true
  fi
  wait "$core_pid" >/dev/null 2>&1 || true
  core_pid=""
  echo "Core contract smoke response is not a complete JSON-RPC line: ${response}" >&2
  exit 1
fi
if [ "$response_ready" -ne 1 ]; then
  if kill -0 "$core_pid" >/dev/null 2>&1; then
    kill "$core_pid" >/dev/null 2>&1 || true
    wait "$core_pid" >/dev/null 2>&1 || true
    core_pid=""
    echo "Core contract smoke test timed out before its initialize response." >&2
    command cat "$STDERR_FILE" >&2
    exit 1
  fi
  exec_status=0
  wait "$core_pid" >/dev/null 2>&1 || exec_status="$?"
  core_pid=""
  # glibc also exits with 1 before entering main when a symbol version is
  # unavailable. Do not classify other status-1 failures as ABI problems.
  if [ "$exec_status" -eq 1 ] \
    && grep -Eq ': version .GLIBC_[0-9.]+. not found' "$STDERR_FILE"; then
    echo "Core contract smoke test requires a newer glibc than this host provides:" >&2
    command cat "$STDERR_FILE" >&2
    exit "$RUNTIME_UNAVAILABLE_EXIT"
  fi
  # 126/127 are the shell's "cannot execute" codes.
  case "$exec_status" in
    126|127)
      echo "Core contract smoke test could not execute the core on this host:" >&2
      command cat "$STDERR_FILE" >&2
      exit "$RUNTIME_UNAVAILABLE_EXIT"
      ;;
  esac
  echo "Core contract smoke test exited before its initialize response (status ${exec_status}):" >&2
  command cat "$STDERR_FILE" >&2
  exit 1
fi
if [ "$response" != "$expected_response" ]; then
  if kill -0 "$core_pid" >/dev/null 2>&1; then
    kill "$core_pid" >/dev/null 2>&1 || true
  fi
  wait "$core_pid" >/dev/null 2>&1 || true
  core_pid=""
  echo "Core contract smoke response does not exactly match the initialize contract: ${response}" >&2
  exit 1
fi

for _attempt in $(seq 1 "$POLL_ATTEMPTS"); do
  if ! kill -0 "$core_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if kill -0 "$core_pid" >/dev/null 2>&1; then
  kill "$core_pid" >/dev/null 2>&1 || true
  wait "$core_pid" >/dev/null 2>&1 || true
  core_pid=""
  echo "Core contract smoke test timed out after its initialize response." >&2
  command cat "$STDERR_FILE" >&2
  exit 1
fi

wait_status=0
wait "$core_pid" || wait_status="$?"
core_pid=""
if [ "$wait_status" -ne 0 ]; then
  echo "Core contract smoke test exited unsuccessfully after its handshake:" >&2
  command cat "$STDERR_FILE" >&2
  exit 1
fi

echo "Core contract smoke test passed: ${core_name} ${version}, protocol ${protocol_version}"
