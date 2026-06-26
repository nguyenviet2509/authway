---
phase: 02
title: IAP reference VPS — Next.js + static HTML
status: pending
priority: P0
effort: 1.5d
blockedBy: [01]
---

# Phase 02 — IAP Reference VPS

## Context
- Pattern: Identity-Aware Proxy (oauth2-proxy trước mọi app)
- App KHÔNG code OIDC, chỉ đọc `X-Auth-Request-Email` header
- Phase này tạo **reference stack** dùng làm template cho phase 03

## Overview
Trên 1 VPS thứ 2, dựng stack: Traefik + **2 oauth2-proxy instance** (mỗi app 1 instance, mỗi instance 1 OIDC client riêng) + 1 Next.js sample + 1 static HTML sample. Mỗi app domain riêng, cookie chỉ scope domain đó. SSO cross-app đạt được qua **Zitadel session** (redirect flash, không re-MFA), KHÔNG qua cookie share.

## Requirements
- VPS-2: 2 domain demo khác parent (vd `nextjs-demo.<owner1>.io.vn` + `static-demo.<owner2>.io.vn`) — phản ánh đúng pattern thật
- **1 oauth2-proxy instance per app** (mỗi instance dùng 1 OIDC client riêng từ Zitadel)
- `--cookie-domain` = chính domain của app đó (KHÔNG dùng parent — public suffix `.io.vn` chặn)
- `--whitelist-domain=auth.<company>.com` (bắt buộc cho logout `rd` chain) <!-- red-team #1 -->
- `--cookie-refresh=1h` để Zitadel disable/revoke propagate trong <1h thay vì chờ session expire <!-- red-team #10 -->
- **Strip `X-Auth-*` middleware ở entrypoint-level** (Traefik `entryPoints.websecure.http.middlewares`), KHÔNG per-router — chống template drift <!-- red-team #2 -->
- **App container bind internal docker network only** (không expose `0.0.0.0:port`). Traefik = sole ingress. <!-- red-team #3 -->
- Sample apps đọc và display email/name từ header
- IP whitelist + VPN giữ nguyên — nhưng **VPN ≠ auth boundary**. Document trong security-model.md. <!-- red-team #3 -->

## Files to Create
- `infra/app-vps-template/docker-compose.yml` — traefik + oauth2-proxy + sample-nextjs + sample-static
- `infra/app-vps-template/.env.example` — oauth2-proxy secrets, Zitadel issuer URL
- `infra/app-vps-template/traefik/dynamic/middlewares.yml` — forwardAuth + strip-auth-headers middleware
- `sample-apps/nextjs-iap-demo/` — minimal Next.js đọc `x-auth-request-email`
- `sample-apps/static-iap-demo/` — static HTML + JS đọc header qua nginx `add_header`
- `docs/iap-pattern-reference.md` — giải thích pattern, security model

## Implementation Steps

1. **Zitadel side** (qua admin UI):
   - Update 2 Application riêng biệt từ phase 01:
     - `nextjs-demo`: redirect_uri = `https://nextjs-demo.<owner1>.io.vn/oauth2/callback`
     - `static-demo`: redirect_uri = `https://static-demo.<owner2>.io.vn/oauth2/callback`
   - Note client_id + client_secret cho mỗi app (riêng biệt)
   - Discovery URL: `https://auth.<company>.com/.well-known/openid-configuration`

2. **VPS-2 base**: Traefik + DNS records + TLS cho cả 2 domain

3. **oauth2-proxy config** — **2 instance riêng**, mỗi app 1 instance. Ví dụ instance cho nextjs-demo:
   ```
   --provider=oidc
   --oidc-issuer-url=https://auth.<company>.com
   --client-id=<nextjs-demo-client-id>
   --client-secret=<nextjs-demo-client-secret>
   --cookie-domain=nextjs-demo.<owner1>.io.vn
   --cookie-secure=true
   --reverse-proxy=true
   --pass-access-token=false
   --set-xauthrequest=true
   --email-domain=*
   --upstream=static://200
   ```
   Instance thứ 2 tương tự với client/cookie-domain của static-demo. KHÔNG share client_id.

4. **Traefik middleware**:
   - `auth-iap`: `forwardAuth.address=http://oauth2-proxy:4180/oauth2/auth`, `forwardAuth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Preferred-Username`
   - `strip-auth-in`: middleware `headers.customRequestHeaders` set `X-Auth-Request-*=""` cho mọi incoming request (tránh client spoof)
   - Chain: `strip-auth-in → auth-iap → app`
   - Error redirect 401 → `/oauth2/start?rd={request.url}`

