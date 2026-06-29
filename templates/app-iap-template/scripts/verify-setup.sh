#!/usr/bin/env bash
# Pre-flight check trước khi docker compose up -d.
# Kiểm tra: .env đầy đủ, DNS resolve, OIDC discovery, Docker running, cert file (lab).
#
# Usage:
#   bash scripts/verify-setup.sh

set -uo pipefail

ENV_FILE="${ENV_FILE:-.env}"
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }

# ─── 1. .env exists ───
echo "[1] .env file"
if [ ! -f "$ENV_FILE" ]; then
  fail "$ENV_FILE not found. Run: cp .env.example .env"
  exit 1
fi
pass "$ENV_FILE found"

# Load env
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ─── 2. Required vars ───
echo "[2] Required env vars"
required=(APP_HOSTNAME APP_IMAGE APP_PORT ZITADEL_ISSUER_URL ZITADEL_HOSTNAME APP_CLIENT_ID APP_CLIENT_SECRET APP_COOKIE_SECRET)
for v in "${required[@]}"; do
  val="${!v:-}"
  if [ -z "$val" ]; then
    fail "$v is empty"
  else
    pass "$v set (${#val} chars)"
  fi
done

# ─── 3. COOKIE_SECRET length ───
echo "[3] APP_COOKIE_SECRET length"
if [ "${#APP_COOKIE_SECRET}" -eq 32 ]; then
  pass "32 chars OK"
else
  fail "Must be 32 chars (current: ${#APP_COOKIE_SECRET}). Run: bash scripts/gen-secrets.sh"
fi

# ─── 4. DNS resolve ───
echo "[4] DNS resolution"
if command -v getent >/dev/null 2>&1; then
  RESOLVER="getent hosts"
elif command -v host >/dev/null 2>&1; then
  RESOLVER="host"
else
  warn "No getent/host command — skip DNS check"
  RESOLVER=""
fi

if [ -n "$RESOLVER" ]; then
  for h in "$APP_HOSTNAME" "$ZITADEL_HOSTNAME"; do
    if $RESOLVER "$h" >/dev/null 2>&1; then
      pass "$h resolves"
    else
      warn "$h does NOT resolve (lab: dùng /etc/hosts hoặc extra_hosts; prod: cần DNS thật)"
    fi
  done
fi

# ─── 5. OIDC discovery ───
echo "[5] OIDC discovery endpoint"
DISC_URL="${ZITADEL_ISSUER_URL%/}/.well-known/openid-configuration"
if curl -ks --max-time 5 -o /dev/null -w "%{http_code}" "$DISC_URL" | grep -q '^200$'; then
  pass "$DISC_URL → 200"
else
  fail "$DISC_URL không trả 200. Verify Zitadel up + DNS + TLS"
fi

# ─── 6. Docker daemon ───
echo "[6] Docker daemon"
if docker info >/dev/null 2>&1; then
  pass "Docker daemon running"
else
  fail "Docker daemon not reachable. Run: sudo systemctl start docker"
fi

# ─── 7. TLS cert (lab mode) ───
echo "[7] TLS cert"
if [ "${TLS_MODE:-lab}" = "lab" ]; then
  if [ -f tls/app.crt ] && [ -f tls/app.key ]; then
    pass "tls/app.crt + tls/app.key found"
  else
    warn "tls/app.crt or tls/app.key missing. Lab → generate self-signed:"
    echo "      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\"
    echo "        -keyout tls/app.key -out tls/app.crt \\"
    echo "        -subj \"/CN=${APP_HOSTNAME}\" \\"
    echo "        -addext \"subjectAltName=DNS:${APP_HOSTNAME}\""
  fi
else
  pass "TLS_MODE=prod (Let's Encrypt — Traefik auto-renew)"
fi

# ─── 8. Cookie secret in placeholder ───
echo "[8] Sanity: client_id / client_secret format"
if echo "$APP_CLIENT_ID" | grep -qE '^[0-9]{15,25}$'; then
  pass "APP_CLIENT_ID looks like Zitadel ID"
else
  warn "APP_CLIENT_ID format không giống Zitadel client_id (số 15-25 chữ số). Verify lại."
fi

if [ "${#APP_CLIENT_SECRET}" -ge 40 ]; then
  pass "APP_CLIENT_SECRET length OK (${#APP_CLIENT_SECRET})"
else
  warn "APP_CLIENT_SECRET ngắn bất thường (${#APP_CLIENT_SECRET}). Zitadel thường cấp ~40-64 chars."
fi

# ─── Summary ───
echo ""
if [ $FAIL -eq 0 ]; then
  echo "✓ All critical checks passed ($WARN warning)."
  echo "  Next: docker compose pull && docker compose up -d"
  exit 0
else
  echo "✗ $FAIL critical error(s), $WARN warning(s). Fix trước khi deploy."
  exit 1
fi
