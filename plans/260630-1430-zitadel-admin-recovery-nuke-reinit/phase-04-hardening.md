# Phase 04 — Hardening

**Status:** pending
**Priority:** P1 (làm ngay sau khi login OK)
**Depends on:** Phase 03 admin login success

## Goal

Recreate config từ snapshot + đóng gap "1 admin duy nhất" để tránh lặp lại sự cố.

## Steps

1. **Re-add OIDC clients** từ `~/oidc-snapshot-pre-nuke.txt`:
   - Vào Console → Projects → tạo lại project
   - Mỗi app: copy redirect URIs + grant_types + response_types theo snapshot
   - **LƯU Ý:** client_id mới sẽ KHÁC → cần update config ở downstream apps

2. **Tạo break-glass admin #2** (runbook yêu cầu ≥2 admin):
   - Console → Users → New → Human user
   - Username: `breakglass-admin@authway-internal.auth.lab.local`
   - Email founder/owner cá nhân (không phải admin@lab.local)
   - Add to IAM_OWNER role
   - Enroll Passkey ngay
   - Lưu password vào vault riêng, **KHÔNG** chia sẻ với primary admin

3. **Enable Passkey cho primary admin** (nếu phase 03 chưa làm):
   - User settings → Authentication → Add Passkey

4. **Document credentials**:
   - Vault entry: primary admin + break-glass admin passwords + Passkey backup codes
   - 2 nơi độc lập (vault chính + offline backup)

5. **Test break-glass path**:
   - Logout primary
   - Login bằng break-glass
   - Verify có thể vào Console, có thể unlock user khác

## Success criteria

- [ ] Tất cả OIDC clients trong snapshot đã được recreate (verify từ downstream apps)
- [ ] Break-glass admin #2 tồn tại + Passkey enrolled
- [ ] Primary admin có Passkey
- [ ] Cả 2 admin credentials lưu vault ≥2 nơi
- [ ] Đã test break-glass login thành công

## Follow-up (out of scope phase này)

- Update `docs/lab-deploy-192-168-122-54.md`: thêm warning "ALWAYS run `bash scripts/render-config.sh` BEFORE first `docker compose up`"
- Consider adding render-config.sh check vào docker-compose `depends_on` hoặc Makefile target
- Setup health probe (`scripts/check-health.sh`) + Telegram alert nếu chưa active

## Notes

Sau phase này hoàn tất → close plan (status → done) + journal.
