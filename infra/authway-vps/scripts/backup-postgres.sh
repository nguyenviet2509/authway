#!/usr/bin/env bash
# Daily Postgres backup → S3 nội bộ. Cron entry suggested:
#   0 2 * * * /opt/authway/infra/auth-vps/scripts/backup-postgres.sh >> /var/log/authway-backup.log 2>&1
# Red-team #11: cron daily + offsite từ ngày 1, không phải khi production.

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

readonly TS=$(date -u +%Y%m%d-%H%M%S)
readonly BACKUP_DIR=/var/backups/authway
readonly DUMP_FILE="${BACKUP_DIR}/zitadel-${TS}.sql.gz"

mkdir -p "${BACKUP_DIR}"

echo "[$(date -Iseconds)] backup-postgres: dumping..."
docker compose exec -T postgres pg_dump \
  -U "${POSTGRES_ADMIN_USER}" \
  -d zitadel \
  --no-owner --no-privileges --clean --if-exists \
  | gzip -9 > "${DUMP_FILE}"

readonly DUMP_SIZE=$(stat -c%s "${DUMP_FILE}")
echo "[$(date -Iseconds)] backup-postgres: dump done, size=${DUMP_SIZE}B"

# Sanity: refuse tiny dumps (likely failed)
if [ "${DUMP_SIZE}" -lt 10240 ]; then
  echo "[$(date -Iseconds)] backup-postgres: DUMP TOO SMALL (${DUMP_SIZE}B) — aborting" >&2
  exit 2
fi

# Offsite: S3 nội bộ qua rclone
echo "[$(date -Iseconds)] backup-postgres: uploading to s3..."
rclone copyto "${DUMP_FILE}" "internal-s3:${S3_BUCKET}/zitadel-${TS}.sql.gz"

# Local retention
find "${BACKUP_DIR}" -name 'zitadel-*.sql.gz' -mtime "+${BACKUP_RETENTION_DAYS:-7}" -delete

# Remote retention (best-effort, soft-fail)
rclone delete "internal-s3:${S3_BUCKET}" --min-age "${BACKUP_RETENTION_DAYS:-30}d" || true

echo "[$(date -Iseconds)] backup-postgres: OK"
