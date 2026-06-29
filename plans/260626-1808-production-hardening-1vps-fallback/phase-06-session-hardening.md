# Phase 06 — Session/Token TTL + Cookie Hardening

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 0.5 ngày

## Overview
**Priority**: P2

App infra-critical → session TTL phải chặt. Mặc định Zitadel + oauth2-proxy có thể quá lỏng. Tune xuống mức cân bằng giữa UX và security.

## Target settings

| Setting | Default | Production target | Rationale |
|---|---|---|---|
| Access token TTL | 1h | 1h | Đủ ngắn để mất impact thấp |
| Refresh token TTL | 30d | 8h | Force re-auth cuối ngày làm việc |
| Session inactive timeout | ? | 4h | Laptop bỏ quên |
| Force re-MFA | never | daily | App critical, đáng phiền 1 lần/ngày |
| oauth2-proxy `cookie-refresh` | 0 | 30m | Refresh token trước khi expire |
| oauth2-proxy `cookie-expire` | 168h | 8h | Match refresh TTL |
| oauth2-proxy `cookie-secure` | true ✅ | true | Đã có |
| oauth2-proxy `cookie-httponly` | true ✅ | true | Default OK |
| oauth2-proxy `cookie-samesite` | lax | lax | OK (strict break OAuth callback) |

## Files to Modify
- `infra/auth-vps/zitadel-config.yaml` — DefaultInstance token TTL
- `infra/app-vps/docker-compose.yml` — oauth2-proxy command flags
- Zitadel UI: Login Policy, Lockout Policy

## Implementation Steps

1. **Zitadel token policy** (qua UI hoặc YAML config)
   ```yaml
   DefaultInstance:
     OIDCSettings:
       AccessTokenLifetime: 1h
       IdTokenLifetime: 1h
       RefreshTokenIdleExpiration: 8h
       RefreshTokenExpiration: 24h
   ```

2. **Session timeout policy**
   - Zitadel Console → Default settings → Session
   - Idle timeout: 4h
   - Maximum lifetime: 12h

3. **Force re-MFA daily**
   - Zitadel Login Policy → Multi-Factor Init Lifetime: 24h
   - Verify với test user: login → 25h sau → buộc MFA lại

4. **oauth2-proxy** command update
   ```
   --cookie-expire=8h
   --cookie-refresh=30m
   --session-cookie-minimal=true
   ```

5. **CSRF + state validation**
   - Verify oauth2-proxy `--code-challenge-method=S256` (PKCE)
   - Verify state parameter random per request (default ✅)

6. **CSP headers** (defense in depth XSS)
   - Traefik middleware `security-headers` đã có; thêm:
     ```yaml
     contentSecurityPolicy: "default-src 'self'; script-src 'self'; ..."
     ```
   - Per-app CSP có thể conflict; document policy override per app

7. **Test matrix**
   - Login → wait 1h5m → access token rotate (silent qua refresh)
   - Login → wait 8h5m → refresh expired → buộc login lại
   - Login → idle 4h → next action redirect login
   - Login day 1 với MFA → day 2 → buộc MFA lại
   - Cookie inspect: HttpOnly + Secure + SameSite=Lax + Path=/

## Todo
- [ ] Update Zitadel token TTL config
- [ ] Update session timeout policy
- [ ] Enable force re-MFA 24h
- [ ] Update oauth2-proxy cookie flags
- [ ] Verify PKCE active
- [ ] Test matrix pass
- [ ] Document trade-off cho dev: phải MFA daily

## Success Criteria
- Test matrix 5/5 pass
- DevTools Cookie inspect: HttpOnly, Secure, SameSite=Lax đầy đủ
- Force re-MFA verify trên 1 user test

## Risks
- **UX phàn nàn re-MFA daily** → mitigation: explain trade-off + Passkey thay TOTP (1 tap vs gõ 6 số)
- **Refresh 30m quá thường xuyên** → load Zitadel tăng. Mitigation: monitor RPS sau deploy, tăng lên 1h nếu OK
- **Session-cookie-minimal=true** có thể break feature nào không? → test kỹ trên staging

## Reference
- Zitadel OIDC settings: https://zitadel.com/docs/apis/openidoauth/endpoints
- oauth2-proxy cookie flags: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview
