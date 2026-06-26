---
phase: 01
title: Shared infrastructure base
status: pending
priority: P0
effort: 0.5d
---

# Phase 01 — Shared Infrastructure Base

## Context
- Brainstorm: [../reports/brainstorm-260626-1103-auth-gateway-poc.md](../reports/brainstorm-260626-1103-auth-gateway-poc.md)
- Both POCs run on same VPS, share Traefik edge + Postgres instance

## Overview
Provision base layer: VPS, Docker, Traefik (TLS, routing, forwardAuth middleware engine), Postgres (with separate logical DBs for each POC), DNS records, Google OAuth credentials.

## Requirements

### Functional
- Traefik routes by hostname → backend container
- Auto TLS via Let's Encrypt (HTTP-01 first; DNS-01 if wildcard needed)
- Postgres exposed only on Docker network, not public
- Network isolation between POC-A and POC-B containers (separate networks, shared edge)

### Non-functional
- Idempotent compose files (re-runnable)
- Volume mounts on host path `/opt/authway/{traefik,postgres,authentik,zitadel}`
- Daily Postgres backup cron (pg_dump → local + offsite)

## Architecture

```
VPS (≥4 GB RAM)
├── network: edge
│   └── traefik (80/443)
├── network: poc-a
│   ├── authentik-*
│   └── traefik (attached)
├── network: poc-b
│   ├── zitadel, oauth2-proxy
│   └── traefik (attached)
└── postgres (own network, both poc-a & poc-b attached)
```

## Files to Create
- `infra/docker-compose.base.yml` — Traefik + Postgres
- `infra/traefik/traefik.yml` — static config
- `infra/traefik/dynamic/middlewares.yml` — security headers, rate limit
- `infra/postgres/init.sql` — create databases `authentik`, `zitadel`, separate users
- `infra/.env.example` — domain, ACME email, Postgres root password
- `infra/scripts/backup-postgres.sh`
- `docs/infra-setup.md` — runbook

## Implementation Steps

1. Confirm VPS specs and DNS access (resolve open questions from plan.md)
2. Install Docker + docker compose plugin on VPS
3. Create `/opt/authway` dir structure with appropriate permissions
4. Write `traefik.yml` with entrypoints `:80` (redirect to 443), `:443`, file provider, docker provider, ACME resolver
5. Write `docker-compose.base.yml`: `traefik`, `postgres:16-alpine` with healthcheck
6. Create separate Postgres DBs + users for authentik & zitadel (least privilege)
7. Bring up base stack; verify Traefik dashboard (gated behind basic auth on internal subnet)
8. Verify ACME cert issuance using a temporary whoami container
9. Register 2 Google Cloud OAuth clients (one per POC) — note client_id/secret, set callback placeholders
10. Document the base layer in `docs/infra-setup.md`

## Todo

- [ ] VPS access confirmed
- [ ] DNS A records added (4 subdomains)
- [ ] Docker + compose installed
- [ ] Traefik up with TLS
- [ ] Postgres up with both DBs/users
- [ ] Google OAuth client A created
- [ ] Google OAuth client B created
- [ ] Backup cron tested
- [ ] Runbook written

## Success Criteria
- `curl https://<traefik-test>.example` returns valid TLS
- `psql` from a sidecar container can connect to both DBs with respective users only
- `whoami` test container reachable through Traefik

## Risks
| Risk | Mitigation |
|---|---|
| ACME rate limit | Use staging during initial setup |
| Postgres data loss | Daily backup + tested restore once |
| Single VPS down | Accept for POC; doc HA plan for production |
