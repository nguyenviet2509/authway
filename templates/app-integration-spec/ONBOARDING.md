# Central RBAC — Onboarding guide cho app mới

**Đọc file này khi:** team có 01 ứng dụng mới, muốn tích hợp **SSO auth** + **phân quyền (RBAC)** qua Central RBAC portal (Zitadel v4 backend).

**Bài docs này = flow end-to-end.** Chi tiết technical AI sẽ đọc từ `SPEC.md` + `bootstrap/CLAUDE.md`. Member chỉ cần:
1. Nắm bối cảnh + biết mình đang ở bước nào
2. Copy-paste prompt đúng cho AI agent
3. Verify output ở checkpoint

---

## Bối cảnh

**Central RBAC** = hệ thống tập trung quản lý:
- **Identity** (ai): dùng Zitadel v4 IdP — user đăng nhập bằng email/password / GitLab SSO / passkey
- **Permission catalog** (làm gì): mỗi app declare permissions của mình (VD `<slug>:orders.read`, `<slug>:orders.approve`)
- **Role assignment** (ai được làm gì): admin gán user vào role của app qua Central UI

**App member** chỉ cần:
- Tin tưởng token Zitadel issue (Bearer JWT)
- Expose 1 file manifest declare permissions app support (để Central sync về)
- Enforce permission ở runtime theo cách app tự chọn (ngoài scope docs này — xem §9)

**KHÔNG cần:** app tự quản lý user, role, permission trong DB nội bộ.

---

## Vai trò

| Role | Ai | Làm gì |
|---|---|---|
| **Admin Central** | Ops/Platform team | Register app trên Central portal, cấp credentials, sync manifest, assign role cho user |
| **Member** | Dev team X (owner app) | Bootstrap AI + `.env` trong project, cook SSO + RBAC manifest, deploy prod, notify admin sync |

Docs này chủ yếu cho **Member**. Admin action ghi chú "**[ADMIN]**" — member chỉ cần biết pipeline, không thực hiện.

---

## Prerequisites (Member)

- App source code sẵn sàng (business logic có, chưa cần auth)
- Biết trước:
  - `<APP_HOST>` prod (VD `app-x.company.vn`)
  - `<APP_PORT>` app native listen (VD `3000`)
- Terminal (bash / PowerShell / git-bash)
- AI tool: Claude Code / Cursor / Cline / aider (bất kỳ tool nào đọc `CLAUDE.md`/`AGENTS.md`)
- Không cần deploy public trước — chỉ cần biết domain sẽ dùng

---

## Bước 1 — [ADMIN] Register app trên Central (5 phút)

**Ai làm:** admin Central RBAC portal (**KHÔNG** phải member — member gửi request cho admin qua kênh nội bộ team).

**Ở đâu:** Central portal → **Apps** → **+ App mới**

**Member cần gửi cho admin (request template):**
```
Xin cấp app trên Central RBAC:
- App name: <Human-readable name>
- Slug đề xuất: <app-slug>              (kebab-case, 3-32 chars, ^[a-z][a-z0-9-]{2,31}$)
- App host prod: https://<APP_HOST>
- Pattern SSO dự kiến: A / B / C         (xem DECISION-TREE.md)
- Manifest URL (nếu đã biết):
    https://<APP_HOST>/api/.well-known/rbac-permissions.json (backend có /api prefix)
    HOẶC
    https://<APP_HOST>/.well-known/rbac-permissions.json     (static / no prefix)
  → có thể để trống, admin set sau khi cook Phase 4 xong
- Callback URL:
    Pattern A: https://<APP_HOST>/oauth2/callback
    Pattern B/C: <framework-specific path>  (xem examples/)
- Post-logout URL: https://<APP_HOST>/
- Owner: <email admin của app team>
- Target org: <Zitadel org>
```

**Admin wizard trả về 5 giá trị** (gửi cho member qua Bitwarden / Slack DM, **KHÔNG** email plain):

| Field | Note |
|---|---|
| `OIDC_ISSUER` | Base URL Zitadel — thường constant per environment (VD `https://auth.inet.vn`), admin verify với member |
| `CLIENT_ID` | Numeric snowflake (VD `387047455193104387`) |
| `CLIENT_SECRET` | Chỉ Pattern B backend Basic auth. SPA + PKCE KHÔNG có secret |
| `REDIRECT_URL` | EXACT match với callback đã register — sai 1 ký tự = Zitadel reject |
| `POST_LOGOUT_URL` | Nơi user land sau end_session |

