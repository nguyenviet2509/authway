# Authway App Integration SPEC (AI contract)

**Purpose:** AI đọc file này + code project + credential từ Central → refactor project cho Central SSO integration đúng contract.

**Prerequisite:** Đọc `DECISION-TREE.md` TRƯỚC để chọn Pattern A hoặc B.

---

## 1. What Central RBAC provides

Khi admin đăng ký app trên Central portal, member nhận:

| Field | Type | Example | Notes |
|---|---|---|---|
| `OIDC_ISSUER` | URL | `http://10.200.0.125` (LAN) / `https://auth.inet.vn` (prod) | Base URL Zitadel |
| `CLIENT_ID` | string (numeric snowflake) | `387047455193104387` | Public, dùng trong URL query |
| `CLIENT_SECRET` | string | `xxxxxxxxxxxxxxxxxxx` | ONLY Basic auth apps. SPA + PKCE app KHÔNG có secret |
| `REDIRECT_URL` | URL | `https://<app-host>/oauth2/callback` (Pattern A) HOẶC `https://<app-host>/<framework-path>` (Pattern B) | EXACT match — sai 1 ký tự = reject |
| `POST_LOGOUT_URL` | URL | `https://<app-host>/` | Nơi user land sau end_session |

Endpoints derived từ `OIDC_ISSUER`:
- `{OIDC_ISSUER}/.well-known/openid-configuration` — discovery
- `{OIDC_ISSUER}/oauth/v2/authorize` — authorization endpoint
- `{OIDC_ISSUER}/oauth/v2/token` — token endpoint
- `{OIDC_ISSUER}/oidc/v1/userinfo` — userinfo
- `{OIDC_ISSUER}/oauth/v2/keys` — JWKS (JWT verify)
- `{OIDC_ISSUER}/oidc/v1/end_session` — sign-out

Roles claim (khi enabled trong Zitadel project — Central mặc định bật):
- Path: `urn:zitadel:iam:org:project:roles`
- Shape: `{ "roleKey": { "orgId": "orgDomain" }, ... }`
- Extract role names: `Object.keys(claim)` hoặc `list(claim.keys())`

---

## 2. Two integration patterns

### Pattern A — IAP sidecar (DEFAULT, 90% case)

**Semantics:**
- `oauth2-proxy` (container hoặc binary) đặt trước app
- Reverse proxy (Caddy / Traefik / nginx) routes:
  - `/oauth2/*` → `oauth2-proxy`
  - `/*` (còn lại) → `oauth2-proxy /oauth2/auth` gate → 200 forward app; 401 redirect `/oauth2/start`
- App đọc request header:
  - `X-Auth-Request-Email` — identity chính
  - `X-Auth-Request-Preferred-Username` — username từ Zitadel
  - `X-Auth-Request-Groups` (optional) — comma-sep role names (chỉ khi enable `set_authorization_header` trong oauth2-proxy config)
- App KHÔNG cần OIDC library.

**App changes required:**
- Bind `127.0.0.1:<PORT>` (NEVER `0.0.0.0`) — oauth2-proxy proxy về
- Xoá login form / session cookie logic cũ
- Replace `getCurrentUser()` bằng `request.header('X-Auth-Request-Email')`
- Redirect logout link tới `/oauth2/sign_out?rd={POST_LOGOUT_URL}`
- KHÔNG cần `CLIENT_SECRET` trong code app (secret sống trong oauth2-proxy config)

**Reverse proxy config example (Caddyfile):**
```
https://app.example.com {
  handle /oauth2/* {
    reverse_proxy oauth2-proxy:4180
  }
  handle {
    forward_auth oauth2-proxy:4180 {
      uri /oauth2/auth
      copy_headers X-Auth-Request-Email X-Auth-Request-Preferred-Username
      @unauth status 401
      handle_response @unauth {
        redir * /oauth2/start?rd={http.request.uri} 302
      }
    }
    reverse_proxy 127.0.0.1:<APP_PORT>
  }
}
```

### Pattern B — Native OIDC (khi cần token / SPA / custom claim parse)

**Semantics:**
- App tự implement OIDC Authorization Code + PKCE flow
- Redirect `/login` → `{OIDC_ISSUER}/oauth/v2/authorize?client_id=...&redirect_uri=...&code_challenge=...`
- Callback endpoint nhận `code` → POST `{OIDC_ISSUER}/oauth/v2/token` → nhận `access_token` + `id_token`
- Verify `id_token` signature via JWKS (`{OIDC_ISSUER}/oauth/v2/keys`) — CACHE 1h
- Extract identity từ `id_token.email` + roles từ `id_token["urn:zitadel:iam:org:project:roles"]`
- `/logout` → clear local session → redirect `{OIDC_ISSUER}/oidc/v1/end_session?client_id=...&post_logout_redirect_uri=...`

