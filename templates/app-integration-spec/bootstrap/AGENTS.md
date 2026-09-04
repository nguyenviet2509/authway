# Authway SSO Integration — AI Instructions

**Purpose:** Instructions cho AI (Claude Code / Cursor / Cline / aider) refactor project để integrate Central RBAC SSO (Zitadel v4 OIDC). Self-contained — không cần fetch external docs.

**When to activate:** User yêu cầu "refactor cho Authway SSO" / "add Central SSO" / "integrate SSO via Zitadel" / "add auth qua Central". Nếu user chưa yêu cầu → wait.

**Deeper reference:** https://github.com/nguyenviet2509/authway/tree/master/templates/app-integration-spec/ (SPEC.md + full examples cho case phức tạp).

---

## 1. What Central RBAC provides (from admin registration)

Member đã đăng ký app trên Central RBAC portal → nhận credentials (fill trong `.env`):

| Field | Type | Notes |
|---|---|---|
| `OIDC_ISSUER` | URL | Base URL Zitadel. VD `http://10.200.0.125` (LAN) hoặc `https://auth.inet.vn` (prod) |
| `CLIENT_ID` | numeric snowflake | Public, dùng trong URL query |
| `CLIENT_SECRET` | string | Basic auth apps only. SPA + PKCE app KHÔNG có secret |
| `REDIRECT_URL` | URL | EXACT match — Zitadel reject nếu sai 1 ký tự (scheme/host/port/path/trailing slash) |
| `POST_LOGOUT_URL` | URL | Nơi user land sau end_session, thường app root |

**Endpoints derived từ `OIDC_ISSUER` (constant):**
- `{OIDC_ISSUER}/.well-known/openid-configuration` — discovery
- `{OIDC_ISSUER}/oauth/v2/authorize` — auth endpoint
- `{OIDC_ISSUER}/oauth/v2/token` — token exchange
- `{OIDC_ISSUER}/oidc/v1/userinfo` — userinfo
- `{OIDC_ISSUER}/oauth/v2/keys` — JWKS
- `{OIDC_ISSUER}/oidc/v1/end_session` — sign-out

**Roles claim (nếu Central enable):**
- Path: `urn:zitadel:iam:org:project:roles`
- Shape: `{ "roleKey": { "orgId": "orgDomain" }, ... }`
- Extract role names: `Object.keys(claim)` / `list(claim.keys())`

---

## 2. Decision tree — Pattern A vs B

Trả lời theo thứ tự, câu đầu "yes" quyết định:

1. **SPA thuần (React/Vue, no backend riêng)?** → Pattern B (browser PKCE)
2. **App cần forward user's access_token xuống downstream API?** → Pattern B
3. **App cần parse role claim structure phức tạp (multi-tenant, orgId map)?** → Pattern B
4. **Reverse proxy (Caddy/Traefik/nginx) có available trước app?** → No: Pattern B; Yes: Q5
5. **Framework = Next.js App Router?** → Pattern B (Auth.js v5 tối ưu). No → **Pattern A (default)**.

**Default: Pattern A.** Refactor delta ~5 dòng. 90% case.

---

## 3. Pattern A — IAP sidecar (default)

**Semantics:**
- oauth2-proxy (container hoặc binary) đặt trước app
- Reverse proxy routes: `/oauth2/*` → oauth2-proxy; `/*` → forward_auth gate → 200 forward; 401 redirect `/oauth2/start`
- App đọc request header (KHÔNG cần OIDC library):
  - `X-Auth-Request-Email` — identity chính
  - `X-Auth-Request-Preferred-Username` — username
  - `X-Auth-Request-Groups` (optional) — comma-sep roles

**App changes required (5 điểm):**
1. Bind `127.0.0.1:<PORT>`, NEVER `0.0.0.0`
2. Xoá login form + session middleware cũ
3. Replace `getCurrentUser()` bằng đọc `X-Auth-Request-Email` header
4. Logout link → `/oauth2/sign_out?rd=<POST_LOGOUT_URL>`
5. KHÔNG cần `CLIENT_SECRET` trong code app (secret sống trong oauth2-proxy config)

**Reverse proxy Caddyfile mẫu:**
```
https://<APP_HOST> {
  handle /oauth2/* { reverse_proxy oauth2-proxy:4180 }
  handle {
    forward_auth oauth2-proxy:4180 {
      uri /oauth2/auth
      copy_headers X-Auth-Request-Email X-Auth-Request-Preferred-Username X-Auth-Request-Groups
      @unauth status 401
      handle_response @unauth {
        redir * /oauth2/start?rd={http.request.uri} 302
      }
    }
    reverse_proxy 127.0.0.1:<APP_PORT>
  }
}
```

**oauth2-proxy config `.cfg` mẫu:**
```ini
http_address       = "0.0.0.0:4180"
provider           = "oidc"
oidc_issuer_url    = "${OIDC_ISSUER}"
client_id          = "${CLIENT_ID}"
client_secret      = "${CLIENT_SECRET}"
redirect_url       = "${REDIRECT_URL}"
cookie_secret      = "${COOKIE_SECRET}"
cookie_domain      = "${APP_HOST}"
cookie_secure      = true
whitelist_domains  = ["${APP_HOST}"]
reverse_proxy      = true
set_xauthrequest   = true
email_domains      = ["*"]
skip_provider_button = true
upstream           = "http://127.0.0.1:<APP_PORT>"
```

