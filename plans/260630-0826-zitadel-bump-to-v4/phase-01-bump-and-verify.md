# Phase 01 — Bump Version & Verify

## Context Links
- Plan overview: [plan.md](plan.md)
- Downstream: [260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md](../260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md)
- Zitadel v4.0.0 release notes: https://github.com/zitadel/zitadel/releases/tag/v4.0.0
- Zitadel v3.0.0 release notes: https://github.com/zitadel/zitadel/releases/tag/v3.0.0
- Self-host config docs: https://zitadel.com/docs/self-hosting/manage/configure

## Overview
- **Priority**: P1 (blocker cho rollout)
- **Status**: pending
- **Effort**: 1-2h ops, 0 dev

Bump Docker image `ghcr.io/zitadel/zitadel:v2.66.0` → `v4.15.3` ở 3 service (zitadel-init, zitadel-setup, zitadel runtime). Re-init clean lab (no data preserve), verify smoke test, update docs cross-reference.

## Key Insights
- v4 dùng cùng Postgres schema migration framework — setup steps tự chạy khi init lần đầu
- Login V2 default ở v4 → UI khác hẳn v1. oauth2-proxy chỉ care OIDC discovery + token → không impact
- Service Ping telemetry mặc định ON ở v4 → cần `Telemetry.Enabled: false` trong zitadel-config.yaml nếu muốn opt-out
- `LoginPolicy.PasswordlessType: 1` enum giữ nguyên v2→v4 (đã verify qua release notes, không có breaking ở policy schema)
- `ssl-insecure-skip-verify=true` ở oauth2-proxy (lab self-signed) → giữ nguyên

## Requirements

### Functional
- Container zitadel v4.15.3 start clean, init+setup chạy không lỗi
- Console UI accessible qua Traefik `https://${ZITADEL_HOSTNAME}`
- Admin login default credential OK
- OIDC discovery endpoint `/.well-known/openid-configuration` trả version mới
- oauth2-proxy reference flow: redirect → login → callback → upstream OK

### Non-functional
- Init time < 3 phút (v4 nhiều setup steps hơn v2)
- Memory footprint runtime ≤ v2 baseline (note nếu vượt 20%)

## Architecture
Không đổi topology. Chỉ swap image tag. Postgres giữ nguyên (v16 OK với v4).

```
auth-vps:
  postgres (16)        ── unchanged
  zitadel-init (v4)    ── re-init clean (drop old zitadel db trước)
  zitadel-setup (v4)   ── run setup steps mới
  zitadel runtime (v4) ── serve API + Console v4
  traefik              ── unchanged
```

## Related Code Files

### Modify
- `infra/auth-vps/docker-compose.yml` — line 39, 61, 98: `v2.66.0` → `v4.15.3`
- `infra/auth-vps/zitadel-config.yaml` — add Telemetry opt-out block (xem step 3)
- `docs/auth-vps-runbook.md` — line 10: bump image tag reference
- `docs/deployment-guide.md` — line 178: bump example image
- `mockups/authway-services-detail.html` — line 192: badge text
- `mockups/authway-system-explainer.html` — line 172: pill text
- `plans/260626-1808-production-hardening-1vps-fallback/phase-07-misc-hardening.md` — line 85, 106: replace "v2.66 EOL" warning + drill thành "v4.15.3 baseline + CVE monitor v4 branch"

### Read for context
- `infra/auth-vps/.env.example` (verify ZITADEL_HOSTNAME, ZITADEL_DB_USER, etc.)
- `plans/reports/brainstorm-260626-1800-selfhost-readiness-assessment.md`

### Create
- (none)

## Implementation Steps

### 1. Backup current state
```bash
cd infra/auth-vps
docker compose ps > /tmp/before-bump.txt
git status  # confirm clean working tree
```

### 2. Drop lab DB (no data to preserve)
```bash
docker compose exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS zitadel;"
docker compose down
docker volume ls | grep zitadel  # note volumes nếu cần wipe
```

### 3. Update image tag + telemetry opt-out
File `infra/auth-vps/docker-compose.yml` — 3 chỗ:
```yaml
image: ghcr.io/zitadel/zitadel:v4.15.3
```

File `infra/auth-vps/zitadel-config.yaml` — append:
```yaml
# v4: opt-out service ping telemetry
Telemetry:
  Enabled: false
```

### 4. Init clean
```bash
docker compose up -d postgres
sleep 5
docker compose up zitadel-init  # chạy 1 lần, exit OK
docker compose up zitadel-setup # chạy 1 lần, exit OK
docker compose up -d zitadel traefik
docker compose logs -f zitadel  # watch ~2 phút tới khi "server listening"
```

