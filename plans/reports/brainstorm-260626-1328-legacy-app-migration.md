---
type: brainstorm
date: 2026-06-26 13:28
slug: legacy-app-migration
status: design-approved
parent-plan: ../260626-1154-zitadel-iap-rollout/
extends: phase-04-migrate-real-apps.md
---

# Legacy App Migration — Patterns & Decisions

## Question
Khi Zitadel deploy xong, các app cũ (auth = IP whitelist hoặc account tự tạo trong app) cần đổi gì?

## Classification

| Nhóm | Đặc điểm | Migration cost |
|---|---|---|
| **A** — IP whitelist only | Không có user concept, ai trong mạng thì xài | 0 dòng code, 5–10 phút |
| **B** — Account tự tạo | Có DB users, login form, session, có data ownership per-user | 50–150 LOC, 1–3h |

User confirm: app mix cả A và B; nhóm B có data per-user nhưng **chấp nhận force re-register** (data cũ bỏ).

## Nhóm A — Pattern

Không thay đổi code app. Chỉ infra:
- Đặt sau Traefik + oauth2-proxy theo template phase 02
- IP whitelist firewall GIỮ (defense in depth)
- Optional: 1 dòng đọc `X-Auth-Request-Email` nếu UI muốn show user

→ Reference: [phase-02-iap-reference.md](../260626-1154-zitadel-iap-rollout/phase-02-iap-reference.md)

## Nhóm B — Pattern: Bỏ auth layer cũ, trust header

### Code changes
**Bỏ**:
- Login/register routes + forms
- Password hash column + verify logic
- Reset password flow
- Email verify (Zitadel đã verify)
- Tự quản session cookie

**Thêm**:
- Middleware authenticate đọc header `X-Auth-Request-Email` / `X-Auth-Request-User` / `X-Auth-Request-Preferred-Username`
- Auto-provision: nếu chưa có user matching → insert row mới
- `/auth/logout` redirect `/oauth2/sign_out`

### Schema migration
```sql
ALTER TABLE users DROP COLUMN password_hash;
ALTER TABLE users DROP COLUMN reset_token;
ALTER TABLE users ADD COLUMN zitadel_subject TEXT UNIQUE;
ALTER TABLE users ADD COLUMN auth_source TEXT DEFAULT 'zitadel';
TRUNCATE users CASCADE;  -- force re-register decision
```

Lưu ý: TRUNCATE CASCADE sẽ xoá data per-user. Đã confirm chấp nhận.

### Middleware pseudo-code
```python
def authenticate(request):
    email = request.headers.get('X-Auth-Request-Email')
    if not email:
        raise Unauthorized
    user = db.users.find_by_email(email)
    if not user:
        user = db.users.create(
            email=email,
            name=request.headers.get('X-Auth-Request-Preferred-Username'),
            zitadel_subject=request.headers.get('X-Auth-Request-User'),
        )
    return user
```

### Framework-specific notes
| Framework | Implementation |
|---|---|
| Next.js | Bỏ NextAuth nếu có; dùng middleware đọc header trong `middleware.ts` + Server Components đọc `headers()` |
| Express/Fastify | Bỏ passport; 1 middleware nhỏ ~20 LOC |
| FastAPI | Dependency `get_current_user` đọc header |
| Django | `RemoteUserMiddleware` built-in + custom auth backend |
| Flask | Before-request handler |

## Cutover playbook (per-app)

1. **Pre-flight**:
   - Admin tạo user trong Zitadel cho 2–3 dev tester
   - Backup DB hiện tại
2. **Build app v2**:
   - Apply schema migration + code change trong branch
   - Build image v2
3. **Staging**:
   - Deploy v2 cùng VPS, port khác
   - Smoke test: login flow + auto-provision + logout
4. **Cutover** (maintenance window ~10 phút):
   - Notify team: "Bạn sẽ phải tạo lại account khi vào app X qua Zitadel"
   - Stop app v1
   - Switch Traefik route → app v2
   - Start v2
5. **Verify**: 1 dev test real login + tạo data mới
6. **Rollback plan**: giữ image v1 + DB backup 7 ngày; nếu critical → revert route + restore DB

## Edge cases
| Case | Handling |
|---|---|
| App có cron job / background task cần "service user" | Tạo Service Account trong Zitadel, dùng client_credentials (out of POC scope) |
| App expose API cho script khác trong nội bộ | Same: client_credentials grant + middleware accept Bearer token (cần verify ở Zitadel) |
| User đổi email trong Google → Zitadel | Khả năng tạo user trùng. Mitigation: bind theo `zitadel_subject` (immutable) thay vì email khi possible |
| App có admin role / permission | Lưu trong DB local, admin set thủ công sau khi user login lần đầu; hoặc dùng Zitadel grants (sau này) |

## Effort estimate per app

| Type | LOC change | Wall time | Risk |
|---|---|---|---|
| Nhóm A | 0 | 10 min | Low |
| Nhóm B đơn giản (CRUD app) | 50 | 2 hrs | Low |
| Nhóm B phức tạp (sessions, OAuth-as-server, multi-tenant in app) | 100–150 | 4 hrs | Medium |
| App Streamlit/Gradio (không có middleware concept) | Có thể chỉ làm Option A (proxy + IP whitelist) | 10 min | Low |

## Recommended order
1. Migrate **tất cả Nhóm A trước** (cheap, build confidence)
2. Migrate 1 app **Nhóm B đơn giản** (validate full pattern + middleware)
3. Migrate phần còn lại Nhóm B
4. Retire IP-whitelist-only check sau khi mọi app đã sau Zitadel? **KHÔNG** — giữ defense in depth

## Update to existing plan
Plan [260626-1154-zitadel-iap-rollout/phase-04-migrate-real-apps.md](../260626-1154-zitadel-iap-rollout/phase-04-migrate-real-apps.md) tham chiếu file này. Khi pick 2–3 app pilot, ưu tiên:
- 1 app Nhóm A (cheap proof)
- 1 app Nhóm B đơn giản (validate pattern)
- 1 app Nhóm B phức tạp nhất (find edge cases sớm)

## Open questions
- App nào cụ thể trong 10 app hiện có thuộc Nhóm A vs B? Cần inventory để plan phase 04.
- Có app nào dùng OAuth-as-server (làm IdP cho app khác) không? Nếu có, migration phức tạp hơn.
- Cron/scheduler có gọi vào app qua HTTP không? Cần liệt kê để xử lý service auth.
- Audit log: user mới được auto-provision lúc nào, ai? Lưu trong app DB hay relay ra log central?
