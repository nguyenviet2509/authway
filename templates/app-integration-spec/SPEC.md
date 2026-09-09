# Authway App Integration SPEC (AI contract)

**Purpose:** AI đọc file này + code project + credential từ Central → refactor project cho Central SSO integration đúng contract.

**Prerequisite:** Đọc `DECISION-TREE.md` TRƯỚC để chọn Pattern A hoặc B.

---

## 1. What Central RBAC provides

Khi admin đăng ký app trên Central portal, member nhận:

| Field | Type | Example | Notes |
|---|---|---|---|
| `OIDC_ISSUER` | URL | `http://10.200.0.125` (LAN) / `https://zitadel.000nethost.com` (prod) | Base URL Zitadel |
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
11. **Manifest = public schema doc, KHÔNG chứa sensitive info.** Manifest endpoint (§12) sẽ Google-indexable (nếu chưa có `X-Robots-Tag: noindex`) + curl-accessible từ internet. → **CẤM** include: internal URL, IP nội bộ, DB schema chi tiết, connection string, hostname service khác, token/secret, PII, business rule chi tiết. → **CHỈ** include: permission ID (đã prefix service slug), Vietnamese action description (verb + noun), role key, role's permission list. Xem §12.2 bảng "Safe vs Forbidden fields".

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

---

## 12. RBAC Permission Manifest (Phase 4 — sau khi SSO đã done)

**When to activate:** app cần Central quản lý permission catalog + role assignment (thay vì tự lưu roles/permissions trong DB app). Nếu app chỉ cần identity (email/username) → skip §12.

### 12.1 What Central RBAC expects

- App expose **manifest endpoint** — file JSON declare toàn bộ permission app support + default roles template
- Admin Central bấm "Sync manifest" từ portal → Central fetch → validate schema → compute diff vs DB → admin approve → apply
- Sau apply: role management, user-role assignment, permission check runtime tất cả qua Central RBAC API

**Manifest URL:**
- Path relative: `.well-known/rbac-permissions.json`
- Absolute URL member khai vào field `manifest_url` khi register app ở Central portal:
  - Backend có API prefix (`/api`): `<APP_URL>/api/.well-known/rbac-permissions.json`
  - Không prefix / static host: `<APP_URL>/.well-known/rbac-permissions.json`

**Endpoint requirements:**
- Public, **NO auth** (Central fetch anonymously) — an toàn miễn tuân §3 rule 11 + §12.2 content policy
- `Content-Type: application/json; charset=utf-8`
- `Cache-Control: public, max-age=300`
- `ETag: "<version-string>"` (optional but recommended — Central respect If-None-Match)
- `X-Robots-Tag: noindex` — tránh Google/Bing index endpoint public
- **Rate limit tại reverse proxy** (Caddy/nginx/Traefik): khuyến nghị 60 req/min per IP cho path `.well-known/rbac-permissions.json` — chặn scraping mass
- **KHÔNG log** full request/response body ở access log — chỉ status code + bytes (tránh index sensitive text vào log stack nếu member vô tình leak)

### 12.2 Manifest schema contract (v1)

```json
{
  "schema": "1",
  "service": "<APP_SLUG>",
  "version": "<VERSION_STRING>",
  "permissions": [
    {
      "id": "<APP_SLUG>:<resource>.<action>",
      "description": "<Human-readable Vietnamese>",
      "since_version": "<VERSION_STRING>",
      "status": "active"
    }
  ],
  "default_roles": [
    {
      "key": "<APP_SLUG>.<role-name>",
      "description": "<Human-readable>",
      "permissions": ["<APP_SLUG>:<resource>.<action>", "..."]
    }
  ]
}
```

**Constraints (regex enforced bởi Central — sai = sync reject):**

| Field | Rule |
|---|---|
| `schema` | Literal `"1"` |
| `service` | `^[a-z][a-z0-9-]{2,31}$` — MUST match slug đã register ở Central portal EXACT |
| `version` | 1-64 chars — semver hoặc date-based, deterministic per build |
| `permissions[].id` | `^[a-z][a-z0-9-]{2,31}:[a-z][a-z0-9._-]+$` — first segment MUST khớp `service` field (namespace enforcement) |
| `permissions[].description` | 1-500 chars |
| `permissions[].status` | `active` (default) hoặc `soft-deleted` |
| `permissions[].alias_of` | Optional — id của permission renamed (backward compat) |
| `permissions` size | Max 500 entries |
| `default_roles[].key` | `^[a-z][a-z0-9-]{2,31}\.[a-z][a-z0-9]{1,31}$` — format `<slug>.<name>` |
| `default_roles` size | Max 50 entries |
| Min 1 role | Bắt buộc có 1 entry với key = `<APP_SLUG>.admin` (superuser fallback) |

