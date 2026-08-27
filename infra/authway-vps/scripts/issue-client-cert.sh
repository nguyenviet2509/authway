#!/usr/bin/env bash
# Issue a client certificate for a service account (SA) via step-ca sidecar.
# Phase 06 Step 5 (test issuance) + Step 15 (rollout).
# CN = SA name (e.g., onemcp-backend, portal-admin, central-rbac-webhook).
# CN is cross-checked against JWT `sub` claim by backend auth-mtls middleware.
#
# Runs on VPS host — uses docker exec into step-ca container (no step CLI needed on host).
# Provisioner password sourced from /root/.secrets/step-ca.env DOCKER_STEPCA_INIT_PASSWORD var.
#
# Usage:
#   ./issue-client-cert.sh <sa-name> [validity]
#     sa-name  = e.g., onemcp-backend
#     validity = e.g., 720h (default 90d = 2160h; Red Team Fix #7 cert rotation window)
#
# Output: writes <sa-name>.crt + <sa-name>.key to $OUT_DIR (0400 key, 0444 cert)
#
# Exit codes:
#   0 = success
#   1 = missing arg / SA not in allowlist
#   2 = step-ca container not running / password not found
#   3 = cert issuance failed

set -euo pipefail

readonly SA_NAME="${1:?Usage: $0 <sa-name> [validity]}"
readonly VALIDITY="${2:-2160h}"
readonly OUT_DIR="${OUT_DIR:-/root/.certs/clients}"
readonly PROVISIONER="${PROVISIONER:-admin}"
readonly CONTAINER="${CONTAINER:-authway-prod-step-ca-1}"
readonly ENV_FILE="${ENV_FILE:-/root/.secrets/step-ca.env}"
readonly CA_URL="${CA_URL:-https://step-ca:9000}"
readonly ROOT_CERT_IN_CONTAINER="/home/step/certs/root_ca.crt"

# SA name allowlist (defense-in-depth — prevents arbitrary CN issuance)
readonly ALLOWED_SAS=("onemcp-backend" "portal-admin" "central-rbac-webhook" "indexer-sa")
if [[ ! " ${ALLOWED_SAS[*]} " =~ " ${SA_NAME} " ]]; then
  echo >&2 "SA '${SA_NAME}' not in allowlist: ${ALLOWED_SAS[*]}"
  echo >&2 "Add to ALLOWED_SAS array in this script if intentional."
  exit 1
fi

# Verify container healthy
docker inspect --format='{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null | grep -q healthy \
  || { echo >&2 "step-ca container ${CONTAINER} not healthy — check 'docker ps'"; exit 2; }

# Extract provisioner password from env file
[[ -r "${ENV_FILE}" ]] || { echo >&2 "Env file ${ENV_FILE} not readable"; exit 2; }
PROV_PW=$(grep -E '^DOCKER_STEPCA_INIT_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')
[[ -n "${PROV_PW}" ]] || { echo >&2 "DOCKER_STEPCA_INIT_PASSWORD not found in ${ENV_FILE}"; exit 2; }

mkdir -p "${OUT_DIR}"

# Write password to container (cleanup stale first — existing 0400 file blocks tee overwrite)
docker exec "${CONTAINER}" rm -f /home/step/prov.pwd
echo -n "${PROV_PW}" | docker exec -i "${CONTAINER}" tee /home/step/prov.pwd > /dev/null
docker exec "${CONTAINER}" chmod 400 /home/step/prov.pwd

cleanup_pwd() {
  docker exec "${CONTAINER}" rm -f /home/step/prov.pwd 2>/dev/null || true
}
trap cleanup_pwd EXIT

# Issue cert. CN matches SA name (used by backend auth-mtls for JWT sub crosscheck).
docker exec "${CONTAINER}" step ca certificate \
  "${SA_NAME}" \
  "/home/step/certs/${SA_NAME}.crt" \
  "/home/step/certs/${SA_NAME}.key" \
  --provisioner "${PROVISIONER}" \
  --provisioner-password-file /home/step/prov.pwd \
  --not-after "${VALIDITY}" \
  --ca-url "${CA_URL}" \
  --root "${ROOT_CERT_IN_CONTAINER}" \
  --force \
  || { echo >&2 "cert issuance failed for ${SA_NAME}"; exit 3; }

# Copy cert + key out of container to host filesystem
docker cp "${CONTAINER}:/home/step/certs/${SA_NAME}.crt" "${OUT_DIR}/${SA_NAME}.crt"
docker cp "${CONTAINER}:/home/step/certs/${SA_NAME}.key" "${OUT_DIR}/${SA_NAME}.key"
chmod 0400 "${OUT_DIR}/${SA_NAME}.key"
chmod 0444 "${OUT_DIR}/${SA_NAME}.crt"

echo "Issued cert for ${SA_NAME}:"
echo "  cert: ${OUT_DIR}/${SA_NAME}.crt"
echo "  key:  ${OUT_DIR}/${SA_NAME}.key"
echo "  valid: ${VALIDITY}"

# Print subject + expiration
docker exec "${CONTAINER}" step certificate inspect "/home/step/certs/${SA_NAME}.crt" --short \
  | grep -E 'Subject:|Valid'

echo
echo "Next: rsync to consumer VPS + restart consumer container to pick up new cert."
echo "See onelog docs/deployment-central-rbac-mtls.md § Cert distribution."
