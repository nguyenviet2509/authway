#!/usr/bin/env bash
# Daily cert expiry monitor with heartbeat + Alertmanager + Telegram fallback.
# Phase 06 Step 12 (Red Team Fix #7): SPOF-hardened.
# - Threshold: 60 days (was 30d — extended per Fix #7 for weekend/holiday buffer)
# - Writes success timestamp to node_textfile collector for Prometheus freshness check
# - Alertmanager primary + direct Telegram fallback if AM unreachable
# - Checks BOTH leaf certs AND intermediate CA (Fix #7)
#
# Cron: 6:00 daily on authway-vps
#   0 6 * * * /opt/authway/scripts/check-cert-expiry.sh >> /var/log/cert-expiry.log 2>&1
#
# Prometheus scrape: node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile
#   Alert rule: time() - cert_expiry_check_last_success_timestamp_seconds > 172800 (2 days stale = alert)

set -euo pipefail

readonly CERT_DIRS=(
  "/opt/step-ca/certs"                    # step-ca root + intermediate
  "/root/.certs/clients"                  # SA client certs
  "/etc/traefik/certs"                    # Server cert (Sectigo or step-ca-issued)
)
readonly THRESHOLD_DAYS="${THRESHOLD_DAYS:-60}"
readonly TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
readonly TEXTFILE="${TEXTFILE_DIR}/cert_expiry_check.prom"
readonly ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://alertmanager:9093/api/v2/alerts}"
readonly TELEGRAM_BOT_TOKEN_FILE="${TELEGRAM_BOT_TOKEN_FILE:-/run/secrets/telegram_bot_token}"
readonly TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
readonly HOSTNAME_TAG="$(hostname -s)"

# Colors for interactive runs (auto-disabled in cron)
if [[ -t 1 ]]; then
  readonly RED=$'\e[31m' YELLOW=$'\e[33m' GREEN=$'\e[32m' RESET=$'\e[0m'
else
  readonly RED='' YELLOW='' GREEN='' RESET=''
fi

warnings=()
criticals=()

check_cert() {
  local cert_path="$1"
  local cn
  local not_after
  local expiry_epoch
  local now_epoch
  local days_left

  cn=$(openssl x509 -in "${cert_path}" -noout -subject 2>/dev/null | sed -n 's/.*CN[ ]*=[ ]*\([^,\/]*\).*/\1/p')
  not_after=$(openssl x509 -in "${cert_path}" -noout -enddate 2>/dev/null | cut -d= -f2)
  expiry_epoch=$(date -d "${not_after}" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)

  if [[ "${expiry_epoch}" -eq 0 ]]; then
    criticals+=("PARSE-FAIL: ${cert_path} — cannot read expiry")
    return
  fi

  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  if [[ "${days_left}" -le 7 ]]; then
    criticals+=("EXPIRING-SOON (${days_left}d): ${cn:-unknown} @ ${cert_path}")
  elif [[ "${days_left}" -le "${THRESHOLD_DAYS}" ]]; then
    warnings+=("WARN (${days_left}d): ${cn:-unknown} @ ${cert_path}")
  else
    echo "${GREEN}OK${RESET}   (${days_left}d): ${cn:-unknown}"
  fi
}

# Scan
for dir in "${CERT_DIRS[@]}"; do
  if [[ ! -d "${dir}" ]]; then continue; fi
  while IFS= read -r -d '' cert; do
    check_cert "${cert}"
  done < <(find "${dir}" -type f \( -name '*.pem' -o -name '*.crt' \) -print0)
done

# Report
echo
for w in "${warnings[@]}"; do echo "${YELLOW}${w}${RESET}"; done
for c in "${criticals[@]}"; do echo "${RED}${c}${RESET}"; done

# Heartbeat: write timestamp for Prometheus freshness alert
mkdir -p "${TEXTFILE_DIR}"
cat > "${TEXTFILE}" <<EOF
# HELP cert_expiry_check_last_success_timestamp_seconds Unix timestamp of last successful cert-expiry check
# TYPE cert_expiry_check_last_success_timestamp_seconds gauge
cert_expiry_check_last_success_timestamp_seconds{host="${HOSTNAME_TAG}"} $(date +%s)
# HELP cert_expiry_warnings_total Number of certs within warn window
# TYPE cert_expiry_warnings_total gauge
cert_expiry_warnings_total{host="${HOSTNAME_TAG}"} ${#warnings[@]}
# HELP cert_expiry_criticals_total Number of certs expiring within 7d
# TYPE cert_expiry_criticals_total gauge
cert_expiry_criticals_total{host="${HOSTNAME_TAG}"} ${#criticals[@]}
EOF

# Alert routing: try Alertmanager first, fall back to direct Telegram
if [[ ${#warnings[@]} -gt 0 || ${#criticals[@]} -gt 0 ]]; then
  alert_body=""
  for c in "${criticals[@]}"; do alert_body="${alert_body}CRITICAL: ${c}\n"; done
  for w in "${warnings[@]}"; do alert_body="${alert_body}WARN: ${w}\n"; done

  # Try Alertmanager (primary — respects existing routing rules)
  am_payload=$(cat <<JSON
[{
  "labels": {"alertname": "CertExpiryImminent", "severity": "warning", "host": "${HOSTNAME_TAG}"},
  "annotations": {"summary": "Cert expiry check found ${#criticals[@]} critical + ${#warnings[@]} warnings", "description": "${alert_body}"}
}]
JSON
)
  am_ok=false
  if curl -sS --max-time 5 -X POST -H "Content-Type: application/json" \
       -d "${am_payload}" "${ALERTMANAGER_URL}" >/dev/null 2>&1; then
    am_ok=true
  fi

  # Fallback: direct Telegram (bypass Alertmanager reload pitfall — memory alertmanager-config-reload.md)
  if [[ "${am_ok}" != "true" ]]; then
    echo >&2 "Alertmanager unreachable — direct Telegram fallback"
    if [[ -f "${TELEGRAM_BOT_TOKEN_FILE}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
      bot_token=$(cat "${TELEGRAM_BOT_TOKEN_FILE}")
      msg="🚨 [${HOSTNAME_TAG}] Cert expiry: ${#criticals[@]} CRIT + ${#warnings[@]} WARN. AM DOWN. Body: ${alert_body}"
      curl -sS --max-time 5 -X POST \
        "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${msg}" >/dev/null 2>&1 || echo >&2 "Telegram fallback also failed"
    else
      echo >&2 "No Telegram credentials configured — alert DROPPED"
    fi
  fi
fi

# Exit code reflects severity (for cron log grep + on-failure hooks)
if [[ ${#criticals[@]} -gt 0 ]]; then exit 2; fi
if [[ ${#warnings[@]} -gt 0 ]]; then exit 1; fi
exit 0
