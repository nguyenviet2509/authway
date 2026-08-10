#!/usr/bin/env bash
# Set/get/delete Zitadel user metadata. Enforces snake_case key convention.
# Usage:
#   ./set-user-metadata.sh set    <user_id> <key> <value>
#   ./set-user-metadata.sh get    <user_id> [key]
#   ./set-user-metadata.sh delete <user_id> <key>
#   ./set-user-metadata.sh bulk   <user_id> key1=val1 key2=val2 ...
#
# Env (load from infra/auth-vps/.env):
#   ZITADEL_PAT  — Personal Access Token of metadata-bot machine user
#   ZITADEL_API  — base URL, e.g. https://auth.lab.local

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

: "${ZITADEL_PAT:?ZITADEL_PAT not set — see docs/zitadel-metadata-convention.md}"
: "${ZITADEL_API:?ZITADEL_API not set — e.g. https://auth.lab.local}"

# Lab self-signed cert — skip TLS verify. Remove -k in prod.
CURL_OPTS=(-sS -k -H "Authorization: Bearer ${ZITADEL_PAT}" -H "Content-Type: application/json")

validate_key() {
  local key="$1"
  if [[ ! "$key" =~ ^[a-z][a-z0-9_]{0,63}$ ]]; then
    echo "ERROR: key '$key' must be snake_case, start with letter, max 64 chars" >&2
    exit 2
  fi
}

cmd_set() {
  local user_id="$1" key="$2" value="$3"
  validate_key "$key"
  local b64
  b64=$(printf '%s' "$value" | base64 -w0 2>/dev/null || printf '%s' "$value" | base64)
  curl "${CURL_OPTS[@]}" -X POST \
    "${ZITADEL_API}/management/v1/users/${user_id}/metadata/${key}" \
    -d "{\"value\":\"${b64}\"}" | jq .
}

cmd_get() {
  local user_id="$1" key="${2:-}"
  if [[ -n "$key" ]]; then
    validate_key "$key"
    curl "${CURL_OPTS[@]}" \
      "${ZITADEL_API}/management/v1/users/${user_id}/metadata/${key}" \
      | jq '.metadata | {key, value: (.value | @base64d), changeDate}'
  else
    curl "${CURL_OPTS[@]}" -X POST \
      "${ZITADEL_API}/management/v1/users/${user_id}/metadata/_search" \
      -d '{}' \
      | jq '.result[] | {key, value: (.value | @base64d), changeDate}'
  fi
}

cmd_delete() {
  local user_id="$1" key="$2"
  validate_key "$key"
  curl "${CURL_OPTS[@]}" -X DELETE \
    "${ZITADEL_API}/management/v1/users/${user_id}/metadata/${key}" | jq .
}

cmd_bulk() {
  local user_id="$1"; shift
  local metadata_json="["
  local first=1
  for kv in "$@"; do
    local key="${kv%%=*}" value="${kv#*=}"
    validate_key "$key"
    local b64
    b64=$(printf '%s' "$value" | base64 -w0 2>/dev/null || printf '%s' "$value" | base64)
    [[ $first -eq 0 ]] && metadata_json+=","
    metadata_json+="{\"key\":\"${key}\",\"value\":\"${b64}\"}"
    first=0
  done
  metadata_json+="]"
  curl "${CURL_OPTS[@]}" -X POST \
    "${ZITADEL_API}/management/v1/users/${user_id}/metadata/_bulk" \
    -d "{\"metadata\":${metadata_json}}" | jq .
}

case "${1:-}" in
  set)    shift; cmd_set    "$@" ;;
  get)    shift; cmd_get    "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  bulk)   shift; cmd_bulk   "$@" ;;
  *)
    sed -n '2,9p' "$0"
    exit 1
    ;;
esac
