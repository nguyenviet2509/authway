# Phase 03 — Verify & Login

**Status:** pending
**Priority:** P0
**Depends on:** Phase 02 stack running

## Goal

Confirm PAT valid + admin login Console được.

## Steps

1. Lấy PAT vào biến shell:
   ```bash
   PAT=$(docker compose exec -T zitadel cat /zitadel/bootstrap/login-client.pat | tr -d '\r\n') && echo "PAT length: ${#PAT}"
   ```
   Mong đợi: length 43-120 chars.

2. Verify PAT call API (KHÔNG còn `Errors.Token.Invalid`):
   ```bash
   curl -k -s "https://auth.lab.local/v2/users/me" -H "Authorization: Bearer ${PAT}" | head -c 500
   ```
   Mong đợi: JSON user info của `login-client`.

3. Verify admin user trong DB (state=1):
   ```bash
   docker compose exec -T postgres psql -U postgres -d zitadel -c "SELECT id, username, state FROM projections.users14 WHERE username LIKE 'zitadel-admin%';"
   ```

3. Browser login:
   - URL: `https://auth.lab.local/ui/v2/login`
   - Username: giá trị `ZITADEL_ADMIN_USERNAME` trong `.env` (thường `zitadel-admin@authway-internal.auth.lab.local`)
   - Password: `ZITADEL_ADMIN_PASSWORD` trong `.env`
   - System sẽ prompt đổi password (do `PasswordChangeRequired: true` trong steps.yaml) → đổi password mới mạnh
   - Enroll OTP/Passkey theo prompt

4. Confirm vào Console:
   - URL: `https://auth.lab.local/ui/console`
   - Phải thấy org "Authway Internal" + user list

## Success criteria

- [ ] `/v2/users/me` trả 200 với user info
- [ ] Browser login thành công, vào Console
- [ ] Đổi password mới, lưu vault
- [ ] OTP/Passkey enrolled cho admin chính

## Failure handling

- PAT vẫn invalid → check `ZITADEL_MASTERKEY` trong `.env` không bị trim/whitespace, masterkey phải đúng 32 chars
- Login UI báo "user not active" → check `docker compose logs zitadel-setup` xem FirstInstance steps có thực sự apply không

## Next

→ [phase-04-hardening.md](phase-04-hardening.md)
