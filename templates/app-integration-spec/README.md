# Authway App Integration Spec — for AI-assisted refactor

Template **AI-facing** để member team dùng Claude / Cursor / Copilot refactor project cho Central SSO integration. Không phải runbook cho human — nếu bạn muốn hướng dẫn deploy tay, xem `../app-iap-template/` (Docker) hoặc `../app-iap-native/` (systemd).

## Cách dùng

**Bước 1.** Request admin đăng ký app trên Central RBAC portal. Nhận:
- `CLIENT_ID` (numeric snowflake)
- `CLIENT_SECRET` (Basic auth apps only — Store password manager, Central chỉ show 1 lần)
- `REDIRECT_URL` (path fixed bởi framework, EXACT match — VD `https://<app-host>/oauth2/callback`)

**Bước 2.** Paste vào AI (Claude/Cursor/Copilot) cùng lúc:
1. `SPEC.md` — contract Central ↔ app (**bắt buộc**)
2. `DECISION-TREE.md` — chọn Pattern A hay B (**bắt buộc, đọc trước SPEC**)
3. Reference gần nhất framework project (VD `examples/nodejs-express-iap.md`)
4. Toàn bộ code project của bạn
5. 3 credential ở Bước 1

**Bước 3.** Prompt AI:
> "Đọc SPEC.md + DECISION-TREE.md + reference đính kèm. Implement Central SSO integration (nếu app đã có auth phức tạp muốn giữ nguyên → chọn Pattern C add-only). Scout stack + report plan trước khi code. Tuân thủ security invariants. Chạy checklist self-validate cuối SPEC.md trước khi báo done."

**Bước 4.** Deploy → browser test flow login → nếu fail, gửi log AI cùng SPEC.md để self-diagnose.

## File map

| File | Đọc khi | Ai đọc |
|---|---|---|
| `SPEC.md` | Luôn luôn | AI |
| `DECISION-TREE.md` | Luôn luôn (trước SPEC) | AI + human |
| `examples/nodejs-express-iap.md` | Node backend Express/Fastify/Koa (SSO) | AI |
| `examples/python-fastapi-iap.md` | Python backend FastAPI/Flask/Django (SSO) | AI |
| `examples/nextjs-app-router-nativeauth.md` | Next.js full-stack (SSO) | AI |
| `examples/spa-react-vue-pkce.md` | SPA thuần React/Vue/Svelte (SSO) | AI |
| `examples/federated-login-example.md` | App có auth phức tạp muốn preserve (Pattern C SSO) | AI |
| `examples/rbac-manifest-nestjs.md` | Phase 4 — NestJS RBAC manifest | AI |
| `examples/rbac-manifest-fastapi.md` | Phase 4 — FastAPI RBAC manifest | AI |
| `examples/rbac-manifest-express.md` | Phase 4 — Express/Fastify/Koa RBAC manifest | AI |

Framework khác (Rails/Go/PHP)? → Paste SPEC.md + DECISION-TREE.md + 1 reference gần nhất (VD Node cho Go). AI adapt được.

## Central RBAC contract

Central bảo đảm cấp:
- OIDC compliant (Zitadel v4)
- 3 default roles per app: `{slug}.viewer`, `{slug}.editor`, `{slug}.admin` (slug = app name kebab-case, VD app slug "myapp" → `myapp.viewer`/`myapp.editor`/`myapp.admin`). Custom roles thêm trong Central UI sau.
- Auto-provision user via Zimbra LDAP + GitLab SSO
- Roles claim: `urn:zitadel:iam:org:project:roles`

App bảo đảm:
- Follow security invariants trong SPEC.md
- KHÔNG hardcode Zitadel URL — dùng env var
- Sign-out chain đầy đủ (app → Central → app root)

## Not covered

- Không guide deploy VPS / Docker — xem `../app-iap-template/` hoặc `../app-iap-native/`
- Không handle HTTPS/TLS — Caddy/Traefik lo (reverse proxy trước app)
- Không setup database/CI — app-specific

## Support

Fail sau khi làm theo AI refactor? → Ping admin + attach: `SPEC.md`, error log, `.env` (xoá secrets), `docker ps` / `systemctl status` output.
