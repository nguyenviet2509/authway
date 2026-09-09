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

---

## Pattern C — Federated Login (preserve existing auth)

**When to use**: App đã có auth phức tạp (password + 2FA/Passkey + JWT rotation + local RBAC) mà member KHÔNG muốn refactor. SSO là 2nd IdP path song song, 0 dòng logic cũ bị đổi.

Concrete reference: `examples/federated-login-example.md` (NestJS + Prisma + zustand example với adaptation table cho 12 stacks).

### Discovery Script (AI MUST run FIRST — BEFORE any code change)

1. Detect language: `ls {package.json, pyproject.toml, go.mod, Gemfile, pom.xml, *.csproj}`
2. Detect framework: grep deps for common frameworks
3. Detect existing auth primitive (grep-discover — DO NOT reimplement):
   - JS: `jwt.sign`, `signInWith`, session middleware
   - Python: `create_access_token`, `login_user`, `django.contrib.auth.login`
   - Go: `jwt.Sign`, session store
   - Ruby: `sign_in`, Devise helpers
4. Detect SPA state store (nếu SPA): `zustand`, `redux`, `pinia`, `vuex`, `jotai`, `recoil`, `ngrx`
5. REPORT stack + recommended deps + files to create/append + LoC delta

## AI Workflow — MUST FOLLOW (Central SSO integration)

### Trigger detection (fuzzy)

Activate this workflow when member prompt contains:
- Keywords: `{authway, central sso, zitadel, gitlab sso, central rbac}`
- + verb: `{implement, setup, add, tich hop, refactor, integrate}`

**Examples triggering workflow:**
- "Implement Authway SSO"
- "Add zitadel login"
- "Tích hợp Central RBAC"
- "Setup GitLab SSO qua Zitadel"
- "Refactor auth qua Central"

### Phase 1 — Scout & Report (READ-ONLY, DO NOT touch code)

1. Read `.env` — verify `OIDC_ISSUER`, `CLIENT_ID`, `REDIRECT_URL` present
   - Missing → tell member fill first, STOP
2. Run Discovery Script above
3. Select Pattern via `DECISION-TREE.md` Q0 → Q5
4. REPORT to member (do not proceed yet):

```
Detected stack: <LANG> + <FRAMEWORK> + <AUTH_LIB> + <STATE_LIB>
Selected pattern: <A|B|C> because <reason>
Deps to install: <LIB1@version>, <LIB2@version>
Files to create (new): <list>
Files to APPEND wiring (0 logic touch): <list>
Estimated delta: +<X> LoC / -0 LoC (Pattern C) or replace <Y> LoC (A/B)
Rollback strategy: delete feature branch OR .env toggle SSO_ISSUER=""

Proceed?
```

5. WAIT for member "OK/proceed/yes" — DO NOT touch code

### Phase 2 — Implement (only after member OK)

1. Git: `git checkout -b feat/authway-sso-integration` (NEVER commit master)
2. Install deps per Phase 1 report
3. Create new files per pattern
4. APPEND wiring files — verify diff KHÔNG touch existing logic
5. Build/compile check
6. Commit + push feature branch
7. Report MR URL

### Phase 3 — Verify & Handoff

1. Provide deploy steps (member executes manually — không auto-deploy prod)
2. E2E test checklist:
   - Fresh incognito browser (tránh Zitadel session collision)
   - Zitadel Console verify: PKCE method + Additional Origins + Add Roles To ID Token
   - Browser hygiene: `<OIDC_ISSUER>/logout` trước test SSO
3. Rollback procedure documented

### Safety Rules (INVIOLABLE)

- **Pattern C**: NEVER modify any existing auth-related file
- NEVER commit master directly (feature branch always)
- NEVER install deps without member OK
- NEVER skip Phase 1 report + WAIT
- If uncertain → STOP + ask member, don't guess stack/pattern
- If member says `--auto`: skip Phase 1 wait but still do Phase 1 report inline

### Failure modes

- Member says "no" to Phase 1 → adjust plan per feedback, re-report, wait again
- Member says "force Pattern X" → override auto-selection
- Discovery detects unknown framework → ASK member for guidance, don't guess
- Existing auth uses uncommon primitive → REPORT + ask member confirm reuse strategy

## Post-implementation traps checklist

Sau khi cook + deploy, verify 6 traps trong `SPEC.md` §11:

1. [ ] Zitadel app auth method đã đổi sang **None (PKCE)** (nếu SPA)
2. [ ] Zitadel Additional Origins đã whitelist `https://<app-host>` (dev + prod nếu có)
3. [ ] `nslookup <app-host>` verify DNS trỏ đúng VPS deploy
4. [ ] Test SSO trong fresh incognito browser (tránh Zitadel session collision)
5. [ ] SPA fetch `/auth/sso/config` runtime (không Vite hard-embed)
6. [ ] Zitadel "Add Roles To ID Token = ON" (nếu Pattern C auto-provision)

---

## Phase 4 — RBAC Permission Manifest (chỉ khi app cần Central quản lý permission)

**When to activate:** app cần Central quản lý permission catalog + role assignment (thay vì tự lưu roles/permissions trong DB app). Nếu app chỉ cần identity → skip Phase 4.

**Deeper reference:** `SPEC.md` §12 + `examples/rbac-manifest-{nestjs,fastapi,express}.md`.

### Trigger detection (fuzzy) — add keywords

