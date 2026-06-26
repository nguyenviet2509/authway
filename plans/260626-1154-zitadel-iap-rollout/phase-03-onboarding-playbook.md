---
phase: 03
title: Onboarding playbook & template repo
status: pending
priority: P0
effort: 0.5d
blockedBy: [02]
---

# Phase 03 — Onboarding Playbook & Template

## Context
- Reference stack từ phase 02 đã chạy
- Phase này biến reference thành thứ dev khác **tự copy** không cần hỏi

## Overview
Tạo template repo + playbook để dev (vibe-coder) deploy app mới sau Zitadel chỉ với:
1. Tạo Application trong Zitadel (admin task, <2 phút)
2. Copy compose template + thay 3 env var
3. Deploy

Target (split metric — wall-clock ≠ README time): <!-- red-team #13 -->
- **README execution time** <15 phút (steps thuần)
- **End-to-end wall-clock** <60 phút (gồm DNS propagation, ACME issuance, firewall/VPN allowlist, admin tạo Zitadel client)

## Requirements
- Template repo `vibe-app-iap-template/` chứa:
  - `docker-compose.yml` boilerplate (traefik labels + oauth2-proxy hooks)
  - `.env.example` với 3 placeholder rõ ràng
  - `README.md` step-by-step
  - 2 starter: `app-static/` (nginx serve HTML) + `app-nextjs/` (Next.js skeleton đọc header)
- Admin playbook trong `docs/` (owner: primary admin + break-glass admin):
  - Cách tạo OIDC Application **riêng cho mỗi app** trong Zitadel (screenshot từng bước)
  - Cách disable user khi offboard
  - Cách reset MFA cho user (admin-mediated only — self-service disabled)
  - Cách check audit log + alert review
  - **Secret rotation**: rotate `ZITADEL_CLIENT_SECRET` per app, rotate `COOKIE_SECRET`, masterkey rotation procedure <!-- red-team #10 -->
  - **Break-glass procedure**: khi primary admin mất, cách dùng sealed credential <!-- red-team #8 -->
  - **Prerequisites checklist** đi kèm onboarding (DNS, ACME, firewall — out of <15min window) <!-- red-team #13 -->
- **Pre-prod DNS/TLS prerequisites**:
  - Wildcard cert per parent domain nếu có thể (giảm ACME pressure)
  - DNS-01 token per zone owner documented

## Files to Create
- `templates/vibe-app-iap/` (template dir)
  - `docker-compose.yml` — app container bind internal network only; strip-auth-headers entrypoint middleware mandatory
  - `.env.example` — gồm `APP_HOSTNAME`, `COOKIE_DOMAIN`, `COOKIE_SECRET`, `ZITADEL_*`
  - `README.md`
  - `app-static/Dockerfile` + sample `index.html` + **strict CSP header** trong nginx config
  - `app-nextjs/Dockerfile` + sample `app/page.tsx` + **CSP middleware**
  - `traefik-labels-snippet.yml` + entrypoint middleware reference
- `docs/onboarding-new-app.md` — dev playbook
- `docs/admin-zitadel-operations.md` — admin playbook
- `docs/security-model.md` — explain IAP, threat model, why IP whitelist still on

## Implementation Steps
1. Extract reference stack từ phase 02 thành template generic
2. Thay hardcode bằng env vars: `APP_HOSTNAME`, `COOKIE_DOMAIN` (= APP_HOSTNAME, exact match — không phải parent), `ZITADEL_ISSUER_URL`, `ZITADEL_CLIENT_ID`, `ZITADEL_CLIENT_SECRET`, `COOKIE_SECRET` (random 32 bytes)
3. Viết README.md với 7 bước (target <15 min):
   - Step 1: Tạo Application trong Zitadel admin → note client_id/secret
   - Step 2: `git clone template`
   - Step 3: copy `.env.example` → `.env`, fill 3 vars
   - Step 4: replace `app-static/` hoặc `app-nextjs/` bằng code thật
   - Step 5: `docker compose up -d`
   - Step 6: verify https://{hostname}/ → redirect Zitadel → login → OK
   - Step 7: smoke test header propagation
4. Admin playbook: screenshot Zitadel admin UI cho 4 task (create app, disable user, reset MFA, view audit)
5. Security model doc: threat model, why strip headers, why IP whitelist, what compromised oauth2-proxy means
6. **Validation**: **N≥3 dev** chưa từng dùng, **async, không có author present**, chỉ README + Slack channel để hỏi. Record screen + count số lần README không đủ. Pass: 3/3 finish without out-of-band help. <!-- red-team #13 -->

## Todo
- [ ] Template repo created
- [ ] README step-by-step viết xong
- [ ] Admin playbook + screenshots
- [ ] Security model doc
- [ ] Validation: dev unfamiliar onboard <15 min
- [ ] Pain points logged & fixed

## Success Criteria
- Dev unfamiliar onboard app static trong <10 phút
- Dev unfamiliar onboard app Next.js trong <15 phút
- Admin tạo Application Zitadel mới trong <2 phút
- 0 câu hỏi "tôi không hiểu bước X" sau khi đọc README

## Risks
| Risk | Mitigation |
|---|---|
| Template phình to khi cover nhiều case | Giữ minimal, doc các variant ở `docs/recipes/` riêng |
| Dev quên strip header middleware → vuln | Middleware chain BẮT BUỘC trong template, không optional |
| Admin task quá nhiều thủ công | Phase sau (out of scope POC): Terraform Zitadel provider |
