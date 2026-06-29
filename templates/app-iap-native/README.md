# Authway App IAP — Native (No Docker) Template

Template KHÔNG dùng Docker. App + oauth2-proxy + reverse proxy chạy trực tiếp trên host qua systemd. Dùng khi member không muốn / không thể cài Docker.

Reverse proxy: **Caddy** (auto-TLS Let's Encrypt, đơn giản nhất). Nếu đã có nginx sẵn → xem `nginx-alternative.conf`.

App vẫn deploy native như trước. Chỉ thêm 2 thứ: oauth2-proxy (binary + systemd) + Caddy reverse proxy.

---

## Architecture

```
Browser → Caddy :443 (TLS, auto LE) → oauth2-proxy :4180 → App native (127.0.0.1:PORT)
                                            ↓
                                       Zitadel OIDC
```

Tất cả chạy trên cùng 1 host, KHÔNG cần container.

---

## Pre-requisites

- VPS Ubuntu 22.04 / 24.04 LTS
- App đã chạy native và listen `127.0.0.1:<PORT>` (KHÔNG bind 0.0.0.0)
- DNS A record `myapp.company.com` → IP VPS
- Port 80 + 443 free (Caddy chiếm)
- `CLIENT_ID` + `CLIENT_SECRET` nhận từ ops admin

---

## Quy trình tổng quan (8 bước)

1. SSH + UFW + NTP
2. Stop web server cũ (nếu có) chiếm 80/443
3. Cài Caddy
4. Cài oauth2-proxy binary
5. Generate cookie secret + render config
6. Setup systemd service + Caddyfile
7. Verify app native listen `127.0.0.1:<PORT>`
8. Smoke test

---

## 1. SSH + UFW + NTP

```bash
# Hardening cơ bản
sudo apt update && sudo apt install -y curl wget openssl jq
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts

# NTP — bắt buộc cho TOTP
sudo timedatectl set-ntp true
timedatectl status

# UFW (thay <VPN_CIDR>)
VPN_CIDR="10.8.0.0/24"
sudo ufw allow from $VPN_CIDR to any port 22 proto tcp
sudo ufw allow from $VPN_CIDR to any port 80 proto tcp
sudo ufw allow from $VPN_CIDR to any port 443 proto tcp
sudo ufw default deny incoming
sudo ufw --force enable
```

## 2. Stop web server cũ

```bash
sudo ss -tlnp | grep -E ':80 |:443 '

# Caddy sẽ thay nginx/apache cho TLS terminate. Nếu app đang dùng nginx local,
# có thể giữ nginx listen 127.0.0.1:NGINX_PORT, Caddy proxy về:
#   reverse_proxy 127.0.0.1:NGINX_PORT
# Hoặc disable nginx hoàn toàn nếu app self-contained.

sudo systemctl stop apache2 lsws openlitespeed 2>/dev/null
sudo systemctl mask apache2 lsws openlitespeed 2>/dev/null
```

## 3. Cài Caddy

```bash
# Official Caddy repo
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

# Verify
caddy version   # → v2.x
sudo systemctl status caddy   # → active
```

## 4. Cài oauth2-proxy binary

```bash
VER=v7.7.1
ARCH=linux-amd64
cd /tmp
curl -L -o oauth2-proxy.tar.gz \
  https://github.com/oauth2-proxy/oauth2-proxy/releases/download/${VER}/oauth2-proxy-${VER}.${ARCH}.tar.gz
tar xzf oauth2-proxy.tar.gz
sudo mv oauth2-proxy-*/oauth2-proxy /usr/local/bin/
sudo chmod +x /usr/local/bin/oauth2-proxy

# Verify
oauth2-proxy --version   # → oauth2-proxy v7.7.1 ...
```

## 5. Generate cookie secret + render config

```bash
sudo mkdir -p /etc/oauth2-proxy
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)
echo "COOKIE_SECRET = $COOKIE_SECRET"   # → lưu password manager

# Fill các biến rồi render config (KHÔNG để comment cùng dòng với value)
sudo tee /etc/oauth2-proxy/config.cfg <<EOF
http_address       = "127.0.0.1:4180"
provider           = "oidc"
oidc_issuer_url    = "https://auth.company.com"
client_id          = "REPLACE_WITH_CLIENT_ID"
client_secret      = "REPLACE_WITH_CLIENT_SECRET"
redirect_url       = "https://myapp.company.com/oauth2/callback"
cookie_secret      = "$COOKIE_SECRET"
cookie_domain      = "myapp.company.com"
cookie_secure      = true
cookie_refresh     = "1h"
whitelist_domains  = ["auth.company.com"]
reverse_proxy      = true
set_xauthrequest   = true
pass_access_token  = false
pass_authorization_header = false
email_domains      = ["*"]
skip_provider_button = true
upstream           = "http://127.0.0.1:3000"
EOF

# Lock perm
sudo chown root:root /etc/oauth2-proxy/config.cfg
sudo chmod 600 /etc/oauth2-proxy/config.cfg

# Edit fill 3 placeholder
sudo nano /etc/oauth2-proxy/config.cfg
# Replace:
#   REPLACE_WITH_CLIENT_ID → từ ops
#   REPLACE_WITH_CLIENT_SECRET → từ ops
#   upstream port (3000 → port app thực tế)
```

## 6. systemd service + Caddyfile

### 6a. systemd service cho oauth2-proxy

```bash
sudo cp scripts/oauth2-proxy.service /etc/systemd/system/oauth2-proxy.service
sudo systemctl daemon-reload
sudo systemctl enable --now oauth2-proxy
sudo systemctl status oauth2-proxy
# → active (running)

# Tail log
sudo journalctl -u oauth2-proxy -f
# Expect: "Listening on 127.0.0.1:4180"
```

### 6b. Caddyfile

```bash
sudo cp Caddyfile /etc/caddy/Caddyfile

# Edit fill APP_HOSTNAME + email LE
sudo nano /etc/caddy/Caddyfile
# Replace:
#   myapp.company.com → hostname thực tế
#   ops@company.com → email LE notification

sudo systemctl reload caddy
sudo journalctl -u caddy -f
# Expect: "certificate obtained successfully" cho domain
```

## 7. Verify app native listen 127.0.0.1

```bash
# App PHẢI listen 127.0.0.1, KHÔNG bind 0.0.0.0
sudo ss -tlnp | grep <APP_PORT>
# Expect: 127.0.0.1:3000  (not 0.0.0.0:3000)

# Nếu app đang bind 0.0.0.0: rebind về 127.0.0.1 trong config app
# Ví dụ Node Express: app.listen(3000, '127.0.0.1')
# Ví dụ gunicorn: --bind 127.0.0.1:3000
# Ví dụ PM2: chỉnh script ecosystem
# Verify lại firewall UFW cũng deny port app từ ngoài (defense in depth)
```

**Vì sao bắt buộc 127.0.0.1:** nếu app bind 0.0.0.0, attacker có thể bypass oauth2-proxy bằng cách gọi thẳng `http://VPS_IP:3000`. UFW giúp nhưng không nên rely chỉ vào firewall.

## 8. Smoke test

```bash
# 1. oauth2-proxy listen
curl -sI http://127.0.0.1:4180/ping
# Expect: HTTP/1.1 200

# 2. Caddy TLS
curl -I https://myapp.company.com/
# Expect: HTTP/2 302 Location: /oauth2/start?...

# 3. Browser incognito → https://myapp.company.com/
# → redirect Zitadel login → MFA → quay lại app
```

---

## Sửa code app

Giống Docker template. App đọc header `X-Auth-Request-Email` từ request (Caddy + oauth2-proxy đã inject vào).

| Stack | Snippet |
|---|---|
| Next.js | `headers().get('x-auth-request-email')` |
| Express | `req.get('X-Auth-Request-Email')` |
| FastAPI | `Header(None)` dependency |
| Django | `RemoteUserMiddleware` |
| Flask | `request.headers.get('X-Auth-Request-Email')` |

Logout: `<a href="/oauth2/sign_out">Logout</a>`

---

## Files

```
.
├── README.md                       # File này
├── Caddyfile                       # Caddy reverse proxy + auto TLS
├── nginx-alternative.conf          # Nếu prefer nginx thay vì Caddy
└── scripts/
    ├── oauth2-proxy.service        # systemd unit cho oauth2-proxy
    └── install-native-stack.sh     # all-in-one install script
```

---

## Maintenance

### Update oauth2-proxy version
```bash
VER=v7.8.0   # version mới
curl -L -o oauth2-proxy.tar.gz \
  https://github.com/oauth2-proxy/oauth2-proxy/releases/download/${VER}/oauth2-proxy-${VER}.linux-amd64.tar.gz
tar xzf oauth2-proxy.tar.gz
sudo systemctl stop oauth2-proxy
sudo mv oauth2-proxy-*/oauth2-proxy /usr/local/bin/
sudo systemctl start oauth2-proxy
```

### Rotate cookie secret
```bash
NEW=$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)
sudo sed -i "s|^cookie_secret.*|cookie_secret = \"$NEW\"|" /etc/oauth2-proxy/config.cfg
sudo systemctl restart oauth2-proxy
# Lưu ý: rotate = tất cả user phải login lại (cookie cũ invalidate)
```

### Caddy auto-renew cert
Tự động, không cần thao tác. Check log: `sudo journalctl -u caddy | grep renew`.

---

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| `oauth2-proxy.service: Failed at step EXEC` | Verify binary có quyền exec: `sudo chmod +x /usr/local/bin/oauth2-proxy` |
| Caddy báo `tls: no certificates configured` | Đảm bảo DNS A record đã trỏ về VPS trước khi Caddy reload (LE phải verify được) |
| `502 Bad Gateway` từ Caddy | oauth2-proxy chưa start. `systemctl status oauth2-proxy` |
| `503` từ oauth2-proxy | App native chưa listen `127.0.0.1:PORT`. `ss -tlnp` verify |
| `redirect_uri mismatch` | Redirect URI trong Zitadel app KHÔNG khớp `https://<host>/oauth2/callback` |
| App nhận identity = null | Caddy stripping `X-Auth-*` không đúng thứ tự. Verify `request_header -X-Auth-Request-*` đứng TRƯỚC `reverse_proxy` trong Caddyfile |
| Browser cảnh báo cert | LE rate limit nếu test nhiều — dùng `acme.zerossl.com` staging trong Caddyfile khi test |

---

## So sánh với Docker template

| | Docker template | Native template (này) |
|---|---|---|
| Setup time | 30 phút | 1–2 giờ lần đầu |
| Components | Traefik + oauth2-proxy + app trong containers | Caddy + oauth2-proxy binary + app native |
| TLS | Self-signed lab / Traefik LE prod | Caddy LE auto |
| Update | `docker compose pull` | Manual download binary + apt upgrade caddy |
| Resource overhead | ~150 MB RAM | ~30 MB RAM (oauth2-proxy + Caddy) |
| Member skill | Docker basic | systemd + reverse proxy basic |
| Recommend cho | App mới / dockerized | App legacy không muốn dockerize |
