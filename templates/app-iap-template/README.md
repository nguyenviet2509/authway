# Authway App IAP Template

Template generic cho member migrate 1 app sang centralized auth qua Zitadel. Copy folder này lên VPS của bạn, fill 6 biến, chạy `docker compose up -d`.

App **KHÔNG cần** code OIDC. oauth2-proxy handle toàn bộ. App chỉ đọc header `X-Auth-Request-Email`.

---

## Pre-requisites

- 1 VPS Ubuntu 22.04 / 24.04 LTS, ≥1 GB RAM
- Quyền sudo
- Hostname đã thông báo cho ops admin để tạo OIDC app (vd `myapp.company.com`)
- Có `CLIENT_ID` + `CLIENT_SECRET` nhận từ ops
- DNS A record (production) hoặc `/etc/hosts` (lab) trỏ `APP_HOSTNAME` → IP VPS

---

## Quy trình tổng quan (10 bước)

1. SSH vào VPS + hardening
2. Cài Docker + compose plugin + tools
3. NTP sync (bắt buộc cho TOTP)
4. Stop web server cũ chiếm port 80/443
5. UFW firewall — chỉ allow VPN/subnet
6. Copy template folder vào `/opt/<app>`
7. Fill `.env`
8. Generate cookie secret + TLS cert (lab) hoặc bật Let's Encrypt (prod)
9. Pre-flight check
10. `docker compose up -d` + smoke test

---

## 1. SSH + hardening

```bash
ssh you@your-vps.com

# Tạo user ops riêng (tránh dùng root daily)
sudo adduser opsuser && sudo usermod -aG sudo opsuser
# Copy SSH key cho opsuser, disable password login trong /etc/ssh/sshd_config:
#   PasswordAuthentication no
#   PermitRootLogin no
sudo systemctl restart ssh

# Fix sudo hostname warning
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts
```

## 2. Cài Docker + tools

```bash
# Docker CE chính thức (tránh docker-compose-v2 conflict với docker.io)
curl -fsSL https://get.docker.com | sudo sh
sudo apt install -y docker-compose-plugin git curl jq openssl

# Đưa user vào group docker (không cần sudo cho docker)
sudo usermod -aG docker $USER
newgrp docker
docker ps   # verify chạy được không cần sudo

# Verify min API version compatible với Traefik
docker version | grep -E 'API version|minimum'
# Nếu Traefik báo "client API too old":
#   echo '{"min-api-version": "1.24"}' | sudo tee /etc/docker/daemon.json
#   sudo systemctl restart docker
```

## 3. NTP sync

```bash
sudo timedatectl set-ntp true
timedatectl status   # verify "System clock synchronized: yes"
```

**Vì sao:** TOTP code phụ thuộc đồng hồ. Lệch >30s = MFA fail toàn bộ user.

## 4. Stop web server cũ chiếm 80/443

```bash
sudo ss -tlnp | grep -E ':80 |:443 '

# Stop + disable + mask để không tự restart
sudo systemctl stop nginx apache2 lsws openlitespeed 2>/dev/null
sudo systemctl disable nginx apache2 lsws openlitespeed 2>/dev/null
sudo systemctl mask nginx apache2 lsws openlitespeed 2>/dev/null
sudo pkill -9 nginx litespeed lsphp 2>/dev/null

# Verify port free
sudo ss -tlnp | grep -E ':80 |:443 '   # → không thấy gì
```

## 5. UFW firewall

```bash
# Chỉ allow VPN subnet (thay <VPN_CIDR> bằng subnet OpenVPN/Tailscale)
VPN_CIDR="10.8.0.0/24"

sudo ufw allow from $VPN_CIDR to any port 22 proto tcp
sudo ufw allow from $VPN_CIDR to any port 80 proto tcp
sudo ufw allow from $VPN_CIDR to any port 443 proto tcp
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

**Defense in depth:** App phía sau OpenVPN + IAP. Network layer chặn before identity layer kicks in.

## 6. Copy template lên VPS

```bash
# Tạo folder app
sudo mkdir -p /opt/myapp && sudo chown $USER:$USER /opt/myapp
cd /opt/myapp