**Trap thường gặp** (nếu app là SPA):
- Admin sau wizard phải vào **Zitadel Console → Project → Application → Configuration → Auth Method = None (PKCE)** + **Additional Origins = `https://<APP_HOST>`**
- Xem `SPEC.md §11 Trap 1 + Trap 2` chi tiết
- Nếu skip → SPA login sẽ fail với `invalid_client` hoặc CORS error

---

## Bước 2 — [Member] Bootstrap AI + `.env` (5 phút)

Vào thư mục root project (chỗ có `package.json` / `pyproject.toml` / `go.mod`):

```bash
# Download 3 file bootstrap
BASE=https://raw.githubusercontent.com/nguyenviet2509/authway/master/templates/app-integration-spec/bootstrap

curl -sSLO $BASE/CLAUDE.md      # Claude Code auto-load
curl -sSLO $BASE/AGENTS.md      # Cursor/aider/Cline auto-load
curl -sSLO $BASE/.env.example
```

**Windows PowerShell:**
```powershell
$base = "https://raw.githubusercontent.com/nguyenviet2509/authway/master/templates/app-integration-spec/bootstrap"
curl.exe -sSLO "$base/CLAUDE.md"
curl.exe -sSLO "$base/AGENTS.md"
curl.exe -sSLO "$base/.env.example"
```

**Fill `.env`** (từ 5 giá trị admin gửi):
```bash
cp .env.example .env
# Edit .env, fill:
#   OIDC_ISSUER=<admin cấp>
#   CLIENT_ID=<admin cấp>
#   CLIENT_SECRET=<admin cấp>              (bỏ nếu SPA + PKCE)
#   REDIRECT_URL=<admin cấp>
#   POST_LOGOUT_URL=<admin cấp>
#   APP_HOST=<member tự set — hostname prod>
#   APP_PORT=<member tự set — port app native>

# Pattern A only (oauth2-proxy sidecar):
#   COOKIE_SECRET=<generate>
```

**Generate `COOKIE_SECRET`:**
```bash
# Linux/macOS/git-bash
openssl rand -base64 32

# Windows PowerShell native (không có openssl)
[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 } | ForEach-Object { [byte]$_ }))
```

**Ignore `.env` trong git:**
```bash
git check-ignore .env || echo ".env" >> .gitignore
```

**Verify pre-flight** (trước khi để AI chạy):
```bash
# DNS trỏ đúng VPS deploy
nslookup <APP_HOST>

# Zitadel reachable
curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | head -3
```

Sai DNS → **STOP**, ping admin verify. Đây là `SPEC.md §11 Trap 3` — deploy nhầm server = code mới không có hiệu lực trên public URL.

---

## Bước 3 — [Member] Cook SSO (Phase 1-3, ~15-30 phút)

**Mục tiêu:** app authenticate user qua Central Zitadel → thay/skip login form cũ.

Mở AI tool trong project (`claude`, `cursor .`, hoặc bất kỳ).

### 3A — Dry-run (khuyến nghị lần đầu)

Muốn AI scan project + report kế hoạch trước khi code (không sửa file nào):

```
Đọc AGENTS.md và scout project. Chỉ report plan Authway SSO,
KHÔNG code. Chờ tôi duyệt trước khi implement.
```

### 3B — Implement

Sau khi review plan dry-run OK, hoặc muốn AI tự pick pattern + code luôn:

```
Đọc AGENTS.md và implement Authway SSO cho project này.
Scout stack + report plan trước khi code, chờ tôi OK Phase 1.
```

AI workflow (từ `bootstrap/CLAUDE.md`):
1. **Phase 1 — Scout & Report** (read-only): đọc `.env`, detect framework, chọn Pattern A/B/C theo `DECISION-TREE.md`, report plan → **WAIT member OK**
2. **Phase 2 — Implement** (sau OK): `git checkout -b feat/authway-sso-integration`, install deps, create/append files
3. **Phase 3 — Verify & Handoff**: local test, push feature branch, cung cấp deploy steps

### Prompt khác (khi cần)

