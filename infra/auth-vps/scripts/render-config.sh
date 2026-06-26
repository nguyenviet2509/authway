#!/usr/bin/env bash
# Render zitadel-config.yaml (template) → zitadel-config.runtime.yaml với giá trị từ .env
# Tránh issue env var injection của Zitadel runtime.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

# Verify required vars
required=(ZITADEL_DB_USER ZITADEL_DB_PASSWORD POSTGRES_ADMIN_USER POSTGRES_ADMIN_PASSWORD)
for v in "${required[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "[render-config] FATAL: ${v} không có giá trị trong .env" >&2
    exit 1
  fi
done

envsubst < zitadel-config.yaml > zitadel-config.runtime.yaml
chmod 600 zitadel-config.runtime.yaml
echo "[render-config] OK → zitadel-config.runtime.yaml"
