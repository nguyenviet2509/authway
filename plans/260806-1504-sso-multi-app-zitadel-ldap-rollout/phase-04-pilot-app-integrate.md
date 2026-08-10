# Phase 4 — Pilot app integrate (OneMCP)

**Effort:** 0.5-1d
**Status:** pending
**Depends on:** Phase 3 (IAP baseline working)

## Context
- Plan: [../plan.md](../plan.md)
- OneMCP hiện tại có OAuth GitLab SSO code (đã supersede) — remove
- OneMCP portal: `D:/Vietnt/Project/onemcp/portal/` (Next.js 15)
- OneMCP backend: `D:/Vietnt/Project/onemcp/backend/` (NestJS)

## Objective
Migrate OneMCP portal + backend về IAP pattern. Remove GitLab OAuth code cũ (đã ship trong plan 260805 nhưng deprecated). Backend đọc `X-Auth-Request-Email` header thay vì cookie session.

## Steps

### 1. Traefik config OneMCP portal (onemcp-vps)
Update onemcp-vps `docker-compose.yml`:
```yaml
onemcp-portal:
  labels:
    - "traefik.http.routers.onemcp.rule=Host(`onemcp.inet.vn`)"
    - "traefik.http.routers.onemcp.middlewares=iap-auth@file"
```

**Blocker:** onemcp-vps hiện tại chưa share network với authway/oauth2-proxy. Cần:
- **Option A:** Deploy oauth2-proxy trên onemcp-vps riêng (multi-instance oauth2-proxy) — dùng chung Zitadel OIDC client hoặc tạo client per VPS
- **Option B:** Traefik federated middleware (Traefik plugin `forwardauth` remote) — call `https://iap.inet.vn/oauth2/auth`
- Recommend **Option B** cho onboarding rẻ.

Middleware config trên onemcp-vps traefik:
```yaml
iap-remote:
  forwardAuth:
    address: "https://iap.inet.vn/oauth2/auth"
    trustForwardHeader: true
    authResponseHeaders: [...]
```

### 2. Remove GitLab OAuth code
Backend cleanup:
- Delete `backend/src/auth/gitlab-oauth.service.ts`
- Delete `backend/src/auth/session.service.ts`, `cookie-auth.middleware.ts`
- Remove `AUTH_MODE`, `GITLAB_OAUTH_*`, `SESSION_*` env keys từ `env.schema.ts` + `.env`
- Simplify `RequestUser` interface — email/displayName giữ, id/username từ header luôn

Portal cleanup:
- Delete `middleware.ts` (redirect logic — Traefik handle)
- Delete `lib/auth.ts` (session check — chuyển sang header read từ SSR)
- `layout.tsx` — read user info từ header trực tiếp (`headers()` API)

### 3. Backend header-based auth middleware mới
Replace old middleware bằng minimal:
```typescript
// backend/src/auth/iap-header.middleware.ts
export class IapHeaderMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction) {
    const email = req.header('X-Auth-Request-Email');
    if (!email) throw new UnauthorizedException('Missing IAP header');
    req.user = {
      email,
      username: req.header('X-Auth-Request-Preferred-Username') ?? email,
      displayName: req.header('X-Auth-Request-User') ?? email,
    };
    next();
  }
}
```

### 4. Portal user info
Next.js RSC:
```typescript
// app/(app)/layout.tsx
import { headers } from 'next/headers';
export default async function Layout({ children }) {
  const h = await headers();
  const email = h.get('x-auth-request-email');
  // Render user chip từ email, không cần lib/auth.ts
}
```

### 5. Zitadel role mapping (defer or minimal)
- Baseline: tất cả LDAP user = default role trong OneMCP (admin/user tùy business)
- Advanced role-based: defer feature request tương lai (map Zimbra group → OneMCP role)

### 6. E2E test
- Incognito → `onemcp.inet.vn` → redirect Zitadel LDAP → login → về portal
- Portal render user info từ header
- Backend API call: verify request.user populated đúng
- Logout: `iap.inet.vn/oauth2/sign_out` → cookie cleared → onemcp.inet.vn re-redirect login

### 7. Update OneMCP docs
- `onemcp/docs/sso-guide.md` — update thành IAP flow (thay vì GitLab OAuth)
- Deprecate `onemcp/docs/sso-rollback-runbook.md` phần GitLab

## Deliverables
- OneMCP portal + backend integrated với IAP
- GitLab OAuth code removed cleanly (không leave dead code)
- Header-based auth middleware working
- Docs updated
- Journal: sso migration OneMCP shipped

## Success criteria
- ✅ OneMCP login end-to-end qua LDAP user
- ✅ Backend read email từ header đúng
- ✅ No legacy GitLab OAuth code left
- ✅ Docs reflect new pattern

## Risks

| Risk | Mitigation |
|---|---|
| Federated forwardAuth cross-VPS latency | Accept ~50-100ms per request; monitor + optimize sau |
| Cross-VPS cookie domain issue | Cookie domain `.inet.vn` cover all subdomains |
| Rollback nếu integration fail | Restore GitLab OAuth code từ git tag pre-P4 |
| Zimbra user chưa được onboard OneMCP → 401 | Auto-provision Zitadel user OK (đã config), OneMCP backend auto-create user record on first login |

## Next → Phase 5
Onboarding docs + template refine.
