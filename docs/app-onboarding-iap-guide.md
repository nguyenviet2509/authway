# App Onboarding — IAP Pattern (Zitadel + Zimbra LDAP)

**Audience:** dev phòng KT muốn thêm app mới vào SSO stack.
**Time:** ~15 phút (nếu VPS + DNS đã ready).
**Prereq đọc:** không. Doc này self-contained.

## What is IAP?

**I**dentity-**A**ware **P**roxy: reverse proxy chặn request → subrequest oauth2-proxy → oauth2-proxy check session (redirect Zitadel nếu chưa có) → inject `X-Auth-Request-Email` vào app. App **không cần biết OIDC**, chỉ đọc header.

```
Browser → Traefik/Caddy/Nginx → [forward_auth] → oauth2-proxy → Zitadel → Zimbra LDAP
                    │
                    └─(authed)→ App backend (đọc X-Auth-Request-Email)
```

## Prerequisites

- App container chạy sau reverse proxy (Traefik / Caddy / Nginx đều OK)
- Hostname / IP đã reachable từ user (LAN, VPN, hoặc public + DNS)
- Yêu cầu ops team cấp: `CLIENT_ID` + `CLIENT_SECRET` + `redirect_uri` đăng ký với Zitadel

## 5-step onboard

### 1. Xin OIDC app từ ops

Message ops:
> App: `myapp.inet.vn` (hoặc IP). Redirect URI: `http://myapp.inet.vn/oauth2/callback`. Cần LDAP-only.

Ops trả `CLIENT_ID` + `CLIENT_SECRET`. Save vào password manager, **không commit**.

### 2. Thêm oauth2-proxy sidecar

Copy `templates/app-iap-template/docker-compose.yml` hoặc merge block sau vào compose hiện tại:

```yaml
oauth2-proxy:
  image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
  restart: unless-stopped
  networks: [edge]
  volumes:
    - ./oauth2-proxy/oauth2-proxy.cfg:/etc/oauth2-proxy.cfg:ro
  command: ["--config=/etc/oauth2-proxy.cfg"]
```

`oauth2-proxy.cfg` (gitignored — chứa secret):

```ini
provider = "oidc"
oidc_issuer_url = "http://<ZITADEL_HOST>"     # http://10.200.0.125 hoặc https://auth.inet.vn
client_id = "<CLIENT_ID>"
client_secret = "<CLIENT_SECRET>"
redirect_url = "http://<APP_HOST>/oauth2/callback"
cookie_secret = "<openssl rand -base64 32 | tr -- '+/' '-_'>"
cookie_secure = false                          # true khi có HTTPS thật
cookie_samesite = "lax"
user_id_claim = "preferred_username"           # LDAP username, không phải Zitadel sub UUID
cookie_csrf_per_request = true                 # tránh CSRF stale khi 2 tab
email_domains = ["*"]
whitelist_domains = ["<APP_HOST>", "<ZITADEL_HOST>"]
skip_provider_button = true
```

**Bẫy hay dính (learned P4):**
- KHÔNG set `cookie_domains = "10.x.x.x"` — Chrome RFC 6265 reject Domain=IP.
- `user_id_claim = "preferred_username"` — nếu để mặc định `sub`, app hiển thị UUID `385593087...` thay vì username.

### 3. Cấu hình reverse proxy forward_auth

Chọn 1 trong 3 (tùy stack app):

**Traefik (khuyến nghị cho app mới)** — dùng middleware `iap-remote` từ template:
```yaml
labels:
  - "traefik.http.routers.app.middlewares=iap-remote@file"
  - "traefik.http.routers.app.rule=Host(`myapp.inet.vn`)"
```

**Caddy (OneLog pattern)**:
```caddy
handle {
    forward_auth oauth2-proxy:4180 {
        uri /oauth2/auth
        copy_headers X-Auth-Request-Email X-Auth-Request-Preferred-Username
        @unauth status 401
        handle_response @unauth {
            redir * /oauth2/start?rd={http.request.uri} 302
        }
    }
    reverse_proxy myapp:3000
}
handle /oauth2/* {
    reverse_proxy oauth2-proxy:4180
}
```

