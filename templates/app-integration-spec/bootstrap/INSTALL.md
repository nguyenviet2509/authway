# Authway SSO Integration — Install (3 lệnh)

Bootstrap AI để tự refactor project của bạn cho Central RBAC SSO integration. Không cần đọc SPEC.md dài — AI đọc `CLAUDE.md` / `AGENTS.md` tự động khi mở project.

## Prerequisite

- Đã đăng ký app trên Central RBAC portal → nhận **`CLIENT_ID`**, **`CLIENT_SECRET`** (nếu Basic auth), **`REDIRECT_URL`**, **`POST_LOGOUT_URL`** từ admin
- Project source code sẵn sàng
- Terminal (bash / PowerShell / cmd)

## Bước 1 — Download 3 file vào project root

Vào thư mục root project của bạn (chỗ có `package.json` / `pyproject.toml` / etc):

```bash
BASE=https://raw.githubusercontent.com/nguyenviet2509/authway/master/templates/app-integration-spec/bootstrap

curl -sSLO $BASE/CLAUDE.md
curl -sSLO $BASE/AGENTS.md
curl -sSLO $BASE/.env.example
```

**Windows PowerShell:**
```powershell
$base = "https://raw.githubusercontent.com/nguyenviet2509/authway/master/templates/app-integration-spec/bootstrap"
curl.exe -sSLO "$base/CLAUDE.md"
curl.exe -sSLO "$base/AGENTS.md"
curl.exe -sSLO "$base/.env.example"
```

## Bước 2 — Fill credentials

```bash
cp .env.example .env
# Edit .env với editor bất kỳ, fill 5 giá trị từ admin:
#   OIDC_ISSUER, CLIENT_ID, CLIENT_SECRET, REDIRECT_URL, POST_LOGOUT_URL
# Và 2 giá trị tự set:
#   APP_HOST (hostname prod), APP_PORT (port app native listen)
```

Verify `.env` trong `.gitignore` (nếu chưa có):
```bash
echo ".env" >> .gitignore
```

Generate `COOKIE_SECRET` (Pattern A only — sẽ dùng nếu AI chọn Pattern A):
```bash
openssl rand -base64 32
# Copy output vào COOKIE_SECRET trong .env
```

## Bước 2.5 — Pre-flight verify (2 lệnh)

```bash
# DNS check — verify domain trỏ đúng VPS anh sẽ deploy
nslookup <APP_HOST>

# Zitadel discovery reachable
curl -sf ${OIDC_ISSUER}/.well-known/openid-configuration | head -3
```

Nếu DNS trỏ VPS khác — **STOP** và verify với admin trước. Đây là trap #3 trong `SPEC.md §11` (deploy nhầm server).

## Bước 3 — Mở AI tool trong project

**Claude Code:**
```bash
claude
```

**Cursor:**
```bash
cursor .
```

**Windsurf / Cline / aider / Copilot:** mở project bình thường. AI sẽ auto-load `CLAUDE.md` (Claude Code) hoặc `AGENTS.md` (Cursor/aider/Cline) — 2 file này chứa AI Workflow 3-phase strict (Scout → Report → WAIT → Implement → Verify).

## Bước 4 — Prompt AI (cheatsheet 6 use cases)

Chọn prompt phù hợp use case. Fuzzy trigger detection — AI đọc AGENTS.md tự activate workflow khi thấy keyword `{authway/central sso/zitadel/gitlab sso/central rbac}` + verb.

### 4.1 Implement SSO (default)
> Đọc AGENTS.md và implement Authway SSO cho project này.
> Scout stack + report plan trước khi code.

### 4.2 Dry-run (scout only, KHÔNG code)
> Đọc AGENTS.md và scout project. Chỉ report plan Authway SSO,
> KHÔNG code. Chờ tôi duyệt trước khi implement.

### 4.3 Force pattern cụ thể
> Đọc AGENTS.md và implement Authway SSO **Pattern C**
> (add-only, giữ nguyên auth cũ). Scout + report trước.

Thay `Pattern C` bằng `Pattern A` hoặc `Pattern B` tùy nhu cầu (xem `DECISION-TREE.md`).

### 4.4 Auto mode (skip confirm gate)
> Đọc AGENTS.md và implement Authway SSO --auto.
> Vẫn report Phase 1 inline nhưng không chờ tôi OK.

### 4.5 Rollback
> Rollback Authway SSO integration: delete feature branch,
> reset local state, verify auth cũ intact.

### 4.6 Test & Troubleshoot
> Cho tôi E2E test checklist Authway SSO (bao gồm browser
> hygiene + Zitadel Console verify + 6 traps SPEC.md §11).

> SSO login lỗi: [paste error]. Đọc AGENTS.md + backend logs +
> browser network tab, root-cause + đề xuất fix.

### 4.7 Phase 4 — RBAC Permission Manifest (chỉ khi app cần Central sync permission)

