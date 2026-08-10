# Phase 5 — Onboarding docs + template

**Effort:** 0.5d
**Status:** done (2026-08-10)
**Depends on:** Phase 4 (pilot pattern proved)

## Delivered

- `authway/docs/app-onboarding-iap-guide.md` — 5-step 1-page guide (~180 lines) với P4 lessons (Chrome Domain=IP, `user_id_claim`, LDAP username strip, signout chain, CSP internal alias)
- Template README linked lên guide mới
- 3 reverse proxy patterns documented: Traefik middleware (new apps), Caddy `forward_auth` (OneLog), Nginx `auth_request` (OneMCP)
- 6-language snippet table (Node/Nextjs/FastAPI/Flask/Go/Django)
- Debug matrix 7 gotcha thật từ P4

Sample snippet files trong `templates/app-iap-template/examples/{go,nodejs-express,nodejs-nextjs,python-fastapi,python-django,python-flask}/` đã có sẵn từ trước — không tạo `samples/` mới trùng lặp (YAGNI).

## Deferred

- Demo repo `authway-app-iap-demo` — optional trong plan, skip (template + guide đủ cho onboard)
- README.md authway root "For app developers" section — sẽ update sau khi guide review OK

## Context
- Plan: [../plan.md](../plan.md)
- Existing template: `authway/templates/app-iap-template/`
- Target audience: vibecode dev (phòng KT, AI-assisted, ít kinh nghiệm auth)

## Objective
Docs 1 page + template repo demo để vibecode dev tự onboard app mới trong < 15 phút.

## Steps

### 1. Refine `authway/templates/app-iap-template/`
Verify template có:
- `docker-compose.yml` skeleton với Traefik labels + `iap-auth@file` / `iap-remote` middleware
- `.env.example` với vars cần fill
- README 5-step onboard
- Sample backend snippet đọc header (Node/Python/Go)

Cập nhật lessons từ P4:
- Cross-VPS forwardAuth pattern
- Cookie domain shared
- Header names chuẩn

### 2. Doc 1-page — `authway/docs/app-onboarding-iap-guide.md`
Sections:
1. **What is IAP?** — 3-line explain (Traefik → oauth2-proxy → Zitadel LDAP)
2. **Prerequisites** — VPS behind Traefik, subdomain `*.inet.vn` DNS pointed
3. **5-step onboard:**
   1. Deploy app container với network `edge`
   2. Add Traefik labels: `Host(...)` + `middlewares=iap-remote@file`
   3. Backend đọc `X-Auth-Request-Email` header
   4. Test incognito → redirect login → về app
   5. Done
4. **Debug tips** — common errors + fix
5. **When NOT to use IAP** — mobile app, API-only client → link OIDC-native docs

Max 200 lines. Copy-paste ready snippets.

### 3. Sample snippets multi-language
Trong `authway/templates/app-iap-template/samples/`:
- `node-express.js` — 15 lines middleware
- `python-fastapi.py` — 15 lines dependency
- `go-http.go` — 15 lines handler wrapper
- `nextjs-rsc.tsx` — 10 lines headers() read

### 4. Demo repo (optional, if time)
Fork template thành `authway-app-iap-demo` — clone, deploy, verify < 10 phút.

### 5. Docs cross-link
Update:
- `authway/docs/zitadel-ldap-zimbra-integration.md` — reference onboarding guide
- `authway/README.md` — add "For app developers" section

## Deliverables
- `authway/docs/app-onboarding-iap-guide.md` (< 200 lines, 5-step)
- `authway/templates/app-iap-template/` refined + tested
- 4 sample snippets in `samples/` dir
- README updates

## Success criteria
- ✅ Dev khác (không phải em) đọc doc + template → onboard app mới trong < 15 phút không hỏi
- ✅ Sample snippet copy-paste works
- ✅ Common errors documented với fix

## Risks

| Risk | Mitigation |
|---|---|
| Docs quá dài, dev bỏ đọc | Cap 200 lines, focus copy-paste flow |
| Sample snippet outdated so với oauth2-proxy version | Version-pin snippets + note khi update |
| Template thiếu edge case (VD app cần WebSocket) | Add "Advanced" section link, không cover trong 1-page |

## Next → Phase 6
Rollout app thứ 2 (OneLog) — smoke test template repeatability.
