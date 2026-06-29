# Phase 03 — SOPS + Age Secrets Pipeline

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 1 ngày
- Critical: phải làm SỚM, vì snapshot VPS (Phase 00) ghi cả `.env` plaintext → snapshot leak = masterkey leak

## Overview
**Priority**: P1

Loại bỏ `.env` plaintext khỏi disk. Mã hoá bằng SOPS + age, decrypt lúc start vào tmpfs `/run/authway/.env`. Reboot là biến mất, snapshot không còn capture plaintext.

## Requirements
- SOPS installed VPS-A + VPS-B
- Age keypair RIÊNG cho secrets (KHÔNG dùng chung với backup key — separation of concern)
- Systemd unit cho stack lifecycle

## Files to Create
- `infra/auth-vps/.env.sops.yaml` — SOPS-encrypted
- `infra/auth-vps/.sops.yaml` — SOPS config (recipients)
- `infra/auth-vps/scripts/decrypt-env.sh` — render runtime .env tmpfs
- `infra/app-vps/.env.sops.yaml` — same pattern
- `/etc/systemd/system/authway.service` — ExecStartPre decrypt, ExecStart compose up
- `docs/secrets-management.md` — runbook rotation

## Implementation Steps

1. **Generate secrets age keypair** (riêng với backup)
   - `age-keygen -o /root/.config/sops/age/keys.txt` trên VPS-A (chmod 600)
   - Public key (recipient) commit vào `.sops.yaml`
   - **Backup private key**:
     - Bitwarden vault (founder)
     - Sealed envelope safe
     - **KHÔNG** lưu trong S3 backup

2. **`.sops.yaml`** config
   ```yaml
   creation_rules:
     - path_regex: \.env\.sops\.yaml$
       age: age1xxx...  # VPS-A pubkey
   ```

3. **Encrypt current `.env`**
   ```bash
   sops --encrypt --input-type dotenv --output-type yaml .env > .env.sops.yaml
   # Verify
   sops --decrypt .env.sops.yaml | diff - .env
   # Xoá .env plaintext khỏi disk + git
   shred -u .env
   ```

4. **`decrypt-env.sh`**
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   mkdir -p /run/authway
   chmod 700 /run/authway
   sops --decrypt --input-type yaml --output-type dotenv \
     /opt/authway/infra/auth-vps/.env.sops.yaml \
     > /run/authway/.env
   chmod 600 /run/authway/.env
   ```

5. **Systemd unit** `authway.service`
   ```ini
   [Unit]
   Description=Authway Zitadel stack
   After=docker.service network-online.target
   Requires=docker.service

   [Service]
   Type=oneshot
   RemainAfterExit=yes
   WorkingDirectory=/opt/authway/infra/auth-vps
   ExecStartPre=/opt/authway/infra/auth-vps/scripts/decrypt-env.sh
   ExecStart=/usr/bin/docker compose --env-file /run/authway/.env up -d
   ExecStop=/usr/bin/docker compose down
   User=root

   [Install]
   WantedBy=multi-user.target
   ```

6. **Verify** runtime
   - `systemctl restart authway` → stack up
   - `find / -name '.env' -not -path '/proc/*' 2>/dev/null` → chỉ thấy `/run/authway/.env` (tmpfs)
   - Reboot → `/run/authway/.env` gone, ExecStartPre tạo lại

7. **Rotation runbook** (`docs/secrets-management.md`)
   - `client_secret` OIDC: 90 ngày, qua Zitadel UI → update `.env.sops.yaml` → re-deploy
   - Postgres password: 180 ngày, downtime ~5 phút (stop stack, ALTER USER, update .env.sops, start)
   - Zitadel masterkey: yearly. ⚠️ **Phức tạp** — masterkey rotate cần re-encrypt mọi encrypted blob trong DB. Document plan riêng, có thể skip cho năm đầu nếu chưa có incident.
   - Cookie secret oauth2-proxy: 180 ngày
   - Telegram bot token: nếu nghi ngờ leak, rotate ngay

8. **Same pattern cho VPS-B** (app-vps)
   - 2 cookie secrets, 2 client secrets
   - Riêng age keypair cho VPS-B? hoặc share? **Decision**: share để giảm key sprawl, accept VPS-B compromise = VPS-A secrets cũng decrypt được (nhưng VPS-B không có Zitadel masterkey nên impact thấp hơn).

9. **Git history scrub**
   - Verify `.env` chưa từng commit: `git log --all --full-history -- '**/.env'`
   - Nếu có → BFG repo-cleaner để xoá history + rotate TẤT CẢ secret trong .env đó

## Todo
- [ ] Generate age keypair, distribute private key 2 nơi (Bitwarden + sealed)
- [ ] Create `.sops.yaml` config
- [ ] Encrypt `.env` VPS-A → commit `.env.sops.yaml`
- [ ] Encrypt `.env` VPS-B → commit `.env.sops.yaml`
- [ ] Write `decrypt-env.sh`
- [ ] Write systemd unit, enable
- [ ] Reboot test: stack up, `.env` plaintext không tồn tại trên disk
- [ ] Audit git history cho `.env` leak
- [ ] Write rotation runbook
- [ ] Update `lab-deploy-192-168-122-54.md` cho production: thay `.env` bằng SOPS workflow
- [ ] Train founder + 1 senior decrypt procedure (khẩn cấp)

## Success Criteria
- `find / -name '.env'` chỉ ra path tmpfs
- Reboot VPS → snapshot mới KHÔNG chứa plaintext masterkey
- Founder decrypt được file SOPS trên laptop với private key offline
- Rotation runbook test: rotate 1 client_secret end-to-end thành công < 15 phút

## Risks
- **Age private key mất** → KHÔNG decrypt được → KHÔNG start stack được sau reboot. Mitigation: 2 nơi backup + verify quarterly
- **Founder + senior đều mất key cùng lúc** (vd hỏa hoạn safe) → bricked. Mitigation: 3rd copy ở trust party (lawyer/family safe) — paranoid level
- **SOPS bug** → stack không start. Mitigation: pin SOPS version, test trên staging trước upgrade
- **tmpfs `/run/authway/.env` accessible bởi process khác trên VPS** → mitigation: chmod 600 + dùng user namespace nếu cần

## Reference
- SOPS: https://github.com/getsops/sops
- age: https://github.com/FiloSottile/age
- Phase 02 backup key MUST DIFFER với phase 03 secrets key (defense separation)
