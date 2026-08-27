#!/usr/bin/env bash
# Rotate HMAC secret used to sign X-Client-Cert-CN header between Traefik and central-rbac.
# Phase 06 Step 7 + Validation Session 1 Decision: docker secret + weekly rotate.
# Fix #3 (Critical): defends against CN header spoofing if backend is reachable off-Traefik.
#
# Flow:
#   1. Generate new secret (32 bytes hex)
#   2. Create new docker secret cert_hmac_v{N+1}
#   3. Update compose file to reference new secret (both traefik + central-rbac)
#   4. docker compose up -d (rolling restart, both services pick up new secret)
#   5. During overlap window (5-10 min), backend accepts BOTH v{N} and v{N+1} sigs
#   6. After 24h grace, delete v{N} secret
#
# Cron: weekly, Sunday 3am
#   0 3 * * 0 /opt/authway/scripts/rotate-cert-hmac.sh
#
# Env:
#   COMPOSE_FILE=/opt/authway/docker-compose.yml
#   SECRET_STATE_FILE=/var/lib/authway/cert-hmac-state

set -euo pipefail

readonly COMPOSE_FILE="${COMPOSE_FILE:-/opt/authway/docker-compose.yml}"
readonly SECRET_STATE_FILE="${SECRET_STATE_FILE:-/var/lib/authway/cert-hmac-state}"
readonly GRACE_HOURS="${GRACE_HOURS:-24}"

mkdir -p "$(dirname "${SECRET_STATE_FILE}")"

# Read current version from state file (default 1 if new)
current_version=1
if [[ -f "${SECRET_STATE_FILE}" ]]; then
  current_version=$(<"${SECRET_STATE_FILE}")
fi
new_version=$((current_version + 1))

echo "Rotating cert_hmac: v${current_version} → v${new_version}"

# Generate new secret
new_secret=$(openssl rand -hex 32)
new_secret_name="cert_hmac_v${new_version}"

# Create docker secret
echo "${new_secret}" | docker secret create "${new_secret_name}" - \
  || { echo >&2 "Failed to create docker secret ${new_secret_name}"; exit 1; }

echo "Created docker secret ${new_secret_name}"

# Update compose file — swap secret reference
# Assumption: compose has structure like:
#   services:
#     traefik:
#       secrets: [cert_hmac_current]
#     central-rbac:
#       secrets: [cert_hmac_current]
#   secrets:
#     cert_hmac_current:
#       external: true
#       name: cert_hmac_v{N}
sed -i.bak "s/name: cert_hmac_v${current_version}$/name: cert_hmac_v${new_version}/" "${COMPOSE_FILE}" \
  || { echo >&2 "sed update failed on ${COMPOSE_FILE}"; exit 2; }

echo "Updated compose secret reference"

# Backend supports BOTH v{N} and v{N+1} via env CERT_HMAC_SECONDARY (see auth-mtls.ts).
# Set secondary to old version so overlap window accepts both.
export CERT_HMAC_SECONDARY_NAME="cert_hmac_v${current_version}"

# Rolling restart — Traefik first (accepts new inbound signed sigs), then backend
docker compose -f "${COMPOSE_FILE}" up -d traefik central-rbac \
  || { echo >&2 "docker compose restart failed"; exit 3; }

# Persist new version
echo "${new_version}" > "${SECRET_STATE_FILE}"

echo
echo "Rotation complete. Overlap window: ${GRACE_HOURS}h."
echo "After ${GRACE_HOURS}h, run cleanup:"
echo "  docker secret rm cert_hmac_v${current_version}"
echo "  (backend will reject any lingering v${current_version} sigs)"

# Schedule grace cleanup via at(1) if available
if command -v at >/dev/null 2>&1; then
  echo "docker secret rm cert_hmac_v${current_version}" | at now + "${GRACE_HOURS}" hours 2>/dev/null \
    && echo "Scheduled auto-cleanup via at(1) in ${GRACE_HOURS}h" \
    || echo "at(1) scheduling failed — cleanup manually"
fi
