# Lab Deploy Phase 02 — App VPS 192.168.122.55

Reference IAP stack: 2 oauth2-proxy + Next.js + static HTML, đứng trước bởi Traefik. Phase 02 của plan [zitadel-iap-rollout](../plans/260626-1154-zitadel-iap-rollout/phase-02-iap-reference.md).

**Pre-req**: Phase 01 đã deploy xong trên `192.168.122.54` và `https://auth.lab.local/.well-known/openid-configuration` trả 200.

---

## 0. Update 2 OIDC Application trong Zitadel (chạy 1 lần)

Trên browser đã trust cert auth.lab.local, login `https://auth.lab.local/ui/console`:

1. Console → Projects → `internal-apps` → Apps → **nextjs-demo** → Redirect Settings:
   - Redirect URI: `https://nextjs-demo.lab.local/oauth2/callback`
   - Post Logout Redirect URI: `https://nextjs-demo.lab.local/`
   - Save
2. App **static-demo** → Redirect Settings:
   - Redirect URI: `https://static-demo.lab.local/oauth2/callback`
   - Post Logout Redirect URI: `https://static-demo.lab.local/`
   - Save
3. Configuration tab cho mỗi app:
   - Authentication Method: **Basic** (cần client_secret cho oauth2-proxy)
   - Refresh Token: **enabled** (cookie-refresh)
   - Copy + lưu `Client ID` + `Client Secret` mỗi app vào password manager

## 1. Provision VPS-2 (192.168.122.55)

```bash
ssh vietnt@192.168.122.55

# Hostname fix
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts

# OS update + tools
sudo apt update && sudo apt upgrade -y
sudo apt install -y gettext-base git openssl curl

# Docker
curl -fsSL https://get.docker.com | sh
sudo apt install -y docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker

# NTP
sudo timedatectl set-ntp true

# Docker daemon min API (Traefik v3.4 OK)
# Nếu deploy thấy "client version too old" → daemon hardened:
#   echo '{"min-api-version": "1.24"}' | sudo tee /etc/docker/daemon.json
#   sudo systemctl restart docker

# Stop web server cũ chiếm 80/443
sudo ss -tlnp | grep -E ':80 |:443 '
sudo systemctl stop nginx apache2 lsws openlitespeed 2>/dev/null
sudo systemctl mask nginx apache2 lsws openlitespeed 2>/dev/null
sudo pkill -9 nginx litespeed lsphp 2>/dev/null

# Firewall — allow private subnet
sudo ufw allow from 192.168.122.0/24 to any port 80 proto tcp
sudo ufw allow from 192.168.122.0/24 to any port 443 proto tcp
sudo ufw allow from 192.168.122.0/24 to any port 22 proto tcp
sudo ufw default deny incoming
sudo ufw --force enable
```

## 2. /etc/hosts — VPS-2 phải resolve auth.lab.local

VPS-2 cần gọi tới Zitadel ở `auth.lab.local` (= 192.168.122.54):

```bash
echo "192.168.122.54 auth.lab.local" | sudo tee -a /etc/hosts
ping -c 1 auth.lab.local   # phải resolve về .54

# Test connectivity OIDC discovery
curl -ksI https://auth.lab.local/.well-known/openid-configuration
# Phải 200 OK
```

## 3. Clone repo + .env

```bash
sudo mkdir -p /opt/authway && sudo chown $USER:$USER /opt/authway
git clone https://github.com/nguyenviet2509/authway.git /opt/authway
cd /opt/authway/infra/app-vps

cp .env.example .env
nano .env
```

Fill `.env` với client_id/secret từ Zitadel (step 0):