**App changes required:**
- Add OIDC library (framework-appropriate — xem examples/)
- Add `/login`, `/callback/<framework-path>`, `/logout` routes
- Add JWT verify middleware (JWKS cached)
- Store session (cookie hoặc server-side)
- Handle PKCE cho SPA / mobile (KHÔNG dùng `CLIENT_SECRET` trong browser)

### Pattern C — Federated Login (add-only, preserve existing auth)

**Semantics:**
- SSO endpoint đặt SONG SONG với existing login endpoint (không thay)
- SPA add "Login via Central SSO" button dưới password form (không thay form)
- After successful SSO: swap Zitadel `id_token` → local token qua REUSE existing token issuance primitive
- Existing auth code (password, 2FA, MFA, JWT rotation, RBAC) UNTOUCHED

**Discovery Script (AI MUST run first — framework-agnostic):**

1. Detect language: check `{package.json, pyproject.toml, go.mod, Gemfile, pom.xml, *.csproj}`
2. Detect framework: grep deps for `{express, nest, fastapi, django, flask, gin, spring, rails, aspnet, ...}`
3. Detect existing auth primitive: grep for `{jwt.sign, jwt.encode, create_access_token, sign_in, create_session, ...}`
4. Detect SPA state store (nếu SPA): grep for `{zustand, redux, pinia, vuex, jotai, recoil, ngrx}`
5. Detect auth module path convention của framework
6. REPORT to member: `Detected {LANG} + {FRAMEWORK} + existing auth primitive: <PRIMITIVE>. Recommend deps: <LIB_LIST>. Files to create: <LIST>. Files to APPEND (0 logic touch): <LIST>. Proceed?`

**App changes required (abstract — no hardcoded deps):**

- Add `<SSO_SERVICE>` (new file) — verify id_token qua JWKS + lookup user local by email + REUSE `<TOKEN_ISSUANCE_PRIMITIVE>` (grep-discover từ existing code)
- Add `<SSO_CONTROLLER>` (new file) — expose `GET /auth/sso/config` (SPA runtime fetch) + `POST /auth/sso/callback` (swap token)
- Add `<CONFIG_LOADER>` (new file) — load 4 SSO env vars
- APPEND `<AUTH_MODULE>` register new controller + service (0 line modified existing register)
- APPEND `<CONFIG_FILE>` add `sso:` section (0 line modified existing config)
- (SPA) Add `<SSO_MANAGER>` (new file) — OIDC client PKCE wrapper, runtime config fetch
- (SPA) Add `<SSO_BUTTON>` (new component) — render dưới existing login form
- (SPA) Add `<SSO_CALLBACK_ROUTE>` (new page) — hoàn tất PKCE + swap
- (SPA) APPEND `<ROUTES_FILE>` add callback route (0 line modified existing routes)
- (SPA) APPEND `<LOGIN_PAGE>` render `<SSO_BUTTON>` dưới form (0 line modified existing form)

**Auto-provision policy (choose one):**

- **Deny 403 + admin pre-provision** — an toàn nhất, admin control ai vào. Zero unknown user.
- **Auto-create từ Zitadel role claim** với fail-safe 0-role → 403. Map claim `urn:zitadel:iam:org:project:roles`: role chứa "admin" → superuser flag, khác → default permissions rỗng. Admin nhớ cấp permissions chi tiết sau.

**SKIP local 2FA/Passkey sau SSO** — trust Zitadel + GitLab MFA (org policy). Không double-prompt MFA.

Concrete reference: `examples/federated-login-example.md`.

---

## 3. Security invariants (BẮT BUỘC — AI KHÔNG được bỏ)

1. **App bind `127.0.0.1`**, NEVER `0.0.0.0` — attacker bypass oauth2-proxy bằng cách gọi thẳng.
2. **Cookie secure=true** khi prod HTTPS. Cookie httpOnly=true luôn. SameSite=Lax (Strict nếu no cross-site).
3. **Cookie secret ≥ 32 bytes random** (Pattern A oauth2-proxy). Rotate = user relogin.
4. **State + Nonce + PKCE** — KHÔNG disable trong Pattern B. State chống CSRF, nonce chống replay, PKCE chống code interception.
5. **JWT verify signature via JWKS** — NEVER accept unsigned JWT hoặc skip verify. Cache JWKS 1h, refresh nếu `kid` không khớp.
6. **Verify `iss` claim** khớp `OIDC_ISSUER`, `aud` khớp `CLIENT_ID`, `exp` chưa hết hạn.
7. **KHÔNG trust `X-Auth-Request-*` headers** khi app KHÔNG có oauth2-proxy trước (attacker chỉ cần curl set header giả).
8. **Sign-out chain đầy đủ** — clear local session + oauth2-proxy cookie + Zitadel session. Half-way sign-out = next login skip MFA.
9. **KHÔNG hardcode `OIDC_ISSUER` / `CLIENT_ID` / `CLIENT_SECRET`** — luôn env var. `.env` phải trong `.gitignore`.
10. **HTTPS bắt buộc prod** (Zitadel reject HTTP redirect_uri trừ khi Zitadel bật Development Mode).

