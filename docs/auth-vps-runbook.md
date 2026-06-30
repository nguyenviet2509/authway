# Auth VPS Runbook — Zitadel Central

Reference plan: [plans/260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md](../plans/260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md)

## Stack overview

| Service | Image | Network | Ingress |
|---|---|---|---|
| traefik | traefik:v3.2 | edge | 80/443 public |
| zitadel | ghcr.io/zitadel/zitadel:v4.15.3 | internal+edge | qua traefik |
| postgres | postgres:16-alpine | internal | NEVER public |
| mailhog (lab) | mailhog/mailhog:v1.0.1 | internal | 127.0.0.1:8025 |
| uptime-kuma | louislam/uptime-kuma:1 | monitoring | 127.0.0.1:3001 |

## Install

1. **Provision VPS** (16 GB RAM, Docker installed)
2. **NTP**: `timedatectl set-ntp true && timedatectl status`
3. **Clone repo**: `git clone <repo> /opt/authway && cd /opt/authway/infra/auth-vps`
4. **Generate secrets** + fill `.env`:
   ```bash
   cp .env.example .env
   # Masterkey: 32 chars random
   openssl rand -base64 32 | tr -d '\n' | head -c 32  # paste vào ZITADEL_MASTERKEY
   openssl rand -base64 24  # POSTGRES_ADMIN_PASSWORD
   openssl rand -base64 24  # ZITADEL_DB_PASSWORD
   openssl rand -base64 24  # ZITADEL_ADMIN_PASSWORD
   ```
5. **Masterkey backup**: lưu **≥2 nơi độc lập** (Bitwarden + sealed envelope safe). Mất = mất tất cả.
6. **Lab TLS** (skip nếu production có ACME): `bash scripts/generate-lab-cert.sh`
7. **DNS/hosts**: thêm `<vps-ip> auth.<domain>` vào DNS công ty hoặc /etc/hosts
8. **Bring up**: `docker compose up -d`
9. Theo dõi: `docker compose logs -f zitadel-setup` (phải completed_successfully)
10. **First login**: `https://auth.<domain>/ui/console`
    - Username: từ `ZITADEL_ADMIN_USERNAME`
    - Password: từ `ZITADEL_ADMIN_PASSWORD` (force change required)
    - Bind Passkey ngay
11. **Tạo break-glass admin** (founder/sếp): Users → New → grant `IAM_OWNER` role → Passkey enroll → seal credential
12. **SMTP config** (Default Settings → SMTP): lab dùng `mailhog:1025`, no-auth. Production dùng relay thật.
13. **Tạo Project + 2 OIDC App skeleton** cho phase 02

## Monitoring

```bash
cd /opt/authway/infra/auth-vps
docker compose -f monitoring/docker-compose.yml up -d
# SSH tunnel để mở Uptime Kuma UI:
#   ssh -L 3001:127.0.0.1:3001 <vps>
# → mở http://localhost:3001
```

Setup probes trong Uptime Kuma:
- HTTPS `https://auth.<domain>/.well-known/openid-configuration` mỗi 60s
- TCP `postgres:5432` mỗi 60s (qua docker network)
- Telegram notification: settings → add → bot token + chat_id

Periodic `check-health.sh` chạy mỗi 10 phút trong `health-checker` container — alert Telegram khi cert <14d, disk >80%, NTP offset >500ms, SMTP fail.

## Backup

**Cron** (root crontab):
```cron
0 2 * * * /opt/authway/infra/auth-vps/scripts/backup-postgres.sh >> /var/log/authway-backup.log 2>&1
0 4 * * 0 /opt/authway/infra/auth-vps/scripts/restore-drill.sh >> /var/log/authway-restore-drill.log 2>&1
```

**Rclone setup** (one-time):
```bash
rclone config
# Tạo remote name=internal-s3, type=s3, endpoint từ .env, access_key/secret_key
rclone lsd internal-s3:  # verify
```

**Manual backup**: `bash scripts/backup-postgres.sh`
**Manual restore drill**: `bash scripts/restore-drill.sh`

## Restore (disaster recovery)

```bash
# 1. Stop stack
docker compose stop zitadel zitadel-setup zitadel-init

# 2. Drop + recreate zitadel DB
docker compose exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS zitadel;"
docker compose exec postgres psql -U postgres -c "CREATE DATABASE zitadel OWNER zitadel;"

# 3. Restore dump
rclone copy internal-s3:authway-zitadel-backup/zitadel-<TS>.sql.gz /tmp/
zcat /tmp/zitadel-<TS>.sql.gz | docker compose exec -T postgres psql -U postgres -d zitadel

# 4. Start
docker compose up -d zitadel

# 5. Verify: login admin, check users count
```

**CRITICAL**: Restore yêu cầu `ZITADEL_MASTERKEY` cùng với backup được tạo. Mất masterkey = backup là ciphertext vô dụng.

## Upgrade Zitadel

1. Backup trước (manual + verify size)
2. Pin version mới trong `docker-compose.yml` (3 chỗ: zitadel-init, zitadel-setup, zitadel)
3. `docker compose pull && docker compose up -d`
4. Theo dõi logs zitadel-setup migration
5. Smoke test: login + list users + create test OIDC client

## Common operations

| Task | Command |
|---|---|
| Logs zitadel | `docker compose logs -f zitadel` |
| Restart zitadel | `docker compose restart zitadel` |
| Reload Traefik dynamic config | tự reload (watch enabled) |
| Generate JWT token (admin API) | qua admin UI → Service User |
| Disable user | Console → Users → … → Deactivate |
| Reset MFA cho user | Console → Users → Detail → MFA → Remove |

## Security checklist

- [ ] Masterkey lưu ≥2 nơi (Bitwarden + safe)
- [ ] ≥2 admin Passkey-enrolled (primary + break-glass founder)
- [ ] Self-service MFA/password reset disabled (config trong zitadel-config.yaml)
- [ ] Lockout policy ON (5 attempts)
- [ ] Traefik rate-limit auth paths (config trong dynamic/middlewares.yml)
- [ ] Postgres bind internal docker network only (no host port)
- [ ] Traefik dashboard bind 127.0.0.1 only (SSH tunnel để access)
- [ ] Backup cron + restore drill cron active
- [ ] Monitoring stack + Telegram alert verified
- [ ] NTP synced
- [ ] IP whitelist firewall layer (VPN/subnet only)

## Troubleshooting

| Symptom | Check |
|---|---|
| `zitadel-setup` exits với error | `docker compose logs zitadel-setup` — usually DB connection or masterkey mismatch |
| Login 502 | `docker compose logs zitadel`, check h2c scheme label |
| MFA fail liên tục | `timedatectl status` — NTP drift |
| Email không tới | check mailhog UI (lab) hoặc SMTP relay logs |
| Cert untrusted (lab) | import `tls/auth.crt` vào client trust store |
