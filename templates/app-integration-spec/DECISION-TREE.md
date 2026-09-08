# Decision tree — Pattern A (IAP sidecar) vs Pattern B (Native OIDC)

**Đọc file này TRƯỚC `SPEC.md`.** Chọn sai pattern = refactor lại lần 2.

## Quick decision

Trả lời 6 câu hỏi theo thứ tự. Câu đầu tiên có "yes" quyết định pattern.

### Q0 — App có sẵn auth logic phức tạp (password + 2FA/MFA + JWT/session + local RBAC/permissions) mà bạn KHÔNG muốn refactor?

VD: enterprise app đã có JWT rotation + WebAuthn/Passkey + TOTP + fine-grained permissions per module + user DB với roles.

- **Yes** → **Pattern C (Federated Login)** — SSO là 2nd IdP path song song, giữ nguyên auth cũ 100%. Add-only guarantee. Xem `examples/federated-login-example.md`.
- **No** → Q1 (Pattern A vs B).

### Q1 — App là SPA thuần (React/Vue/Svelte, không backend riêng)?

- **Yes** → **Pattern B** với browser PKCE flow. Xem `examples/spa-react-vue-pkce.md`. KHÔNG dùng `CLIENT_SECRET`.
- **No** → Q2.

### Q2 — App cần forward user's access token xuống downstream API?

VD: app gọi API khác cùng cần biết user identity (multi-service architecture, BFF pattern).

- **Yes** → **Pattern B**. Cần `access_token` để forward.
- **No** → Q3.

### Q3 — App cần parse role claim structure phức tạp?

VD: role có `orgId` metadata, multi-tenant, roles map → khác feature per tenant.

- **Yes** → **Pattern B**. JWT parse toàn bộ claim JSON.
- **No** → Q4.

### Q4 — Reverse proxy (Caddy/Traefik/nginx) available trước app?

- **No** → **Pattern B** (không có sidecar setup). Native OIDC in-process.
- **Yes** → Q5.

### Q5 — Framework Next.js App Router?

- **Yes** → **Pattern B** vì NextAuth (Auth.js v5) integrate cực đơn giản (5 dòng config). IAP sidecar trước Next.js không tối ưu.
- **No** → **Pattern A** (default). Refactor delta ~5 dòng. Xem `examples/nodejs-express-iap.md` hoặc `examples/python-fastapi-iap.md`.

---

## Pattern A summary

- **Setup**: oauth2-proxy container/binary + Caddy/Traefik config
- **App changes**: đọc `X-Auth-Request-Email` header, bind `127.0.0.1`, redirect logout `/oauth2/sign_out`
- **Cover**: 90% vibecode backend
- **Refactor delta**: ~5 dòng code
- **Pros**: framework-agnostic, no OIDC library, secret sống trong sidecar
- **Cons**: cần reverse proxy setup, khó forward token downstream, roles = comma-sep string

## Pattern B summary

- **Setup**: OIDC library trong app
- **App changes**: `/login`, `/callback`, `/logout` routes + JWT verify middleware + session store
- **Cover**: SPA, Next.js, apps cần token/claim parse
- **Refactor delta**: ~50-100 dòng code + 1 dependency
- **Pros**: full token access, custom claim parse, no sidecar
- **Cons**: framework-specific code, PKCE bookkeeping, JWKS cache

## Pattern C summary

- **Setup**: Add SSO endpoint song song với existing auth. REUSE existing token issuance primitive
- **App changes**: Add-only — new SSO service + controller + callback route + login button. **0 dòng logic auth cũ bị đổi**
- **Cover**: Apps có JWT rotation + 2FA/Passkey + local RBAC muốn preserve
- **Refactor delta**: ~350-500 dòng ADD, 0 dòng modify existing auth
- **Pros**: rollback = delete feature branch. Zero risk phá auth cũ. Dual login path (password + SSO)
- **Cons**: 2 auth systems song song (maintenance). User DB vẫn own permissions

---

## Nếu vẫn không chắc

Default → **Pattern A**. Refactor delta nhỏ, dễ rollback. Nếu sau này cần token → migrate sang B, code Pattern A xoá không tốn.
