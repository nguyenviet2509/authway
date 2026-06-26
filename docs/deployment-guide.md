# Deployment Guide — Authway Zitadel Gateway (Lab)

> Hướng dẫn deploy + smoke test cho centralized auth gateway dùng **Zitadel** (auth server) + **oauth2-proxy** sidecar (IAP pattern) trên lab nội bộ.
> Plan tham chiếu: [plans/260626-1154-zitadel-iap-rollout/plan.md](../plans/260626-1154-zitadel-iap-rollout/plan.md).

## 1. Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAB SUBNET 192.168.122.0/24                                        │
│                                                                     │
│   auth-server (192.168.122.54) — Zitadel Central                    │
│   ─ docker compose stack:                                           │
│       traefik     : 80, 443 (tls internal, IP whitelist subnet)     │
│       zitadel     : 8080 (internal, sau traefik /)                  │
│       postgres    : 5432 (127.0.0.1)                                │
│                                                                     │
│   app-vps-N (192.168.122.5x) — App phía sau IAP                     │
│   ─ docker compose stack:                                           │
│       traefik     : 80, 443                                         │
│       oauth2-proxy: 4180 (internal)                                 │
│       app(s)      : (Next.js / static HTML / Streamlit)             │
│                                                                     │
│   Flow login:                                                       │
│       browser → traefik (app-vps) → oauth2-proxy → ↩ redirect       │
│              → traefik (auth-server) → zitadel login + MFA          │
│              → callback → oauth2-proxy sets cookie                  │
│              → app reads X-Auth-Request-Email header                │
└─────────────────────────────────────────────────────────────────────┘
```

Lab mode quyết định:
- **No public DNS / Let's Encrypt** → Traefik dùng `tls.certResolver=internal` (self-signed) cho lab.
- **No public IdP** → Zitadel chứa local users, admin tạo thủ công, MFA bắt buộc.
- **IP whitelist** subnet 192.168.122.0/24 + VPN giữ song song (defense in depth).
- Domain pattern dùng `auth.authway.lab` + `/etc/hosts` (lab) thay vì DNS thật. Production sau chuyển sang domain công ty.

---

## 2. Pre-requisites mỗi VM

Ubuntu 22.04/24.04 LTS, cho cả auth-server và app-vps:

```bash
sudo apt-get update
sudo apt-get install -y curl wget git ca-certificates ufw jq
sudo timedatectl set-timezone Asia/Saigon
```

NTP sync (bắt buộc — token JWT timestamp lệch sẽ reject):
```bash
sudo apt-get install -y chrony && sudo systemctl enable --now chrony
chronyc tracking | head -3
```

DNS lab (nếu chưa có DNS resolver nội bộ), thêm `/etc/hosts` trên **tất cả VM + workstation dev**:
```
192.168.122.54  auth.authway.lab
```

---

## 3. Deploy auth-server (192.168.122.54)

### 3.1 SSH + hardening

```bash
ssh root@192.168.122.54
adduser authops && usermod -aG sudo authops
# copy ssh key cho authops, disable password login /etc/ssh/sshd_config:
#   PasswordAuthentication no
sudo systemctl restart ssh
```

### 3.2 Docker + UFW + Docker group

```bash
# Docker CE chính thức (Ubuntu 24.04: tránh docker-compose-v2 / docker.io conflict)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# UFW: chỉ cho subnet lab
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.122.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.122.0/24 to any port 80 proto tcp
sudo ufw allow from 192.168.122.0/24 to any port 443 proto tcp
sudo ufw enable
sudo ufw status verbose
```

### 3.3 Clone repo + thư mục state

```bash
sudo mkdir -p /opt/authway && sudo chown authops:authops /opt/authway
cd /opt/authway
git clone <repo-url> .
mkdir -p data/postgres data/zitadel-keys backup
chmod 700 data/zitadel-keys
```

### 3.4 Generate secrets

```bash
# Masterkey Zitadel (BẮT BUỘC, lưu Bitwarden/1Password)
openssl rand -base64 32

