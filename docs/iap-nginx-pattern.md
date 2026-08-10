# IAP Pattern với Nginx (thay thế Traefik)

> Cho member đã có Nginx sẵn trên VPS (LEMP, WordPress, app legacy...) — không muốn cài Traefik. Vẫn dùng oauth2-proxy + Zitadel, chỉ thay reverse proxy bằng Nginx + `auth_request`.

## Khi nào dùng pattern này

| Dùng Nginx | Dùng Traefik (chuẩn repo) |
|---|---|
| VPS đã chạy Nginx host nhiều site khác | VPS trắng / dành riêng 1 app stack |
| Quen Nginx, không muốn học Traefik | Mới setup, theo template repo |
| Cần TLS cert tự manage (certbot) | Muốn auto Let's Encrypt |
| Self-support, không cần team đỡ | Cần template chuẩn + docs đầy đủ |

→ Mặc định **khuyến nghị Traefik** ([template](../templates/app-iap-template/docker-compose.yml)). Pattern Nginx này là alternative khi context bắt buộc.

## Kiến trúc

```
Browser ──HTTPS──► Nginx (host, port 443)
                     │
                     ├── auth_request /oauth2/auth ──► oauth2-proxy (127.0.0.1:4180) ──OIDC──► Zitadel
                     │
                     ▼ (nếu pass)
                  App upstream (127.0.0.1:<port>, native hoặc Docker)
```

→ Nginx làm 2 việc: **TLS terminate** + **auth gate**. oauth2-proxy chạy Docker. App native hoặc Docker, bắt buộc bind `127.0.0.1`.

## Components

### 1. `docker-compose.yml` — chỉ oauth2-proxy

```yaml
services:
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    container_name: oauth2-proxy-${APP_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:4180:4180"   # bind localhost, Nginx host gọi qua loopback
    extra_hosts:
      - "${ZITADEL_HOSTNAME}:${ZITADEL_IP}"   # lab self-signed; production xoá
    command:
      - --http-address=0.0.0.0:4180
      - --reverse-proxy=true
      - --provider=oidc
      - --oidc-issuer-url=${ZITADEL_ISSUER_URL}
      - --client-id=${APP_CLIENT_ID}
      - --client-secret=${APP_CLIENT_SECRET}
      - --redirect-url=https://${APP_HOSTNAME}/oauth2/callback
      - --cookie-secret=${APP_COOKIE_SECRET}
      - --cookie-secure=true
      - --cookie-domain=${APP_HOSTNAME}
      - --cookie-refresh=1h
      - --email-domain=*
      - --pass-authorization-header=false
      - --set-xauthrequest=true
      - --whitelist-domain=${ZITADEL_HOSTNAME}
      - --skip-provider-button=true
```

### 2. `.env`

```env
APP_NAME=myapp
APP_HOSTNAME=myapp.example.com
APP_PORT=3000

APP_CLIENT_ID=...
APP_CLIENT_SECRET=...
APP_COOKIE_SECRET=...                # openssl rand -base64 32

ZITADEL_ISSUER_URL=https://auth.example.com
ZITADEL_HOSTNAME=auth.example.com
ZITADEL_IP=192.168.122.54            # chỉ lab self-signed
```

### 3. `/etc/nginx/sites-available/myapp.conf`

```nginx
# HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name myapp.example.com;
    return 301 https://$host$request_uri;
}

# HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name myapp.example.com;

    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;

    # OAuth2 endpoints (oauth2-proxy handle)
    location /oauth2/ {
        proxy_pass http://127.0.0.1:4180;
        proxy_set_header Host                    $host;
        proxy_set_header X-Real-IP               $remote_addr;
        proxy_set_header X-Scheme                $scheme;
        proxy_set_header X-Forwarded-For         $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto       $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
    }

    # Internal subrequest endpoint (chỉ Nginx tự gọi)
    location = /oauth2/auth {
        internal;
        proxy_pass               http://127.0.0.1:4180;
        proxy_set_header Host    $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_pass_request_body  off;
        proxy_set_header Content-Length "";
    }

    # App routes — gate bằng auth_request
    location / {
        auth_request /oauth2/auth;

        # Lấy identity từ response oauth2-proxy
        auth_request_set $auth_email $upstream_http_x_auth_request_email;
        auth_request_set $auth_user  $upstream_http_x_auth_request_user;

        # 401 → redirect sign_in
        error_page 401 = @oauth2_signin;

        # Pass identity xuống app
        proxy_set_header X-Auth-Request-Email $auth_email;
        proxy_set_header X-Auth-Request-User  $auth_user;
        proxy_set_header Host                 $host;
        proxy_set_header X-Real-IP            $remote_addr;
        proxy_set_header X-Forwarded-Proto    $scheme;

        proxy_pass http://127.0.0.1:3000;
    }

    location @oauth2_signin {
        return 302 /oauth2/sign_in?rd=$scheme://$host$request_uri;
    }
}
```

### 4. App native — bắt buộc bind `127.0.0.1`

```bash
node server.js --host 127.0.0.1 --port 3000
gunicorn -b 127.0.0.1:3000 app:app
# PHP-FPM: listen = 127.0.0.1:9000
# Go: http.ListenAndServe("127.0.0.1:3000", ...)
```

