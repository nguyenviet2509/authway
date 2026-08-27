#!/usr/bin/env bash
# Non-interactive step-ca bootstrap for OneLog central-rbac mTLS.
# Phase 06 Step 0 (PoC) + Step 4 (deploy).
# Reference plan: plans/260826-1644-central-rbac-hardening-and-self-service/phase-06-security-foundation.md
#
# Produces: root_ca.crt + root_ca.key + intermediate_ca.crt + intermediate_ca.key + ca.json + provisioner
# After success on lab (onelog-source), export root_ca.key + intermediate_ca.key OFFLINE
# (Age-encrypted per Validation Session 1 Decision — reuse OneLog backup-age.pub pattern).
#
# Usage:
#   STEPPATH=/opt/step-ca \
#   DNS_NAMES=step-ca,rbac.internal.local,10.200.0.125 \
#   PROVISIONER_PASSWORD_FILE=/root/.secrets/step-ca-provisioner.pwd \
#   ROOT_PASSWORD_FILE=/root/.secrets/step-ca-root.pwd \
#   ./init.sh
#
# Exit codes:
#   0 = success
#   1 = missing required env var
#   2 = step-ca binary not found
#   3 = init failed
#   4 = provisioner add failed

set -euo pipefail

: "${STEPPATH:?STEPPATH must be set (e.g., /opt/step-ca)}"
: "${DNS_NAMES:?DNS_NAMES must be comma-separated hostnames (e.g., step-ca,rbac.internal.local)}"
: "${PROVISIONER_PASSWORD_FILE:?PROVISIONER_PASSWORD_FILE must point to a file with the provisioner password (chmod 0400)}"
: "${ROOT_PASSWORD_FILE:?ROOT_PASSWORD_FILE must point to a file with the root CA password (chmod 0400)}"

# Verify binaries
command -v step >/dev/null 2>&1 || { echo >&2 "step CLI not found"; exit 2; }
command -v step-ca >/dev/null 2>&1 || { echo >&2 "step-ca binary not found"; exit 2; }

# Idempotency: skip if already initialized
if [[ -f "${STEPPATH}/config/ca.json" ]]; then
  echo "step-ca already initialized at ${STEPPATH} — skipping init"
  exit 0
fi

echo "Initializing step-ca at ${STEPPATH}..."
export STEPPATH

# Non-interactive init (no TTY prompts).
# --name = CA display name
# --dns  = SAN entries for internal server cert
# --address = listen addr:port
# --provisioner = default JWK provisioner name (used for cert issuance)
# --deployment-type = standalone (single-node, no HSM)
step ca init \
  --name "OneLog Central RBAC CA" \
  --dns "${DNS_NAMES}" \
  --address ":9000" \
  --provisioner "admin" \
  --password-file "${ROOT_PASSWORD_FILE}" \
  --provisioner-password-file "${PROVISIONER_PASSWORD_FILE}" \
  --deployment-type "standalone" \
  --no-db || { echo >&2 "step ca init failed"; exit 3; }

echo "step-ca initialized. Certs at:"
ls -la "${STEPPATH}/certs/"

# Phase 06 Fix #10: healthcheck endpoint validation
echo "Verify healthcheck endpoint..."
# Note: this only works after step-ca daemon is started. Kept here as a doc reminder.
echo "  step ca health --ca-url https://localhost:9000 --root ${STEPPATH}/certs/root_ca.crt"

# Print backup reminder (Validation Session 1 Decision — Age-encrypted offline)
cat <<EOF

============================================================
NEXT STEP — BACKUP ROOT KEY (MANDATORY before proceeding):
============================================================
  1. Copy ${STEPPATH}/secrets/root_ca_key to a secure workstation
  2. Encrypt with Age using OneLog backup-age.pub:
       age -R /path/to/backup-age.pub -o root_ca_key.age root_ca_key
  3. Store root_ca_key.age in Bitwarden (attachment) + print QR paper backup
  4. Delete plaintext root_ca_key from VPS:
       shred -u ${STEPPATH}/secrets/root_ca_key
  5. Intermediate key stays on VPS (needed for cert signing)

Losing root_ca_key = re-issue every cert. DO NOT SKIP.
============================================================
EOF
