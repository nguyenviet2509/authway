#!/usr/bin/env bash
# Render zitadel-config.yaml (template) → zitadel-config.runtime.yaml với giá trị từ .env
# Tránh issue env var injection của Zitadel runtime.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

# Verify required vars
required=(ZITADEL_DB_USER ZITADEL_DB_PASSWORD POSTGRES_ADMIN_USER POSTGRES_ADMIN_PASSWORD ZITADEL_ADMIN_USERNAME ZITADEL_ADMIN_PASSWORD)
for v in "${required[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "[render-config] FATAL: ${v} không có giá trị trong .env" >&2
    exit 1
  fi
done

# Defensive: nếu Docker compose start trước khi script này chạy, nó sẽ auto-tạo
# directory trống tại bind-mount path. Phải xóa trước khi envsubst (không ghi đè được dir).
for f in zitadel-config.runtime.yaml zitadel-steps.runtime.yaml; do
  if [ -d "$f" ]; then
    echo "[render-config] WARN: '$f' tồn tại dưới dạng directory (docker auto-tạo) → xóa" >&2
    rm -rf "$f"
  fi
done

envsubst < zitadel-config.yaml > zitadel-config.runtime.yaml
chmod 600 zitadel-config.runtime.yaml

envsubst < zitadel-steps.yaml > zitadel-steps.runtime.yaml
chmod 600 zitadel-steps.runtime.yaml

# Sanity: verify placeholders đều resolve
if grep -E '\$\{[A-Z_]+\}' zitadel-config.runtime.yaml zitadel-steps.runtime.yaml >/dev/null 2>&1; then
  echo "[render-config] FATAL: còn placeholder chưa resolve trong runtime files" >&2
  grep -nE '\$\{[A-Z_]+\}' zitadel-config.runtime.yaml zitadel-steps.runtime.yaml >&2
  exit 1
fi

echo "[render-config] OK → zitadel-config.runtime.yaml + zitadel-steps.runtime.yaml"
