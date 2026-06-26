---
phase: 02
title: POC-A — Authentik full stack
status: pending
priority: P0
effort: 1.5d
parallelWith: [03]
blockedBy: [01]
---

# Phase 02 — POC-A: Authentik

## Context
- Brainstorm §4 Approach A
- Authentik docs: https://docs.goauthentik.io/

## Overview
Deploy Authentik (server + worker + redis) on shared infra, federate with Google Workspace, enforce MFA/Passkey, prove BOTH integration modes with sample apps.

## Key Insights
- Authentik = 1 tool: OIDC provider + Proxy Outpost (forward-auth) + admin UI
- Outpost can be embedded (same compose) or separate; POC uses embedded for simplicity
- Flow Designer lets you compose: identification → password → MFA → consent

## Requirements
- OIDC Provider for sample app `app-oidc.<internal>.example`
- Proxy Provider (forward-auth mode) protecting `app-zeroauth.<internal>.example`
- Google as Federation Source (not direct OAuth login button; broker mode)
- MFA stage: Passkey preferred, TOTP fallback, enforced for all users
- Admin user via env bootstrap, then disabled after first login

## Architecture
```
Google Workspace
    ↓ OIDC federation source
Authentik server ←→ Postgres (db: authentik)
    ↑       ↘
    │        Redis
    │
    ├── OIDC Provider → app-oidc (redirect flow)
    └── Proxy Outpost ←─ Traefik forwardAuth → app-zeroauth
```

## Files to Create
- `infra/poc-a/docker-compose.authentik.yml` — authentik-server, authentik-worker, redis
- `infra/poc-a/.env` — secret_key, Postgres creds, bootstrap admin
- `infra/poc-a/blueprints/` — declarative config exports (after manual setup, export as YAML for reproducibility)
- `sample-apps/oidc-demo/` — Next.js or simple Node app with `openid-client`
- `sample-apps/zeroauth-demo/` — static nginx serving HTML page (proxy by docker, no auth code)
- `docs/poc-a-runbook.md`

## Implementation Steps

1. Add `docker-compose.authentik.yml` to the base stack with Traefik labels for `auth-a.<internal>.example`
2. Bootstrap admin via env, login, change password
3. **Google federation**:
   - Add Source → OIDC → use Google client A credentials, scopes `openid email profile`
   - Set "enrollment flow" to auto-create user on first Google login
4. **MFA stages**:
   - Add Authenticator Validation Stage (Passkey, TOTP allowed)
   - Modify default-authentication-flow to require MFA after identification
5. **OIDC Provider for sample app**:
   - Create Provider (OIDC, authorization code + PKCE)
   - Note `client_id`, `client_secret`, well-known URL
   - Create Application linking provider, slug `oidc-demo`
6. **Sample OIDC app** (`sample-apps/oidc-demo`):
   - Next.js with NextAuth or Node + `openid-client`
   - Add Traefik labels for `app-oidc.<internal>.example`
   - Test login → redirect to Authentik → Google → MFA → callback → session
7. **Proxy Provider for zero-auth app**:
   - Create Provider (Proxy mode = Forward auth single application)
   - External host = `https://app-zeroauth.<internal>.example`
   - Create Application
   - Configure embedded Outpost to include this provider
8. **Wire Traefik forwardAuth**:
   - Add middleware pointing to Outpost endpoint `https://auth-a.<internal>.example/outpost.goauthentik.io/auth/traefik`
   - Attach middleware to `app-zeroauth` router
9. **Sample zero-auth app**:
   - Static nginx container serving HTML
   - Test: unauthenticated → redirect to Authentik → after auth → page loads
   - Verify headers `X-authentik-username`, `X-authentik-email` injected to upstream
10. **Export blueprints** for reproducibility: `ak export blueprint > blueprints/poc-a.yaml`
11. **7-day soak**: leave running, capture daily metrics (RAM, CPU, restart count)

## Todo
- [ ] Authentik up, login works
- [ ] Google federation tested (login with company Google)
- [ ] MFA enforced (cannot bypass)
- [ ] OIDC sample app working
- [ ] Forward-auth sample app working
- [ ] Blueprint exported
- [ ] Onboard timing measured (target: OIDC <15min, fwdAuth <10min)
- [ ] 7-day uptime metrics collected

## Success Criteria
- New user (Google identity) gets enrolled + MFA prompt on first login
- Both sample apps protected, headers propagated
- 0 unintended crashes in 7 days
- Onboard times meet targets

## Risks
| Risk | Mitigation |
|---|---|
| Outpost connectivity issues | Use embedded outpost first; document switching to separate if needed |
| Flow misconfig blocks all logins | Keep `akadmin` recovery flow enabled |
| Cookie domain scoping | All apps share parent domain `*.<internal>.example` |

## Reference
- Authentik install (Docker): https://docs.goauthentik.io/docs/installation/docker-compose
- Forward auth (Traefik): https://docs.goauthentik.io/docs/providers/proxy/forward_auth
