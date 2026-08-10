# Phase 6 — Second app rollout (OneLog)

**Effort:** 0.5d
**Status:** pending
**Depends on:** Phase 5 (template + docs ready)

## Context
- Plan: [../plan.md](../plan.md)
- OneLog: `D:/Vietnt/Project/onelog/` (already deployed onelog-vps)
- OneLog hiện tại chưa có SSO — endpoints public hoặc rely on network isolation

## Objective
Rollout template cho OneLog để verify template repeatable, đo effort thực tế (target < 15 phút không tính discussion). OneLog case = smoke test cho vibecode apps tương lai.

## Steps

### 1. Follow onboarding guide 5-step (from Phase 5)
Đóng vai "vibecode dev đọc guide" — không dùng lessons riêng ngoài docs.

1. onelog-vps đã ở edge network (verify)
2. Add Traefik labels vào OneLog compose service:
   - `Host('onelog.inet.vn')`
   - `middlewares=iap-remote@file`
3. OneLog backend (nếu có endpoint cần user context) — add header-read middleware theo sample
4. Deploy: `docker compose up -d`
5. Test incognito

### 2. Đo effort thực tế
Time-box: 15 phút. Nếu > 15 phút → phase 5 template/docs chưa đủ, iterate.

### 3. Log gap analysis
Ghi lại:
- Bước nào docs miss?
- Sample snippet nào không copy-paste được?
- Error nào không có trong debug tips?

Feedback loop update Phase 5 docs.

### 4. Multi-app SSO verification
- Login OneMCP (từ P4) trong browser 1
- Cùng browser mở tab mới `onelog.inet.vn` → **KỲ VỌNG: không cần login lại** (SSO cookie share `.inet.vn` domain)
- Logout từ OneMCP → refresh OneLog → phải redirect login lại

### 5. Optional: 3rd app pilot
Nếu có vibecode app sẵn (VD monitoring dashboard, internal tool) → rollout luôn để test lần 3.

## Deliverables
- OneLog protected qua IAP
- SSO multi-app verified (cross-tab, cross-app cookie share)
- Feedback loop → docs P5 refined nếu cần
- Journal: SSO rollout hoàn tất, unblock plans OneMCP/AI Connector Hub

## Success criteria
- ✅ OneLog SSO E2E qua Zimbra user
- ✅ Multi-app SSO cookie share OK
- ✅ Onboarding < 15 phút (đo thực tế)
- ✅ Docs P5 confirm dùng được cho dev khác

## Risks

| Risk | Mitigation |
|---|---|
| OneLog OpenWebUI bridge cần API key riêng, không IAP | IAP chỉ bọc portal UI, bridge dùng bearer token flow (opt-in OIDC-native) |
| Vector/Loki UI cần auth khác | IAP bọc được, Vector/Loki đọc header hoặc pass-through user context |
| Kết quả > 15 phút | Iterate docs, không ship P6 done cho đến khi target đạt |

## Post-completion

- Update `plan.md` status → completed
- Send notification KT team: "SSO ready, apps mới có thể onboard qua template"
- Unblock signal:
  - `onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel` → confirm P4 đã cover
  - `onelog:260805-0852-onemcp-ai-connector-hub` → có thể start
- Journal entry: SSO rollout journey (bug encounter, workaround, final state)
- Archive plan sau 2 tuần nếu không regression report

## Deferred (out of scope, log)
- MFA policy enforce cho tất cả LDAP user
- Group sync Zimbra → app roles
- Zitadel HA multi-node
- OIDC-native migration cho API-only clients (OneMCP MCP endpoint cho AI client)
- Zimbra password change flow trong Zitadel UI (chỉ đổi qua Zimbra webmail, Zitadel không có write access)
