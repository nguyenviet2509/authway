---
title: AutoSSL — Zitadel Auth Integration (IAP, Zero Code Change)
date: 2026-06-29
status: pending
mode: sequential
brainstorm: ../reports/brainstorm-260629-1714-autossl-zitadel-iap.md
guide: ../../docs/deploy-autossl-zitadel-iap.md
blockedBy: [260626-1154-zitadel-iap-rollout, 260630-0826-zitadel-bump-to-v4]
---

# AutoSSL Zitadel Integration

## Objective
Bọc Zitadel auth lên AutoSSL (đang chạy production) qua oauth2-proxy sidecar — **không sửa code app**, chỉ thao tác infrastructure. Effort: 1-2h ops, 0 dev.

## Constraints
- AutoSSL đang chạy ổn → không rebuild, không restart PM2 trừ khi rollback
- Giữ IP whitelist song song (defense in depth)
- MFA bắt buộc, config trong Zitadel policy
- Cookie domain exact match (không parent — public suffix chặn)

## Blocked by
- `260626-1154-zitadel-iap-rollout` phase 01 (Zitadel central VPS phải up + accessible từ VPS AutoSSL)
- Optional: phase 02 (reference pattern đã verify — giảm risk first-time edge cases)

## Phases

| # | Phase | Status | Effort |
|---|---|---|---|
| 01 | [Deploy oauth2-proxy + nginx wiring](phase-01-deploy.md) | pending | 1-2h |

Single-phase plan vì scope đủ nhỏ (KISS — không over-decompose).

## Resolved decisions
- **Approach**: oauth2-proxy sidecar, zero code change (đã confirm với user 2026-06-29)
- **Audit log app-level**: bỏ — trace qua nginx + Zitadel + PM2 log đủ
- **IP whitelist**: giữ
- **Logout UI**: bookmark URL — không sửa code app

## Success criteria
- `curl -I https://autossl.<domain>/` → 302 redirect Zitadel
- Login full flow Zitadel → MFA → AutoSSL UI gốc
- Header injection test fail (nginx strip headers)
- Logout chain → re-MFA verified
- IP outside whitelist → 403 từ nginx (không reach Zitadel)
- WHM token trong localStorage không mất sau login lại
- Rollback drill: stop oauth2-proxy + revert nginx = app cũ về trong 30s

## Unresolved questions
1. Cookie refresh 15m vs 1h — chọn cuối khi deploy
2. Office/VPN IP cụ thể cần điền — collect trước deploy
3. Monitor stack: chấp nhận tail log thủ công cho POC, defer Loki/Prom

## Out of scope
- Sửa code AutoSSL (audit log, logout button, RBAC) — nếu cần sau, plan riêng
- Move WHM token từ localStorage sang server-side — production hardening, plan riêng
- Automate backup oauth2-proxy config — manual đủ POC
