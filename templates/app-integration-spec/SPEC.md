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
- KHÔNG add new dependency ngoài: OIDC library (Pattern B) + oauth2-proxy config (Pattern A)

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

## 9. Version pinning (repro)

- `oauth2-proxy` v7.7.1
- Auth.js (NextAuth v5) `^5.0.0-beta.20` — cho Next.js reference
- `oidc-client-ts` `^3.0.1` — cho SPA reference
- Node `>=20` (Auth.js v5 requirement)
- Python `>=3.11` (FastAPI reference)

Nếu framework project version khác major, AI adapt syntax nhưng giữ security invariants.

---

## 10. Prompt gợi ý cho member

Copy đoạn dưới paste vào Claude/Cursor cùng file spec:

```
Tôi có project [framework] tại [path]. Nhiệm vụ: refactor để integrate Central SSO.

Credential từ admin:
- OIDC_ISSUER: <value>
- CLIENT_ID: <value>
- CLIENT_SECRET: <value>  (bỏ nếu SPA)
- REDIRECT_URL: <value>
- POST_LOGOUT_URL: <value>

Bước làm:
1. Đọc DECISION-TREE.md → chọn Pattern A hoặc B
2. Đọc SPEC.md → hiểu contract + security invariants
3. Đọc examples/<framework gần nhất>.md → concrete pattern
4. Scan code project → identify auth cũ cần thay
5. Refactor + create .env.example + update .gitignore
6. Chạy checklist section 6 SPEC.md — self-validate
7. Report back: files changed, new deps added, env vars required, test flow
```
