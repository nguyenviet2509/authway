#!/usr/bin/env bash
# Weekly restore drill — restore latest backup vào throwaway Postgres container.
# Red-team #11: backup không có restore test là theatre.
# Cron suggested: 0 4 * * 0  (4am Sundays)

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a

readonly DRILL_CONTAINER=authway-restore-drill
readonly DRILL_PASSWORD=$(openssl rand -base64 24)
readonly LATEST_DUMP=$(ls -t /var/backups/authway/zitadel-*.sql.gz 2>/dev/null | head -1)

if [ -z "${LATEST_DUMP}" ]; then
  echo "[$(date -Iseconds)] restore-drill: no backup found in /var/backups/authway" >&2
  exit 2
fi

echo "[$(date -Iseconds)] restore-drill: using ${LATEST_DUMP}"

# Clean any prior drill container
docker rm -f "${DRILL_CONTAINER}" >/dev/null 2>&1 || true

docker run -d \
  --name "${DRILL_CONTAINER}" \
  -e POSTGRES_PASSWORD="${DRILL_PASSWORD}" \
  -e POSTGRES_USER=postgres \
  postgres:16-alpine

# Wait healthy
for i in {1..30}; do
  if docker exec "${DRILL_CONTAINER}" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec -i "${DRILL_CONTAINER}" psql -U postgres -c "CREATE DATABASE zitadel_drill;"

zcat "${LATEST_DUMP}" | docker exec -i "${DRILL_CONTAINER}" psql -U postgres -d zitadel_drill >/dev/null

# Assertion: zitadel core tables exist + non-empty
readonly USER_COUNT=$(docker exec -i "${DRILL_CONTAINER}" psql -U postgres -d zitadel_drill -tAc \
  "SELECT count(*) FROM projections.users10;" 2>/dev/null || echo 0)

docker rm -f "${DRILL_CONTAINER}" >/dev/null

if [ "${USER_COUNT}" -lt 1 ]; then
  echo "[$(date -Iseconds)] restore-drill: FAIL — users10 count=${USER_COUNT}" >&2
  # Alert via telegram
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="🚨 Authway restore-drill FAILED ($(hostname)). users10 count=${USER_COUNT}. Backup: ${LATEST_DUMP}" >/dev/null
  fi
  exit 1
fi

echo "[$(date -Iseconds)] restore-drill: OK — users10 count=${USER_COUNT}"
