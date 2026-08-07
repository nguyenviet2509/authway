# authway-vps — Zitadel Prod Deploy Runbook

**Stack:** Zitadel v4.16.1 + Postgres 16 + Traefik v3.2  
**Mode:** HTTP-only, IP-as-domain (`10.200.0.125`), TLS deferred  
**Host:** authway-vps (10.200.0.125), Ubuntu 24.04, SSH port 24700

---

## Golden Rules

1. **Never commit `.env`** — contains masterkey + DB passwords
2. **Always run `render-config.sh` before `docker compose up`** — generates `.runtime.yaml` from templates
3. **`zitadel-init` + `zitadel-setup` are idempotent** — safe to re-run; skip if DB already bootstrapped
4. **Masterkey is immutable** — changing it after first `setup` corrupts all encrypted data
5. **Backup before any destructive operation** — `scripts/backup-postgres.sh`

---

## Quick Deploy (first time)

```bash
# 1. SSH into VPS
ssh -p 24700 root@10.200.0.125

# 2. Install Docker (Ubuntu 24.04)
apt-get update && apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# 3. Prep directory
mkdir -p /opt/authway/infra/authway-vps
```

```bash
# 4. From LOCAL — copy config + .env to VPS
rsync -av -e "ssh -p 24700 -i ~/.ssh/zimbra_ldap" \
  D:/Vietnt/Project/authway/infra/authway-vps/ \
  root@10.200.0.125:/opt/authway/infra/authway-vps/

# Copy .env separately (not in rsync scope if excluded)
scp -P 24700 -i ~/.ssh/zimbra_ldap \
  D:/Vietnt/Project/authway/infra/authway-vps/.env \
  root@10.200.0.125:/opt/authway/infra/authway-vps/.env
```

```bash
# 5. On VPS — render configs + deploy
cd /opt/authway/infra/authway-vps
chmod +x scripts/*.sh
bash scripts/render-config.sh

docker compose --env-file .env up -d
docker compose logs -f --tail 100
```

---

## Verify

```bash
# Container status (all should be Up/healthy after ~2 min)
docker compose ps

# Zitadel ready check
curl -sv http://10.200.0.125/debug/ready

# Console loads
curl -sI http://10.200.0.125/ui/console/

# Login V2 healthy
curl -sI http://10.200.0.125/ui/v2/login/healthy

# Zitadel logs (look for "listening" or "ready")
docker compose logs zitadel --tail 50 | grep -iE "listen|ready|error"
```

Expected ready response: `HTTP/1.1 200 OK`

---

## First Login

1. Open browser: `http://10.200.0.125/ui/console/`
2. Login: `zitadel-admin` / `<password from .env>`
3. System prompts password change on first login (PasswordChangeRequired=true)
4. Set new password, save securely

---

## Post-Deploy: Configure Zimbra LDAP IdP

After console access confirmed, follow the LDAP IdP setup checklist:  
`authway/plans/260806-0939-zitadel-ldap-zimbra-lab/completion-notes.md`

Key config values:
- LDAP URL: `ldap://103.57.220.98:389`
- Bind DN: `uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn`
- Bind password: `/EHNOQ98k/mXpVVv7b2IXAeVZwqXh1A8`

> **Prereq:** Zimbra CSF must whitelist authway-vps egress IP first (see report for IP).

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `zitadel-setup` exits non-zero | `docker compose logs zitadel-setup` — often DB not ready or placeholder not resolved |
| Console returns 502 | `docker compose ps` — zitadel or zitadel-login not healthy yet; wait 60s |
| `curl /debug/ready` → connection refused | Traefik not up: `docker compose logs traefik` |
| Login V2 redirect loop | Check `ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI` uses `http://` not `https://` |
| `.runtime.yaml` has unresolved `${VAR}` | Re-run `render-config.sh`; verify `.env` has all required vars |
| Mailhog web UI | SSH tunnel: `ssh -L 8025:localhost:8025 -p 24700 root@10.200.0.125` → `http://localhost:8025` |
| Traefik dashboard | SSH tunnel: `ssh -L 8088:localhost:8088 -p 24700 root@10.200.0.125` → `http://localhost:8088` |

---

## Rollback

```bash
# Stop everything (data preserved in volumes)
docker compose down

# Full wipe including volumes (DESTRUCTIVE — loses all data)
docker compose down -v

# Re-deploy from scratch after wipe
bash scripts/render-config.sh
docker compose --env-file .env up -d
```

---

## Upgrade TLS (when domain available)

1. Update `ZITADEL_EXTERNAL_DOMAIN` in `.env` to real domain
2. In `docker-compose.yml`: change `ZITADEL_EXTERNALPORT: 80` → `443`, `ZITADEL_EXTERNALSECURE: "false"` → `"true"`, update all `http://` URLs to `https://`
3. In `traefik.yml`: add `websecure` entrypoint + ACME resolver; restore redirect from `web`
4. In `dynamic/middlewares.yml`: restore `security-headers` middleware with HSTS
5. Re-render configs + `docker compose up -d`

---

## Backup

```bash
# Manual backup
bash scripts/backup-postgres.sh

# Backup stored in /opt/authway/backups/ by default
```