**Nginx (OneMCP pattern)**:
```nginx
location = /oauth2/auth {
  internal;
  proxy_pass http://oauth2-proxy:4180/oauth2/auth;
  proxy_pass_request_body off;
  proxy_set_header Content-Length "";
}
location /oauth2/ { proxy_pass http://oauth2-proxy:4180; }
error_page 401 = @signin;
location @signin { return 302 /oauth2/start?rd=$scheme://$host$request_uri; }
location / {
  auth_request /oauth2/auth;
  auth_request_set $email $upstream_http_x_auth_request_email;
  proxy_set_header X-Auth-Request-Email $email;
  proxy_pass http://app:3000;
}
```

Nếu backend chỉ nhận `local-part` (không phải full email), strip `@domain`:
```nginx
map $email $username { ~^(?<u>[^@]+)@ $u; default $email; }
proxy_set_header X-Onemcp-User $username;
```

### 4. App đọc header

| Stack | Snippet (5-line max) |
|---|---|
| **Node/Express** | `app.use((req,_,next)=>{req.userEmail=req.get('X-Auth-Request-Email');next()})` |
| **Next.js RSC** | `const email = headers().get('x-auth-request-email')` |
| **Python/FastAPI** | `def me(email: str = Header(alias='X-Auth-Request-Email')): return {"email": email}` |
| **Python/Flask** | `@app.before_request\ndef _u(): g.email = request.headers.get('X-Auth-Request-Email')` |
| **Go net/http** | `email := r.Header.Get("X-Auth-Request-Email")` |
| **Django** | `MIDDLEWARE += ["django.contrib.auth.middleware.RemoteUserMiddleware"]` + set `REMOTE_USER` from header |

Logout: `<a href="/oauth2/sign_out?rd=<ZITADEL_LOGOUT_URL>">Sign out</a>`

### 5. Test

```bash
docker compose up -d oauth2-proxy
docker compose logs oauth2-proxy | grep -i "listening\|error"
# Expect: "OAuthProxy configured..."  và "Listening on 0.0.0.0:4180"

# Incognito browser → https://myapp.inet.vn/
# → redirect Zitadel login → LDAP username/password → về app, hiển thị email
```

Done.

## Debug tips (learned P4)

| Triệu chứng | Root cause | Fix |
|---|---|---|
| CSRF token missing/invalid | Chrome không nhận `Domain=IP` cookie | Xoá `cookie_domains` khỏi cfg |
| Redirect loop `/oauth2/start` | `cookie_secure=true` nhưng app HTTP | Set `cookie_secure=false` |
| App hiển thị UUID thay username | Claim mapping mặc định = `sub` | `user_id_claim = "preferred_username"` |
| "Invalid username format" backend | Backend regex reject full email | Nginx map strip `@domain` (xem step 3) |
| Login xong không redirect về app | Multi-page flow (MFA/change password) mất session cookie trên HTTP+IP | Ops disable ForceMFA + PasswordChangeRequired ở Zitadel (đã fix ở prod pilot) |
| Signout redirect nhiều bước | Chain oauth2-proxy → Zitadel end_session chưa set | Set `WEBUI_AUTH_SIGNOUT_REDIRECT_URL=/oauth2/sign_out?rd=<zitadel_end_session>` |
| Broken images/CSS ở login sidecar | Zitadel API_URL = internal Docker alias | Set `ZITADEL_API_URL = http://<external_host>` (public URL) |

## When NOT to use IAP

- **Mobile app / native client** → dùng OIDC PKCE flow trực tiếp (Zitadel emit Bearer token).
- **API-only, machine-to-machine** → PAT hoặc client_credentials + Bearer JWT (không cookie).
- **WebSocket-heavy app** → IAP OK nhưng test kỹ; oauth2-proxy support WS forward.
- **Cần per-user data isolation nghiêm ngặt** → IAP + app đọc header đủ, không cần OIDC-native.

Cho các case trên: xem `docs/deploy-autossl-zitadel-iap.md` phần "OIDC-native opt-in".

## Related

- `templates/app-iap-template/` — copy folder, fill `.env`, up
- `docs/lab-deploy-192-168-122-54.md` — reference deploy lab
- `docs/why-zitadel-pitch.md` — architecture rationale
- `docs/zitadel-log-viewing-guide.md` — debug từ Zitadel side

## Unresolved

- HTTPS + domain thật cho Zitadel prod (đang HTTP + IP `10.200.0.125` cho pilot)
- Group sync Zimbra → Zitadel role: chưa có, plan sau
- Per-user resource isolation ở OpenWebUI (P4 rollback về shared admin identity)
