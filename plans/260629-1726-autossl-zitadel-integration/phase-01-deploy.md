---
phase: 01
title: Deploy oauth2-proxy + nginx wiring for AutoSSL
status: pending
priority: P0
effort: 1-2h
blockedBy: [260626-1154-zitadel-iap-rollout/phase-01-zitadel-central]
---

# Phase 01 — Deploy oauth2-proxy + nginx wiring

## Context
- Guide chi tiết: [`docs/deploy-autossl-zitadel-iap.md`](../../docs/deploy-autossl-zitadel-iap.md)
- Brainstorm history: 3 turns confirm approach Option A (oauth2-proxy, zero code change)
- AutoSSL VPS: Next.js qua PM2 ở `127.0.0.1:3000`, nginx :443 front, IP whitelist via `allow/deny` + `middleware.ts`

## Overview
Tích hợp Zitadel auth bằng cách thêm oauth2-proxy layer giữa nginx và Next.js. **Không touch repo AutoSSL.**

## Key insights
- Header strip **phải ở nginx** (entrypoint), không chỉ ở oauth2-proxy — chống bypass nếu oauth2-proxy compromise
- Cookie domain = exact `autossl.<domain>`, KHÔNG parent `.io.vn` (public suffix block)
- Logout URL phải chain qua Zitadel `end_session`, không thì re-login skip MFA
- `whitelist_domains = ["auth.<company>.com"]` trong oauth2-proxy config chống open-redirect attack qua `?rd=`
- Backup nginx vhost trước khi sửa → rollback 30s đúng nghĩa

## Requirements
- Zitadel central up ở `https://auth.<company>.com` (verify từ VPS AutoSSL: `curl -I https://auth.<company>.com/.well-known/openid-configuration` → 200)
- DNS `autossl.<domain>` trỏ về VPS AutoSSL (đã có)
- TLS cert đã issued cho `autossl.<domain>` (đã có)
- Admin Zitadel để tạo OIDC client
- Office/VPN public IP confirmed để giữ IP allowlist

## Files to create
- `/etc/oauth2-proxy/autossl.cfg` (mode 600, owner root)
- `/etc/systemd/system/oauth2-proxy-autossl.service`

## Files to modify (on VPS, không phải repo)
- `/etc/nginx/sites-available/autossl` — đổi `proxy_pass` :3000 → :4180, thêm `proxy_set_header X-Forwarded-* ""`

## Files NOT to touch
- Toàn bộ `sample-apps/AutoSSL/src/` — zero code change
- `sample-apps/AutoSSL/src/middleware.ts` — giữ IP middleware nguyên

## Implementation steps

1. **Pre-flight** (5 min)
   - SSH vào VPS AutoSSL
   - Verify Zitadel reachable: `curl -I https://auth.<company>.com/.well-known/openid-configuration`
   - Confirm AutoSSL đang chạy: `pm2 status autossl` + `curl -I https://autossl.<domain>/`
   - Backup vhost: `sudo cp /etc/nginx/sites-available/autossl /etc/nginx/sites-available/autossl.bak`

2. **Zitadel OIDC app** (5 min, browser)
   - Login Zitadel admin → Projects → `internal-apps` → New Application
   - Type: Web / Code (confidential)
   - Redirect URI: `https://autossl.<domain>/oauth2/callback`
   - Post Logout URI: `https://autossl.<domain>/`
   - Token: JWT, User Info in ID Token = ON
   - Copy client_id + client_secret (one-time)
   - Authorization tab: grant users được phép

3. **Install oauth2-proxy** (10 min)
   - Theo guide section 3.1 — wget binary v7.6.0, extract, mv `/usr/local/bin/`
   - Sinh cookie_secret: `python3 -c 'import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())'`
   - Write `/etc/oauth2-proxy/autossl.cfg` (mode 600) — fill client_id, client_secret, cookie_secret, hostnames
   - Write systemd unit `/etc/systemd/system/oauth2-proxy-autossl.service`
   - `systemctl daemon-reload && systemctl enable --now oauth2-proxy-autossl`
   - Verify: `systemctl status` + `curl -I http://127.0.0.1:4180/` → 302

4. **Nginx wiring** (10 min)
   - Sửa `/etc/nginx/sites-available/autossl`:
     - `proxy_pass http://127.0.0.1:4180;` (thay :3000)
     - Thêm 7 dòng `proxy_set_header X-Forwarded-* ""` strip headers
     - Giữ `allow/deny` IP whitelist nguyên
   - `nginx -t && systemctl reload nginx`

5. **Verify** (15 min) — checklist section 5 guide
   - 302 redirect Zitadel
   - Browser full login flow + MFA
   - Header injection test (curl với fake X-Forwarded-Email)
   - IP outside whitelist → 403
   - Logout chain → re-MFA
   - WHM token localStorage persist

6. **Rollback drill** (5 min) — verify rollback path works trước khi tin tưởng
   - `systemctl stop oauth2-proxy-autossl`
   - `mv autossl.bak autossl && nginx -t && systemctl reload nginx`
   - Verify AutoSSL về trạng thái cũ
   - Re-apply Zitadel layer lại

## Todo
- [ ] Pre-flight: Zitadel reachable + AutoSSL healthy + vhost backed up
- [ ] Zitadel OIDC client created + credentials secured
- [ ] oauth2-proxy installed + config + systemd running
- [ ] Nginx vhost updated + reloaded
- [ ] Verify checklist passed (6 items)
- [ ] Rollback drill executed successfully
- [ ] Update brainstorm report status → done
- [ ] Notify users về logout URL bookmark

## Success criteria
- All 6 verify checklist items pass
- Rollback drill < 30s
- Zero downtime on AutoSSL (PM2 process không restart)

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Cookie domain mismatch → login loop | Medium | High | Test cookie_domains = exact hostname trước khi go-live; check browser cookies tab |
| Zitadel issuer URL có trailing slash → discovery fail | Low | High | Test `curl /.well-known/openid-configuration` từ VPS trước config |
| Strip headers thiếu trường nào → injection | Low | High | Test bằng curl với từng header injection sau deploy |
| IP whitelist block dev đang test | Medium | Low | Confirm tester IP trong allowlist trước; có thể tạm widen rồi narrow lại |
| TLS cert expire trong khi test | Low | Medium | `certbot certificates` check expiry trước |
| oauth2-proxy version mismatch behavior | Low | Medium | Pin v7.6.0, document version trong config |

## Security considerations
- `client_secret` + `cookie_secret` chỉ tồn tại trong `/etc/oauth2-proxy/autossl.cfg` (mode 600 root) — không commit
- `whitelist_domains` chống open-redirect qua `?rd=`
- Headers strip ở nginx = chống injection ngay cả nếu oauth2-proxy bypass
- IP whitelist giữ = nếu Zitadel/oauth2-proxy compromise, attacker vẫn cần IP đúng
- Disable user trong Zitadel → max 1h lag (cookie_refresh) — acceptable cho internal tool 10 user

## Next steps (sau khi done)
- Update `260626-1154-zitadel-iap-rollout/phase-04` mark AutoSSL = first real app migrated
- 7-day soak monitoring: tail oauth2-proxy journal + nginx access log daily
- Defer: cookie_refresh tune, monitor stack (Loki/Prom), audit log app-level