Nếu app trong Docker: `-p 127.0.0.1:3000:3000`.

## Auth flow

| # | Ai | Hành động |
|---|---|---|
| 1 | Browser | `GET https://myapp.example.com/dashboard` |
| 2 | Nginx | Match `location /` → `auth_request /oauth2/auth` |
| 3 | Nginx → oauth2-proxy | Subrequest `/oauth2/auth` + cookie |
| 4a | oauth2-proxy | Cookie OK → **200** + header identity |
| 4b | oauth2-proxy | Cookie miss → **401** |
| 5a | Nginx (200) | `proxy_pass 127.0.0.1:3000` kèm `X-Auth-Request-*` |
| 5b | Nginx (401) | `error_page 401` → redirect `/oauth2/sign_in?rd=<url>` |
| 6 | oauth2-proxy | Build authorize URL → redirect Zitadel |
| 7 | Zitadel | Login → callback → set cookie → quay app |

## `auth.<zitadel>` cấu hình ở đâu

**KHÔNG ở nginx.conf.** Chỉ 3 chỗ:
- `.env` (`ZITADEL_ISSUER_URL`, `ZITADEL_HOSTNAME`, `ZITADEL_IP`)
- `docker-compose.yml` oauth2-proxy (`--oidc-issuer-url`, `--whitelist-domain`, `extra_hosts`)
- `/etc/hosts` máy user (lab only — vì `auth.lab.local` không có DNS public)

Nginx app chỉ proxy tới `127.0.0.1:4180` + `127.0.0.1:<app-port>`. Browser tự đi tới Zitadel qua 302 redirect từ oauth2-proxy.

## Pitfall

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| Redirect loop khi login | `cookie-secure=true` nhưng thiếu `X-Forwarded-Proto https` | Add `proxy_set_header X-Forwarded-Proto $scheme;` mọi `/oauth2/*` |
| 502 Bad Gateway | oauth2-proxy bind `0.0.0.0:4180` bị firewall | Bind `127.0.0.1:4180`, Nginx gọi qua loopback |
| `X-Auth-Request-Email` trống | Thiếu `--set-xauthrequest=true` | Bật flag oauth2-proxy |
| POST body mất | `proxy_pass_request_body off` ở `location /` (nhầm) | `off` CHỈ ở `location = /oauth2/auth` |
| IAP bypass | App bind `0.0.0.0:<port>` → curl thẳng VPS:port vào được | Bind `127.0.0.1` + `ufw deny <port>` |
| Lab: cert verify fail | oauth2-proxy không trust self-signed CA của Zitadel | `--ssl-insecure-skip-verify=true` (lab only) hoặc mount CA |

## Verify

```bash
# 1. Browser redirect Zitadel
curl -I https://myapp.example.com/dashboard
# → 302 Location: /oauth2/sign_in?rd=...

# 2. Bypass test (từ máy khác)
curl http://<vps-ip>:3000
# → timeout / Connection refused

# 3. Header inject test (fake identity)
curl -H "X-Auth-Request-Email: hacker@evil.com" https://myapp.example.com/dashboard
# → vẫn 302 (Nginx ghi đè header từ subrequest, không tin client)

# 4. oauth2-proxy reach Zitadel
docker exec oauth2-proxy-myapp wget -qO- https://auth.example.com/.well-known/openid-configuration | head -5
# → JSON với "issuer": "https://auth.example.com"
```

## So sánh Traefik vs Nginx

| | Traefik (chuẩn repo) | Nginx (pattern này) |
|---|---|---|
| File config | 1 (compose + labels) | 2 (compose + nginx.conf) |
| TLS cert | Auto Let's Encrypt | Tự manage (certbot) |
| Thêm app mới | Thêm cặp service trong compose | 1 file `sites-available/` + 1 oauth2-proxy |
| Multi-app cùng host | Native | Cần khéo manage port + cert |
| Support team | Có template + docs | Tự lo, ref doc này |
| Phù hợp | VPS riêng cho app stack | VPS có Nginx host nhiều site |

## Add app thứ 2

Mỗi app cần:
- 1 `oauth2-proxy-<app>` riêng (client_id + cookie_secret riêng, bind port khác: `127.0.0.1:4181`, `:4182`...)
- 1 `sites-available/<app>.conf` riêng (server_name riêng, proxy_pass tới `127.0.0.1:418X`)
- 1 OIDC client trên Zitadel

→ Không share oauth2-proxy giữa các app (do cookie-domain + client_id riêng).

## Tham khảo

- [docs/app-vps-containers.md](app-vps-containers.md) — 3 pattern (A/B/C) tổng quan
- [docs/deploy-autossl-zitadel-iap.md](deploy-autossl-zitadel-iap.md) — case study AutoSSL (Nginx + PM2)
- [templates/app-iap-template/docker-compose.yml](../templates/app-iap-template/docker-compose.yml) — template Traefik chuẩn
- oauth2-proxy docs: https://oauth2-proxy.github.io/oauth2-proxy/configuration/integration#nginx-auth-request