**Pin oauth2-proxy version:** `quay.io/oauth2-proxy/oauth2-proxy:v7.7.1`

---

## 4. Pattern B — Native OIDC (khi cần)

**Semantics:**
- App tự implement Authorization Code + PKCE flow
- 3 endpoint mới: `/login`, `/callback`, `/logout` (path tuỳ framework)
- JWT verify signature qua JWKS (cache 1h, refresh nếu `kid` không khớp)
- Extract identity từ `id_token.email` + roles từ `id_token["urn:zitadel:iam:org:project:roles"]`

**Framework-specific outline:**

### Next.js App Router
- Deps: `next-auth@beta` (Auth.js v5, `^5.0.0-beta.20`)
- Files: `auth.ts` (root), `app/api/auth/[...nextauth]/route.ts`, `middleware.ts`, `types/next-auth.d.ts`
- Provider: `Zitadel({ clientId, clientSecret, issuer, authorization: { params: { scope: "openid email profile urn:zitadel:iam:org:project:roles" }}})`
- Callback path: `/api/auth/callback/zitadel` (fixed) — REDIRECT_URL với admin phải EXACT match
- Sign-out chain: cần custom `/api/auth/signout-full` route để redirect Zitadel `end_session` (Auth.js default không clear IdP session)

### SPA React/Vue (Pattern B browser)
- Deps: `oidc-client-ts` (`^3.0.1`)
- Files: `auth/oidc-manager.ts` (UserManager config), `auth/auth-context.tsx` (React) hoặc Pinia store (Vue), `routes/callback.tsx`, `routes/protected.tsx`
- Config: `response_type: "code"` (PKCE auto), `scope: "openid email profile urn:zitadel:iam:org:project:roles"`, `userStore: sessionStorage`
- Callback path: tuỳ chọn (`/callback`), phải khai REDIRECT_URL với admin EXACT
- KHÔNG dùng `CLIENT_SECRET` — public client
- Static host cần `try_files ... /index.html` cho SPA routing

### Backend Node/Python (Pattern B if needed)
- Deps: `openid-client` (Node) hoặc `authlib` (Python)
- Manual flow: `/login` build authorize URL + state + PKCE → `/callback` exchange code → JWT verify → set session cookie → `/logout` clear + redirect end_session

---

## 5. Security invariants (BẮT BUỘC — AI KHÔNG được bỏ)

1. App bind `127.0.0.1`, NEVER `0.0.0.0`
2. Cookie `secure=true` khi HTTPS; `httpOnly=true` luôn; `SameSite=Lax` (Strict nếu no cross-site)
3. Cookie secret ≥ 32 bytes random (Pattern A)
4. State + Nonce + PKCE — KHÔNG disable
5. JWT verify qua JWKS — NEVER accept unsigned JWT / skip verify
6. Verify `iss` khớp `OIDC_ISSUER`, `aud` khớp `CLIENT_ID`, `exp` chưa hết hạn
7. KHÔNG trust `X-Auth-Request-*` headers khi app KHÔNG có oauth2-proxy trước
8. Sign-out chain đầy đủ — clear local + oauth2-proxy cookie + Zitadel session
9. KHÔNG hardcode `OIDC_ISSUER`/`CLIENT_ID`/`CLIENT_SECRET` — env var only, `.env` trong `.gitignore`
10. HTTPS prod bắt buộc (Zitadel reject HTTP redirect_uri trừ Dev Mode)

---

## 6. Env vars contract

App phải support:
```env
OIDC_ISSUER=       # Cấp bởi admin
CLIENT_ID=         # Cấp bởi admin
CLIENT_SECRET=     # Cấp bởi admin (bỏ nếu SPA)
REDIRECT_URL=      # Cấp bởi admin
POST_LOGOUT_URL=   # Cấp bởi admin

APP_HOST=          # Member tự set — hostname public app
APP_PORT=          # Member tự set — port app native listen

# Pattern A only
COOKIE_SECRET=     # Generate: openssl rand -base64 32
```

**Ngày commit:** verify `.env` trong `.gitignore` (`git check-ignore .env` → return `.env`). Verify `.env.example` tồn tại với placeholder KHÔNG chứa real secret.

---

## 7. Refactor procedure (AI steps — làm THEO thứ tự)

1. **Read `.env`** trong project → verify có đủ credentials. Nếu thiếu → hỏi user, KHÔNG generate fake values.
2. **Scout project structure:**
   - Grep `package.json` / `pyproject.toml` / `requirements.txt` / `go.mod` — detect framework
   - Grep `listen`, `bind`, `HOST` — detect current bind address (0.0.0.0 vs 127.0.0.1)
   - Grep `session`, `passport`, `login`, `auth` — find auth code cũ cần thay
   - Grep hardcoded auth (`req.session.user = { admin: true }`, `if user == "admin"`) — flag
