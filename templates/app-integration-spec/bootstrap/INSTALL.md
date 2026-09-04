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

## Bước 3 — Mở AI tool trong project + prompt

**Claude Code:**
```bash
claude
```
Prompt: `Refactor project cho Authway SSO`

**Cursor:**
```bash
cursor .
```
Chat: `Refactor project cho Authway SSO`

**Windsurf / Cline / aider / Copilot:** mở project + prompt tương tự.

AI sẽ:
1. Auto-load `CLAUDE.md` (Claude Code) hoặc `AGENTS.md` (Cursor/aider/Cline)
2. Đọc `.env` → verify credentials có
3. Scout project → detect framework
4. Chọn Pattern A hoặc B (decision tree)
5. Refactor code + add config files
6. Self-validate checklist
7. Report files changed + next deploy steps

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
