# Tích hợp Zitadel Auth vào AutoSSL (Zero Code Change)

> AutoSSL đang chạy production (Next.js + PM2 + nginx). Guide này thêm Zitadel auth **không sửa 1 dòng code app** — chỉ thao tác infrastructure. Effort: ~1-2h.

## Quyết định kiến trúc

| Item | Giá trị |
|---|---|
| Pattern | IAP — oauth2-proxy đứng trước Next.js cùng VPS |
| Code AutoSSL sửa | **Zero** — không touch repo |
| IP whitelist | **Giữ** (defense in depth, cost ~0) |
| Audit log app-level | **Bỏ** — Zitadel audit + nginx access log đã đủ trace |
| MFA | Bắt buộc, config trong Zitadel policy |
| Cookie domain | exact match = `autossl.<your-domain>` |

## Topology

```
client → nginx :443 (IP whitelist + strip headers) → oauth2-proxy :4180 → Next.js :3000 (PM2)
                                                            ↓
                                             https://auth.<company>.com (Zitadel)
```

---

## 1. Prerequisites

- [ ] Zitadel central đang chạy: `https://auth.<company>.com`
- [ ] DNS `autossl.<your-domain>` trỏ về VPS AutoSSL (đã có)
- [ ] AutoSSL đang chạy ổn ở `127.0.0.1:3000` qua PM2 (đã có)
- [ ] Có quyền admin Zitadel để tạo OIDC application

---

## 2. Tạo OIDC Application trong Zitadel

1. Login `https://auth.<company>.com` → Projects → chọn `internal-apps` → **New Application**.
2. Cấu hình:
   - Name: `autossl`
   - Type: **Web** → Authentication Method: **Code** (confidential)
3. **Redirect URIs:** `https://autossl.<your-domain>/oauth2/callback`
4. **Post Logout URIs:** `https://autossl.<your-domain>/`
5. Token Settings: Auth Token Type = **JWT**, User Info inside ID Token = ON
6. Copy ngay (chỉ hiện 1 lần):
   - **Client ID**: `xxxxxxxx@autossl`
   - **Client Secret**: `xxxxx`
7. **Authorization** tab → grant các user được phép vào AutoSSL.

---

## 3. Cài oauth2-proxy trên VPS AutoSSL

### 3.1. Binary

```bash
cd /opt
sudo wget https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.6.0/oauth2-proxy-v7.6.0.linux-amd64.tar.gz
sudo tar -xzf oauth2-proxy-v7.6.0.linux-amd64.tar.gz
sudo mv oauth2-proxy-v7.6.0.linux-amd64/oauth2-proxy /usr/local/bin/
sudo chmod +x /usr/local/bin/oauth2-proxy
```

### 3.2. Sinh cookie secret

```bash
python3 -c 'import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())'
```

### 3.3. Config — `/etc/oauth2-proxy/autossl.cfg`

```ini
# Provider
provider = "oidc"
oidc_issuer_url = "https://auth.<company>.com"
client_id = "xxxxxxxx@autossl"
client_secret = "xxxxx"
redirect_url = "https://autossl.<your-domain>/oauth2/callback"
scope = "openid profile email"

# Upstream — Next.js PM2
http_address = "127.0.0.1:4180"
upstreams = ["http://127.0.0.1:3000/"]

# Cookie
cookie_secret = "PASTE_COOKIE_SECRET_HERE"
cookie_domains = ["autossl.<your-domain>"]
cookie_secure = true
cookie_samesite = "lax"
cookie_expire = "8h"
cookie_refresh = "1h"
session_store_type = "cookie"

# Email allowlist (optional, an toàn hơn nếu chưa thiết lập group/role)
email_domains = ["<company>.com"]

# Reverse proxy
reverse_proxy = true
real_client_ip_header = "X-Forwarded-For"

# Logout safety — chặn open redirect
whitelist_domains = ["auth.<company>.com"]
```

```bash
sudo chmod 600 /etc/oauth2-proxy/autossl.cfg
```

### 3.4. systemd — `/etc/systemd/system/oauth2-proxy-autossl.service`

```ini
[Unit]
Description=OAuth2 Proxy for AutoSSL
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/oauth2-proxy/autossl.cfg
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now oauth2-proxy-autossl
sudo systemctl status oauth2-proxy-autossl
```

---

## 4. Sửa nginx vhost

**Backup vhost cũ trước:**
```bash
sudo cp /etc/nginx/sites-available/autossl /etc/nginx/sites-available/autossl.bak
```

Sửa `/etc/nginx/sites-available/autossl`:

