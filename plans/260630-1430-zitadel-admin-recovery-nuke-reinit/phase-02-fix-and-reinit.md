# Phase 02 — Fix Script + Nuke & Reinit

**Status:** pending
**Priority:** P0
**Depends on:** Phase 01 snapshot

## Goal

Đẩy script fix lên VPS, xóa sạch state, render config đúng, bring up fresh.

## Steps

1. Push fix `scripts/render-config.sh` lên VPS — chọn 1 cách:

   Cách A (git pull trên VPS):
   ```bash
   cd /opt/authway && git pull && cd /opt/authway/infra/auth-vps
   ```

   Cách B (scp từ máy dev Windows):
   ```bash
   scp infra/auth-vps/scripts/render-config.sh vietnt@192.168.122.54:/opt/authway/infra/auth-vps/scripts/
   ```

2. Nuke stack:
   ```bash
   docker compose down -v
   ```

3. Xóa directory rác:
   ```bash
   sudo rm -rf zitadel-steps.runtime.yaml zitadel-config.runtime.yaml
   ```

4. Render runtime config (script đã fix, có defensive cleanup):
   ```bash
   bash scripts/render-config.sh
   ```

5. Verify cả 2 là FILE (không phải directory):
   ```bash
   ls -la zitadel-config.runtime.yaml zitadel-steps.runtime.yaml
   ```
   Mong đợi: `-rw-------` size > 0, không phải `drwx...`.

6. Bring stack up:
   ```bash
   docker compose up -d
   ```

7. Watch setup logs cho đến khi thấy `setup completed` rồi Ctrl+C:
   ```bash
   docker compose logs -f zitadel-setup
   ```

## Success criteria

- [ ] `ls -la *.runtime.yaml` → cả 2 là file (size > 0)
- [ ] `docker compose logs zitadel-setup` có `setup completed`
- [ ] **KHÔNG** còn warning `read /zitadel-steps.yaml: is a directory`
- [ ] `docker compose ps` → zitadel, zitadel-login, postgres, traefik đều `running` + `healthy`

## Rollback

Nếu fail: state đã nuke không thể rollback. Phải fix forward (sửa script bug khác nếu có).

## Next

→ [phase-03-verify-and-login.md](phase-03-verify-and-login.md)