| Use case | Prompt |
|---|---|
| Force pattern cụ thể | `Đọc AGENTS.md và implement Authway SSO Pattern C (add-only, giữ auth cũ). Scout + report trước.` |
| Auto mode (skip confirm gate) | `Đọc AGENTS.md và implement Authway SSO --auto. Report Phase 1 inline nhưng không chờ tôi OK.` |
| Rollback | `Rollback Authway SSO integration: delete feature branch, reset local state, verify auth cũ intact.` |
| Debug fail | `SSO login lỗi: <paste error>. Đọc AGENTS.md + backend logs + browser network tab, root-cause + đề xuất fix.` |

Cheatsheet đầy đủ 6 prompt: xem `INSTALL.md` §4.

### Confirm Phase 1 plan — member nên đánh giá gì?

AI báo report gồm: framework detect, pattern chose + reason, files changed count, deps sẽ install, rollback strategy. Member OK khi:
- Framework detect đúng
- Pattern chose khớp expectation (Pattern A cho backend có reverse proxy; B cho SPA / Next.js; C cho app auth phức tạp preserve)
- Files changed count reasonable (Pattern A ~5 line, B ~50-100 line, C ~350-500 line add)
- Deps thêm là library standard (Auth.js v5, oidc-client-ts, jose, oauth2-proxy sidecar container)

Không đúng → member phản hồi correction cho AI, tránh code sai rồi mới rollback.

### Deploy prod (member manual, KHÔNG auto)

```bash
git checkout master
git merge --no-ff feat/authway-sso-integration
# Deploy theo target (docker compose up -d / systemctl restart / vercel deploy / v.v.)
```

### Verify browser

**BẮT BUỘC fresh incognito** (Ctrl+Shift+N Chrome/Edge, Ctrl+Shift+P Firefox) để tránh Zitadel session collision (`SPEC.md §11 Trap 4`):

1. Vào `https://<APP_HOST>/`
2. Redirect Zitadel login → login email/password hoặc GitLab SSO
3. Callback về app → thấy user info (email, name)
4. Sign out → clear session, redirect về Zitadel logout xong về app root

Nếu chỉ cần identity (không quản permission qua Central) → **STOP ở đây**. App tự lưu roles internal như cũ.

Nếu cần phân quyền qua Central → tiếp Bước 4.

---

## Bước 4 — [Member] Cook RBAC Manifest (Phase 4, ~15 phút)

**Mục tiêu:** app expose file JSON declare permissions của mình để Central sync về (permission catalog).

**Prompt AI:**

```
Đọc AGENTS.md Phase 4 và implement RBAC Permission Manifest cho app này.
APP_SLUG = <slug đã register ở Bước 1>.
Scout routes + report draft PERMISSIONS list trước khi code, chờ tôi confirm.
```

AI workflow Phase 4 (từ `bootstrap/CLAUDE.md`):

1. **Phase 4.1 — Scout** (read-only):
   - Verify SSO Phase 1-3 đã done — nếu chưa: STOP, complete Bước 3 trước
   - Detect route registry pattern theo framework
   - Draft `PERMISSIONS` list theo format `<slug>:<resource>.<action>`
   - Report: framework, N routes, M permissions draft, files sẽ create/append
   - **WAIT member confirm draft PERMISSIONS**

2. **Phase 4.2 — Implement** (sau OK):
   - `git checkout -b feat/rbac-manifest-phase4`
   - Tạo 3 file (kebab-case, per convention framework):
     - `src/rbac/permissions-catalog.<ext>` — literal array + `APP_SLUG` + version fn
     - `src/rbac/manifest-endpoint.<ext>` — route handler `GET /.well-known/rbac-permissions.json`
     - `src/rbac/boot-validator.<ext>` — cross-check drift declared vs actual routes, set `/ready` state
   - Wire vào router / boot sequence (0 line modified existing business logic)
   - Build + local smoke test

3. **Phase 4.3 — Verify & Handoff**:
   - Local `curl` test manifest URL
   - Push feature branch

### Confirm draft PERMISSIONS — member cần review

AI draft danh sách permissions từ scan routes. Member kiểm:
- ID format đúng `<slug>:<resource>.<action>` (VD `<slug>:orders.read`, `<slug>:reports.export`)
- Description tiếng Việt human-readable (VD "Xem đơn hàng", "Xuất báo cáo")
- Số lượng permissions ≤ 500 (Central limit)
- Missing permission nào không (VD route admin-only chưa được cover)
- Default roles 3 (`<slug>.admin` / `<slug>.editor` / `<slug>.viewer`) — customize nếu cần

