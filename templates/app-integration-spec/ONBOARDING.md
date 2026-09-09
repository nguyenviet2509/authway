# Central RBAC — Onboarding cho app mới

**Khi nào dùng:** team có app mới, muốn tích hợp SSO auth + RBAC qua Central RBAC portal.

Docs này = quickstart. Chi tiết technical để AI đọc nằm ở `CLAUDE.md`/`AGENTS.md` (member download về project ở Bước 2).

---

## Bước 1 — Xin credentials từ admin Central

Ping admin qua kênh nội bộ, gửi request:

```
Xin cấp app trên Central RBAC:
- App name: <Human name>
- Slug: <app-slug>            (kebab-case, 3-32 chars)
- App host prod: https://<APP_HOST>
- Callback URL: https://<APP_HOST>/oauth2/callback   (Pattern A default)
- Post-logout: https://<APP_HOST>/
- Owner email: <email>
```

Admin trả về **5 giá trị** (qua Bitwarden/Slack DM, KHÔNG email plain):
- `OIDC_ISSUER` (VD `https://zitadel.000nethost.com`)
- `CLIENT_ID`
- `CLIENT_SECRET` (bỏ nếu SPA + PKCE)
- `REDIRECT_URL`
- `POST_LOGOUT_URL`

---

## Bước 2 — Download bootstrap vào project

Vào thư mục root project (chỗ có `package.json` / `pyproject.toml` / `go.mod`):

**Linux / macOS / git-bash:**
```bash
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

Fill `.env`:
```bash
cp .env.example .env
# Edit .env fill 5 giá trị admin gửi + APP_HOST + APP_PORT
# Pattern A cần thêm COOKIE_SECRET:
#   Linux/macOS/git-bash: openssl rand -base64 32
#   Windows PS: [Convert]::ToBase64String((1..32|%{[byte](Get-Random -Max 256)}))

echo ".env" >> .gitignore
```

---

## Bước 3 — Prompt AI implement

Mở AI tool trong project: `claude`, `cursor .`, hoặc bất kỳ tool nào đọc `CLAUDE.md`/`AGENTS.md`.

### Case 1 — App mới, muốn SSO + phân quyền qua Central (full pipeline)

```
Đọc AGENTS.md và implement Authway SSO + RBAC manifest cho project này.
APP_SLUG = <slug đã register ở Bước 1>.
Scout stack + report plan cho từng phase, chờ tôi OK trước khi code.
```

AI sẽ:
1. Scout framework + chọn Pattern A/B/C → report plan Phase 1 (SSO) → **wait member OK**
2. Implement SSO trên branch `feat/authway-sso-integration` → push
3. Report plan Phase 4 (RBAC manifest) → **wait member OK**
4. Implement RBAC manifest trên branch `feat/rbac-manifest-phase4` → push
5. Report deploy checklist

### Case 2 — App chỉ cần SSO (identity, không phân quyền qua Central)

```
Đọc AGENTS.md và implement Authway SSO cho project này.
Scout stack + report plan trước khi code, chờ tôi OK.
```

### Case 3 — App đã có SSO, giờ thêm RBAC

```
App đã có Authway SSO. Đọc AGENTS.md Phase 4 và add RBAC Permission
Manifest. APP_SLUG = <slug>. Không touch SSO code cũ. Scout routes +
report draft PERMISSIONS trước khi code.
```

### Case 4 — App có auth phức tạp (password + 2FA + local RBAC) muốn preserve

```
Đọc AGENTS.md và implement Authway SSO Pattern C (add-only, giữ auth cũ).
Scout + report trước khi code.
```

### Case 5 — Debug fail

```
SSO login lỗi: <paste error>. Đọc AGENTS.md + logs backend + browser
Network tab, root-cause + đề xuất fix.
```

---

## Bước 4 — Deploy + verify

AI xong Phase 1-3 (SSO) sẽ push feature branch. Member merge + deploy:

```bash
git checkout master
git merge --no-ff feat/authway-sso-integration
# Deploy tuỳ target (docker compose / systemd / vercel / ...)
```

Verify browser (fresh incognito Ctrl+Shift+N):
1. Vào `https://<APP_HOST>/`
2. Redirect Zitadel login → login → callback về app → thấy user info
3. Sign out → clear session

Nếu Case 1 hoặc 3 (có RBAC): deploy Phase 4 tương tự, verify manifest:
```bash
curl -sSL https://<APP_HOST>/api/.well-known/rbac-permissions.json | jq .
# Expect: {schema:"1", service:"<slug>", permissions:[...], default_roles:[...]}
```

Notify admin URL manifest → admin vào Central portal → Sync manifest → assign role user.

---

## Nếu AI cook fail

1. Paste error log + `.env` (đã xoá secret) + browser Network HAR cho AI:
   ```
   AI cook lỗi: <paste log>. Đọc AGENTS.md + Common Issues section 10
   để self-diagnose.
   ```
2. Nếu vẫn stuck sau 15 phút → ping admin Central team, attach:
   - Error log full
   - `.env` (xoá secrets)
   - `docker logs <app>` hoặc `journalctl -u <app>` last 100 lines
   - Prompt đã dùng

---

## Reference

- Deeper spec (nếu AI cần reference sâu): https://github.com/nguyenviet2509/authway/tree/master/templates/app-integration-spec/
  - `SPEC.md` — full contract Central ↔ app
  - `DECISION-TREE.md` — chọn Pattern A/B/C
  - `examples/` — code reference per framework (NestJS/FastAPI/Express/Next.js/SPA)
