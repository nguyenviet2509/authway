---
type: brainstorm
date: 2026-06-26 11:54
slug: zitadel-iap-rollout
status: design-approved
supersedes: brainstorm-260626-1103-auth-gateway-poc.md
---

# Zitadel IAP Rollout — Brainstorm Summary

## Decision history
- Session 1103: Brainstorm Authentik vs Zitadel + POC parallel plan
- Session 1139: Khẳng định internal-only, đặt trọng số scale/longevity
- **Session 1154 (this)**: User chốt **Zitadel**, self-host, internal-only, multi-VPS. Plan POC parallel cũ → superseded.

## Final constraints
| Khoản | Quyết định |
|---|---|
| Tool | Zitadel (self-host, AGPL OK) |
| Identity source | Local users trong Zitadel (admin tạo thủ công), KHÔNG federate Google |
| MFA | Passkey ưu tiên, TOTP fallback, enforced |
| Network | IP whitelist GIỮ song song (defense in depth) + VPN sẵn có |
| App stack | Mix: Next.js/Node sửa code được + static HTML vibe-code |
| Deploy | Multi-VPS: 1 VPS auth central + N VPS apps |
| Scope | Nội bộ, không B2B, không thương mại |

## Recommended pattern: **Identity-Aware Proxy (IAP)**

Mọi app đứng sau `oauth2-proxy` local; app chỉ đọc HTTP header `X-Auth-Request-Email` để biết user — KHÔNG tự code OIDC client. Pattern tiêu chuẩn của Google Cloud IAP / Cloudflare Access / AWS ALB OIDC.

### Vì sao IAP, không phải OIDC-in-app
- Static HTML không thể tự code OIDC → phải có proxy → để đồng nhất, dùng cho cả Next.js
- Vibe-coder KHÔNG cần học OIDC — code 1 dòng đọc header
- Migrate auth provider sau = đổi env oauth2-proxy, app không sửa
- 1 reference template áp dụng cho mọi app mới (DRY)

### Trade-off chấp nhận
- Mỗi VPS app thêm 1 container oauth2-proxy (~30 MB RAM)
- 2 systems (Zitadel + oauth2-proxy) thay vì 1 — có chủ đích, không phải accident
- Header trust: oauth2-proxy chạy local cùng VPS, Traefik strip incoming `X-Auth-*` headers từ client

## Architecture

```
        [Firewall: IP whitelist + VPN]
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
┌─────────────────┐    ┌──────────────────────┐
│ VPS Auth         │    │ VPS App-N            │
│  traefik (TLS)  │    │  traefik (TLS)       │
│  zitadel         │◄───│  oauth2-proxy        │
│  postgres        │OIDC│  app(s) (Next.js or  │
│                  │    │    static HTML)      │
└──────────────────┘    └──────────────────────┘
```

## Rollout phases (plan: 260626-1154-zitadel-iap-rollout)

| # | Phase | Outcome |
|---|---|---|
| 01 | Zitadel central | 1 VPS auth chạy ổn, admin tạo user + bật MFA |
| 02 | IAP reference VPS | 1 VPS mẫu protect 1 Next.js + 1 static HTML, end-to-end OK |
| 03 | Onboarding playbook | Docs + template repo: dev tự deploy app mới <15 phút |
| 04 | Migrate 2–3 app thực | App thật chạy qua gateway, retrospective |

## Success criteria
- User local tạo trong Zitadel login được, MFA bắt buộc
- 1 Next.js app + 1 static HTML app cùng pattern, đọc được user qua header
- Dev khác (chưa từng dùng Zitadel) tự deploy app mới qua playbook <15 phút
- IP whitelist + VPN vẫn áp dụng, login flow hoạt động qua VPN
- 0 crash trong 7 ngày soak

## Risks
| Risk | Mitigation |
|---|---|
| Header spoofing | Traefik strip incoming `X-Auth-*` từ client; oauth2-proxy bind 127.0.0.1; app chỉ accept từ proxy network |
| Single auth VPS down → mọi app khoá | POC chấp nhận; production thêm replica + managed Postgres |
| Local password leak | MFA enforced; password rotation policy 90 ngày; admin onboarding kèm Passkey ngay lần login đầu |
| Zitadel CVE | Subscribe security advisory, pin minor, monthly patch window |
| Cookie cross-domain | All apps cùng parent domain `*.<internal>.example`, cookie-domain set ở oauth2-proxy |

## Open questions
- Domain nội bộ dùng cái nào? `.internal`, `.local`, hay subdomain của domain công ty?
- VPS auth spec: ≥4 GB RAM đủ cho Zitadel + Postgres?
- Backup strategy: pg_dump cron local, hay snapshot VPS, hay cả hai?
- Khi user nghỉ việc: workflow disable trong Zitadel — ai chịu trách nhiệm?
- M2M auth (CI/CD gọi internal API qua gateway): cần client_credentials trong POC không?
