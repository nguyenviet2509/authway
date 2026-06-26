---
title: Zitadel IAP Rollout — Centralized Auth Gateway for Internal Apps
date: 2026-06-26
status: pending
mode: sequential
brainstorm: ../reports/brainstorm-260626-1154-zitadel-iap-rollout.md
supersedes: ../260626-1103-auth-gateway-poc/plan.md
---

# Zitadel IAP Rollout Plan

## Objective
Triển khai Zitadel làm auth gateway tập trung cho ~10 app vibe-code nội bộ, dùng pattern **Identity-Aware Proxy** (oauth2-proxy phía trước mọi app) để app downstream không cần code OIDC.

## Constraints
- Self-host, internal-only, không B2B/thương mại
- Local users trong Zitadel (admin tạo), MFA bắt buộc (Passkey + TOTP)
- IP whitelist + VPN giữ song song (defense in depth)
- Multi-VPS: 1 VPS auth central + N VPS apps
- Mix Next.js/Node + static HTML vibe-code

## Phases

| # | Phase | Status | Effort |
|---|---|---|---|
| 01 | [Zitadel central VPS](phase-01-zitadel-central.md) | **artifacts ready** — deploy pending | 1d |
| 02 | [IAP reference VPS (Next.js + static HTML)](phase-02-iap-reference.md) | pending | 1.5d |
| 03 | [Onboarding playbook & template](phase-03-onboarding-playbook.md) | pending | 0.5d |
| 04 | [Migrate first 2–3 real apps](phase-04-migrate-real-apps.md) | pending | 1.5d + 7d soak |

Total: ~4.5 ngày base estimate + **50% buffer** cho first-time Zitadel/oauth2-proxy/ACME edge cases ⇒ thực tế ~7 ngày active + 7 ngày soak. Re-baseline sau phase 01 actuals.

## Resolved decisions (2026-06-26)
- **Zitadel domain**: subdomain công ty (vd `auth.<company>.com`)
- **App domains**: mỗi app TLD/parent khác nhau (vd `autossl.trungtq.io.vn`, `mailcenter.haina.io.vn`)
  - Hệ quả: KHÔNG share cookie cross-app (public suffix `.io.vn` chặn). SSO qua **Zitadel session** (redirect flash, không re-MFA).
  - Mỗi app = 1 OIDC client riêng + 1 oauth2-proxy riêng với `cookie-domain = app domain`
- **VPS auth**: 16 GB RAM
- **Backup**: thủ công giai đoạn POC, tự động hoá khi production
- **Admin**: ≥2 admin (primary + break-glass) — single admin bus factor unacceptable. Primary làm offboarding day-to-day, break-glass cho recovery <!-- red-team #8 -->
- **M2M**: out of scope POC

## Success criteria
- Login với local user + MFA, vào được 2 sample app (Next.js + static)
- Logout chain (oauth2-proxy sign_out + Zitadel end_session) verified end-to-end
- Cross-browser SSO matrix pass (Chrome/Safari/Firefox/Brave)
- Onboard app mới: README <15 phút, wall-clock <60 phút, N≥3 dev async validators
- 7-day soak với **monitoring active + audit review daily** (0 silent incident, không chỉ 0 user complaint)
- Playbook + template repo viết xong, có người ngoài team test

## Red Team Review (2026-06-26)
15 finding accepted (9 critical, 4 high, 2 medium) — applied inline trong phase files với marker `<!-- red-team #N -->`. Key gaps đã đóng:
- Logout `rd` whitelist + `id_token_hint` (phase 02)
- Header strip ở entrypoint-level chống template drift (phase 02)
- App container bind internal docker network (phase 02)
- Cross-browser session SSO test matrix (phase 02)
- TRUNCATE → rename `users_legacy` + FK audit (phase 04)
- Monitoring + cron backup + offsite + restore drill (phase 01)
- ≥2 admin, masterkey ≥2 nơi, disable self-service MFA reset (phase 01)
- Lockout + rate-limit + audit log shipping (phase 01)
- Secret rotation playbook + cookie-refresh=1h (phase 02/03)
- CSP strict trong template (phase 02/03)

**Deferred (post-POC):** HA hot standby Zitadel + DNS failover, PSL/non-PSL parent test.

## Validation Log (2026-06-26)
- **Break-glass admin**: Founder / sếp trực tiếp — Passkey enroll day 1, sealed credential. Cần training procedure 30 phút.
- **Offsite backup**: S3 nội bộ công ty — endpoint/credential ghi vào `.env` phase 01, rclone config.
- **Alert channel**: Telegram bot, group chat team — tạo bot + group + chat_id trước phase 01.
- **Phase 04 pilot mix**: 1 Nhóm A static + 1 Nhóm B đơn giản + 1 Nhóm B phức tạp (broad coverage, edge case sớm).