Không đúng → member phản hồi correction (add/rename/remove), AI re-draft.

### Deploy prod

```bash
git checkout master
git merge --no-ff feat/rbac-manifest-phase4
# Deploy + BẮT BUỘC RESTART app
#   → memoized manifest cần rebuild lại (SPEC.md §12.8 Trap 11)
```

### Verify từ external (không phải localhost)

```bash
# Manifest live
curl -sSL https://<APP_HOST>/api/.well-known/rbac-permissions.json | jq .
# Expect: {schema: "1", service: "<slug>", version: "...", permissions: [...], default_roles: [...]}

# Readiness (validator PASS)
curl -sSL https://<APP_HOST>/api/ready
# Expect: 200 {"status": "HEALTHY"}
```

Nếu path không có `/api` prefix → `curl https://<APP_HOST>/.well-known/rbac-permissions.json`.

**Fail cases:**
- 404 external nhưng 200 localhost → `SPEC.md §12.8 Trap 8` (global prefix nuốt) hoặc `Trap 10` (WAF/CDN block)
- 200 nhưng schema mismatch → validate qua Central schema trước khi báo admin:
  ```bash
  curl -sSL <CENTRAL_URL>/.well-known/rbac-permissions-schema.json > /tmp/schema.json
  curl -sSL https://<APP_HOST>/api/.well-known/rbac-permissions.json | npx -y ajv-cli validate -s /tmp/schema.json -d /dev/stdin
  ```

Manifest live + validate PASS → notify admin qua kênh nội bộ với full URL manifest.

---

## Bước 5 — [ADMIN] Sync manifest vào Central (2 phút)

**Ai làm:** admin Central RBAC portal.

**Flow admin (member không thực hiện, chỉ note cho ngữ cảnh):**

1. **Nếu Bước 1 chưa set Manifest URL:** vào Central portal → **Apps → `<app-slug>` → Edit** → set field **Manifest URL** = URL member đã verify Bước 4 → **Save**. Nếu Bước 1 đã set → nhảy step 2.
2. **Actions → Sync manifest** → Central fetch + validate schema
3. Preview **4-category diff**:
   - **Add** — permission mới trong manifest, chưa có trong DB (sync đầu tiên: expect N entries)
   - **Update-desc** — description đã đổi
   - **Explicit-deprecate** — member marked `status: soft-deleted`
   - **Implicit-deprecate** — permission mất khỏi manifest (⚠️ default UNCHECKED, warning banner — admin quyết định có deprecate không)
4. Review kỹ → **Apply**

**Sau Apply, Central tự động:**
- Persist permissions vào DB
- **Auto-wire `default_roles` → `role_permissions`**: roles từ manifest (VD `<slug>.admin/editor/viewer`) tự tạo + link với permissions declared. Admin **KHÔNG** cần setup role thủ công.
- Write audit trail entry

Member không phải làm gì ở bước này — chỉ chờ notify từ admin "sync done".

---

## Bước 6 — [ADMIN] Assign role cho user (2 phút / user)

**Ai làm:** admin Central RBAC portal.

Central portal → **Users → `<user-email>` → Assign role**:
- Chọn app `<app-slug>`
- Chọn role: `<slug>.admin` / `<slug>.editor` / `<slug>.viewer` (hoặc custom role nếu member declare thêm ở `default_roles`)
- Save

**User bị assign phải re-login** để permission có hiệu lực (Zitadel Pre-Token Webhook resolve permission mỗi lần Zitadel issue token → inject claim vào JWT). Session cũ giữ claim cũ đến hết TTL (typical 5-60 phút) hoặc user logout.

**Enforce permission ở app-side:** xem §9 "Runtime permission enforcement" cuối docs.

---

## Bước 7 — Version bump cycle (khi thêm/sửa permission)

Khi app có feature mới cần permission chưa declare, hoặc rename/deprecate:

### Add permission mới

1. **Member sửa `permissions-catalog.<ext>`** → thêm entry:
   ```
   { id: '<slug>:<resource>.<action>', description: '<Human vietnamese>' }
   ```