```dotenv
ZITADEL_HOSTNAME=auth.lab.local
ZITADEL_ISSUER_URL=https://auth.lab.local

NEXTJS_HOSTNAME=nextjs-demo.lab.local
NEXTJS_CLIENT_ID=<paste từ Zitadel>
NEXTJS_CLIENT_SECRET=<paste từ Zitadel>
NEXTJS_COOKIE_SECRET=<sẽ generate ở dưới>

STATIC_HOSTNAME=static-demo.lab.local
STATIC_CLIENT_ID=<paste từ Zitadel>
STATIC_CLIENT_SECRET=<paste từ Zitadel>
STATIC_COOKIE_SECRET=<sẽ generate ở dưới>
```

Generate 2 cookie secret (oauth2-proxy yêu cầu đúng 16/24/32 bytes):

```bash
set +H
N1=$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-32)
N2=$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-32)
sed -i "s|NEXTJS_COOKIE_SECRET=.*|NEXTJS_COOKIE_SECRET=${N1}|" .env
sed -i "s|STATIC_COOKIE_SECRET=.*|STATIC_COOKIE_SECRET=${N2}|" .env
echo "NEXTJS_COOKIE_SECRET=${N1}"
echo "STATIC_COOKIE_SECRET=${N2}"

# Verify all required filled
grep -E '^(NEXTJS|STATIC)_(CLIENT_ID|CLIENT_SECRET|COOKIE_SECRET)=' .env | awk -F= '{print $1"="(length($2)>0?"<set>":"<EMPTY!!>")}'
```

## 4. Self-signed TLS cert (cover 2 app domain)

```bash
cd /opt/authway/infra/app-vps
chmod +x scripts/*.sh
bash scripts/generate-lab-cert.sh
# → tls/app.crt phục vụ cả nextjs-demo.lab.local + static-demo.lab.local
```

## 5. DNS / hosts trên máy client

Thêm 2 entry vào `hosts` file máy client (Windows: `C:\Windows\System32\drivers\etc\hosts`):

```
192.168.122.55 nextjs-demo.lab.local
192.168.122.55 static-demo.lab.local
```

(Đã có `192.168.122.54 auth.lab.local` từ phase 01.)

Verify từ client: `ping nextjs-demo.lab.local` → .55.

## 6. Trust cert app trên máy client (optional)

```powershell
# PowerShell (admin) trên Windows client
scp vietnt@192.168.122.55:/opt/authway/infra/app-vps/tls/app.crt $env:USERPROFILE\Desktop\authway-app.crt
Import-Certificate -FilePath "$env:USERPROFILE\Desktop\authway-app.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

Restart browser. (Hoặc skip + accept exception cho 2 domain.)

## 7. Bring up stack

```bash
cd /opt/authway/infra/app-vps
docker compose up -d --build   # --build vì có Dockerfile cho nextjs

# Theo dõi
docker compose ps
docker compose logs -f oauth2-proxy-nextjs
# Phải thấy: "OAuthProxy" started, no fatal errors
# Khi healthy → Ctrl+C

# Verify Traefik thấy routers
curl -s http://127.0.0.1:8088/api/http/routers | python3 -m json.tool | grep -E '"name"|"rule"' | head -30
# Phải thấy nextjs-app, nextjs-auth, static-app, static-auth
```

## 8. Test workflow end-to-end

### Test A: Login flow lần đầu

1. Browser (đã clear cookie cho `*.lab.local`): https://nextjs-demo.lab.local/
2. Expect redirect: → `auth.lab.local` login page
3. Login với admin Zitadel (đã setup ở phase 01) — MFA prompt
4. Sau MFA OK → redirect về `https://nextjs-demo.lab.local/`
5. **Trang Next.js hiển thị "Hello {email}"** ← workflow OK

### Test B: Zitadel session SSO (cross-app, cùng browser)

1. Đang login ở nextjs → mở tab mới: https://static-demo.lab.local/
2. Expect: redirect flash qua auth.lab.local → **không nhập password/MFA lại** (Zitadel session reuse)
3. Trang static hiển thị email qua `/oauth2/userinfo`

### Test C: Header spoof protection (red-team #2)

