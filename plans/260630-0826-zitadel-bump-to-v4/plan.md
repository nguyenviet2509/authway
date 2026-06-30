---
title: Zitadel Version Bump v2.66.0 → v4.15.3
date: 2026-06-30
status: in_progress
mode: sequential
blockedBy: []
blocks: [260626-1154-zitadel-iap-rollout, 260626-1808-production-hardening-1vps-fallback, 260629-1726-autossl-zitadel-integration]
---

# Zitadel Bump to v4.15.3

## Objective
Pin Zitadel lên **v4.15.3** (latest stable, 2026-06-22) thay vì v2.66.0 (EOL từ 2025-05) trước khi rollout production. Lab chưa có user thật → không cần data migration, chỉ re-init clean với version mới.

## Rationale
- v2.66.0 đã EOL → không patch CVE. IdP = bề mặt tấn công cao nhất, không thể chạy version EOL trên prod.
- User đã chọn: lab-only, no real users, không custom UI → pin thẳng v4 ngay rollout, bỏ qua upgrade dance v2→v3→v4.
- Khoảng cách: 2 major version. Source code AuthWay không gọi Management/Admin API → 0 code change phía app.

## Constraints
- Lab only (192.168.122.54), downtime thoải mái
- Không có data cần preserve → re-init clean
- oauth2-proxy + OIDC chuẩn → flow downstream không đổi
- Login UI default v4 (Login V2 Next.js) — không custom branding nên chấp nhận

## Breaking changes phải verify (v2.66 → v4.15)
1. **Postgres**: vẫn support (CockroachDB bị bỏ ở v3, mình không dùng) → OK
2. **License**: AGPLv3 (từ v3). Self-host không fork → OK
3. **Login V2 default**: UI Next.js mới. Test oauth2-proxy redirect flow vẫn work
4. **API v1 deprecated endpoints** (User/Project/Member/Org): mình không gọi → OK
5. **Service Ping telemetry**: opt-out → cần disable trong config nếu privacy concern
6. **zitadel-config.yaml schema**: `LoginPolicy.SecondFactors/MultiFactors/PasswordlessType` enum giữ nguyên (v4 vẫn dùng cùng policy backend) — verify khi init

## Phases

| # | Phase | Status | Effort |
|---|---|---|---|
| 01 | [Bump version + verify smoke test](phase-01-bump-and-verify.md) | pending | 1-2h |

## Files to modify
- `infra/auth-vps/docker-compose.yml` (3 dòng image tag)
- `infra/auth-vps/zitadel-config.yaml` (verify schema, optional add ServicePing opt-out)
- `docs/auth-vps-runbook.md` (line 10)
- `docs/deployment-guide.md` (line 178)
- `mockups/authway-services-detail.html` (line 192)
- `mockups/authway-system-explainer.html` (line 172)
- `plans/260626-1808-production-hardening-1vps-fallback/phase-07-misc-hardening.md` (line 85, 106 — bỏ "first upgrade drill v2.66→v2.66.x")

## Success criteria
- `docker compose up` clean, zitadel-init + setup chạy không error
- Console accessible, login admin default OK
- oauth2-proxy reference app (phase 02 của plan rollout) OIDC redirect + token validation OK
- Smoke test 1 user create + 1 session login pass

## Downstream impact
- Plan **260626-1154-zitadel-iap-rollout**: rollout sẽ start trực tiếp trên v4. Phase 01 deploy chạy với image mới.
- Plan **260626-1808-production-hardening**: phase-07 update — không còn "first upgrade drill v2.66→v2.66.x", thay bằng CVE monitor v4.x branch.
- Plan **260629-1726-autossl-zitadel-integration**: OIDC discovery URL không đổi, không impact.
