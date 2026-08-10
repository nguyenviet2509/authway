---
name: SSO đa app qua Zitadel + Zimbra LDAP + IAP pattern
slug: sso-multi-app-zitadel-ldap-rollout
status: pending
created: 2026-08-06
effort: 4-6 days
blockedBy: []  # ✅ Unblocked 2026-08-06: authway:260806-0939 completed (T1 LDAP browser flow verified E2E on lab, all Zitadel v4.16.1 config fixes applied)
blocks:
  - onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel
  - onelog:260805-0852-onemcp-ai-connector-hub
---

# SSO đa app qua Zitadel + Zimbra LDAP + IAP pattern

**Brainstorm:** [../../onelog/plans/reports/brainstorm-260806-1504-sso-zitadel-ldap-multi-app.md](../../../onelog/plans/reports/brainstorm-260806-1504-sso-zitadel-ldap-multi-app.md)

## Goal

Ship SSO cho tất cả app internal KT (OneLog, OneMCP, vibecode apps tương lai) qua Zitadel OIDC + Zimbra LDAP backend, dùng IAP (oauth2-proxy) làm default auth pattern.

## Approach chốt

- **IAP default** (oauth2-proxy trước Traefik forwardAuth) — cheap onboarding per app
- **OIDC-native opt-in** cho app phức tạp (API/mobile) — defer, chưa cần ngay
- **LDAP-only** (Zimbra là single source of truth cho KT internal)
- **Zitadel v4.16+** để retest bug SSR fetch (nếu chưa fix → fallback OIDC direct)

## Kiến trúc

```
User (browser)
  │
  ▼
Traefik ─forwardAuth─► oauth2-proxy ─OIDC─► Zitadel ─LDAP─► Zimbra
  │
  ▼
App backend (đọc X-Forwarded-Email header)
```

## Phases

| # | Phase | Effort | Status |
|---|---|---|---|
| 1 | [Zitadel prod deploy v4.16+](phase-01-zitadel-prod-deploy.md) | 1-2d | pending |
| 2 | [Zimbra prod LDAP integration](phase-02-zimbra-prod-ldap.md) | 0.5d | pending |
| 3 | [oauth2-proxy IAP baseline](phase-03-oauth2-proxy-iap-baseline.md) | 1d | pending |
| 4 | [Pilot app integrate (OneMCP)](phase-04-pilot-app-integrate.md) | 0.5-1d | pending |
| 5 | [Onboarding docs + template](phase-05-onboarding-docs-template.md) | 0.5d | done (2026-08-10) |
| 6 | [Second app rollout (OneLog)](phase-06-second-app-rollout.md) | 0.5d | done (2026-08-09) |

**Tổng:** 4-6 ngày. P1+P2 có thể chạy song song. P4-P6 sequential.

## Key dependencies

- **Domain thật** cho Zitadel prod (VD `auth.inet.vn`) — user cấp DNS trước P1
- **VPS prod** cho Zitadel — user provision hoặc reuse `onelog-vps`/`onemcp-vps`
- **Zimbra prod** ready + admin access (đã có)
- **Blocker resolved:** authway plan 260806-0939 Phase 3 (Zitadel v4.15 bug) — hoặc upgrade v4.16 fix, hoặc dùng fallback OIDC direct

## Success criteria

- ✅ KT user login 1 lần → tất cả app không re-login
- ✅ Add app mới = 1 file traefik config (< 10 phút)
- ✅ Logout Zitadel = logout all app
- ✅ Zimbra password change → next login refresh
- ✅ Zero secret leak (app không thấy password LDAP)

## Related plans

- `authway/plans/260806-0939-zitadel-ldap-zimbra-lab/` — LDAP config lab, blocker T1
- `authway/plans/260626-1154-zitadel-iap-rollout/` — original IAP rollout (kế thừa artifacts)
- `authway/templates/app-iap-template/` — starting point cho P5 template refine
- `onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel` — unblocked sau P4
- `onelog:260805-0852-onemcp-ai-connector-hub` — unblocked sau 260805-1409

## Unresolved

- Domain thật cho Zitadel prod (chờ user cấp)
- MFA policy: enable all vs opt-in — defer sau P4 verify baseline
- Group sync Zimbra → Zitadel role: out of scope, feature request tương lai
- Zitadel HA: defer, single node đủ prod đầu