Activate Phase 4 workflow khi member prompt chứa:
- Keywords: `{rbac manifest, permission catalog, central sync, phan quyen central, expose permission, sync permission}`
- + verb: `{implement, setup, add, tich hop, expose, publish}`

**Examples triggering Phase 4:**
- "Add RBAC manifest cho app"
- "Expose permission catalog để Central sync"
- "Tích hợp Central RBAC permission sync"
- "Publish rbac-permissions.json endpoint"

### Phase 4.1 — Scout & Report (READ-ONLY)

1. Verify SSO integration (Phase A/B/C) đã done — nếu chưa: STOP, tell member complete SSO Phase 1-3 trước
2. Verify `APP_SLUG` biết rõ — hỏi member (slug đã register ở Central portal), grep `.env` hoặc app config
3. Detect route registry pattern theo framework:
   - NestJS: `@Get/@Post/@Controller` decorators + custom `@RequirePermission()` (nếu có)
   - FastAPI: `@app.get/@router.get` + `Depends(has_permission(...))`
   - Express/Fastify/Koa: `router.get/router.post` + permission middleware
   - Django: `urlpatterns` + `@permission_required` decorator
   - Spring: `@GetMapping/@PostMapping` + `@PreAuthorize`
   - Rails: `routes.rb` + Pundit/CanCanCan policies
   - Go (Gin/Echo/Fiber): route registration + middleware
4. Detect existing permission check pattern (nếu app đã có ACL internal):
   - Grep: `checkPermission`, `hasPermission`, `@RequirePermission`, `@permission_required`, `authorize!`, `enforce`
5. REPORT to member (do not proceed yet):
```
Detected framework: <FW>
APP_SLUG: <slug> (from <source: .env / config / member confirm>)
Existing permission check pattern: <found: <pattern> | not-found>
Routes discovered: <N> routes
Suggested permissions to declare (draft): <M> permissions:
  <slug>:<resource>.<action> — <suggested description>
  ...
Default roles (3 recommended): <slug>.admin, <slug>.editor, <slug>.viewer

Files to create (new):
  - src/rbac/permissions-catalog.<ext>    (~80 LoC — literal array + APP_SLUG + version fn)
  - src/rbac/manifest-endpoint.<ext>      (~30 LoC — route handler)
  - src/rbac/boot-validator.<ext>         (~50 LoC — cross-check + /ready state)

Files to APPEND wiring (0 logic touch):
  - <router/module init file>              (+3 LoC — register endpoint)
  - <boot sequence file>                   (+2 LoC — call onBoot() validator)
  - <existing /ready handler, nếu có>      (+1 LoC — include RBAC state)

Estimated delta: +~165 LoC / -0 LoC

Proceed?
```
6. WAIT for member "OK/proceed/yes" — DO NOT touch code

### Phase 4.2 — Implement (only after member OK)

1. Git: `git checkout -b feat/rbac-manifest-phase4` (feature branch, NEVER commit master)
2. Create 3 file: `permissions-catalog`, `manifest-endpoint`, `boot-validator` per framework example
3. Populate `PERMISSIONS` array — offer draft từ route scan, member confirm/edit BEFORE commit
4. Populate `DEFAULT_ROLES` — 3 recommended (admin/editor/viewer) filter logic
5. APPEND route registration + boot wiring — verify diff KHÔNG touch business logic hoặc auth code cũ
6. Build/compile check — fail = fix + retry
7. Local smoke test:
   ```bash
   curl -sSL http://127.0.0.1:<PORT>/<path>/.well-known/rbac-permissions.json | jq .
   # Expect: valid JSON, schema="1", service=<APP_SLUG>, permissions[], default_roles[]
   ```
8. Optional local validate qua Central schema:
   ```bash
   curl -sSL <CENTRAL_URL>/.well-known/rbac-permissions-schema.json > /tmp/schema.json
   curl -sSL http://127.0.0.1:<PORT>/<path>/.well-known/rbac-permissions.json | npx -y ajv-cli validate -s /tmp/schema.json -d /dev/stdin
   ```
9. Commit + push feature branch

### Phase 4.3 — Verify & Handoff

1. Provide deploy steps (member executes manual — không auto-deploy prod)
2. Post-deploy checklist `SPEC.md` §12.7 (10 items) — walk through with member
3. Notify member — copy-paste template:
```
✅ Phase 4 RBAC Manifest done.

Manifest URL live:
  <APP_URL>/<path>/.well-known/rbac-permissions.json

Next step (admin action, không phải member):
  1. Admin vào Central portal → Apps → <APP_SLUG> → Edit
  2. Field "Manifest URL" = <full absolute URL ở trên>
  3. Save
  4. Actions → Sync manifest → review 4-category diff → Apply
```

### Safety Rules Phase 4 (INVIOLABLE)

- NEVER touch business logic hoặc auth code cũ (Phase A/B/C artifacts)
- NEVER auto-populate `PERMISSIONS` array từ route scan — always show DRAFT + member confirm BEFORE commit
- NEVER commit master directly (feature branch always)
- If `APP_SLUG` unknown → STOP + ask member (không guess)
- If framework unknown → STOP + ask member (không guess pattern)
- If SSO chưa done → STOP + tell member complete Phase 1-3 trước
- If `PERMISSIONS` array > 500 entries → REPORT to member "vượt Central max 500, cần split app"