2. Wire route decorator/middleware dùng permission id mới (boot-validator sẽ catch nếu quên)
3. Commit + deploy + **RESTART app** (`SPEC.md §12.8 Trap 11`)
4. Verify manifest live có entry mới (`curl` + `jq`)
5. Notify admin sync
6. **[ADMIN]** Central → Apps → `<slug>` → Actions → Sync manifest → review diff (thấy "Add: 1") → Apply
7. Nếu role hiện tại cần include permission mới: xem "Manage role permissions" ở phần lifecycle cuối docs

**Prompt AI hỗ trợ:**
```
Vừa add feature mới cần permission '<slug>:<resource>.<action>'.
Update PERMISSIONS array trong permissions-catalog, wire route decorator,
bump version. Report deploy checklist.
```

### Rename permission

- Trong `permissions-catalog`: entry mới có `alias_of: '<old-id>'`, entry cũ marked `status: 'soft-deleted'`
- Central sync sẽ diff: 1 add + 1 explicit-deprecate → admin apply → users role cũ tự trỏ sang perm mới qua alias
- Chi tiết schema: xem `SPEC.md §12.2` (fields `alias_of`, `status`)

### Remove permission

- Xóa entry trong `permissions-catalog` (không cần marked, sẽ implicit-deprecate)
- Sync → admin thấy "Implicit-deprecate: 1" → tick checkbox → apply
- ⚠️ **BREAKING** cho user đang có role gán perm này — coordinate với admin trước khi ship

---

## Decision tree tóm tắt — App này cần Phase nào?

**Q1: App đã có auth logic phức tạp (password + 2FA + local RBAC) muốn preserve?**
- Yes → **Pattern C** (add-only Federated Login). Skip Phase 4 nếu app tự quản permission internal.
- No → Q2

**Q2: App là SPA thuần (không backend riêng), hay Next.js App Router, hay cần forward access_token downstream?**
- Yes → **Pattern B** (Native OIDC với PKCE / Auth.js v5)
- No → Q3

**Q3: Có reverse proxy (Caddy/Traefik/nginx) trước app?**
- Yes → **Pattern A** (IAP sidecar oauth2-proxy) — default, refactor ~5 line
- No → **Pattern B**

**Q4: App có cần Central quản permission catalog + role assignment?**
- Yes → Sau Pattern chose, tiếp **Phase 4 RBAC Manifest**
- No → skip Phase 4, app tự quản roles internal

Chi tiết: xem `DECISION-TREE.md`.

---

## Timeline

| Phase | Ai | Thời gian |
|---|---|---|
| Bước 1 register | Admin | 5 phút |
| Bước 2 bootstrap | Member | 5 phút |
| Bước 3 cook SSO | Member + AI | 15-30 phút |
| Bước 4 cook RBAC | Member + AI | 15 phút |
| Bước 5 sync | Admin | 2 phút |
| Bước 6 assign role | Admin | 2 phút / user |
| **Member total** | | **~35 phút** |
| **Admin total** (excl. per-user) | | **~10 phút** |
| **E2E first app** | | **~45-60 phút** |

App thứ 2+ nhanh hơn (member đã quen prompt) — cỡ 30 phút member, 5 phút admin.

---

## 9. Runtime permission enforcement (out of scope Phase 4)

Phase 4 chỉ cover **expose manifest** (Central biết permissions app support). Enforce permission ở runtime (route allow/deny) member tự implement.

**Zitadel Pre-Token Webhook** (Central-side setup — không phải việc member) sẽ inject claim vào JWT mỗi lần user login:
- `permissions: string[]` — inline nếu ≤ 30 permissions (JWT size guard)
- `permissions_hash: string` — SHA256 nếu > 30 permissions

**App enforce pattern (member tự chọn):**
1. Decode JWT ở middleware → đọc `permissions` claim
2. Nếu có inline → check `token.permissions.includes('<slug>:<resource>.<action>')`
3. Nếu chỉ có `permissions_hash` → fetch `<CENTRAL_URL>/v1/permissions-lookup?hash=<hash>` với Bearer JWT → cache local TTL 5min → check

**Middleware trong 3 example** (`examples/rbac-manifest-{nestjs,fastapi,express}.md`) hiện có stub `TODO: call Central` — member wire theo pattern chọn.

**Consult Central team** nếu cần:
- URL Central prod / staging
- Cache client library / SDK có sẵn không
- Fail-close vs fail-open policy khi Central down
- CORS whitelist cho SPA direct-call `/v1/permissions-lookup`

---

## Common failure modes + first-line debug