---

## 4. Env var contract

App phải support (via `.env` hoặc environment):

```env
# Cấp bởi Central RBAC portal
OIDC_ISSUER=http://10.200.0.125
CLIENT_ID=<snowflake-number>
CLIENT_SECRET=<secret>    # Pattern B Basic auth apps only

# App-specific
APP_HOST=app.example.com
APP_PORT=3000             # port app native listen

# Pattern A oauth2-proxy only
COOKIE_SECRET=<32-random>
```

**KHÔNG bao giờ commit `.env`.** Add `.env` vào `.gitignore` nếu chưa có. Provide `.env.example` với placeholder.

---

## 5. Refactor delta contract

### Pattern A refactor (framework-agnostic pseudocode)

```pseudocode
// BEFORE (typical vibecode)
function getCurrentUser(req):
  return req.session.user  // hoặc hardcoded admin

// AFTER
function getCurrentUser(req):
  email = req.header("X-Auth-Request-Email")
  if not email: return null  // KHÔNG throw — để middleware handle 401
  return { email: email, username: req.header("X-Auth-Request-Preferred-Username") }
```

Logout link:
```html
<!-- BEFORE -->
<a href="/logout">Sign out</a>

<!-- AFTER -->
<a href="/oauth2/sign_out?rd=https%3A%2F%2Fapp.example.com%2F">Sign out</a>
```

Xoá login form + session middleware cũ.

### Pattern B refactor (framework-specific — xem examples/)

3 endpoint mới: `/login`, `/callback`, `/logout`. 1 middleware: JWT verify + inject `req.user`.

---

## 6. Refactor validation checklist (AI self-check)

Chạy TRƯỚC khi báo done:

- [ ] `grep -rE "0\.0\.0\.0|listen.*0\.0\.0\.0" src/` → 0 match (app bind 127.0.0.1)
- [ ] `grep -rE "http://.*zitadel|10\.200\.0\.125" src/` → 0 match trong code (chỉ trong config docs)
- [ ] `grep -rE "CLIENT_SECRET|clientSecret" src/` → chỉ đọc từ env, không hardcode
- [ ] `.env` trong `.gitignore` — verify: `git check-ignore .env` return `.env`
- [ ] `.env.example` tồn tại với placeholder
- [ ] (Pattern A) Reverse proxy config chứa `/oauth2/*` handler + `forward_auth`
- [ ] (Pattern A) App KHÔNG có OIDC library dependency
- [ ] (Pattern B) `state`, `nonce`, PKCE `code_challenge` được tạo random per-request
- [ ] (Pattern B) JWT verify dùng JWKS (không hardcode public key)
- [ ] (Pattern B) `iss` + `aud` + `exp` được verify
- [ ] Sign-out chain: local session cleared + redirect `/oauth2/sign_out` (A) hoặc `end_session` (B)
- [ ] Health check endpoint (`/health`, `/ready`) bypass IAP (nếu có ops monitor)
- [ ] `.gitignore` chứa `.env`
- [ ] README/AGENTS.md app cập nhật env vars cần set

---

## 7. What AI must NOT change (business logic invariants)

- KHÔNG xoá / rewrite business logic (data models, API endpoints ngoài auth, background jobs)
- KHÔNG đổi framework version chính (VD Express 4 → 5) trừ khi member yêu cầu
- KHÔNG add analytics / telemetry / third-party service không có trong requirements gốc
- KHÔNG rewrite CSS / UI trừ khi refactor auth UI (login/logout buttons)
- KHÔNG đổi database schema
- KHÔNG add new dependency ngoài: OIDC library (Pattern B) + oauth2-proxy config (Pattern A) + JWKS verify library (Pattern C)
- **Pattern C**: NEVER modify any existing auth-related file (`AuthController`/`AuthService`/`JwtStrategy`/`PasskeyService`/`TwoFactorService`/`TokenService`, SPA login form, existing session/state store). Only APPEND wiring lines.

---

## 8. Common issues + AI resolution

