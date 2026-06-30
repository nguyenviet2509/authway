#!/bin/bash
# ============================================
# AutoSSL Manager - AlmaLinux 8 Deployment
# ============================================
# Usage: bash deploy.sh
# Run on VPS: 103.216.117.178
# ============================================

set -e

APP_DIR="/var/www/autossl"
SERVER_IP="103.216.117.178"

echo "=========================================="
echo "  AutoSSL Manager - AlmaLinux 8 Deploy"
echo "=========================================="

# 1. Install Node.js 20
if ! command -v node &> /dev/null; then
    echo "[1/7] Installing Node.js 20..."
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    dnf install -y nodejs
else
    echo "[1/7] Node.js already installed: $(node -v)"
fi

# 2. Install PM2
if ! command -v pm2 &> /dev/null; then
    echo "[2/7] Installing PM2..."
    npm install -g pm2
else
    echo "[2/7] PM2 already installed"
fi

# 3. Install nginx
if ! command -v nginx &> /dev/null; then
    echo "[3/7] Installing nginx..."
    dnf install -y epel-release
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx
else
    echo "[3/7] nginx already installed"
fi

# 4. Firewall - open port 80
echo "[4/7] Configuring firewall..."
firewall-cmd --permanent --add-service=http 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

# 5. Install dependencies & build
echo "[5/7] Installing dependencies & building..."
mkdir -p $APP_DIR
cd $APP_DIR
npm install --production=false
npm run build

# 6. Create .env.local
echo "[6/7] Setting up environment..."
if [ ! -f "$APP_DIR/.env.local" ]; then
    cat > $APP_DIR/.env.local << 'EOF'
NODE_TLS_REJECT_UNAUTHORIZED=0
ALLOWED_IPS=123.25.21.12,172.31.98.188,115.73.218.192,103.57.222.245
ALLOWED_CIDRS=
EOF
    echo "  Created .env.local with iNET allowed IPs"
else
    echo "  .env.local already exists, skipping"
fi

# 7. Setup nginx
echo "[7/7] Setting up nginx..."
cp $APP_DIR/nginx.conf /etc/nginx/conf.d/autossl.conf

# Remove default server block if it conflicts
if [ -f /etc/nginx/conf.d/default.conf ]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak
fi

nginx -t && systemctl reload nginx

# SELinux: allow nginx to proxy
setsebool -P httpd_can_network_connect 1 2>/dev/null || true

# Start/Restart app with PM2
echo ""
echo "Starting app with PM2..."
cd $APP_DIR
pm2 delete autossl 2>/dev/null || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Deployment complete!"
echo "=========================================="
echo ""
echo "  App:    http://${SERVER_IP}"
echo "  PM2:    pm2 status / pm2 logs autossl"
echo "  Nginx:  /etc/nginx/conf.d/autossl.conf"
echo "  Env:    $APP_DIR/.env.local"
echo ""
echo "  Allowed IPs:"
echo "    - 123.25.21.12"
echo "    - 172.31.98.188"
echo "    - 115.73.218.192"
echo "    - 103.57.222.245"
echo ""
