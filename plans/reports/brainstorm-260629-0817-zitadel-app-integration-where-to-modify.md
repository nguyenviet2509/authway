# Brainstorm — Áp Zitadel cho App Team: Nơi Nào Cần Chỉnh Sửa

**Date:** 2026-06-29 08:17 (Asia/Saigon)
**Scope:** Inventory đầy đủ các nơi cần đụng khi migrate 1 app từ auth cũ sang IAP qua Zitadel
**Context:** 4–10 app team, stack Next.js/Node + Python (FastAPI/Django/Flask/Streamlit?), auth hiện tại mix 3 loại (IP whitelist + account tự tạo + shared account)
**Related:** [brainstorm-260626-1328-legacy-app-migration.md](brainstorm-260626-1328-legacy-app-migration.md) — base migration patterns

## 6 nơi cần chỉnh sửa

| # | Nơi | Bắt buộc | Effort/app |
|---|---|---|---|
| 1 | Zitadel admin console — tạo OIDC application | ✅ | 5' |
| 2 | DNS/hosts — hostname app → app-vps | ✅ | 1' |
| 3 | Infra `docker-compose.yml` — oauth2-proxy + app service | ✅ | 10' |
| 4 | App `.env` — CLIENT_ID/SECRET/COOKIE_SECRET/HOSTNAME | ✅ | 2' |
| 5 | App code — bỏ auth cũ, đọc `X-Auth-Request-*` header | Tuỳ nhóm | 0–4h |
| 6 | App DB schema — drop password_hash, add zitadel_subject | Chỉ nhóm B | 30' |

## Pattern theo loại auth hiện tại

### Loại A — IP whitelist / VPN only
- **Code change:** 0 LOC
- **Action:** đặt sau oauth2-proxy + Traefik theo template `infra/app-vps/`. Giữ IP whitelist firewall (defense in depth).
- **Optional:** 1 dòng read `X-Auth-Request-Email` nếu UI cần show user.

### Loại B — Account tự tạo (login form + password)
- **Code change:** 50–150 LOC
- **Bỏ:** login/register routes, password hash + verify, reset password, email verify, session cookie management
- **Thêm:** middleware read header + auto-provision user nếu chưa tồn tại
- **Schema:** rename `users` → `users_legacy` (giữ forensic), tạo `users` mới với `zitadel_subject` UNIQUE

### Loại Shared account
- **Code change:** giống A (nếu app không có data per-user) hoặc B (nếu có)
- **Trước:** 1 account `admin/Admin@2024` cả team biết
- **Sau:** mỗi người 1 Zitadel user, MFA bắt buộc, revoke centralized

## Code snippet per stack

### Next.js (App Router)
```ts
import { headers } from 'next/headers';
const email = headers().get('x-auth-request-email');
```
Migration từ NextAuth: gỡ dependency + `[...nextauth]/route.ts` + `SessionProvider`. Replace `useSession()` → server-side header read hoặc client fetch `/oauth2/userinfo`. Logout = `<a href="/oauth2/sign_out">`.

### Express/Fastify
```js
app.use((req, res, next) => {
  const email = req.get('X-Auth-Request-Email');
  if (!email) return res.status(401).end();
  req.user = { email, sub: req.get('X-Auth-Request-User') };
  next();
});
```
Bỏ passport / jwt-verify / session.

### FastAPI
```python
def get_current_user(
    x_auth_request_email: str = Header(None),
    x_auth_request_user: str = Header(None),
):
    if not x_auth_request_email: raise HTTPException(401)
    return {"email": x_auth_request_email, "sub": x_auth_request_user}
```

### Django
- Built-in `RemoteUserMiddleware` + `RemoteUserBackend`
- Custom middleware nhỏ map `X-Auth-Request-Email` → `REMOTE_USER`

### Flask
```python
@app.before_request
def authenticate():
    email = request.headers.get('X-Auth-Request-Email')
    if not email: abort(401)
    g.user_email = email
```

### Streamlit (cần kiểm tra version)
3 option:
- **F1** (Streamlit cũ, không cần per-user): treat như Nhóm A, oauth2-proxy + IP whitelist, không read header
- **F2** (Streamlit ≥ 1.37): `st.context.headers.get('X-Auth-Request-Email')`
- **F3**: Tornado handler wrapper — không khuyến cáo
**Recommend:** F2 nếu version đủ mới. User chưa confirm có Streamlit hay không → defer decision.

## DB schema migration (nhóm B)

```sql
ALTER TABLE users RENAME TO users_legacy;   -- giữ forensic 30d
CREATE TABLE users (
  id ..., email ..., zitadel_subject TEXT UNIQUE,
  name TEXT, created_at TIMESTAMP, ...
);
-- KHÔNG TRUNCATE — rename an toàn hơn (đã red-team confirm)
```

Auto-provision pattern:
```
on_request:
  email = X-Auth-Request-Email
  user = SELECT * FROM users WHERE email = email
  if not user: user = INSERT (email, zitadel_subject, ...)
  request.user = user
```

## Estimate 10 app

| Loại | Effort/app | Số app giả định | Tổng |
|---|---|---|---|
| Nhóm A | 30' | 4 | 2h |
| Shared (đơn) | 30' | 2 | 1h |
| Nhóm B đơn giản | 2h | 3 | 6h |
| Nhóm B phức tạp | 4h | 1 | 4h |
| **Tổng** | | **10** | **~13h ≈ 2 ngày tuần tự** |

Parallel 2 dev → 1 ngày.

## Recommended migration order

1. Nhóm A đầu tiên (cheap, build confidence) — 1 ngày
2. 1 app shared account đơn giản (validate per-user flow)
3. 1 app Nhóm B đơn giản (validate middleware + schema)
4. 1 app Streamlit (validate F2)
5. Còn lại phân loại, parallel
6. **KHÔNG** retire IP whitelist sau migration (defense in depth)

## Quyết định

User chọn: **chỉ brainstorm, chưa cần plan template repo**. Có sẵn `sample-apps/nextjs-iap-demo` và `static-iap-demo` làm reference. Khi migrate app đầu tiên sẽ đúc rút template từ thực tế.

## Unresolved questions

1. App nào cụ thể thuộc nhóm A vs B vs shared? Cần inventory để pick pilot.
2. Có Streamlit không, version nào? — User chưa confirm.
3. Hostname strategy: dùng chung parent domain (`*.internal.company.com`) hay TLD khác per-app? — ảnh hưởng SSO cookie behavior.
4. Có app nào làm IdP cho app khác (OAuth-as-server) không? Nếu có, migration phức tạp hơn.
5. User đổi email Google → Zitadel: bind theo `zitadel_subject` (immutable) thay vì email khi possible. Cần document trong template middleware.