```nginx
server {
    listen 443 ssl http2;
    server_name autossl.<your-domain>;

    ssl_certificate     /etc/letsencrypt/live/autossl.<your-domain>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/autossl.<your-domain>/privkey.pem;

    # === IP whitelist — GIỮ NGUYÊN ===
    allow 103.75.184.0/24;
    allow <office-public-ip>;
    allow <vpn-cidr>;
    deny all;

    # === Strip auth headers — chống header injection từ client ===
    proxy_set_header X-Forwarded-User "";
    proxy_set_header X-Forwarded-Email "";
    proxy_set_header X-Forwarded-Preferred-Username "";
    proxy_set_header X-Forwarded-Groups "";
    proxy_set_header X-Auth-Request-User "";
    proxy_set_header X-Auth-Request-Email "";
    proxy_set_header X-Auth-Request-Groups "";

    location / {
        # ĐỔI: trước đây :3000 → giờ :4180 (oauth2-proxy)
        proxy_pass http://127.0.0.1:4180;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name autossl.<your-domain>;
    return 301 https://$host$request_uri;
}
```

Apply:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 5. Verify

- [ ] `curl -I https://autossl.<your-domain>/` → 302 redirect tới Zitadel
- [ ] Browser: vào URL → Zitadel login → MFA → redirect lại AutoSSL → thấy UI gốc
- [ ] Test header injection: `curl -H "X-Forwarded-Email: admin@evil.com" https://autossl.<your-domain>/api/check-dns` → nginx phải strip, không leak vào Next.js
- [ ] IP không trong whitelist → 403 ngay từ nginx (không thấy Zitadel)
- [ ] Logout: vào `https://autossl.<your-domain>/oauth2/sign_out?rd=https%3A%2F%2Fauth.<company>.com%2Foidc%2Fv1%2Fend_session` → bấm Login lại → **phải re-MFA**
- [ ] WHM token trong localStorage **không mất** sau khi login lại (đúng behavior — localStorage tied to domain, không tied to session)

---

## 6. Rollback (30 giây)

```bash
sudo systemctl stop oauth2-proxy-autossl
sudo mv /etc/nginx/sites-available/autossl.bak /etc/nginx/sites-available/autossl
sudo nginx -t && sudo systemctl reload nginx
```

→ Về trạng thái cũ. AutoSSL vẫn chạy như trước, chỉ IP whitelist.

---

## 7. Operational

### Logout URL (bookmark cho user)
```
https://autossl.<your-domain>/oauth2/sign_out?rd=https%3A%2F%2Fauth.<company>.com%2Foidc%2Fv1%2Fend_session%3Fpost_logout_redirect_uri%3Dhttps%253A%252F%252Fautossl.<your-domain>%252F
```

App không có nút Logout (không sửa code) → dev tạo bookmark hoặc gõ URL.

### Disable user (offboarding)
- Zitadel → Users → chọn user → **Deactivate**
- User bị kick ra trong tối đa `cookie_refresh = 1h`

### Rotate secrets
- `client_secret`: tạo mới ở Zitadel UI → update `/etc/oauth2-proxy/autossl.cfg` → `systemctl restart oauth2-proxy-autossl` → xoá secret cũ ở Zitadel
- `cookie_secret`: regen → update config → restart → tất cả user phải login lại

### Monitor
- `journalctl -u oauth2-proxy-autossl -f` — login attempts, errors
- `tail -f /var/log/nginx/access.log` — request log + actor IP
- Zitadel audit log: `https://auth.<company>.com/ui/console/instance/auditlog` — ai login khi nào

### Trace "ai cài SSL cho domain X?"
Correlate 3 nguồn:
1. nginx access log: timestamp + IP + path `/api/install-ssl` + body size
2. Zitadel audit: cùng timestamp → user nào đang có session từ IP đó
3. PM2 log AutoSSL: domain cụ thể trong request body

Đủ điều tra. Không cần audit log riêng trong app.

---

## Known limitations (accepted)

- **WHM token vẫn localStorage**: không liên quan Zitadel. Mitigation: machine policy, screen lock, không share máy.
- **Cookie 8h**: user phải login lại sau 8h. Adjust nếu cần.
- **Không có nút Logout trong UI**: dùng bookmark. Acceptable cho internal tool ≤10 user.
- **Không có RBAC trong app**: mọi user trong Zitadel project = full access. Nếu cần phân quyền sau này → mới sửa code.
- **Offboarding lag 1h**: do `cookie_refresh = 1h`. Lower xuống nếu critical (cost: nhiều token refresh request hơn).

---

## Unresolved questions

1. Có cần lower `cookie_refresh` xuống 15m để offboarding nhanh hơn không?
2. Office/VPN IP cụ thể cần whitelist là gì? (placeholder `<office-public-ip>`, `<vpn-cidr>` cần điền)
3. Cần monitoring/alert (Loki, Prometheus) cho oauth2-proxy không, hay tail log thủ công là đủ POC?
