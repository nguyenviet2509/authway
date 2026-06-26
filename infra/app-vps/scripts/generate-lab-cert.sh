#!/usr/bin/env bash
# Generate self-signed cert cho 2 demo app domain.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

readonly TLS_DIR=./tls
mkdir -p "${TLS_DIR}"

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "${TLS_DIR}/app.key" \
  -out "${TLS_DIR}/app.crt" \
  -subj "/CN=${NEXTJS_HOSTNAME}/O=Authway Lab" \
  -addext "subjectAltName=DNS:${NEXTJS_HOSTNAME},DNS:${STATIC_HOSTNAME}"

chmod 600 "${TLS_DIR}/app.key"
chmod 644 "${TLS_DIR}/app.crt"

echo "[generate-lab-cert] OK → ${TLS_DIR}/app.crt"
echo "  Domains: ${NEXTJS_HOSTNAME}, ${STATIC_HOSTNAME}"