3. **Chọn pattern** theo decision tree section 2. Tell user pattern chose + reason.
4. **Apply refactor:**
   - Add/replace files theo pattern outline section 3 hoặc 4
   - KEEP business logic intact (không xoá endpoint ngoài auth)
   - Update bind address `127.0.0.1`
   - Add `.env.example` với placeholder, verify `.env` trong `.gitignore`
5. **Run validation checklist** section 8 self-check.
6. **Report back user:** files changed, deps added, env vars needed, next steps (deploy).

---

## 8. Validation checklist (self-check TRƯỚC khi báo done)

- [ ] `grep -rE "0\.0\.0\.0" src/` → 0 match (app bind 127.0.0.1)
- [ ] `grep -rE "10\.200\.0\.125|auth\.inet\.vn|http://.*zitadel" src/` → 0 match (URL trong env var only)
- [ ] `grep -rE "CLIENT_SECRET.*=.*['\"]" src/` → 0 match hardcode (chỉ đọc từ env)
- [ ] `.env` trong `.gitignore` (`git check-ignore .env` return `.env`)
- [ ] `.env.example` tồn tại, chứa placeholder (KHÔNG real secret)
- [ ] (Pattern A) Reverse proxy config file có `/oauth2/*` handler + `forward_auth`
- [ ] (Pattern A) App KHÔNG có OIDC library trong deps
- [ ] (Pattern B) `state`, `nonce`, PKCE `code_challenge` random per-request
- [ ] (Pattern B) JWT verify dùng JWKS (không hardcode public key)
- [ ] (Pattern B) `iss` + `aud` + `exp` được verify
- [ ] Sign-out chain: local session cleared + redirect `/oauth2/sign_out` (A) hoặc `end_session` (B)
- [ ] Health check endpoint (nếu có `/health`, `/ready`) bypass IAP
- [ ] README project cập nhật env vars mới

---

## 9. What AI must NOT change (invariants)

- Business logic (data models, non-auth API endpoints, background jobs, cron)
- Framework major version (VD Express 4 → 5) trừ user yêu cầu
- Third-party integrations không liên quan auth (analytics, payment, etc.)
- CSS/UI trừ auth UI (login/logout buttons)
- Database schema / migrations
- Test files logic ngoài auth-related tests
- `.gitignore` items khác ngoài add `.env`

Add ONLY: OIDC library (Pattern B) hoặc oauth2-proxy config file (Pattern A).

---

## 10. Common issues + AI resolution

| Symptom | Root cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | REDIRECT_URL Zitadel ≠ URL app emit | Log URL app emit, so EXACT với REDIRECT_URL từ `.env` (scheme + host + port + path + trailing slash) |
| `invalid_client` | CLIENT_ID/SECRET sai | Verify env var đọc đúng, không whitespace/newline thừa |
| Cookie oversize >4KB | User có nhiều UserGrant | Switch scope-limited claim `urn:zitadel:iam:org:project:id:{CLIENT_ID}:roles` (báo admin enable trước) |
| Header `X-Auth-Request-Email` empty (Pattern A) | oauth2-proxy chưa auth hoặc `copy_headers` thiếu | Verify Caddyfile `copy_headers` list; check oauth2-proxy log |
| JWT verify fail `kid not found` | JWKS cache stale | Force refresh JWKS, KHÔNG cache expired kid |
| Sign-out không clear Zitadel session | Chỉ clear local | Add `end_session` redirect (Pattern B) hoặc verify `/oauth2/sign_out?rd=` chain (Pattern A) |
| App accessible từ IP bypass reverse proxy | App bind 0.0.0.0 | Rebind 127.0.0.1, verify `ss -tlnp` |
| PKCE fail HTTP + IP LAN (SPA) | `crypto.subtle` require secure context | Dev: SSH tunnel + localhost; Prod: HTTPS bắt buộc |

---

## 11. Deploy targets (framework-independent)

Sau refactor, deploy tuỳ target:

**Docker Compose:** copy oauth2-proxy service + app service vào `docker-compose.yml`. Reverse proxy (Caddy/Traefik) là service riêng.

**Native systemd:** oauth2-proxy binary + systemd unit + Caddy service. Ref: `authway/templates/app-iap-native/README.md` upstream repo.

**Static host (SPA):** build → static files → serve qua Caddy/nginx với `try_files`. KHÔNG cần oauth2-proxy (SPA dùng browser PKCE).

**Serverless (Vercel/Cloudflare):** chỉ Pattern B với Auth.js v5 hoặc native OIDC. Không có oauth2-proxy sidecar layer.

---

## 12. Report format (khi báo done)

```
## Refactor complete

**Pattern chose:** A / B (reason)

**Files changed:**
- <list>

**Files added:**
- <list>

**Deps added:**
- <lib name> <version>

**Env vars required in .env:**
- <list>

**Validation checklist:** X/13 passed (list failed items)

**Next steps:**
1. `cp .env.example .env` + fill credentials từ admin
2. Deploy: <command tuỳ target>
3. Verify: browser incognito → <APP_HOST> → login flow

**Warnings/limitations:** <nếu có>
```