# Postgres password
openssl rand -hex 24
```

Paste vào `infra/auth-server/.env` (copy từ `.env.example`):
```env
# Domain
ZITADEL_EXTERNALDOMAIN=auth.authway.lab
ZITADEL_EXTERNALSECURE=true
ZITADEL_EXTERNALPORT=443
ZITADEL_TLS_ENABLED=false       # TLS terminate ở Traefik

# Masterkey (paste output openssl)
ZITADEL_MASTERKEY=<paste>

# Postgres
POSTGRES_USER=zitadel
POSTGRES_PASSWORD=<paste>
POSTGRES_DB=zitadel

# Admin bootstrap (đổi password ngay sau login lần đầu)
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=root
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=ChangeMeFirst!2026
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL=admin@authway.lab

# Subnet whitelist (Traefik middleware)
ALLOWED_CIDR=192.168.122.0/24
```

### 3.5 docker-compose.yml (auth-server)

File `infra/auth-server/docker-compose.yml`:
```yaml
services:
  traefik:
    image: traefik:v3.2
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.directory=/etc/traefik/dynamic
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.internal.acme.tlschallenge=true
      - --certificatesresolvers.internal.acme.email=admin@authway.lab
      - --certificatesresolvers.internal.acme.storage=/letsencrypt/acme.json
      # Lab: self-signed thay vì LE thật (không có public DNS)
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./data/letsencrypt:/letsencrypt

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes: ["./data/postgres:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 5

  zitadel:
    image: ghcr.io/zitadel/zitadel:v2.66
    restart: unless-stopped
    command: 'start-from-init --masterkey "${ZITADEL_MASTERKEY}" --tlsMode disabled'
    depends_on:
      postgres: { condition: service_healthy }
    environment:
      ZITADEL_DATABASE_POSTGRES_HOST: postgres
      ZITADEL_DATABASE_POSTGRES_PORT: 5432
      ZITADEL_DATABASE_POSTGRES_DATABASE: ${POSTGRES_DB}
      ZITADEL_DATABASE_POSTGRES_USER_USERNAME: ${POSTGRES_USER}
      ZITADEL_DATABASE_POSTGRES_USER_PASSWORD: ${POSTGRES_PASSWORD}
      ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE: disable
      ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME: ${POSTGRES_USER}
      ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD: ${POSTGRES_PASSWORD}
      ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE: disable
      ZITADEL_EXTERNALDOMAIN: ${ZITADEL_EXTERNALDOMAIN}
      ZITADEL_EXTERNALPORT: ${ZITADEL_EXTERNALPORT}
      ZITADEL_EXTERNALSECURE: ${ZITADEL_EXTERNALSECURE}
      ZITADEL_TLS_ENABLED: ${ZITADEL_TLS_ENABLED}
      ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME: ${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME}
      ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD: ${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD}
      ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL: ${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL}
    labels:
      - traefik.enable=true
      - traefik.http.routers.zitadel.rule=Host(`${ZITADEL_EXTERNALDOMAIN}`)
      - traefik.http.routers.zitadel.entrypoints=websecure
      - traefik.http.routers.zitadel.tls=true
      - traefik.http.routers.zitadel.middlewares=ipwhitelist@file
      - traefik.http.services.zitadel.loadbalancer.server.port=8080
      - traefik.http.services.zitadel.loadbalancer.server.scheme=h2c
```

File `infra/auth-server/traefik/dynamic/middlewares.yml`:
```yaml
http:
  middlewares:
    ipwhitelist:
      ipAllowList:
        sourceRange:
          - 192.168.122.0/24
    security-headers:
      headers:
        stsSeconds: 31536000
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: strict-origin-when-cross-origin
```

### 3.6 Khởi động stack

```bash
cd /opt/authway/infra/auth-server
docker compose pull
docker compose up -d
docker compose ps
```

Kỳ vọng (3 service):
```
traefik     running
postgres    healthy
zitadel     running
```

Tail log nếu zitadel restart:
```bash
docker compose logs -f --tail=200 zitadel
```

### 3.7 Login lần đầu + bind Passkey

1. Mở https://auth.authway.lab (accept self-signed warning)
2. Login: `root` / `ChangeMeFirst!2026`
3. **Đổi password ngay** (Settings → Personal Info → Change Password)
4. **Bind Passkey** (Settings → Multi-Factor → Add Passkey/U2F)
5. Logout, login lại → verify MFA prompt

### 3.8 Bật Force MFA cho cả org

Default Settings → Login Behavior and Access → Login Policy:
- Force MFA = **ON**
- Allowed Second Factors: **OTP**, **U2F (Passkey)**
- Multi-factor Init Lifetime: 1 day

Tạo user thứ 2 (test), login lần đầu → verify bị buộc setup MFA.

### 3.9 systemd auto-restart

```bash
sudo tee /etc/systemd/system/authway.service >/dev/null <<EOF
[Unit]
Description=Authway Zitadel stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/authway/infra/auth-server
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=authops

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable authway.service
```

### 3.10 Backup daily

```bash
sudo tee /opt/authway/infra/auth-server/scripts/backup-postgres.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TS=$(date +%Y%m%d-%H%M)
DEST=/opt/authway/backup
mkdir -p "$DEST"
docker compose -f /opt/authway/infra/auth-server/docker-compose.yml exec -T postgres \
  pg_dump -U zitadel -d zitadel --format=custom \
  > "$DEST/zitadel-$TS.dump"
find "$DEST" -name 'zitadel-*.dump' -mtime +30 -delete
EOF
chmod +x /opt/authway/infra/auth-server/scripts/backup-postgres.sh

(crontab -l 2>/dev/null; echo "0 2 * * * /opt/authway/infra/auth-server/scripts/backup-postgres.sh >> /var/log/authway-backup.log 2>&1") | crontab -

# Smoke test ngay
bash /opt/authway/infra/auth-server/scripts/backup-postgres.sh
ls -lh /opt/authway/backup/
```

Restore test (vào staging container riêng) — định kỳ tháng 1 lần.

---

## 4. Cấu hình app-vps (downstream)

Pattern Identity-Aware Proxy: mỗi VPS có Traefik + oauth2-proxy + app(s). App đọc header `X-Auth-Request-Email` thay vì code OIDC.

### 4.1 Tạo OIDC Application trong Zitadel

Console https://auth.authway.lab → Projects → "internal-apps" → New Application:
- Name: `app-${slug}` (vd `app-server-mgmt`)
- Type: **Web**
- Authentication Method: **Code** + PKCE
- Redirect URIs: `https://${APP_HOSTNAME}/oauth2/callback`
- Post-logout URIs: `https://${APP_HOSTNAME}/`

Note xuống: `client_id`, `client_secret`, discovery URL `https://auth.authway.lab/.well-known/openid-configuration`.

### 4.2 Stack template trên app-vps

Pre-requisites giống section 2 (Docker, UFW, NTP, /etc/hosts mapping auth.authway.lab).

File `docker-compose.yml`:
```yaml
services:
  traefik:
    image: traefik:v3.2
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.directory=/etc/traefik/dynamic
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.websecure.address=:443
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    restart: unless-stopped
    command:
      - --provider=oidc
      - --oidc-issuer-url=https://auth.authway.lab
      - --client-id=${ZITADEL_CLIENT_ID}
      - --client-secret=${ZITADEL_CLIENT_SECRET}
      - --cookie-secret=${COOKIE_SECRET}
      - --cookie-domain=.authway.lab
      - --cookie-secure=true
      - --whitelist-domain=.authway.lab
      - --email-domain=*
      - --reverse-proxy=true
      - --set-xauthrequest=true
      - --pass-access-token=false
      - --skip-provider-button=true
      - --upstream=static://200
      - --redirect-url=https://${APP_HOSTNAME}/oauth2/callback
      - --ssl-insecure-skip-verify=true    # lab: Zitadel dùng self-signed
    labels:
      - traefik.enable=true
      - traefik.http.routers.oauth2.rule=Host(`${APP_HOSTNAME}`) && PathPrefix(`/oauth2/`)
      - traefik.http.routers.oauth2.entrypoints=websecure
      - traefik.http.routers.oauth2.tls=true
      - traefik.http.services.oauth2.loadbalancer.server.port=4180

  app:
    image: ${APP_IMAGE}
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - traefik.http.routers.app.rule=Host(`${APP_HOSTNAME}`)
      - traefik.http.routers.app.entrypoints=websecure
      - traefik.http.routers.app.tls=true
      - traefik.http.routers.app.middlewares=strip-auth-in@file,iap-auth@file
      - traefik.http.services.app.loadbalancer.server.port=${APP_PORT}
```

File `traefik/dynamic/middlewares.yml`:
```yaml
http:
  middlewares:
    strip-auth-in:
      headers:
        customRequestHeaders:
          X-Auth-Request-User: ""
          X-Auth-Request-Email: ""
          X-Auth-Request-Preferred-Username: ""
          X-Auth-Request-Access-Token: ""
    iap-auth:
      forwardAuth:
        address: http://oauth2-proxy:4180/oauth2/auth
        trustForwardHeader: true
        authResponseHeaders:
          - X-Auth-Request-User
          - X-Auth-Request-Email
          - X-Auth-Request-Preferred-Username
    ipwhitelist:
      ipAllowList:
        sourceRange:
          - 192.168.122.0/24
```

Chú ý middleware chain: `strip-auth-in → iap-auth → app`. `strip-auth-in` xoá header từ client (chống spoof) **trước khi** `iap-auth` gọi oauth2-proxy.

Error redirect khi 401: oauth2-proxy tự handle qua route `Host=... && PathPrefix=/oauth2/` — Traefik forwardAuth nhận 401 → browser redirect tới `/oauth2/start`.

File `.env`:
```env
APP_HOSTNAME=server-mgmt.authway.lab
APP_IMAGE=ghcr.io/team/server-mgmt:latest
APP_PORT=3000
ZITADEL_CLIENT_ID=<from-zitadel>
ZITADEL_CLIENT_SECRET=<from-zitadel>
COOKIE_SECRET=<openssl rand -base64 32>
```

### 4.3 Hostname mapping

Thêm vào `/etc/hosts` trên app-vps + workstation dev:
```
192.168.122.54  auth.authway.lab
192.168.122.5x  server-mgmt.authway.lab
```

### 4.4 Khởi động + verify

```bash
docker compose up -d
docker compose ps
docker compose logs -f --tail=100 oauth2-proxy
```

Browser: `https://server-mgmt.authway.lab` → redirect Zitadel login → MFA → callback → app load.

---

## 5. Smoke tests (theo thứ tự)

### 5.1 Zitadel health

```bash
curl -fsS -k https://auth.authway.lab/debug/ready && echo " Zitadel OK"
docker exec -it authway-postgres pg_isready -U zitadel
```

### 5.2 Login flow auth-server

- Mở `https://auth.authway.lab` từ máy trong subnet
- Login với user test → buộc MFA prompt
- Logout → quay lại login → MFA prompt lần nữa
- Truy cập từ máy ngoài subnet (4G/khác mạng) → **phải bị block** (IP whitelist)

### 5.3 OIDC discovery

```bash
curl -fsS -k https://auth.authway.lab/.well-known/openid-configuration | jq .issuer
```
Kỳ vọng: `"issuer": "https://auth.authway.lab"`.

### 5.4 IAP flow end-to-end (sample app)

Deploy 1 sample app static HTML theo template section 4 với hostname `demo.authway.lab`.

- Browser mở `https://demo.authway.lab` → redirect `https://auth.authway.lab/oauth2/...` → login + MFA → callback → cookie set → page load.
- Verify header propagation:
  ```bash
  # Vào shell app container
  docker exec -it <app-container> sh
  # Trong app, log incoming headers; reload page; thấy:
  # X-Auth-Request-Email: user@authway.lab
  # X-Auth-Request-User: <zitadel-subject-uuid>
  ```

### 5.5 SSO giữa 2 app

- Login `demo.authway.lab` xong, KHÔNG logout
- Mở tab mới `https://demo2.authway.lab` (sample thứ 2 cùng cookie domain)
- Kỳ vọng: vào thẳng app2 không bị login lại

### 5.6 Header spoofing test (CRITICAL security check)

Từ workstation (trong subnet whitelist), gửi request kèm header giả:
```bash
curl -k -v "https://demo.authway.lab/" \
  -H "X-Auth-Request-Email: attacker@x.com" \
  -H "X-Auth-Request-User: 999999"
```
Kỳ vọng: Hoặc 401 redirect login (nếu chưa có cookie), HOẶC nếu có cookie thì header `X-Auth-Request-Email` upstream nhận được phải là user thật, **KHÔNG phải** `attacker@x.com`. Strip middleware phải làm việc.

Để chắc chắn, log header trong app:
```bash
docker compose logs app | grep "X-Auth-Request-Email"
```

### 5.7 Logout flow

`https://demo.authway.lab/oauth2/sign_out?rd=https://auth.authway.lab/oidc/v1/end_session`
→ oauth2-proxy clear cookie → redirect Zitadel logout → session terminate.

### 5.8 Audit log

Zitadel Console → Events → filter user → verify thấy entries: login, MFA verified, token issued, logout.

---

## 6. Verification checklist

- [ ] auth-server ping được từ subnet, không ping được từ ngoài subnet
- [ ] NTP sync trên cả auth-server và app-vps (drift < 1s)
- [ ] `docker compose ps` trên auth-server: 3/3 service healthy
- [ ] Zitadel login `root` đổi password + bind Passkey
- [ ] Force MFA policy ON, user thứ 2 bị buộc setup MFA lần đầu
- [ ] IP whitelist verified: ngoài subnet → 403/connection refused
- [ ] OIDC discovery JSON trả về issuer đúng
- [ ] Sample app static IAP flow OK
- [ ] SSO giữa 2 app cùng domain OK
- [ ] Header spoof test: incoming X-Auth-* bị strip
- [ ] Logout terminate session ở cả oauth2-proxy + Zitadel
- [ ] Audit log có entry login/MFA/token
- [ ] `systemctl status authway` enabled, restart-on-boot OK
- [ ] Backup script chạy không lỗi, file `zitadel-YYYYMMDD-HHMM.dump` xuất hiện
- [ ] Restore khô (staging) thành công, data đúng

---

## 7. Troubleshooting nhanh

| Triệu chứng | Check | Fix |
|---|---|---|
| Zitadel restart loop với `cannot reach database` | postgres healthy? credentials match? | `docker compose logs postgres`; verify `.env` POSTGRES_PASSWORD đồng bộ giữa cả 2 service |
| `ERR_TOO_MANY_REDIRECTS` khi login | Traefik HTTPS redirect loop hoặc Zitadel nghĩ là HTTP | Set `ZITADEL_EXTERNALSECURE=true`, `ZITADEL_EXTERNALPORT=443`, Traefik `tls=true` cho router |
| Login OK nhưng app báo 401 forever | oauth2-proxy không set cookie domain đúng | `--cookie-domain=.authway.lab` (leading dot); cookie-secure=true; truy cập qua HTTPS |
| oauth2-proxy log `tls: failed to verify certificate` | Lab self-signed, oauth2-proxy strict TLS | Thêm `--ssl-insecure-skip-verify=true` (chỉ lab, production phải có CA hợp lệ) |
| Browser warning self-signed | Lab dùng `tls internal` | Accept exception; production thay bằng domain + LE thật |
| Header `X-Auth-Request-Email` không thấy trong app | Middleware chain sai thứ tự hoặc thiếu `authResponseHeaders` | Verify `iap-auth.forwardAuth.authResponseHeaders` listed + middleware chain `strip-auth-in,iap-auth` (không phải ngược lại) |
| Spoof test pass (header attacker không bị strip) | `strip-auth-in` không đứng TRƯỚC `iap-auth` | Sửa thứ tự middleware chain trong label router |
| Login Zitadel báo "device is not registered" mỗi lần | Cookie session bị clear | Check browser block 3rd-party cookies; auth.authway.lab và app phải cùng parent domain |
| User mới tạo không login được lần đầu | Verify email/password reset chưa hoàn tất | Zitadel Console → Users → resend verification, hoặc skip verify trong dev |
| Lab → workstation dev không vào được auth.authway.lab | DNS hoặc /etc/hosts thiếu | Thêm `192.168.122.54 auth.authway.lab` vào hosts; ping verify |
| Backup script báo `pg_dump: connection refused` | Postgres bind 127.0.0.1, hoặc compose context sai | Dùng `docker compose exec postgres` thay vì `pg_dump` từ host |
| docker compose label Traefik không pickup | Service không cùng network với traefik | Mặc định docker-compose tạo network chung; verify `docker network inspect` |
| MFA Passkey không setup được trên Firefox | Firefox WebAuthn cần HTTPS + valid origin | Lab HTTPS self-signed OK, nhưng phải accept exception trước; Chrome dễ hơn |

Log tổng hợp:
```bash
docker compose -f /opt/authway/infra/auth-server/docker-compose.yml logs --since=10m | grep -iE 'error|panic|fatal'
```

---

## 8. Rollback / cleanup

```bash
# Dừng stack giữ data
cd /opt/authway/infra/auth-server
docker compose down

# Xoá toàn bộ data (CẨN THẬN, mất hết user + audit log)
docker compose down -v
sudo rm -rf /opt/authway/data/postgres /opt/authway/data/zitadel-keys

# Khôi phục từ backup
docker compose up -d postgres
docker compose exec -T postgres pg_restore -U zitadel -d zitadel --clean --if-exists \
  < /opt/authway/backup/zitadel-YYYYMMDD-HHMM.dump
docker compose up -d zitadel
```

Trên app-vps (rollback về IP whitelist only):
```bash
cd /opt/<app>/infra
# Comment các middleware iap-auth, strip-auth-in trong router labels
docker compose up -d
# Hoặc:
docker compose down && switch về compose file cũ
```

---

## 9. Lab → Production checklist

- [ ] Thay `auth.authway.lab` + self-signed bằng domain công ty + Let's Encrypt (DNS-01 nếu domain nội bộ)
- [ ] Bật `ZITADEL_TLS_ENABLED=true` hoặc giữ Traefik terminate TLS (depends on cert chain)
- [ ] Force MFA enforcement audit: 100% user có Passkey hoặc TOTP đăng ký
- [ ] oauth2-proxy: gỡ `--ssl-insecure-skip-verify`, dùng valid CA
- [ ] Backup offsite (rsync ra NAS hoặc upload MinIO/S3) thay vì local-only
- [ ] HA: Zitadel chạy ≥2 replica, Postgres managed (HA hoặc replication)
- [ ] Monitoring: Prometheus scrape Zitadel metrics + oauth2-proxy metrics; alert qua Telegram/PagerDuty
- [ ] Audit log shipping ra log central (OneLog?) để retention dài + correlation
- [ ] Secret rotation policy: client_secret rotate 90 ngày qua Terraform/script
- [ ] Documented admin runbook: reset MFA, disable user, view audit, restore backup
- [ ] DR test: shutdown auth-server VM → workstation không vào app được; restore từ snapshot → app login lại OK
- [ ] Onboarding doc finalized cho dev tự deploy app mới (target <15 phút)

---

## 10. Unresolved questions

1. DNS lab — có resolver nội bộ (PowerDNS, Pi-hole) để bỏ `/etc/hosts` mỗi máy?
2. VPS auth spec hiện tại bao nhiêu RAM/CPU? Zitadel + Postgres ≥4 GB là khuyến nghị.
3. Backup offsite: có NAS / MinIO / S3 nội bộ subnet không, hay accept local-only giai đoạn POC?
4. M2M auth (cron job, CI/CD gọi internal API qua gateway): cần client_credentials trong POC không?
5. Audit log retention: giữ trong Zitadel Postgres bao lâu? Ship ra log central?
6. Offboarding workflow: ai chịu trách nhiệm disable user khi nhân viên nghỉ? SLA bao nhiêu?
7. Onboarding user mới: admin tạo qua UI hay viết script Terraform/API?
8. App migration playbook (Nhóm A vs B): tham chiếu [brainstorm-260626-1328-legacy-app-migration.md](../plans/reports/brainstorm-260626-1328-legacy-app-migration.md), phase nào nên migrate trước?