# Option A: clone từ git repo Authway
git clone https://github.com/<org>/authway.git /tmp/authway
cp -r /tmp/authway/templates/app-iap-template/* /tmp/authway/templates/app-iap-template/.env.example \
      /tmp/authway/templates/app-iap-template/.gitignore .
rm -rf /tmp/authway

# Option B: scp từ máy local
# scp -r ./templates/app-iap-template/ you@your-vps.com:/opt/myapp/

# Option C: rsync (giữ permissions)
# rsync -av templates/app-iap-template/ you@your-vps.com:/opt/myapp/

# Verify cấu trúc
ls -la
# Expect: README.md, docker-compose.yml, .env.example, .gitignore,
#         traefik.yml, dynamic/, scripts/, tls/
```

## 7. Fill `.env`

```bash
cp .env.example .env
nano .env
```

Điền 6 biến (chi tiết comment trong `.env.example`):

```dotenv
APP_HOSTNAME=myapp.company.com
APP_IMAGE=ghcr.io/team/myapp:latest      # hoặc build local
APP_PORT=3000
ZITADEL_ISSUER_URL=https://auth.company.com
ZITADEL_HOSTNAME=auth.company.com
APP_CLIENT_ID=<từ ops>
APP_CLIENT_SECRET=<từ ops>
# APP_COOKIE_SECRET tự generate ở bước 8
# ZITADEL_IP=<auth-vps-ip>   # chỉ cần khi lab self-signed
TLS_MODE=lab                  # đổi thành `prod` khi production
```

**KHÔNG để inline comment sau `=`** — parser `.env` tính toàn bộ phần sau `=` là value (bao gồm `# comment`).

```bash
# Lock permission
chmod 600 .env
```

## 8. Generate cookie secret + TLS cert

### 8a. Cookie secret

```bash
bash scripts/gen-secrets.sh
# → APP_COOKIE_SECRET generated (32 chars) trong .env
```

### 8b. TLS cert

**Lab (self-signed):**

```bash
mkdir -p tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls/app.key -out tls/app.crt \
  -subj "/CN=${APP_HOSTNAME:-myapp.company.com}" \
  -addext "subjectAltName=DNS:${APP_HOSTNAME:-myapp.company.com}"
chmod 600 tls/app.key
```

Trust cert trên máy client để browser không cảnh báo:
- Linux/Mac: `sudo cp tls/app.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`
- Windows admin: `Import-Certificate -FilePath app.crt -CertStoreLocation Cert:\LocalMachine\Root`

**Production (Let's Encrypt):**

1. Uncomment block `certificatesResolvers.le` trong `traefik.yml`, set email + DNS provider
2. Provider API token vào `.env` (vd `CF_DNS_API_TOKEN=...`)
3. Update label trong `docker-compose.yml` thêm `traefik.http.routers.app.tls.certresolver=le`
4. Xoá file `tls/app.crt` + `tls/app.key` (Traefik dùng ACME storage)
5. Set `TLS_MODE=prod` trong `.env`

## 9. DNS / hosts mapping

**Production:** DNS A record `myapp.company.com` → IP VPS (qua provider DNS panel).

**Lab:** `/etc/hosts` trên VPS + tất cả máy client:

```bash
# Trên VPS:
echo "127.0.0.1 ${APP_HOSTNAME}" | sudo tee -a /etc/hosts

# Trên client (Linux/Mac):
echo "<VPS_IP> myapp.company.com" | sudo tee -a /etc/hosts

# Trên client (Windows admin):
# Add to C:\Windows\System32\drivers\etc\hosts: <VPS_IP> myapp.company.com
```

Container oauth2-proxy resolve Zitadel hostname qua `extra_hosts` trong `docker-compose.yml` (đã có sẵn). Production có DNS thật → comment block `extra_hosts`.

## 10. Pre-flight + deploy

```bash
bash scripts/verify-setup.sh
# Verify 8 check pass (hoặc warning chấp nhận được)

docker compose pull
docker compose up -d
docker compose ps

# Tail log oauth2-proxy đợi sẵn sàng
docker compose logs -f oauth2-proxy
# Expect: "OAuthProxy configured for OpenID Connect Client ID: ..."
# Ctrl+C khi thấy "Listening on 0.0.0.0:4180"
```

### Smoke test

```bash
# 1. Traefik routing
curl -ksI https://${APP_HOSTNAME}/
# Expect: HTTP/2 302 Location: /oauth2/start?...

# 2. OIDC discovery resolve OK
docker compose exec oauth2-proxy wget -qO- ${ZITADEL_ISSUER_URL}/.well-known/openid-configuration | head -3

# 3. Browser e2e
# Mở incognito: https://myapp.company.com/
# → redirect Zitadel login → MFA → quay lại app, hiển thị identity
```

### systemd auto-restart (production)

```bash
sudo tee /etc/systemd/system/myapp.service >/dev/null <<EOF
[Unit]
Description=MyApp IAP stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/myapp
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable myapp.service
```

---

## Sửa code app như thế nào?

App phải đọc HTTP header `X-Auth-Request-Email` để biết user.

| Stack | Snippet |
|---|---|
| Next.js (App Router) | `const email = headers().get('x-auth-request-email')` |
| Express | `app.use((req,res,next)=>{const e=req.get('X-Auth-Request-Email');if(!e)return res.status(401).end();req.user={email:e};next()})` |
| FastAPI | `def get_user(x_auth_request_email: str = Header(None)):` |
| Django | `RemoteUserMiddleware` + map header → REMOTE_USER |
| Flask | `@app.before_request: g.user_email = request.headers.get('X-Auth-Request-Email')` |
| Streamlit ≥1.37 | `email = st.context.headers.get('X-Auth-Request-Email')` |

Logout link: `<a href="/oauth2/sign_out">Logout</a>`

Chi tiết theo nhóm app (A/B/C/Shared): xem `mockups/authway-app-migration-guide.html`.

---

## Cấu trúc folder template

```
.
├── README.md                      # File này
├── docker-compose.yml             # Traefik + oauth2-proxy + app
├── .env.example                   # Template env, copy → .env
├── .gitignore                     # Loại trừ .env + tls/
├── traefik.yml                    # Traefik static config
├── dynamic/middlewares.yml        # strip-auth-in + security-headers
├── scripts/
│   ├── gen-secrets.sh             # Generate COOKIE_SECRET
│   └── verify-setup.sh            # Pre-flight 8-check
└── tls/                           # TLS certs (gitignored)
```

---

## Update template về sau

Khi ops admin update template (vd thêm middleware mới, bump version Traefik/oauth2-proxy):

```bash
cd /opt/myapp

# Backup .env trước
cp .env .env.bak

# Pull template mới
git pull   # nếu deploy qua git
# hoặc rsync lại từ source

# .env không bị overwrite (đã trong .gitignore)
docker compose pull
docker compose up -d
```

---

## Troubleshooting

| Triệu chứng | Root cause | Fix |
|---|---|---|
| `ERR_TOO_MANY_REDIRECTS` | `--cookie-secure=true` nhưng request không HTTPS, hoặc `APP_HOSTNAME` không khớp URL browser | Verify HTTPS + match exact hostname |
| oauth2-proxy `tls: failed to verify certificate` | Zitadel cert self-signed (lab) | Compose đã có `--ssl-insecure-skip-verify=true`. Production phải xoá flag + dùng cert thật |
| `redirect_uri mismatch` lúc login | Redirect URI trong Zitadel app khác URL oauth2-proxy gọi | Set EXACT `https://<APP_HOSTNAME>/oauth2/callback` trong Zitadel console |
| App nhận identity = null/missing | Traefik route trỏ thẳng app port thay vì oauth2-proxy:4180 | Verify `traefik.http.services.app.loadbalancer.server.port=4180` |
| oauth2-proxy `lookup auth.company.com: no such host` | Container không resolve được Zitadel | Thêm `extra_hosts: ZITADEL_HOSTNAME:ZITADEL_IP` trong compose (lab), hoặc DNS thật |
| `missing setting: cookie-secret` | `.env` `APP_COOKIE_SECRET` empty | Chạy `bash scripts/gen-secrets.sh` |
| `.env` value bị cắt ngắn | Inline comment `#` sau `=` | KHÔNG để comment cùng dòng với value |
| Traefik dashboard 8088 accessible từ ngoài | Bind 0.0.0.0:8088 thay vì 127.0.0.1 | Compose đã set `127.0.0.1:8088:8080`, verify lại |
| Browser cache login state lung tung | HSTS + Service Worker cũ | DevTools → Application → Clear site data, hoặc dùng incognito |
| MFA code "invalid" liên tục | NTP chưa sync, đồng hồ lệch | `sudo timedatectl set-ntp true` đợi `synchronized: yes` |
| `client version 1.24 is too old. Minimum 1.40` | Daemon API min quá cao với Traefik | Compose đã set `DOCKER_API_VERSION: "1.43"`, hoặc add `min-api-version` trong `/etc/docker/daemon.json` |
| `WebAuthn not supported on sites with TLS certificate errors` | Self-signed cert block Passkey | Dùng TOTP cho lab. Production cert thật thì OK |

Chi tiết hơn: `docs/lab-deploy-192-168-122-54.md` section "Troubleshooting".

---

## Rollback

Nếu sau khi enable IAP mà app không work, tạm rollback về truy cập trực tiếp:

```bash
cd /opt/myapp
docker compose down

# Backup compose hiện tại
cp docker-compose.yml docker-compose.iap.yml.bak

# Tạm dùng compose đơn giản chỉ có Traefik → app (KHÔNG oauth2-proxy)
# Khi đó app sẽ KHÔNG có auth — chỉ dùng trong khẩn cấp, qua VPN
# Khôi phục IAP khi đã fix issue:
cp docker-compose.iap.yml.bak docker-compose.yml
docker compose up -d
```

Cảnh báo: rollback = mất MFA + per-user audit. Chỉ dùng tạm thời. Có quy trình breakglass chính thức trong production hardening plan.

---

## Quick reset (POC, chưa có data thật)

```bash
cd /opt/myapp
docker compose down -v   # XOÁ volume — mất hết
bash scripts/gen-secrets.sh
docker compose up -d
```
