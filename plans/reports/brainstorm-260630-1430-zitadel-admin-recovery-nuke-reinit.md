# Zitadel Admin Recovery — Nuke & Reinit

**Date:** 2026-06-30 14:30 ICT
**Context:** Lab instance auth.lab.local (192.168.122.54), Zitadel v4.15.3
**Outcome:** Approved Approach A — full reinit. Root cause fix applied in `scripts/render-config.sh`.

## Problem statement

UI báo "Could not create session for user" → "User is not active" khi login admin Zitadel ở https://auth.lab.local.

Triệu chứng:
- `Errors.User.NotActive` (SESSION-Gj4ko) xuất hiện từ 06:58 UTC, **trước** mọi password fail.
- 4-5 lần password fail (07:10–07:18) → trigger `user.locked` event → lockout policy hợp lệ.
- Patch event `user.unlocked` insert vào eventstore, restart zitadel, UI vẫn báo "not active".
- PAT `login-client` ở `/zitadel/bootstrap/login-client.pat` reject với `Errors.Token.Invalid` ngay cả call `/v2/users/me`.

## Root cause

`scripts/render-config.sh` không có guard cho trường hợp Docker compose start trước khi script chạy:

1. Lần deploy đầu tiên user (hoặc một sub-agent trước đó) chạy `docker compose up` **trước** `render-config.sh`.
2. Docker thấy bind-mount `./zitadel-config.runtime.yaml:/zitadel-config.yaml:ro` & `./zitadel-steps.runtime.yaml:/zitadel-steps.yaml:ro` mà host path không tồn tại → tự tạo **directory rỗng**.
3. `render-config.sh` chạy sau, `envsubst > zitadel-steps.runtime.yaml` fail với "Is a directory".
4. Container `zitadel-setup` mount empty directory thành `/zitadel-steps.yaml` → setup log warning `read /zitadel-steps.yaml: is a directory`, skip phần `--steps`.
5. **FirstInstance steps không chạy** → admin user và org có thể bootstrap nửa vời, PAT file orphan, masterkey-encrypted bằng key cũ không decrypt được bằng env hiện tại.

Lockout chỉ là hệ quả phụ khi user gõ thử nhiều password.

## Approaches evaluated

| Approach | Effort | Risk | Decision |
|---|---|---|---|
| A — Nuke `down -v` + reinit clean | 15 min | Mất data lab (vài OIDC client) | **Chosen** |
| B — Forensic debug events/projections | 1-2h | Không guarantee, config gốc vẫn buggy | Rejected |
| C — Hack PAT/permissions trong DB | 30 min | Hack-y, masterkey mismatch không workaround được | Rejected |

Lý do chọn A:
- Lab env, data nhỏ (vài OIDC client) → recreate < 10 phút.
- Không có break-glass admin #2 → mất admin hiện tại = mất tất cả UI access dù path nào.
- Root cause là config script bug → không fix thì lần deploy tới lặp lại.

## Fix applied

`infra/auth-vps/scripts/render-config.sh` — thêm defensive cleanup trước `envsubst`:

```bash
for f in zitadel-config.runtime.yaml zitadel-steps.runtime.yaml; do
  if [ -d "$f" ]; then
    echo "[render-config] WARN: '$f' tồn tại dưới dạng directory (docker auto-tạo) → xóa" >&2
    rm -rf "$f"
  fi
done
```

## Execution sequence (chạy trên 192.168.122.54)

```bash
cd /opt/authway/infra/auth-vps

# 0. Pull script fix mới
git pull   # hoặc scp script fixed lên

# 1. Snapshot OIDC apps trước khi nuke
docker compose exec -T postgres psql -U postgres -d zitadel -c \
"SELECT a.id, a.name, a.project_id, p.name AS project_name, oc.client_id, oc.redirect_uris, oc.grant_types
 FROM projections.apps7 a
 LEFT JOIN projections.apps7_oidc_configs oc ON oc.app_id=a.id
 LEFT JOIN projections.projects4 p ON p.id=a.project_id;" | tee ~/oidc-snapshot-pre-nuke.txt

docker compose exec -T postgres psql -U postgres -d zitadel -c \
"SELECT id, username, resource_owner FROM projections.users14
 WHERE username NOT LIKE 'zitadel-admin%' AND username != 'login-client';" | tee ~/users-snapshot-pre-nuke.txt

# 2. Nuke
docker compose down -v
sudo rm -rf zitadel-steps.runtime.yaml zitadel-config.runtime.yaml

# 3. Render config (FIXED script)
bash scripts/render-config.sh
ls -la *.runtime.yaml   # CONFIRM: cả 2 phải là FILE, không dir

# 4. Up lại
docker compose up -d

# 5. Verify setup chạy đúng
docker compose logs zitadel-setup | tail -50
# PHẢI thấy "setup completed" và KHÔNG còn warning "read /zitadel-steps.yaml: is a directory"

# 6. Verify PAT
PAT=$(docker compose exec -T zitadel cat /zitadel/bootstrap/login-client.pat | tr -d '\r\n')
echo "PAT length: ${#PAT}"
curl -k -s "https://auth.lab.local/v2/users/me" -H "Authorization: Bearer ${PAT}" | head -c 500
# PHẢI trả về user info, KHÔNG còn Token.Invalid

# 7. Test browser login
# - Mở https://auth.lab.local/ui/v2/login
# - Username: zitadel-admin@authway-internal.auth.lab.local (theo ZITADEL_ADMIN_USERNAME trong .env)
# - Password: từ .env ZITADEL_ADMIN_PASSWORD
# - Đổi password theo prompt
```

## Post-recovery hardening

1. **Tạo break-glass admin #2** ngay khi login Console — runbook đã yêu cầu ≥2 admin nhưng đang có 1.
2. **Enable Passkey** cho cả 2 admin — password lockout sẽ không khoá Passkey path.
3. **Re-add OIDC clients** từ snapshot file `~/oidc-snapshot-pre-nuke.txt`.
4. **Document workflow** trong README: "ALWAYS run `bash scripts/render-config.sh` BEFORE first `docker compose up`."

## Success criteria

- [ ] `docker compose logs zitadel-setup` có dòng `setup completed`, không có warning về steps.yaml directory.
- [ ] PAT `/v2/users/me` trả 200 với user info.
- [ ] Browser login `zitadel-admin@...` thành công, vào được Console.
- [ ] OIDC clients đã được recreate khớp với snapshot.
- [ ] Break-glass admin #2 đã được tạo + Passkey enrolled cho cả 2.

## Unresolved questions

- Lần deploy đầu tiên có thực sự là user chạy `docker compose up` trước render-config.sh? Cần xem git history `infra/auth-vps/` để confirm. Không quan trọng cho recovery, chỉ để hiểu nguyên nhân.
- Có cần update `docs/lab-deploy-192-168-122-54.md` đánh dấu thứ tự render-trước-up không? (Recommend: yes, thêm 1 dòng warning.)
