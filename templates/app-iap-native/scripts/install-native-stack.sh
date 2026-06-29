#!/usr/bin/env bash
# Authway App IAP — Native install script (no Docker)
# Cài Caddy + oauth2-proxy binary + systemd unit + config.
#
# Usage:
#   sudo APP_HOSTNAME=myapp.company.com \
#        APP_PORT=3000 \
#        ZITADEL_ISSUER_URL=https://auth.company.com \
#        APP_CLIENT_ID=xxx \
#        APP_CLIENT_SECRET=yyy \
#        LE_EMAIL=ops@company.com \
#        bash install-native-stack.sh
#
# Idempotent: chạy lại không phá config hiện tại (skip phần đã có).

set -euo pipefail
set +H

# ─── Required env vars ───
: "${APP_HOSTNAME:?APP_HOSTNAME required}"
: "${APP_PORT:?APP_PORT required}"
: "${ZITADEL_ISSUER_URL:?ZITADEL_ISSUER_URL required}"
: "${APP_CLIENT_ID:?APP_CLIENT_ID required}"
: "${APP_CLIENT_SECRET:?APP_CLIENT_SECRET required}"
: "${LE_EMAIL:?LE_EMAIL required (for Let's Encrypt notification)}"

OAUTH2_PROXY_VERSION="${OAUTH2_PROXY_VERSION:-v7.7.1}"
ARCH="${ARCH:-linux-amd64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "✗ Phải chạy với sudo / root."
    exit 1
  fi
}
require_root

echo "[1/7] apt update + base tools"
apt-get update -qq
apt-get install -y -qq curl wget openssl jq debian-keyring debian-archive-keyring apt-transport-https

echo "[2/7] Cài Caddy"
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
else
  echo "  ✓ Caddy already installed: $(caddy version | head -1)"
fi

echo "[3/7] Cài oauth2-proxy ${OAUTH2_PROXY_VERSION}"
if ! command -v oauth2-proxy >/dev/null 2>&1 || \
   ! oauth2-proxy --version 2>&1 | grep -q "${OAUTH2_PROXY_VERSION#v}"; then
  cd /tmp
  curl -sL -o oauth2-proxy.tar.gz \
    "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/${OAUTH2_PROXY_VERSION}/oauth2-proxy-${OAUTH2_PROXY_VERSION}.${ARCH}.tar.gz"
  tar xzf oauth2-proxy.tar.gz
  mv oauth2-proxy-*/oauth2-proxy /usr/local/bin/
  chmod +x /usr/local/bin/oauth2-proxy
  rm -rf /tmp/oauth2-proxy-* /tmp/oauth2-proxy.tar.gz
else
  echo "  ✓ oauth2-proxy already installed: $(oauth2-proxy --version | head -1)"
fi

echo "[4/7] Generate cookie secret + render oauth2-proxy config"
mkdir -p /etc/oauth2-proxy
if [ ! -f /etc/oauth2-proxy/config.cfg ]; then
  COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)
  echo "  ⚠ COOKIE_SECRET generated: $COOKIE_SECRET (lưu Bitwarden)"
else
  echo "  ⚠ config.cfg đã tồn tại — không overwrite (backup + xóa thủ công nếu cần regenerate)"
  exit 1
fi

# Derive Zitadel hostname từ issuer URL
ZITADEL_HOSTNAME=$(echo "$ZITADEL_ISSUER_URL" | sed -E 's|^https?://||; s|/.*$||')

cat > /etc/oauth2-proxy/config.cfg <<EOF
http_address       = "127.0.0.1:4180"
provider           = "oidc"
oidc_issuer_url    = "${ZITADEL_ISSUER_URL}"
client_id          = "${APP_CLIENT_ID}"
client_secret      = "${APP_CLIENT_SECRET}"
redirect_url       = "https://${APP_HOSTNAME}/oauth2/callback"
cookie_secret      = "${COOKIE_SECRET}"
cookie_domain      = "${APP_HOSTNAME}"
cookie_secure      = true
cookie_refresh     = "1h"
whitelist_domains  = ["${ZITADEL_HOSTNAME}"]
reverse_proxy      = true
set_xauthrequest   = true
pass_access_token  = false
pass_authorization_header = false
email_domains      = ["*"]
skip_provider_button = true
upstream           = "http://127.0.0.1:${APP_PORT}"
EOF
chown root:root /etc/oauth2-proxy/config.cfg
chmod 600 /etc/oauth2-proxy/config.cfg
echo "  ✓ /etc/oauth2-proxy/config.cfg"

echo "[5/7] Install systemd unit"
cp "$SCRIPT_DIR/oauth2-proxy.service" /etc/systemd/system/oauth2-proxy.service
systemctl daemon-reload
systemctl enable --now oauth2-proxy
sleep 2
if systemctl is-active --quiet oauth2-proxy; then
  echo "  ✓ oauth2-proxy.service active"
else
  echo "  ✗ oauth2-proxy.service KHÔNG active. Check: journalctl -u oauth2-proxy -n 50"
  exit 1
fi

echo "[6/7] Setup Caddyfile"
CADDYFILE=/etc/caddy/Caddyfile
if [ -f "$CADDYFILE" ] && grep -q "${APP_HOSTNAME}" "$CADDYFILE"; then
  echo "  ⚠ Caddyfile đã chứa ${APP_HOSTNAME} — không overwrite"
else
  # Backup nếu có
  [ -f "$CADDYFILE" ] && cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s)"

  # Render từ template
  sed -e "s|myapp.company.com|${APP_HOSTNAME}|g" \
      -e "s|ops@company.com|${LE_EMAIL}|g" \
      "$TEMPLATE_DIR/Caddyfile" > "$CADDYFILE"
  echo "  ✓ $CADDYFILE rendered"
fi
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy 2>/dev/null || true
systemctl reload caddy
sleep 2
if systemctl is-active --quiet caddy; then
  echo "  ✓ Caddy reloaded"
else
  echo "  ✗ Caddy reload fail. Check: journalctl -u caddy -n 50"
  exit 1
fi

echo "[7/7] Smoke test"
sleep 5   # wait LE cert provisioning

if curl -ksI "https://${APP_HOSTNAME}/" | head -1 | grep -qE 'HTTP.*30[12]'; then
  echo "  ✓ Endpoint trả redirect (302/301) — flow OIDC OK"
else
  echo "  ⚠ Endpoint chưa redirect. Có thể app chưa start hoặc DNS chưa propagate."
  echo "    Check: curl -ksI https://${APP_HOSTNAME}/"
  echo "    Check: journalctl -u oauth2-proxy -u caddy -n 50"
fi

echo ""
echo "=============================================================="
echo "✓ Install hoàn tất."
echo "  - oauth2-proxy: 127.0.0.1:4180 (systemd)"
echo "  - Caddy:        :80, :443 (auto-TLS Let's Encrypt)"
echo "  - App native:   phải listen 127.0.0.1:${APP_PORT}"
echo ""
echo "Tiếp theo:"
echo "  1. Verify app listen 127.0.0.1:${APP_PORT}:  ss -tlnp | grep ${APP_PORT}"
echo "  2. Browser test:  https://${APP_HOSTNAME}/"
echo "  3. Tail log:      journalctl -u oauth2-proxy -u caddy -f"
echo "=============================================================="