**Content policy — Safe vs Forbidden fields (BẮT BUỘC — §3 rule 11 chi tiết):**

Vì manifest public → phải viết như public API doc, không phải internal comment.

| Field | ✅ Allowed | ❌ Cấm |
|---|---|---|
| `permissions[].id` | `<slug>:<resource>.<action>` — abstract action name | Nhúng ID user thật / tenant ID / UUID cụ thể |
| `permissions[].description` | Vietnamese verb + noun ngắn ("Xem thiết bị", "Duyệt cấp phát") | Business rule chi tiết ("Duyệt khi >5M cần CFO ký"), URL nội bộ, hostname, IP, DB name, stack trace, code comment |
| `default_roles[].key` | `<slug>.<role-name>` abstract | Nhúng tên user thật / employee code |
| `default_roles[].description` | Vietnamese role name ("Quản trị", "Nghiệp vụ") | SOP nội bộ, tên team member, workflow chi tiết |
| `default_roles[].permissions` | Reference permission id đã declare trong same manifest | Reference permission của app khác (leak namespace) |
| ANY field | (không có gì khác) | HTTP URL, `\d+\.\d+\.\d+\.\d+`, `password/token/secret/key`, hostname `*-prod/dev/staging`, connection string |

**Self-check regex (dev/AI phải chạy trước ship):**
```
grep -iE 'https?://|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|-(prod|dev|staging|internal)|password|token|secret|apikey' manifest.json
```
Nếu match → REJECT, sửa description thành abstract Vietnamese noun.

**Validate manifest TRƯỚC ship (dev-time):**
```bash
# Fetch Central schema (một lần, cache local)
curl -sSL <CENTRAL_URL>/.well-known/rbac-permissions-schema.json -o rbac-permissions-schema.json

# Validate app manifest against schema
npx -y ajv-cli validate -s rbac-permissions-schema.json -d <APP_URL>/.well-known/rbac-permissions.json
```

### 12.3 Default pattern — Manual declare + boot validator

**Rationale:** literal array trong source file — grep-friendly, version-diff-friendly, framework-agnostic. Boot-time validator chống drift giữa declared list và permission dùng thực tế.

**File structure (kebab-case cho JS/TS/Python; respect ngôn ngữ khác):**
```
<APP_ROOT>/src/rbac/                # hoặc convention framework tương đương
├── permissions-catalog.<ext>       # literal array + APP_SLUG + version fn
├── manifest-endpoint.<ext>         # route handler build JSON response
└── boot-validator.<ext>            # cross-check declared vs actual routes, set /ready state
```

**Pseudocode `permissions-catalog` (framework-agnostic):**
```pseudo
APP_SLUG = "<slug>"

buildVersion() = process.env.GIT_SHA?.slice(0, 8) OR `${today("YYYY-MM-DD")}.1`

# Flat array — grep-friendly, review-friendly
PERMISSIONS = [
  { id: "<slug>:<resource>.<action>", description: "<Human vietnamese>" },
  ...
]

# 3 recommended roles — customize theo nghiệp vụ, có thể add thêm role custom
DEFAULT_ROLES = [
  {
    key: "<slug>.admin",
    description: "Quản trị viên — full access",
    permissions: PERMISSIONS.map(p => p.id)                    # all
  },
  {
    key: "<slug>.editor",
    description: "Nghiệp vụ — CRUD trừ delete/approve/user-mgmt",
    permissions: PERMISSIONS.filter(p => !isDestructiveOrUserMgmt(p.id)).map(p => p.id)
  },
  {
    key: "<slug>.viewer",
    description: "Chỉ xem",
    permissions: PERMISSIONS.filter(p => isReadOrExport(p.id)).map(p => p.id)
  }
]

buildManifest() = {
  schema: "1",
  service: APP_SLUG,
  version: buildVersion(),
  permissions: PERMISSIONS,
  default_roles: DEFAULT_ROLES
}
```

**Pseudocode `manifest-endpoint`:**
```pseudo
# Register route theo framework convention
GET "<PATH>/.well-known/rbac-permissions.json" → handler(req, res):
  manifest = MEMOIZED_MANIFEST OR (MEMOIZED_MANIFEST = buildManifest())
  res.setHeader("Content-Type", "application/json; charset=utf-8")
  res.setHeader("Cache-Control", "public, max-age=300")
  res.setHeader("ETag", `"${manifest.version}"`)
  res.send(JSON.stringify(manifest))
```

