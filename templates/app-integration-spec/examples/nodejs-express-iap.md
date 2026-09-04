# Reference — Node.js Express + oauth2-proxy IAP (Pattern A)

App backend Node dùng Express/Fastify/Koa/Hono. Refactor delta ~5 dòng.

## Deps

**KHÔNG add OIDC library.** oauth2-proxy sidecar handle. Chỉ cần app đọc header.

Nếu app chưa có middleware để parse `req.headers` → verify Express built-in đủ (yes, `req.get()`).

## `.env.example`

```env
# Cấp bởi Central RBAC portal
OIDC_ISSUER=http://10.200.0.125
CLIENT_ID=387047455193104387
CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxx

# App
APP_HOST=myapp.example.com
APP_PORT=3000

# oauth2-proxy
COOKIE_SECRET=change-me-32-random-bytes-base64
```

## App code (Express)

```javascript
// server.js
const express = require('express');
const app = express();

// Middleware: inject req.user từ oauth2-proxy header
app.use((req, res, next) => {
  const email = req.get('X-Auth-Request-Email');
  const username = req.get('X-Auth-Request-Preferred-Username');
  const groupsRaw = req.get('X-Auth-Request-Groups') || '';

  req.user = email ? {
    email,
    username: username || email.split('@')[0],
    roles: groupsRaw.split(',').filter(Boolean),
  } : null;

  next();
});

// Guard route (nếu health check public thì skip)
function requireAuth(req, res, next) {
  if (!req.user) return res.status(401).send('Unauthorized');
  next();
}

// Bypass health/ready cho ops monitor
app.get('/health', (req, res) => res.send('ok'));
app.get('/ready', (req, res) => res.send('ready'));

app.get('/', requireAuth, (req, res) => {
  res.send(`Hello ${req.user.email}. <a href="/oauth2/sign_out?rd=https%3A%2F%2F${process.env.APP_HOST}%2F">Sign out</a>`);
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json(req.user);
});

// CRITICAL: bind 127.0.0.1 — NEVER 0.0.0.0
const PORT = process.env.APP_PORT || 3000;
app.listen(PORT, '127.0.0.1', () => {
  console.log(`Listening on 127.0.0.1:${PORT}`);
});
```

## oauth2-proxy config `oauth2-proxy.cfg`

```ini
http_address       = "0.0.0.0:4180"
provider           = "oidc"
oidc_issuer_url    = "${OIDC_ISSUER}"
client_id          = "${CLIENT_ID}"
client_secret      = "${CLIENT_SECRET}"
redirect_url       = "https://${APP_HOST}/oauth2/callback"
cookie_secret      = "${COOKIE_SECRET}"
cookie_domain      = "${APP_HOST}"
cookie_secure      = true
cookie_refresh     = "1h"
whitelist_domains  = ["${APP_HOST}"]
reverse_proxy      = true
set_xauthrequest   = true
pass_access_token  = false
pass_authorization_header = false
email_domains      = ["*"]
skip_provider_button = true
upstream           = "http://127.0.0.1:3000"
```

## Docker Compose (nếu deploy Docker)

```yaml
services:
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    command: ["--config=/etc/oauth2-proxy.cfg"]
    volumes:
      - ./oauth2-proxy.cfg:/etc/oauth2-proxy.cfg:ro
    ports:
      - "127.0.0.1:4180:4180"
    environment:
      OIDC_ISSUER: ${OIDC_ISSUER}
      CLIENT_ID: ${CLIENT_ID}
      CLIENT_SECRET: ${CLIENT_SECRET}
      APP_HOST: ${APP_HOST}
      COOKIE_SECRET: ${COOKIE_SECRET}

  app:
    build: .
    environment:
      APP_HOST: ${APP_HOST}
      APP_PORT: 3000
    # KHÔNG expose port — chỉ oauth2-proxy reach qua internal network
    network_mode: host  # nếu cần bind 127.0.0.1 host
```

Nếu native (systemd) — xem `../../app-iap-native/README.md` cho pattern binary + systemd.

## Caddyfile (reverse proxy trước cả oauth2-proxy)

```
https://myapp.example.com {
    handle /health { reverse_proxy 127.0.0.1:3000 }
    handle /ready  { reverse_proxy 127.0.0.1:3000 }

    handle /oauth2/* {
        reverse_proxy 127.0.0.1:4180
    }

    handle {
        forward_auth 127.0.0.1:4180 {
            uri /oauth2/auth
            copy_headers X-Auth-Request-Email X-Auth-Request-Preferred-Username X-Auth-Request-Groups
            @unauth status 401
            handle_response @unauth {
                redir * /oauth2/start?rd={http.request.uri} 302
            }
        }
        reverse_proxy 127.0.0.1:3000
    }
}
```

## What AI must NOT change

- Business routes (VD `/api/posts`, `/api/orders`) — chỉ add middleware `requireAuth`, không rewrite handler logic
- Database calls / ORM setup
- Existing rate limit / CORS middleware ngoài auth-related

## Refactor delta cụ thể

1. Xoá: session middleware cũ (VD `express-session` với memstore), passport-local, login form routes `/login POST`, logout handler cũ
2. Add: middleware inject `req.user` từ header (10 dòng)
3. Add: `requireAuth` guard hoặc dùng existing authorization middleware nhưng đọc `req.user.roles`
4. Update: bind `127.0.0.1` thay vì `0.0.0.0`
5. Update: logout link href → `/oauth2/sign_out?rd=...`

## Validation

```bash
# 1. App bind local only
ss -tlnp | grep 3000
# Expect: 127.0.0.1:3000  (NOT 0.0.0.0:3000)

# 2. oauth2-proxy healthy
curl -sI http://127.0.0.1:4180/ping
# Expect: 200 OK

# 3. Direct app hit fail auth check
curl -H "X-Auth-Request-Email: test@example.com" http://127.0.0.1:3000/api/me
# Expect: {"email":"test@example.com",...}

# 4. Reverse proxy public: 302 to /oauth2/start
curl -sI https://myapp.example.com/
# Expect: 302 Location: /oauth2/start?rd=...
```
