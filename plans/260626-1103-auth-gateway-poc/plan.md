---
title: Auth Gateway — Parallel POC (Authentik vs Zitadel)
date: 2026-06-26
status: superseded
supersededBy: ../260626-1154-zitadel-iap-rollout/plan.md
supersededReason: User chốt Zitadel (session 1154); chuyển sang IAP pattern thay vì POC parallel
mode: parallel
blockedBy: []
blocks: []
brainstorm: ../reports/brainstorm-260626-1103-auth-gateway-poc.md
---

# Auth Gateway POC Plan

## Objective
Run two POCs in parallel to choose centralized auth gateway for internal "vibe coding" apps:
- **POC-A**: Authentik (1 tool, MIT, native forward-auth)
- **POC-B**: Zitadel + oauth2-proxy (AGPL, OIDC-certified)

Decide winner after 7-day uptime + 7-criteria comparison.

## Constraints
- Docker Compose on single VPS
- Traefik edge + Postgres shared
- Google Workspace IdP source
- MFA/Passkey policy mandatory
- Internal-only, 5–15 apps, <1k users
- Each POC must prove BOTH OIDC redirect AND forward-auth flows

## Phases

| # | Phase | Status | Parallel? | Effort |
|---|---|---|---|---|
| 01 | [Shared infra base](phase-01-shared-infra-base.md) | pending | — | 0.5d |
| 02 | [POC-A: Authentik full stack](phase-02-poc-a-authentik.md) | pending | with 03 | 1.5d |
| 03 | [POC-B: Zitadel + oauth2-proxy](phase-03-poc-b-zitadel.md) | pending | with 02 | 2d |
| 04 | [Evaluation & decision](phase-04-evaluation-and-decision.md) | pending | after 02+03 | 0.5d |

Total wall-clock: ~3 days (2 parallel tracks) + 7-day soak before phase 04.

## Key Dependencies
- VPS provisioned (≥4 GB RAM, ≥2 vCPU, Docker installed)
- DNS: `auth-a.<internal>.example`, `auth-b.<internal>.example`, `app-oidc.<internal>.example`, `app-zeroauth.<internal>.example` resolvable
- Google Cloud project with OIDC OAuth credentials (one for each POC)
- Let's Encrypt access (HTTP-01 or DNS-01)

## Open Questions (from brainstorm §9)
- [ ] Domain xác định? DNS provider?
- [ ] VPS spec hiện có?
- [ ] Audit log requirement?
- [ ] M2M client_credentials needed in POC?

**Block-or-proceed:** Open questions không block POC start, có thể fill in trong phase 01.

## Success Criteria (plan-level)
- Cả 2 POC chạy 7 ngày không crash
- Onboard sample app (OIDC) <15min, (forward-auth) <10min cho mỗi POC
- Decision doc kết luận winner + rollout plan production
