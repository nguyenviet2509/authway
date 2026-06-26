---
phase: 01
title: Zitadel central VPS
status: in-progress
priority: P0
effort: 1d
artifacts: infra/auth-vps/
deployGuide: docs/lab-deploy-192-168-122-54.md
---

# Phase 01 — Zitadel Central VPS

## Context
- Brainstorm: [../reports/brainstorm-260626-1154-zitadel-iap-rollout.md](../reports/brainstorm-260626-1154-zitadel-iap-rollout.md)
- IAP pattern: Zitadel chỉ là OIDC issuer; mọi app dùng oauth2-proxy

## Overview
Deploy Zitadel + Postgres + Traefik trên 1 VPS, domain `auth.<internal>.example`. Tạo local admin, bật MFA policy, chuẩn bị 2 OIDC application cho phase 02 (Next.js, static HTML).

## Requirements
- VPS 16 GB RAM, Ubuntu/Debian, Docker
- Zitadel self-host qua docker-compose
- Postgres 16 (local container, dedicated db `zitadel`, dedicated user)
- Traefik TLS qua Let's Encrypt (HTTP-01 hoặc DNS-01 nếu domain nội bộ không expose Internet)
- IP whitelist firewall layer giữ nguyên (VPS chỉ accept từ subnet nội bộ + VPN)
- MFA policy: Force MFA = ON; Passkey + TOTP allowed
- **≥2 admin user** bind Passkey day 1: primary (team lead/IT) + break-glass (**founder/sếp trực tiếp**). Break-glass credential sealed offline + 30 phút training procedure. <!-- red-team #8, validation -->

- **Masterkey lưu ≥2 nơi độc lập** (Bitwarden + sealed envelope trong safe). Restore drill thực: restore vào VM mới, login test user thành công. <!-- red-team #7 -->
- **SMTP** cho Zitadel: bắt buộc. Login Policy: **disable self-service MFA/password reset** — admin-mediated only (tránh SMTP-compromise → MFA bypass). <!-- red-team #9 -->
- **NTP sync** trên VPS: `timedatectl set-ntp true` — bắt buộc để TOTP không lệch giờ
- **Lockout Policy** Zitadel: max password attempts + lockout duration. Disable username enumeration (uniform error). <!-- red-team #14 -->
- **Rate-limit** Traefik trên `/oauth/v2/authorize`, `/login` paths. <!-- red-team #14 -->
- **Monitoring stack** (Uptime Kuma self-host): probe `/.well-known/openid-configuration` 200, TLS cert >14d, Postgres disk <80%, NTP offset <500ms, SMTP test weekly. **Alert qua Telegram bot → group chat team** (tạo bot + chat_id trước khi cài). <!-- red-team #6, #12, validation -->
- **Audit log shipping**: tail Zitadel events ra log file central (rsyslog/journald + rclone offsite) — daily review checklist trong soak. <!-- red-team #14 -->
- Domain `auth.<company>.com` (subdomain công ty), DNS public hoặc private tuỳ network model

## Files to Create
- `infra/auth-vps/docker-compose.yml` — traefik + zitadel + postgres
- `infra/auth-vps/.env.example` — masterkey, postgres password, external domain, SMTP creds
- `infra/auth-vps/traefik.yml` + `dynamic/middlewares.yml`
- `infra/auth-vps/zitadel-init.yaml` — declarative init (org, project skeleton, SMTP config)
- `infra/auth-vps/scripts/backup-postgres.sh` — **cron daily NGAY trong POC**. Đẩy lên **S3 nội bộ công ty** qua rclone (endpoint/credential trong `.env`). <!-- red-team #11, validation -->
- `infra/auth-vps/scripts/restore-drill.sh` — **chạy weekly**: restore vào throwaway container, assert login test user OK. <!-- red-team #11 -->
- `infra/auth-vps/monitoring/` — Uptime Kuma compose, probe list, alert channel config <!-- red-team #6 -->
- `docs/auth-vps-runbook.md` — install, backup/restore, upgrade, SMTP test, NTP check

## Implementation Steps
1. Provision VPS 16 GB RAM, Docker installed; confirm IP whitelist firewall áp dụng; bật NTP (`timedatectl set-ntp true`, verify `timedatectl status`)
2. Tạo DNS A record `auth.<company>.com` → VPS IP
3. Generate masterkey: `openssl rand -base64 32`
4. Tạo Postgres user/db least-privilege cho Zitadel
5. Bring up stack với `ZITADEL_EXTERNALDOMAIN=auth.<internal>.example`, `_EXTERNALSECURE=true`
6. Chạy `zitadel init` + `zitadel setup` (init containers)
7. Login admin, đổi password, bind Passkey
8. Default Settings → Login Policy → Force MFA ON; allowed factors: OTP, U2F (Passkey)
9. **SMTP config**: Default Settings → SMTP → fill host/port/user/pass; send test email → verify nhận
10. Tạo Project "internal-apps"
11. Tạo 2 OIDC Application skeleton (mỗi app 1 client riêng, redirect URI fill ở phase 02):
    - App "nextjs-demo" (Web, code+PKCE)
    - App "static-demo" (Web, sẽ là client của oauth2-proxy)
12. Document runbook: install, backup thủ công, restore test, upgrade procedure, SMTP test, NTP check
13. Backup test: chạy `backup-postgres.sh` → restore vào staging container → verify data

## Todo
- [ ] VPS up, IP whitelist verified, NTP synced
- [ ] DNS resolve OK
- [ ] Traefik TLS valid + cert expiry monitor armed
- [ ] Zitadel init done, **2 admin** login + Passkey OK; break-glass credential sealed
- [ ] Masterkey lưu ≥2 nơi, document recovery path
- [ ] SMTP test email nhận OK; self-service MFA/password reset **disabled**
- [ ] Lockout Policy ON; Traefik rate-limit auth paths
- [ ] MFA policy enforced (tạo user test, verify bị prompt MFA)
- [ ] Postgres backup **cron daily** + offsite OK; **restore drill weekly** automated
- [ ] Monitoring stack live, alert channel nhận test page
- [ ] Audit log shipping + daily review checklist viết xong
- [ ] Runbook viết xong

## Success Criteria
- Login Zitadel UI từ máy nội bộ → buộc MFA prompt
- Tạo user thứ 2 → user đó login lần đầu cũng bị MFA setup
- Backup chạy daily, restore test thành công
- VPS chỉ reachable từ subnet nội bộ + VPN

## Risks
| Risk | Mitigation |
|---|---|
| ACME rate limit | Dùng staging cert trong setup, switch prod khi ổn |
| Masterkey leak | Lưu trong secret manager (Bitwarden/1Password), không commit |
| Init step fragile | Dùng `condition: service_completed_successfully` trong compose |
| DNS không expose Internet → HTTP-01 fail | Dùng DNS-01 với API token Cloudflare/provider |

## Reference
- Zitadel docker compose: https://zitadel.com/docs/self-hosting/deploy/compose
- Login Policy: https://zitadel.com/docs/guides/manage/console/default-settings#login-behavior-and-access