**Pseudocode `boot-validator`:**
```pseudo
READY_STATE = "STARTING"

onBoot():
  declared_ids = new Set(PERMISSIONS.map(p => p.id))
  actual_ids   = scanRouteRegistryForPermissionUsage()   # framework-specific — grep decorator/middleware

  missing = actual_ids.filter(id => !declared_ids.has(id))
  unused  = [...declared_ids].filter(id => !actual_ids.has(id))

  if missing.length > 0:
    log.ERROR("[rbac-manifest] Routes use undeclared permissions:", missing)
    log.ERROR("[rbac-manifest] Fix: add to PERMISSIONS array in permissions-catalog")
    READY_STATE = "UNHEALTHY"           # /ready → 503
  else:
    if unused.length > 0:
      log.WARN("[rbac-manifest] Declared but unused (dead code):", unused)
    log.INFO(`[rbac-manifest] Catalog OK — ${declared_ids.size} permissions declared`)
    READY_STATE = "HEALTHY"

# /ready endpoint
GET "/ready" → 200 if READY_STATE == "HEALTHY" else 503
```

### 12.4 Refactor delta

**Files to CREATE (new, ~150 LoC total):**
- `<APP_ROOT>/src/rbac/permissions-catalog.<ext>` — literal array + APP_SLUG + version fn
- `<APP_ROOT>/src/rbac/manifest-endpoint.<ext>` — route handler
- `<APP_ROOT>/src/rbac/boot-validator.<ext>` — cross-check + /ready state

**Files to APPEND (0 line modified existing logic):**
- Router / module init file → register manifest endpoint route
- Boot sequence file → call `onBoot()` validator, initialize READY_STATE
- `/ready` handler (nếu app đã có) → include RBAC catalog state; nếu chưa có → boot-validator tự create endpoint

**Files NOT to touch:**
- Business logic (data models, business API endpoints, background jobs)
- Existing auth code (SSO integration đã done ở Pattern A/B/C)
- `.env` structure — RBAC manifest KHÔNG cần env var mới (trừ optional `GIT_SHA` cho version)

### 12.5 Default roles convention

**Recommended pattern (start point, member customize theo nghiệp vụ):**

| Role | Permission set |
|---|---|
| `<slug>.admin` | ALL permissions |
| `<slug>.editor` | ALL EXCEPT: `*.delete`, `*.approve`, `users.*`, `object-permissions.*`, `user-groups.*` |
| `<slug>.viewer` | ONLY: `*.read`, `*.export` |

**Custom roles:** member được thêm role theo nghiệp vụ (VD `<slug>.approver`, `<slug>.auditor`, `<slug>.support-l1`). Central UI display tất cả roles trong `default_roles` khi admin assign user.

**Note quan trọng:** `default_roles` = **TEMPLATE SEED** — Central admin có thể tạo thêm role custom trên UI sau, không bị giới hạn bởi list này. Manifest chỉ seed lần đầu + reference cho admin.

**Constraint:** min 1 role `<APP_SLUG>.admin` — bắt buộc để có superuser fallback nếu Central admin không config gì.

### 12.6 Sync workflow (admin-side — NOT member concern, FYI only)

1. Member deploy app → manifest endpoint live tại `<manifest_url>`
2. Admin vào Central UI → **Apps** → `<APP_SLUG>` → **Actions → Sync manifest**
3. Central fetch `manifest_url` → validate schema qua zod → nếu fail: display error, stop
4. Central compute diff vs DB current state:
   - **Add** — permission mới trong manifest, chưa có trong DB
   - **Update-desc** — permission đã có, description đổi
   - **Explicit-deprecate** — permission trong DB `status: soft-deleted` trong manifest (member soft-delete)
   - **Implicit-deprecate** — permission trong DB không còn xuất hiện trong manifest + không marked deprecate
5. Admin review 4-category diff → tick checkbox implicit-deprecate (default UNCHECKED, warning banner) → **Apply**
6. Central persist → audit trail entry
7. Role management, user assignment, permission check runtime → dùng Central RBAC API tiếp

**Version bump flow:** member ship version mới → app RESTART (memoized manifest rebuild) → admin sync lại cùng flow. Không có auto-sync để tránh drift ẩn.

### 12.7 Validation checklist (RBAC — thêm vào §6)

Chạy TRƯỚC khi báo done Phase 4:

- [ ] `curl <APP_URL>/<path>/.well-known/rbac-permissions.json` → HTTP 200 + `Content-Type: application/json`
- [ ] Response validate PASS qua Central schema:
      ```bash
      curl -sSL <CENTRAL_URL>/.well-known/rbac-permissions-schema.json > /tmp/schema.json
      curl -sSL <APP_URL>/<path>/.well-known/rbac-permissions.json | npx -y ajv-cli validate -s /tmp/schema.json -d /dev/stdin
      ```