```bash
# Từ client, gửi request kèm X-Auth-Request-Email giả mạo (chưa login)
curl -ks https://nextjs-demo.lab.local/whoami -H "X-Auth-Request-Email: attacker@evil.com"
# Expect: redirect login (401 → /oauth2/start), KHÔNG return JSON với email giả mạo

# Từ trong VPS-2, bypass Traefik gọi thẳng app:
docker compose exec nextjs-demo wget -qO- http://localhost:3000/whoami
# Nếu app KHÔNG có middleware strip, header này sẽ pass through.
# Đây là lý do phải strip ở Traefik entrypoint (đã config), VÀ container không bind 0.0.0.0
```

### Test D: Logout chain

1. Click "Logout" trong app (hoặc gọi trực tiếp): https://nextjs-demo.lab.local/oauth2/sign_out?rd=https://auth.lab.local/oidc/v1/end_session
2. Expect: oauth2-proxy clear cookie → redirect Zitadel `end_session` → Zitadel clear session → redirect về app
3. Re-access app → buộc login + MFA lại (cookie + Zitadel session đều cleared)

### Test E: Cookie domain isolation

Open DevTools → Application → Cookies sau khi login:
- `nextjs-demo.lab.local` → có cookie `_oauth2_proxy_*` với Domain = `nextjs-demo.lab.local` (KHÔNG phải `.lab.local`)
- Tương tự cho static-demo
- → 2 cookie độc lập, không share (đúng pattern public-suffix-safe)

## 9. Smoke test checklist

- [ ] Both routers `nextjs-app@docker`, `static-app@docker` trong Traefik
- [ ] Login Test A pass (redirect → MFA → trang Next.js hiển thị email)
- [ ] Login Test B pass (SSO cross-app: redirect flash, no MFA)
- [ ] Spoof Test C: header giả mạo không pass
- [ ] Logout Test D: sign_out + end_session chain work
- [ ] Cookie Test E: 2 cookie domain riêng biệt, không share
- [ ] Static `/oauth2/userinfo` trả JSON với email đúng
- [ ] Next.js `/whoami` trả JSON với email đúng

## 10. Common issues

| Symptom | Fix |
|---|---|
| `oauth2-proxy: failed to validate `--cookie-secret` length 30, need 16, 24, 32` | Cookie secret bị tr-d strip mất ký tự < 32. Regenerate với `head -c 32` đảm bảo 32 chars |
| `oauth2-proxy: x509: certificate signed by unknown authority` khi gọi Zitadel | Self-signed cert. Đã set `--ssl-insecure-skip-verify=true` cho lab. Production: trust CA hoặc dùng cert thật |
| `redirect_uri mismatch` lúc login | Zitadel app config khác với `https://<HOSTNAME>/oauth2/callback`. Update step 0. |
| 404 sau login (callback) | Traefik router `*-auth` (PathPrefix `/oauth2`) bị conflict với app router. Verify priority=10 |
| Loop redirect Zitadel ↔ app | Cookie không set được (browser block cross-site). Check `Cookie-Secure` HTTPS, `SameSite` không bị quá strict |
| App page load OK nhưng email = `(missing)` | Header không inject. Check forwardAuth middleware `authResponseHeaders` config + Traefik logs |

---

## Khác biệt Lab vs Production cho phase 02

| Aspect | Lab | Production |
|---|---|---|
| Cert app | Self-signed cover cả 2 host | ACME per domain (DNS-01 với token mỗi parent) |
| `--ssl-insecure-skip-verify` oauth2-proxy | true (Zitadel self-signed) | false (Let's Encrypt cert thật) |
| App domain | `*.lab.local` qua /etc/hosts | TLD thật (`autossl.trungtq.io.vn`, etc.) |
| Cookie domain | exact match `nextjs-demo.lab.local` | exact match app hostname |
| oauth2-proxy `--cookie-secure` | true | true (không đổi) |
| Build vs prebuilt image | `--build` Dockerfile | CI build + push registry, compose pull |