5. **Sample Next.js**:
   - Page `/`: server component đọc `headers().get('x-auth-request-email')`, hiển thị "Hello {email}"
   - Endpoint `/whoami`: trả JSON
   - **CSP header strict**: `default-src 'self'; script-src 'self'` <!-- red-team #15 -->

6. **Sample static HTML**:
   - nginx serve `index.html` + JS gọi `/whoami` endpoint
   - oauth2-proxy có `/userinfo` endpoint trả JSON user info (dùng cái này cho static)
   - **CSP strict bắt buộc trong template** (vibe-code dễ XSS). `--pass-access-token=false` (đã set) — KHÔNG đổi. <!-- red-team #15 -->

7. **Logout flow** (định nghĩa rõ): <!-- red-team #1: prerequisites -->
   - App link logout → `https://<app>/oauth2/sign_out?rd=<zitadel-end-session-url>`
   - `rd` = `https://auth.<company>.com/oidc/v1/end_session?id_token_hint=<token>&post_logout_redirect_uri=<app-home>`
   - **Prerequisites BẮT BUỘC**:
     - oauth2-proxy: `--whitelist-domain=auth.<company>.com` (nếu thiếu, `rd` bị drop silent)
     - oauth2-proxy: enable forward `id_token_hint` (config: `--set-authorization-header=true` hoặc tương đương — verify version)
     - Zitadel Application: register `post_logout_redirect_uri` exact match cho mỗi app
   - **Spike trước success-criteria sign-off**: curl-trace toàn chain end-to-end

8. **Test cases**:
   - Login flow: clear cookie → access app A → redirect Zitadel → MFA → callback → app load với email
   - **SSO Zitadel session** — test matrix cross-browser (Chrome 3PCD on/off, Safari ITP, Firefox ETP strict, Brave): sau khi login app A, mở app B (domain khác) cùng browser → redirect flash qua Zitadel → vào app B KHÔNG cần MFA lại. Document attributes thực tế của Zitadel session cookie (SameSite, MaxAge) qua DevTools. <!-- red-team #4 -->
   - **Negative test**: thêm 1 Traefik router KHÔNG có middleware chain → request bypass forwardAuth → must fail/be blocked bởi entrypoint-level strip <!-- red-team #2 -->
   - Logout: gọi sign_out chain → re-access app A → buộc login + MFA lại
   - Spoof protection: gửi request kèm `X-Auth-Request-Email: admin@x.com` từ outside → header phải bị strip
   - Session lifetime: idle timeout test (default 12h Zitadel — confirm)
   - 7-day soak

## Todo
- [ ] Zitadel 2 apps redirect URI updated, mỗi app client riêng
- [ ] VPS-2 Traefik + TLS OK cho 2 domain
- [ ] 2 oauth2-proxy instance connect Zitadel, login flow works từng app
- [ ] Zitadel session SSO test pass (login app A → app B redirect flash, no MFA prompt)
- [ ] Next.js sample reads header correctly
- [ ] Static HTML sample reads `/userinfo` correctly
- [ ] Header spoof test pass (incoming `X-Auth-*` stripped)
- [ ] Logout chain works (oauth2-proxy sign_out + Zitadel end_session)
- [ ] 7-day soak: 0 crash

## Success Criteria
- Cả 2 sample app protected, lần đầu MFA, app thứ 2 chỉ "flash redirect" (Zitadel session SSO)
- Spoof test pass
- Header user info propagate đúng
- Logout chain hoạt động end-to-end
- Stack chạy 7 ngày không sự cố

## Risks
| Risk | Mitigation |
|---|---|
| Hiểu nhầm SSO = cookie share | Doc rõ: SSO qua Zitadel session, mỗi app cookie độc lập |
| Cookie domain set sai (vd `.io.vn`) | `cookie-domain` = exact app hostname; test set-cookie response header |
| oauth2-proxy version incompatible với Zitadel | Pin version, smoke test khi upgrade |
| Client spoof X-Auth-* | Strip middleware bắt buộc, test case dedicated |
| Static HTML xài /userinfo có CORS issue | oauth2-proxy cùng domain, không CORS |

## Reference
- oauth2-proxy OIDC config: https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/openid_connect
- Traefik forwardAuth: https://doc.traefik.io/traefik/middlewares/http/forwardauth/
