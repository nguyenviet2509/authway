#!/usr/bin/env bash
# Issue a client certificate for a service account (SA) via step-ca.
# Phase 06 Step 5 (test issuance) + Step 15 (rollout).
# CN = SA name (e.g., onemcp-backend, portal-admin, central-rbac-webhook).
# CN is cross-checked against JWT `sub` claim by backend auth-mtls middleware.
#
# Usage:
#   ./issue-client-cert.sh <sa-name> [validity]
#     sa-name  = e.g., onemcp-backend
#     validity = e.g., 720h (default 90d = 2160h; Red Team Fix #7 cert rotation window)
#
# Output: writes <sa-name>-cert.pem + <sa-name>-key.pem to $OUT_DIR
#
# Exit codes:
#   0 = success
#   1 = missing arg
#   2 = step-ca not reachable
#   3 = cert issuance failed

set -euo pipefail

readonly SA_NAME="${1:?Usage: $0 <sa-name> [validity]}"
readonly VALIDITY="${2:-2160h}"
readonly OUT_DIR="${OUT_DIR:-/root/.certs/clients}"
readonly PROVISIONER="${PROVISIONER:-admin}"
readonly PROVISIONER_PASSWORD_FILE="${PROVISIONER_PASSWORD_FILE:-/root/.secrets/step-ca-provisioner.pwd}"
readonly CA_URL="${CA_URL:-https://step-ca:9000}"
readonly ROOT_CERT="${ROOT_CERT:-/opt/step-ca/certs/root_ca.crt}"

# SA name allowlist (defense-in-depth — prevents arbitrary CN issuance)
readonly ALLOWED_SAS=("onemcp-backend" "portal-admin" "central-rbac-webhook" "indexer-sa")
if [[ ! " ${ALLOWED_SAS[*]} " =~ " ${SA_NAME} " ]]; then
  echo >&2 "SA '${SA_NAME}' not in allowlist: ${ALLOWED_SAS[*]}"
  echo >&2 "Add to ALLOWED_SAS array in this script if intentional."
  exit 1
fi

mkdir -p "${OUT_DIR}"

# Health check step-ca before issuance
step ca health --ca-url "${CA_URL}" --root "${ROOT_CERT}" >/dev/null 2>&1 \
  || { echo >&2 "step-ca not reachable at ${CA_URL}"; exit 2; }

# Issue cert. CN matches SA name; SAN includes SA name for hostname verification.
step ca certificate "${SA_NAME}" \
  "${OUT_DIR}/${SA_NAME}-cert.pem" \
  "${OUT_DIR}/${SA_NAME}-key.pem" \
  --provisioner "${PROVISIONER}" \
  --provisioner-password-file "${PROVISIONER_PASSWORD_FILE}" \
  --not-after "${VALIDITY}" \
  --ca-url "${CA_URL}" \
  --root "${ROOT_CERT}" \
  --force || { echo >&2 "cert issuance failed for ${SA_NAME}"; exit 3; }

chmod 0400 "${OUT_DIR}/${SA_NAME}-key.pem"
chmod 0444 "${OUT_DIR}/${SA_NAME}-cert.pem"

echo "Issued cert for ${SA_NAME}:"
echo "  cert: ${OUT_DIR}/${SA_NAME}-cert.pem"
echo "  key:  ${OUT_DIR}/${SA_NAME}-key.pem"
echo "  valid: ${VALIDITY}"

# Print expiration for logging
step certificate inspect "${OUT_DIR}/${SA_NAME}-cert.pem" --format=json \
  | grep -E '"not_after"' || true

echo
echo "Next: rsync to consumer VPS + restart consumer container to pick up new cert."
echo "See docs/deployment-central-rbac-mtls.md § Cert distribution."