Sau khi SSO Phase 1-3 done + app cần Central quản lý permission catalog + role assignment (thay vì tự lưu roles trong DB app):

> Đọc AGENTS.md Phase 4 và implement RBAC Permission Manifest cho
> app này. APP_SLUG = <slug đã register ở Central>. Scout routes +
> report draft PERMISSIONS list trước khi code, chờ tôi confirm.

Dry-run (scout only, không code):

> Đọc AGENTS.md Phase 4 và scout routes app này. Report draft
> PERMISSIONS list + files sẽ create, KHÔNG code. Chờ tôi duyệt.

Sau khi AI xong: admin vào Central portal → **Apps → `<APP_SLUG>` → Edit → set field Manifest URL** = URL AI report → **Actions → Sync manifest → Apply**.

## Bước 5 — Post-implementation manual steps

AI xong Phase 1-2. Anh làm manual:

### 5.1 Zitadel Console adjust (nếu SPA)

Vào Zitadel Console → Project → Application:
- **Configuration**: Auth Method = **None (PKCE)** + Require PKCE = ON *(Trap #1 SPEC.md §11)*
- **URLs**: verify Redirect URI + Post Logout URI match `.env`
- **Additional Origins**: add `https://<app-host>` (dev + prod) *(Trap #2)*
- **Token Settings**: Add Roles To ID Token = ON, User Info Inside ID Token = ON *(Trap #6, cần cho Pattern C auto-provision)*

### 5.2 Browser E2E test

**BẮT BUỘC fresh incognito** để tránh Zitadel session collision *(Trap #4)*:
- Ctrl+Shift+N (Chrome/Edge) hoặc Ctrl+Shift+P (Firefox)
- HOẶC visit `<OIDC_ISSUER>/logout` trước khi test SSO

Test flow:
1. Vào `https://<app-host>/login`
2. Click SSO button
3. Zitadel login page → click **GitLab** → login GitLab
4. Callback về app → verify vào dashboard (không double-prompt 2FA nếu Pattern C với SKIP policy)

### 5.3 Deploy prod (khi ready)

AI đã push feature branch. Merge master + deploy prod tuỳ workflow team:

```bash
git checkout master
git merge --no-ff feat/authway-sso-integration
git push origin master
```

## Verify sau khi AI xong

```bash
# 1. App bind 127.0.0.1 (không phải 0.0.0.0)
grep -rE "0\.0\.0\.0" src/     # Expect: 0 match

# 2. Không hardcode Zitadel URL
grep -rE "10\.200\.0\.125|http://.*zitadel" src/   # Expect: 0 match

# 3. .env trong .gitignore
git check-ignore .env    # Expect: .env

# 4. .env.example tồn tại
ls -la .env.example      # Expect: file present

# 5. Deploy theo hướng dẫn AI report
```

Browser test:
- Incognito → `https://<APP_HOST>/`
- Redirect Zitadel login → email/password hoặc GitLab SSO
- Callback về app → thấy user info
- Sign out → clear session, back về Zitadel login

## Nếu fail

1. **Copy error log + `.env` (đã xoá secret) + browser Network tab HAR** → paste lại AI cùng file `CLAUDE.md`
2. AI self-diagnose theo Common Issues section 10 trong `CLAUDE.md`
3. Nếu vẫn stuck → ping admin, attach 3 thứ trên

## Files copied (checklist)

- [ ] `CLAUDE.md` — instructions cho Claude Code
- [ ] `AGENTS.md` — instructions cho Cursor/aider/Cline (identical content, khác tên)
- [ ] `.env` — credentials filled (KHÔNG commit)
- [ ] `.env.example` — template placeholder (commit)

Chỉ cần 1 trong CLAUDE.md hoặc AGENTS.md tuỳ tool. Copy cả 2 nếu team dùng nhiều tool khác nhau — không harm.

## Không dùng file nào?

- **KHÔNG dùng CLAUDE.md**: xoá nếu team không có ai dùng Claude Code
- **KHÔNG dùng AGENTS.md**: xoá nếu team chỉ dùng Claude Code
- **Đọc SPEC.md full**: nếu case phức tạp cần reference sâu → xem https://github.com/nguyenviet2509/authway/tree/master/templates/app-integration-spec/

## Deeper reference

Files ngắn `CLAUDE.md`/`AGENTS.md` là compact version (~350 dòng). Full spec + 4 example concrete tại authway repo `templates/app-integration-spec/`:

- `SPEC.md` — full contract + patterns
- `DECISION-TREE.md` — 5-question decision
- `examples/nodejs-express-iap.md` — Node backend concrete
- `examples/python-fastapi-iap.md` — Python backend concrete
- `examples/nextjs-app-router-nativeauth.md` — Next.js concrete
- `examples/spa-react-vue-pkce.md` — SPA concrete

AI có thể tự fetch qua WebFetch nếu cần deeper reference (Claude Code, Cursor support).
