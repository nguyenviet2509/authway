#!/usr/bin/env bash
# Periodic health checks → Telegram alert.
# Run every 10 phút via health-checker container.
# Probes:
#   - Zitadel discovery endpoint 200
#   - TLS cert days remaining >14
#   - Postgres disk <80%
#   - NTP offset <500ms
#   - SMTP test (weekly — Sunday)
# Red-team #6, #12

set -uo pipefail

readonly DOMAIN="${ZITADEL_EXTERNAL_DOMAIN}"
readonly DOW=$(date +%u)
ISSUES=()

alert() {
  local msg="$1"
  echo "[$(date -Iseconds)] ALERT: ${msg}" >&2
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="🚨 Authway: ${msg}" >/dev/null
  fi
}

# 1) Discovery endpoint
if ! curl -ksf -o /dev/null --max-time 10 "https://${DOMAIN}/.well-known/openid-configuration"; then
  ISSUES+=("Zitadel discovery endpoint down")
fi

# 2) TLS cert days remaining
EXPIRY=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "${EXPIRY}" ]; then
  EXPIRY_EPOCH=$(date -d "${EXPIRY}" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  DAYS=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
  if [ "${DAYS}" -lt 14 ]; then
    ISSUES+=("TLS cert expires in ${DAYS}d")
  fi
fi

# 3) Postgres disk (via docker exec)
DISK_USED=$(docker exec authway-auth-postgres-1 df /var/lib/postgresql/data 2>/dev/null \
  | awk 'NR==2{print $5}' | tr -d '%')
if [ -n "${DISK_USED}" ] && [ "${DISK_USED}" -gt 80 ]; then
  ISSUES+=("Postgres disk ${DISK_USED}% full")
fi

# 4) NTP offset
if command -v chronyc >/dev/null 2>&1; then
  OFFSET_MS=$(chronyc tracking 2>/dev/null | awk '/^Last offset/{print int($4 * 1000)}')
  if [ -n "${OFFSET_MS}" ] && [ "${OFFSET_MS#-}" -gt 500 ]; then
    ISSUES+=("NTP offset ${OFFSET_MS}ms (>500ms → TOTP risk)")
  fi
fi

# 5) SMTP test — only Sunday
if [ "${DOW}" = "7" ]; then
  if ! timeout 5 bash -c "</dev/tcp/mailhog/1025" 2>/dev/null; then
    ISSUES+=("SMTP relay unreachable (mailhog:1025)")
  fi
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
  for issue in "${ISSUES[@]}"; do
    alert "${issue}"
  done
  exit 1
fi

echo "[$(date -Iseconds)] health OK"
