# Phase 02 — Offsite Encrypted Backup + Restore Drill

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 1 ngày
- RPO target: 1h. RTO target: 15 phút khi VPS hỏng (snapshot 5 phút + DB restore 10 phút)

## Overview
**Priority**: P1 (DR critical với 1 VPS no HA)

Backup pipeline: hourly pg_dump → age encrypt → rclone S3 nội bộ. GFS retention. Weekly restore drill tự động vào VPS staging với smoke test.

## Requirements
- S3 nội bộ endpoint + credentials (write-only token)
- Age keypair: pubkey trên VPS-A (encrypt), privkey offline (Bitwarden + sealed envelope)
- rclone installed VPS-A (đã có theo lab-deploy doc)
- VPS staging on-demand cho restore drill (provider API spawn)

## Files to Create
- `infra/auth-vps/scripts/backup-hourly.sh` — pg_dump | age | rclone
- `infra/auth-vps/scripts/restore-from-s3.sh` — pull S3 → age decrypt → pg_restore
- `infra/auth-vps/scripts/restore-drill-weekly.sh` — chạy trên VPS-C, spawn staging, test
- `infra/auth-vps/.age-recipients` — public key file (commit OK)
- Crontab entries

## Implementation Steps

1. **Generate age keypair**
   - `age-keygen -o age-key.txt` trên máy offline (laptop founder)
   - Public key vào `.age-recipients` repo
   - Private key:
     - Copy 1 vào Bitwarden personal vault
     - Copy 1 in sealed envelope, founder cất safe
     - Thử decrypt test message trước khi giao trách nhiệm

2. **Backup script `backup-hourly.sh`**
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   TS=$(date -u +%Y%m%dT%H%M%SZ)
   DEST="s3:authway-backup/zitadel/$TS.dump.age"
   docker compose -f /opt/authway/infra/auth-vps/docker-compose.yml \
     exec -T postgres pg_dump -U postgres -d zitadel \
       --format=custom --no-owner --clean --if-exists \
     | age -R /opt/authway/infra/auth-vps/.age-recipients \
     | rclone rcat --s3-no-check-bucket "$DEST"
   # Telegram heartbeat
   curl -s "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
     -d chat_id="$TG_CHAT" -d text="✅ Backup OK: $TS ($(rclone size $DEST | awk '{print $3,$4}'))"
   ```

3. **Cron schedule**
   - VPS-A: `0 * * * *` (hourly on the hour)
   - Lock với flock để tránh overlap: `flock -n /tmp/backup.lock`
   - Stderr → Telegram alert on fail (>0 exit code)

4. **GFS retention policy** trên S3
   - Hourly: giữ 24h
   - Daily: snapshot 02:00, giữ 30d
   - Weekly: chủ nhật, giữ 12w
   - Monthly: ngày 1, giữ 12m
   - Implement: rclone script chạy daily 03:00 dùng lifecycle rule hoặc explicit `rclone delete --min-age`

5. **Restore drill script** chạy hàng tuần trên VPS-C
   - Spawn VPS staging qua provider API
   - Pull latest S3 dump
   - Decrypt với age privkey (chỉ có trên VPS-C? KHÔNG — sẽ vi phạm rule không có host nào có đủ 3 yếu tố). **Cách an toàn**: drill thủ công monthly bởi founder dùng laptop có age key. Hoặc setup VPS drill có age key HSM-style chỉ dùng decrypt one-shot, key destroy after.
   - **Decision**: drill weekly **automatic không có age key** — chỉ test rclone pull OK + file size sane. Monthly drill **manual** restore + smoke test login.

6. **Smoke test sau restore**
   - Postgres up → Zitadel start → query `/.well-known/openid-configuration` → 200
   - DB row count check vs source (allow drift do hourly)
   - 1 user login test với credential test account
   - Cleanup VPS staging

7. **Telegram alert**
   - Backup fail → 🚨 immediate
   - Backup OK > 25h chưa có file mới → 🚨 stale
   - Drill weekly fail → 🚨
   - Drill weekly OK → ✅ thông báo silent (nhật ký)

## Todo
- [ ] Generate age keypair offline, distribute private key 2 nơi
- [ ] Test encrypt/decrypt round-trip
- [ ] Write + test `backup-hourly.sh` manual run
- [ ] Setup crontab hourly + GFS cleanup daily
- [ ] Configure Vector alert: backup stale > 25h
- [ ] Write `restore-from-s3.sh` runbook
- [ ] Weekly auto drill: rclone pull + size check
- [ ] Monthly manual drill: full restore + smoke test login
- [ ] Document RTO measurement từ 3 drill đầu

## Success Criteria
- Backup file mới nhất trên S3 < 65 phút tuổi mỗi check
- Encrypted file: `head -c 20 < dump.age` cho thấy `age-encryption.org/v1` header, KHÔNG plaintext SQL
- Monthly drill: restore full + login pass < 30 phút
- 3 drill liên tiếp pass → ký nhận RTO 15 phút khả thi

## Risks
- **Age private key mất** → backup vô dụng. Mitigation: 2 nơi storage (Bitwarden + sealed envelope), verify decrypt 6 tháng/lần
- **S3 bucket compromise** → attacker có encrypted blobs nhưng KHÔNG có key. Trừ khi key cũng leak cùng host.
- **Backup size grow**: monitor tổng S3 usage; nếu Zitadel events table phình → consider archive cũ ra S3 deep storage
- **pg_dump khoá lock** trên DB lớn: với Zitadel < 1k user, dump < 30s OK; alert nếu > 5 phút
- **Drill chỉ pull không decrypt** → có rủi ro file corrupt mà không phát hiện. Mitigation: monthly manual full drill cover.

## Reference
- age: https://github.com/FiloSottile/age
- rclone S3: https://rclone.org/s3/
- pg_dump custom format: https://www.postgresql.org/docs/current/app-pgdump.html
