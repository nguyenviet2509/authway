# Phase 01 — Pre-flight Snapshot

**Status:** pending
**Priority:** P0 (blocker cho phase 2)

## Goal

Lưu lại config OIDC/users hiện có để recreate sau khi nuke. Verify `.env` còn credentials để login lại.

## Steps

1. SSH vào VPS:
   ```bash
   ssh vietnt@192.168.122.54
   ```

2. Vào working dir:
   ```bash
   cd /opt/authway/infra/auth-vps
   ```

3. Snapshot OIDC apps + projects:
   ```bash
   docker compose exec -T postgres psql -U postgres -d zitadel -c "SELECT a.id, a.name, a.project_id, p.name AS project_name, oc.client_id, oc.redirect_uris, oc.grant_types, oc.response_types FROM projections.apps7 a LEFT JOIN projections.apps7_oidc_configs oc ON oc.app_id=a.id LEFT JOIN projections.projects4 p ON p.id=a.project_id;" | tee ~/oidc-snapshot-pre-nuke.txt
   ```

4. Snapshot non-system users:
   ```bash
   docker compose exec -T postgres psql -U postgres -d zitadel -c "SELECT id, username, resource_owner, state FROM projections.users14 WHERE username NOT LIKE 'zitadel-admin%' AND username != 'login-client';" | tee ~/users-snapshot-pre-nuke.txt
   ```

5. Verify `.env` còn admin creds:
   ```bash
   grep -E '^ZITADEL_ADMIN_(USERNAME|PASSWORD)=' .env
   ```
   Nếu thiếu → DỪNG, set lại trước khi phase 2.

## Success criteria

- [ ] `~/oidc-snapshot-pre-nuke.txt` tồn tại, có rows OIDC clients
- [ ] `~/users-snapshot-pre-nuke.txt` tồn tại
- [ ] `.env` có cả `ZITADEL_ADMIN_USERNAME` và `ZITADEL_ADMIN_PASSWORD` non-empty

## Next

→ [phase-02-fix-and-reinit.md](phase-02-fix-and-reinit.md)