| Symptom | Root cause | AI fix |
|---|---|---|
| `redirect_uri_mismatch` | REDIRECT_URL trong Zitadel Console ≠ URL app emit | Verify EXACT match (scheme + host + port + path + trailing slash). AI: log URL app emit, so với REDIRECT_URL từ credential |
| `invalid_client` | CLIENT_ID / SECRET sai | AI: verify env var đọc đúng, không có whitespace |
| Cookie oversize >4KB, browser reject | User có nhiều UserGrant → roles claim lớn | AI: switch scope-limited claim `urn:zitadel:iam:org:project:id:{CLIENT_ID}:roles` — chỉ khi Central admin đã enable |
| Header `X-Auth-Request-Email` empty ở Pattern A | oauth2-proxy chưa auth hoặc `copy_headers` thiếu | AI: verify Caddyfile / Traefik middleware `copy_headers` list |
| JWT verify fail `kid not found` | JWKS cache stale sau Zitadel rotate | AI: force refresh JWKS, KHÔNG cache expired kid |
| Sign-out không clear Zitadel session | Chỉ clear local session | AI: add end_session redirect chain |
| App accessible từ IP LAN bypass reverse proxy | App bind 0.0.0.0 | AI: rebind 127.0.0.1, verify `ss -tlnp` |

---

## 9. Version pinning (repro — EXAMPLE stacks only)

> **Framework-agnostic note:** Versions dưới đây chỉ apply cho SPECIFIC EXAMPLE files. For YOUR stack, dùng Discovery Script (§2.5 Pattern C hoặc bootstrap CLAUDE.md/AGENTS.md) — AI recommends equivalents based on detected language/framework. Hardcoded versions here are for reference implementations only, KHÔNG bắt buộc cho stack khác.

- `oauth2-proxy` v7.7.1 — Pattern A sidecar reference
- Auth.js (NextAuth v5) `^5.0.0-beta.20` — Next.js reference example
- `oidc-client-ts` `^3.0.1` — React/Vanilla SPA reference example
- `jose` `^5` — Node JWKS verify (Pattern C NestJS example)
- Node `>=20` (Auth.js v5 requirement)
- Python `>=3.11` (FastAPI reference)

Nếu framework project version khác major, AI adapt syntax nhưng giữ security invariants.

---

## 10. Prompt cheatsheet cho member

Xem `bootstrap/INSTALL.md` — 6-prompt cheatsheet (Implement / Dry-run / Force Pattern / Auto mode / Rollback / Test-troubleshoot) là **source of truth** cho member prompts. AI reads `bootstrap/{CLAUDE,AGENTS}.md` để biết trigger detection + AI Workflow 3-phase strict (Scout → Report → WAIT → Implement → Verify).

---

## 11. Common Traps (rút từ real implementations)

### Trap 1 — Central RBAC wizard tạo BASIC auth, không PKCE

Wizard `POST /v1/admin/apps` mặc định set `authMethodType: OIDC_AUTH_METHOD_TYPE_BASIC` (confidential client với `client_secret`). Zitadel sẽ REJECT SPA PKCE flow không có secret.

**Fix**: Sau khi wizard done, vào Zitadel Console → Project → Application → **Configuration** → đổi Auth Method sang **None (PKCE)** + enable **Require Proof Key for Code Exchange**.

### Trap 2 — CORS "Additional Origins" chưa whitelist

SPA PKCE call token endpoint từ browser → Zitadel CORS block nếu origin chưa được whitelist.

**Fix**: Zitadel Console → Application → **Additional Origins** → add `https://<app-host>` (cả dev + prod domain nếu có).

### Trap 3 — DNS mismatch giữa deploy target và domain

Deploy code lên VPS A nhưng domain trỏ VPS B → code mới không có hiệu lực trên public URL.

**Verify TRƯỚC deploy:**
```bash
nslookup <APP_HOST>
# So sánh với IP VPS mình đang SSH
```

### Trap 4 — Zitadel session collision khi test

User đang login Zitadel Console (VD `admin@<zitadel-host>`) trong browser → click SSO → Zitadel reuse session → id_token trả admin identity, không phải GitLab user → 403 sai nguyên nhân.

**Fix**:
- Fresh incognito browser (Ctrl+Shift+N)
- HOẶC visit `<OIDC_ISSUER>/logout` trước khi test SSO

### Trap 5 — Vite hard-embed SSO config bắt rebuild web khi rotate CLIENT_ID

`VITE_SSO_*` env compile vào SPA bundle at build time → đổi CLIENT_ID phải rebuild + redeploy web.

**Fix**: Backend expose `GET /auth/sso/config` runtime endpoint. SPA fetch runtime config → 0 rebuild khi rotate.

### Trap 6 — Zitadel role claim chưa được include trong id_token

Auto-provision Pattern C cần parse role claim `urn:zitadel:iam:org:project:roles`. Nếu app không enable "Add Roles To ID Token" → claim empty → auto-provision fail-safe 403.

**Fix**: Zitadel Console → Application → **Token Settings** → **Add Roles To ID Token = ON** + **User Info Inside ID Token = ON**.
