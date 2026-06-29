#!/usr/bin/env bash
# Generate APP_COOKIE_SECRET (32 chars) và update .env in-place.
# Idempotent: chạy nhiều lần sẽ overwrite secret cũ (rotate).
#
# Usage:
#   bash scripts/gen-secrets.sh
#   bash scripts/gen-secrets.sh --force   # rotate kể cả khi đã có

set -euo pipefail
set +H   # disable bash history expansion (avoid ! issues)

ENV_FILE="${ENV_FILE:-.env}"
FORCE="${1:-}"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ $ENV_FILE not found. Run: cp .env.example .env"
  exit 1
fi

current=$(grep -E '^APP_COOKIE_SECRET=' "$ENV_FILE" | cut -d= -f2-)

if [ -n "$current" ] && [ "$FORCE" != "--force" ]; then
  echo "✓ APP_COOKIE_SECRET đã có sẵn (${#current} chars). Dùng --force để rotate."
  exit 0
fi

# 32 chars from base64, strip non-alphanumeric to avoid escape issues
NEW=$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)

if [ ${#NEW} -ne 32 ]; then
  echo "✗ Generated secret length ${#NEW} != 32. Retry."
  exit 1
fi

# sed in-place. macOS sed cần `-i ''`, GNU sed cần `-i`. Detect.
if sed --version >/dev/null 2>&1; then
  sed -i "s|^APP_COOKIE_SECRET=.*|APP_COOKIE_SECRET=${NEW}|" "$ENV_FILE"
else
  sed -i '' "s|^APP_COOKIE_SECRET=.*|APP_COOKIE_SECRET=${NEW}|" "$ENV_FILE"
fi

echo "✓ APP_COOKIE_SECRET generated (32 chars) → $ENV_FILE"
echo "  Next: bash scripts/verify-setup.sh"
