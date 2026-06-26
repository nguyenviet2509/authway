---
phase: 03
title: POC-B — Zitadel + oauth2-proxy
status: pending
priority: P0
effort: 2d
parallelWith: [02]
blockedBy: [01]
---

# Phase 03 — POC-B: Zitadel + oauth2-proxy

## Context
- Brainstorm §4 Approach B
- Zitadel docs: https://zitadel.com/docs
- oauth2-proxy: https://oauth2-proxy.github.io/oauth2-proxy/

## Overview
Deploy Zitadel on shared infra, federate Google Workspace, enforce MFA/Passkey, expose OIDC for sample app, attach oauth2-proxy as forward-auth bridge for zero-auth app.

## Key Insights
- Zitadel: Org → Project → Application hierarchy
- No native forward-auth → oauth2-proxy validates Zitadel session, exposes `/oauth2/auth` for Traefik forwardAuth
- AGPL license — accepted per brainstorm (internal use)
- Zitadel needs `ZITADEL_EXTERNALDOMAIN`, `ZITADEL_EXTERNALSECURE`, masterkey, init steps

## Requirements
- OIDC Application for sample app `app-oidc-b.<internal>.example`
- oauth2-proxy in forward-auth mode for `app-zeroauth-b.<internal>.example`
- Google IDP configured in Zitadel
- MFA policy: Passkey preferred, TOTP fallback, enforced
- Admin user provisioned via masterkey + init

## Architecture
```
Google Workspace
    ↓ IDP
Zitadel ←→ Postgres (db: zitadel)
    │
    ├── OIDC App → app-oidc-b (redirect)
    └── OIDC App → oauth2-proxy ←─ Traefik forwardAuth → app-zeroauth-b
```

## Files to Create
- `infra/poc-b/docker-compose.zitadel.yml` — zitadel, oauth2-proxy
- `infra/poc-b/.env` — masterkey, postgres creds, oauth2-proxy secret
- `infra/poc-b/zitadel-init.yaml` — declarative init (org, admin user, project)
- `sample-apps/oidc-demo-b/` — separate Next.js or reuse pattern from POC-A
- `sample-apps/zeroauth-demo-b/` — static nginx
- `docs/poc-b-runbook.md`

## Implementation Steps

1. Generate masterkey: `openssl rand -base64 32`
2. Add `docker-compose.zitadel.yml` with Traefik labels for `auth-b.<internal>.example`, env `ZITADEL_EXTERNALDOMAIN`, `_EXTERNALSECURE=true`
3. Run `zitadel init` then `zitadel setup` (one-shot init containers per official docker compose example)
4. Bring up Zitadel server, login as initial admin, change password
5. **Google IDP**:
   - Default Settings → Identity Providers → Add Google
   - Paste client B credentials, scopes `openid email profile`
   - Enable "Auto Register" so new users from Google create accounts
6. **MFA policy**:
   - Default Settings → Login Policy → Force MFA = ON
   - Allowed factors: OTP, U2F (Passkey)
7. **OIDC Application for sample app**:
   - Create Project "internal-apps"
   - Add Application (Web, code flow + PKCE)
   - Redirect URI: `https://app-oidc-b.<internal>.example/api/auth/callback`
   - Note client_id/secret + discovery URL
8. **Sample OIDC app**: same pattern as POC-A, separate folder
9. **OIDC Application for oauth2-proxy**:
   - Add second Application (Web, confidential)
   - Redirect URI: `https://app-zeroauth-b.<internal>.example/oauth2/callback`
   - Note client_id/secret
10. **oauth2-proxy config**:
    - `--provider=oidc`
    - `--oidc-issuer-url=https://auth-b.<internal>.example`
    - `--client-id`/`--client-secret` from step 9
    - `--reverse-proxy=true`
    - `--cookie-domain=.<internal>.example`
    - `--whitelist-domain=.<internal>.example`
    - Run as sidecar to zero-auth app OR shared instance (use shared for POC)
11. **Traefik forwardAuth**:
    - Middleware `auth-b-fwd`: `forwardAuth.address=http://oauth2-proxy:4180/oauth2/auth`
    - Attach to `app-zeroauth-b` router
    - Add error redirect to `/oauth2/start?rd=$scheme://$host$request_uri`
12. **Test flows**: same as POC-A
13. **7-day soak**: collect metrics

## Todo
- [ ] Zitadel init complete, admin login works
- [ ] Google IDP working
- [ ] MFA enforced
- [ ] OIDC sample app working
- [ ] oauth2-proxy session validates
- [ ] Forward-auth sample app working
- [ ] Onboard timing measured (target: OIDC <15min, fwdAuth <10min including oauth2-proxy)
- [ ] 7-day uptime metrics collected

## Success Criteria
- Same login UX as POC-A
- Both sample apps protected
- 0 unintended crashes in 7 days

## Risks
| Risk | Mitigation |
|---|---|
| Init step fragile | Use docker-compose `condition: service_completed_successfully` |
| oauth2-proxy + Zitadel cookie conflicts | Set `--cookie-domain` carefully, document |
| Two systems failure modes | Document failover behavior |
| Zitadel CVE patches | Subscribe to security advisory, pin minor version |

## Reference
- Zitadel docker compose: https://zitadel.com/docs/self-hosting/deploy/compose
- oauth2-proxy OIDC: https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/openid_connect