### 5. Smoke test
```bash
# OIDC discovery
curl -sk "https://${ZITADEL_HOSTNAME}/.well-known/openid-configuration" | jq '.issuer, .token_endpoint'

# Admin console
# Browser: https://${ZITADEL_HOSTNAME}/ui/console
# Login: zitadel-admin@zitadel.${ZITADEL_HOSTNAME} / Password1!
# Force password change → set strong pw

# Create 1 test user qua console
# Setup MFA (TOTP)
```

### 6. oauth2-proxy reference verify
Chạy reference IAP từ phase 02 plan rollout (nếu artifacts đã sẵn):
- Browser → app endpoint → 302 sang Zitadel login
- Login → callback → app render với user header

Nếu reference VPS chưa deploy → defer test này sang plan 260626-1154 phase 02.

### 7. Update docs cross-reference
Replace tất cả mention `v2.66` / `v2.66.0` thành `v4.15.3` ở các file đã list. Dùng grep verify:
```bash
grep -rn "v2\.66" --include="*.md" --include="*.html" --include="*.yml" --include="*.yaml" d:/Vietnt/Project/authway
# expect: 0 results sau khi update
```

### 8. Update downstream plan note
File `plans/260626-1808-production-hardening-1vps-fallback/phase-07-misc-hardening.md`:
- Line 85: đổi "Đang pin v2.66.0. Không có process check CVE / upgrade." → "Pin v4.15.3 (latest 2026-06-22). Cần CVE monitor v4 branch + quarterly bump drill."
- Line 106: đổi "First upgrade drill: bump v2.66.0 → v2.66.x latest" → "Quarterly upgrade drill: bump v4.x → v4 latest patch"

## Todo List

### File edits (done — Claude side)
- [x] Bump image tag 3 chỗ trong docker-compose.yml
- [x] Append Telemetry opt-out block trong zitadel-config.yaml
- [x] Update 6 docs/mockup files (zero `v2.66` còn lại trong code/docs paths)
- [x] Update phase-07-misc-hardening.md (2 dòng)

### VPS-side ops (pending — user phải chạy trên auth-vps 192.168.122.54)
- [ ] Backup state, confirm git clean
- [ ] Drop lab `zitadel` DB
- [ ] `docker compose up` init + setup, không error
- [ ] OIDC discovery endpoint trả issuer + endpoints đúng
- [ ] Console login admin default OK, force password change
- [ ] Create 1 test user + MFA setup OK
- [ ] (Optional) oauth2-proxy reference flow OK

### Final
- [ ] Commit: `chore(infra): bump Zitadel v2.66.0 → v4.15.3`

## Success Criteria
- `grep -rn "v2\.66" d:/Vietnt/Project/authway` → 0 result (trừ file plan này + release notes nếu lưu)
- Zitadel container running stable ≥ 10 phút sau init
- Console + OIDC discovery + admin login đều OK
- Phase 07 hardening note đã cập nhật

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| zitadel-config.yaml schema breaking ở v4 | Low | Medium | Test init clean lab — fail fast, không touch prod. Reference v4 config docs nếu setup error. |
| Login V2 UI khác user expect | Medium | Low | User OK với default, không custom. Nếu cần fallback v1 → flag `LoginV2: Required: false` trong feature config. |
| oauth2-proxy không tương thích token format mới | Low | High | OIDC chuẩn không đổi. Verify discovery + ID token claims khớp expectation. Rollback = revert tag. |
| Setup steps v4 chạy lâu hơn timeout healthcheck | Medium | Low | Increase healthcheck `start_period` lên 180s lần đầu init. |
| Telemetry opt-out config key sai → vẫn ping | Low | Low | Check docs.zitadel.com/self-hosting/manage/service_ping confirm key. Network egress monitor verify. |

## Security Considerations
- v4.15.3 là latest stable → bao gồm tất cả CVE patches tới 2026-06-22
- Admin default password BẮT BUỘC đổi sau first login
- Telemetry opt-out tránh leak instance metadata ra ngoài
- TLS vẫn terminate ở Traefik, Zitadel container plain HTTP internal — không đổi

## Next Steps
- Unblock plan **260626-1154-zitadel-iap-rollout** → phase 01 deploy có thể start với image v4.15.3
- Phase 07 hardening (plan 260626-1808) cần update: setup CVE monitor v4 branch (GitHub watch `zitadel/zitadel` security advisories)
- Optional follow-up: document Login V2 customization path nếu sau này muốn brand
