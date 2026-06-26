#!/usr/bin/env bash
# Generate self-signed cert cho lab (auth.lab.local).
# Production: thay bằng Let's Encrypt qua ACME (xem traefik.yml).

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

readonly TLS_DIR=./tls
readonly DOMAIN="${ZITADEL_EXTERNAL_DOMAIN}"

mkdir -p "${TLS_DIR}"

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "${TLS_DIR}/auth.key" \
  -out "${TLS_DIR}/auth.crt" \
  -subj "/CN=${DOMAIN}/O=Authway Lab" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:*.lab.local,IP:192.168.122.54"

chmod 600 "${TLS_DIR}/auth.key"
chmod 644 "${TLS_DIR}/auth.crt"

echo "[generate-lab-cert] Cert generated: ${TLS_DIR}/auth.crt"
echo "[generate-lab-cert] Để trust cert trên client: import ${TLS_DIR}/auth.crt vào trust store"
echo "[generate-lab-cert] Linux: sudo cp auth.crt /usr/local/share/ca-certificates/authway-lab.crt && sudo update-ca-certificates"
echo "[generate-lab-cert] Windows: certutil -addstore -user Root auth.crt"
