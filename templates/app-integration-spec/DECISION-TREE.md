# Decision tree — Pattern A (IAP sidecar) vs Pattern B (Native OIDC)

**Đọc file này TRƯỚC `SPEC.md`.** Chọn sai pattern = refactor lại lần 2.

## Quick decision

Trả lời 5 câu hỏi theo thứ tự. Câu đầu tiên có "yes" quyết định pattern.

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

---

## Nếu vẫn không chắc

Default → **Pattern A**. Refactor delta nhỏ, dễ rollback. Nếu sau này cần token → migrate sang B, code Pattern A xoá không tốn.