| Symptom | Bước fail | First-line check |
|---|---|---|
| `redirect_uri_mismatch` khi login | Bước 3 browser test | REDIRECT_URL trong `.env` EXACT match callback register Central (scheme/host/port/path/trailing slash) |
| Cookie oversize >4KB, browser reject | Bước 3 login | User có nhiều UserGrant → admin enable scope-limited claim (`SPEC.md §10`) |
| `invalid_client` | Bước 3 login | CLIENT_ID/SECRET sai / có whitespace |
| SSO login OK nhưng role/permission empty | Bước 6 sau assign | User chưa re-login sau assign; hoặc Pre-Token Webhook chưa wire (báo admin) |
| Manifest `curl` 404 external | Bước 4 verify | `SPEC.md §12.8 Trap 8` (framework prefix) hoặc `Trap 10` (WAF/CDN block) |
| Central sync "namespace violation" | Bước 5 | `SPEC.md §12.8 Trap 7` — `service` field manifest ≠ slug register ở Central |
| Central sync diff empty dù ship mới | Bước 5 | `SPEC.md §12.8 Trap 9` (version string non-deterministic) hoặc `Trap 11` (chưa restart app) |
| Route permission check pass qua nhưng user không có perm | §9 runtime | Middleware stub chưa wire — implement decode JWT + check inline/hash |

Fail lâu hơn 15 phút → paste:
- Error message full
- `.env` (đã xoá secrets)
- Browser Network tab HAR (nếu SSO)
- `docker logs <app>` hoặc `journalctl -u <app>` last 100 lines

→ Gửi AI cùng `AGENTS.md` để self-diagnose, hoặc ping admin Central team.

---

## App lifecycle sau onboard

**Manage role permissions** (thêm/bớt perm cho role hiện có):
- Sửa `default_roles[].permissions[]` trong `permissions-catalog.<ext>` → deploy + restart → admin sync
- Hoặc admin chỉnh trực tiếp qua Central UI (nếu customize per-instance)

**Add custom role ngoài admin/editor/viewer** (VD `<slug>.approver`):
- Member thêm entry vào `DEFAULT_ROLES` array → deploy → admin sync
- Role sẽ available cho admin assign user ở Bước 6

**Deprecate app:**
- Notify admin trước → admin unassign tất cả user → xóa app khỏi Central
- App code có thể vẫn deploy độc lập, nhưng token Zitadel không còn permissions claim → user hit route → app tự fallback (403 hoặc redirect logout)

---

## Reference

| Cần gì | File | Ai đọc |
|---|---|---|
| Contract Central ↔ App | `SPEC.md` (~600 line) | AI + member (skim) |
| Decision Pattern A/B/C + Phase 4 | `DECISION-TREE.md` | Member + AI |
| AI workflow instructions | `bootstrap/CLAUDE.md` (Claude Code) | AI |
| AI workflow instructions | `bootstrap/AGENTS.md` (Cursor/aider/Cline) | AI |
| Setup + prompt cheatsheet | `bootstrap/INSTALL.md` | Member |
| SSO examples per stack | `examples/{nodejs-express,python-fastapi,nextjs,spa-react-vue,federated-login}-*.md` | AI |
| RBAC manifest examples per stack | `examples/rbac-manifest-{nestjs,fastapi,express}.md` | AI |
| Central schema JSON | `<CENTRAL_URL>/.well-known/rbac-permissions-schema.json` | AI (dev-time validate) |

Repo authway: https://github.com/nguyenviet2509/authway/tree/master/templates/app-integration-spec/

---

## Không cover trong docs này

- Deploy VPS / Docker / Kubernetes runtime → xem `../app-iap-template/` hoặc `../app-iap-native/`
- HTTPS/TLS setup → Caddy/Traefik lo (reverse proxy trước app)
- Zitadel Pre-Token Webhook config → admin/platform team setup (1 lần per Zitadel project, không per-app)
- Database schema / CI/CD → app-specific
- Runtime permission enforcement chi tiết → xem §9 + consult Central team
- Multi-environment (dev/staging/prod) strategy → register app riêng mỗi env với slug khác (`<app>-dev`, `<app>`)
- Local dev testing với Zitadel dev instance → coordinate với admin

## Support

Ping admin Central team qua kênh nội bộ. Attach: `AGENTS.md` project, `.env` (xoá secrets), error log, `docker ps` / `systemctl status` output.
