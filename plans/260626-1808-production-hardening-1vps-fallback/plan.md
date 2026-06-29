---
title: Production Hardening — 1-VPS Zitadel + VPN-only Breakglass Fallback
date: 2026-06-26
status: pending
mode: sequential
brainstorm: ../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md
blockedBy: [260626-1154-zitadel-iap-rollout]
blocks: []
---

# Production Hardening Plan

## Objective
Đưa AuthWay từ lab POC → production-ready cho team kỹ thuật 5 người (10 app infra-critical, nội bộ công ty) với constraint **1 VPS Zitadel** (no HA). Achieve RTO 5 phút qua breakglass VPN-only fallback thay vì HA active-active.

## Constraints
- 1 VPS duy nhất cho Zitadel (no HA)
- OpenVPN self-host đã sẵn sàng (identity layer khi fallback)
- S3 nội bộ có sẵn cho backup destination
- Provider VPS hỗ trợ daily snapshot
- RTO target 5 phút, RPO 1h
- Compliance nội bộ only (không B2B audit)
- App chưa migrate IAP nên không có legacy auth burden khi triển khai breakglass
- Alert qua Telegram bot

## Resolved decisions (2026-06-26 brainstorm)
- **Fallback strategy**: VPN-only (Option F2 pure) — KHÔNG dual-auth code, KHÔNG IP whitelist + no-MFA mode
- **Identity khi fallback**: OpenVPN cert qua VPN server log, app header inject placeholder `breakglass-mode@authway.lab`
- **Secrets**: SOPS + age (không Vault, không SaaS secrets manager)
- **Backup**: hourly pg_dump → age encrypt → S3, GFS retention (24h + 30d + 12w + 12m)
- **Snapshot**: daily VM provider-level, retention 7 ngày
- **Log shipping**: Vector + Loki trên VPS-C observability tách trust boundary
- **HA**: KHÔNG. Accept downtime window 15–30 phút khi restore; breakglass fallback cover gap 5–15 phút đầu.

## Phases

| # | Phase | Status | Effort |
|---|---|---|---|
| 00 | [Enable provider VM snapshot](phase-00-provider-snapshot.md) | pending | 5 phút |
| 01 | [Audit log shipping + Telegram alert](phase-01-log-shipping-alert.md) | pending | 1d |
| 02 | [Offsite encrypted backup + restore drill](phase-02-backup-restore-drill.md) | pending | 1d |
| 03 | [SOPS + age secrets pipeline](phase-03-sops-secrets.md) | pending | 1d |
| 04 | [Breakglass VPN-only fallback](phase-04-breakglass-vpn-fallback.md) | pending | 1d |
| 05 | [Bastion SSH + break-glass admin sealing](phase-05-bastion-and-admin.md) | pending | 0.5d |
| 06 | [Session/token TTL + cookie hardening](phase-06-session-hardening.md) | pending | 0.5d |
| 07 | [Misc hardening (PG SSL, socket-proxy, microseg, upgrade SOP)](phase-07-misc-hardening.md) | pending | 0.5d |

**Total**: ~6.5 ngày active. Order chạy có thể song song phase 01 ↔ 02 ↔ 03 nếu có 2 dev.

## Success criteria
- Zitadel down test → toggle breakglass < 30s → app login lại qua VPN-only identity, có log alert Telegram
- Restore drill weekly pass 3 tuần liên tiếp
- Reboot VPS → KHÔNG tìm thấy plaintext masterkey/secrets trên disk (SOPS + tmpfs)
- Tampere thử Zitadel log local → bản gốc vẫn còn trên Loki + S3 archive
- SSH trực tiếp từ workstation bypass bastion → bị deny
- Offboarding test: deactivate user + revoke VPN cert < 1h, verify mất quyền tất cả app
- Spoof header test pass (đã có ✅, regression test)
- Quarterly breakglass drill: toggle on→off staging + forensic correlation OpenVPN ↔ Traefik log < 10 phút

## Risks
- **Provider VPS down ngoài tầm kiểm soát** → mitigation: snapshot + restore runbook < 15 phút, breakglass cover gap
- **Attacker DoS Zitadel để ép bật breakglass** → mitigation: runbook yêu cầu investigate root cause trước khi toggle
- **VPN cert leak trong giai đoạn breakglass** → mitigation: cert TTL 90d, revoke at offboarding, monthly audit
- **SOPS age key mất** → backup offline 2 nơi (Bitwarden + sealed envelope)
- **Backup ship S3 fail silently** → alert nếu file backup mới nhất > 25h tuổi

## Cost estimate
| Item | Monthly |
|---|---|
| VPS-A Zitadel (4–16GB) | ~$15–40 |
| VPS-C observability (2GB) | ~$10 |
| VPS-D bastion (1GB) | ~$5 |
| Provider snapshot | ~$2 |
| S3 nội bộ | có sẵn |
| **Total** | **~$30–60/tháng** |

## Reference
- Brainstorm: [../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md](../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md)
- Parent rollout plan: [../260626-1154-zitadel-iap-rollout/plan.md](../260626-1154-zitadel-iap-rollout/plan.md)
- Existing infra: `infra/auth-vps/` (Zitadel + PG + Traefik), `infra/app-vps/` (IAP)
