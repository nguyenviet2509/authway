# Phase 1 — Zitadel prod deploy v4.16+

**Effort:** 1-2d
**Status:** pending
**Depends on:** Domain thật + VPS prod (user cấp)

## Context
- Plan: [../plan.md](../plan.md)
- Lab hiện tại: `authserver` (192.168.122.54) chạy Zitadel v4.15.3 (bug SSR)
- Compose reference: `authway/infra/auth-vps/docker-compose.yml`

## Objective
Deploy Zitadel prod trên VPS thật với version v4.16+ (nếu có) hoặc v4.15.3 nếu chưa ra. Verify OIDC discovery endpoint reachable public.

## Prerequisites (blocking gate)

- ✅ Domain thật (VD `auth.inet.vn`) DNS trỏ về VPS prod IP
- ✅ VPS prod provisioned (Ubuntu 22/24, ≥4GB RAM, ≥40GB disk)
- ✅ SSH access + hostname config trong `~/.ssh/config`

## Steps

### 1. VPS bootstrap
- Firewall: allow 22/443/24700-range, deny 80/8080/5432 public
- Install Docker + docker-compose plugin
- Setup non-root user `vietnt` với docker group

### 2. Clone authway repo lên VPS
```bash
git clone git@github.com:<org>/authway.git /opt/authway
cd /opt/authway/infra/auth-vps
```

### 3. Version selection
- Check `ghcr.io/zitadel/zitadel` latest tag (v4.16+ nếu có)
- Update `docker-compose.yml`: `image: ghcr.io/zitadel/zitadel:v4.16.x`
- Nếu v4.16 chưa ra → deploy v4.15.3 (accept bug, workaround sau)

### 4. Environment config
`.env` prod (khác lab):
```
ZITADEL_EXTERNAL_DOMAIN=auth.inet.vn
ZITADEL_MASTERKEY=<generate 32-char strong>
POSTGRES_ADMIN_PASSWORD=<generate>
ZITADEL_DB_PASSWORD=<generate>
# Traefik email cho LE
LE_EMAIL=admin@inet.vn
```

Lưu Bitwarden.

### 5. TLS Let's Encrypt (Traefik)
Traefik config: `traefik.yml` — enable LE resolver với `httpChallenge` hoặc `dnsChallenge`. Cert auto-renew.

### 6. Postgres backup setup
- Cron: `docker exec postgres pg_dump -U postgres zitadel | gzip > /backup/zitadel-$(date +%F).sql.gz` daily
- Retention 14 ngày
- Verify restore procedure documented

### 7. Deploy
```bash
docker compose config -q && docker compose up -d
```

Wait ~2 min for setup + zitadel-setup exit → zitadel healthy.

### 8. Verify
- `curl https://auth.inet.vn/.well-known/openid-configuration` return JSON
- Console UI accessible `https://auth.inet.vn/ui/console`
- Login với `zitadel-admin@<domain>` (init password trong logs setup container)
- Change admin password ngay lần đầu

### 9. Apply lab lessons
Từ lab đã học:
- Add network alias `auth.inet.vn` cho zitadel container trong internal network (fix Node fetch Host header cho login sidecar, if bug still exists trong v4.16)
- Set login policy Instance level: `ignoreUnknownUsernames: true`, `allowExternalIdp: true`, `allowRegister: true`

## Deliverables
- Zitadel prod running v4.16+ (hoặc v4.15.3)
- Domain HTTPS accessible
- Admin credentials Bitwarden
- Postgres backup cron verified
- Journal entry note version + workaround status

## Success criteria
- ✅ OIDC discovery endpoint 200 OK
- ✅ Console UI login được với admin
- ✅ Postgres backup file tạo được sau 24h
- ✅ TLS cert valid (LE production)

## Risks

| Risk | Mitigation |
|---|---|
| v4.16 chưa ra khi deploy | Fallback v4.15.3, apply lab alias workaround |
| LE rate limit | Test staging LE trước, chỉ switch prod khi verified |
| Postgres data corruption | Backup + tested restore procedure BEFORE launch |

## Next → Phase 2
Zimbra prod LDAP integration.