- [ ] `permissions[].id` first segment == `service` field (namespace check) — Central reject nếu mismatch
- [ ] `default_roles[]` có min 1 entry với key = `<APP_SLUG>.admin`
- [ ] Boot validator log emit khi startup — verify `docker logs` / `journalctl` thấy `[rbac-manifest]`
- [ ] `/ready` return 503 khi validator fail (test: xóa 1 entry declared → restart → `curl /ready` phải 503)
- [ ] Response headers có `ETag` + `Cache-Control: public, max-age=300`
- [ ] Reverse proxy / WAF / CDN KHÔNG block `.well-known/*` path (verify curl từ external network)
- [ ] Slug trong manifest EXACT match slug đã register ở Central portal (không typo)
- [ ] `manifest_url` field đã update ở Central portal (nếu app đã register trước Phase 4)

### 12.8 Common traps (RBAC — thêm vào §11)

#### Trap 7 — Slug mismatch giữa app register và manifest `service` field

- **Symptom**: Central sync fail "namespace violation" hoặc "service does not match app slug"
- **Root cause**: admin register slug `<slug-a>` ở Central portal nhưng manifest ghi `service: "<slug-b>"`
- **Fix**: verify slug ở Central Apps table = `service` field trong manifest EXACT match (case-sensitive)

#### Trap 8 — Global prefix framework nuốt `.well-known` path

- **Symptom**: `curl <APP_URL>/.well-known/rbac-permissions.json` → 404 (route không match)
- **Root cause**: framework auto-prefix mọi route (NestJS `setGlobalPrefix('api')`, Django `path('api/', include(...))`, FastAPI `app.include_router(router, prefix='/api')`)
- **Fix**: hoặc register endpoint dưới prefix (`<APP_URL>/api/.well-known/...`) và khai đúng vào `manifest_url` ở Central portal, hoặc whitelist path exclusion khỏi global prefix (framework-specific)

#### Trap 9 — ETag / version không stable → Central re-sync no-op

- **Symptom**: admin bấm sync → diff empty dù member vừa ship perm mới
- **Root cause**: version string non-deterministic (VD `Date.now()` — đổi mỗi request), hoặc member không restart app sau deploy → memoized manifest cũ vẫn serve
- **Fix**:
  - Version = `GIT_SHA` short (deterministic per build) hoặc date-based `YYYY-MM-DD.N` (bump N khi ship trong cùng ngày)
  - RESTART app sau mỗi deploy để memoized manifest rebuild

#### Trap 10 — Reverse proxy / WAF / CDN block `.well-known/*`

- **Symptom**: `curl` từ external → 404 hoặc 403, nhưng gọi trực tiếp container/localhost OK
- **Root cause**: OpenResty / Cloudflare / nginx / ModSecurity block path pattern `.well-known/*` mặc định (đã hit prod tháng 8/2026 với `.well-known/rbac-permissions-schema`)
- **Fix**: whitelist path trong proxy config; verify BẮT BUỘC bằng `curl` từ external TRƯỚC báo done

#### Trap 11 — Memoized manifest không refresh sau version bump

- **Symptom**: member ship version mới, deploy xong, nhưng Central sync vẫn thấy version cũ
- **Root cause**: `buildManifest()` memoize forever trong process memory, không invalidate runtime
- **Fix**: memoize OK (rebuild only on process restart) — nhưng member phải RESTART app sau deploy (không chỉ reload code). Document rõ trong deploy runbook

#### Trap 12 — Manifest publish nhưng `manifest_url` chưa set ở Central

- **Symptom**: admin bấm sync → error "no manifest URL configured for this app"
- **Root cause**: app đã register trước khi có Phase 4 → field `manifest_url` empty ở DB
- **Fix**: admin vào Central UI → **Apps** → `<APP_SLUG>` → **Edit** → set field `Manifest URL` = full absolute URL → save. Sync lại.

#### Trap 13 — Leak sensitive info qua manifest description

- **Symptom**: security review / Google search phát hiện manifest chứa `"connect qua db-prod-01:5432"` hoặc `"gọi https://internal-billing.corp/api"` hoặc `"password field bị hash SHA256 salt=xxx"`
- **Root cause**: dev/AI copy-paste code comment / SOP nội bộ / stack trace vào `description` field khi build permissions catalog. Manifest public → leak internal architecture cho attacker recon.
- **Fix**:
  - `description` = business action từ POV end-user, viết Vietnamese noun ngắn ("Xem thiết bị", KHÔNG "Xem thiết bị từ MySQL table `assets` join `branches`")
  - Chạy self-check regex (§12.2) trước ship
  - Rotate: nếu đã leak — bump version + apply-diff mới, verify Central không cache raw sensitive (Central chỉ lưu permission id + description sau apply, không raw manifest → OK sau khi member ship version fix)
  - Cấu hình `X-Robots-Tag: noindex` ngay để tránh Google/Bing index sẵn
