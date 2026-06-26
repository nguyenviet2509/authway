---
type: brainstorm
date: 2026-06-26
slug: auth-gateway-poc
status: design-approved
---

# Auth Gateway — Brainstorm Summary & POC Design

## 1. Problem Statement

Team kỹ thuật xây nhiều app "vibe coding" (AI tools nội bộ) — phần lớn chưa có auth hoặc chỉ auth sơ sài. Cần một **gateway authentication tập trung** để:

- Cung cấp SSO duy nhất cho toàn bộ apps nội bộ
- Hỗ trợ **2 mode tích hợp**: (a) OIDC client cho app sửa được code, (b) forward-auth proxy cho app zero-auth
- Tích Google Workspace (IdP nguồn của nhân viên) + bật MFA/Passkey policy
- Self-host trên Docker Compose / VPS, 1 instance phục vụ 5–15 apps, <1k internal users
- Vận hành đơn giản, vibe coders có thể self-serve onboard app mới

## 2. Constraints (xác nhận từ user)

| Khoản | Quyết định |
|---|---|
| License | AGPL chấp nhận (self-host nội bộ) |
| Scale | 5–15 apps, <1k users |
| Audience | Internal employees only |
| IdP source | Google Workspace |
| Features bắt buộc | Social login, MFA/2FA/Passkeys |
| Features KHÔNG cần | SAML, hard multi-tenant isolation |
| Infra | Docker Compose / VPS |
| Tích hợp | Cả OIDC redirect lẫn forward-auth proxy |

## 3. Approaches Evaluated

### A — Authentik (MIT) ⭐
**Pros**: 1 tool cho cả OIDC + forward-auth (Outpost); MIT; Application Catalog UI; ~500MB RAM; flow designer trực quan; broker Google Workspace native; onboard app mới 5–10 phút.
**Cons**: Community nhỏ hơn Keycloak; ít "enterprise polish" so Zitadel; Python/Django stack (cần familiar).

### B — Zitadel (AGPL) + oauth2-proxy
**Pros**: OIDC certified; passkeys/MFA tốt; audit event-sourced; UI hiện đại; multi-org hierarchy (nếu cần sau này).
**Cons**: Không có forward-auth native → phải chạy oauth2-proxy thêm (2 systems); over-engineered cho scale này; self-host docs gaps; recent CVE high-severity; AGPL.

### C — Keycloak (Apache 2.0) + oauth2-proxy — **loại**
JVM ~1GB RAM, cấu hình verbose, cùng vấn đề 2-systems như B. Không có lý do chọn ở scale này.

### D — Pomerium/Authelia — **loại**
Mạnh về identity-aware proxy nhưng user management yếu, không phù hợp khi cần email/password + social fallback.

## 4. Recommended Plan — Parallel POC (A vs B)

Mục tiêu: trong **1–2 tuần** chạy 2 POC giống hệt nhau về scope, so sánh ops effort & DX, chọn winner.

### Scope chung cho cả 2 POC

| Mục | Yêu cầu |
|---|---|
| Edge proxy | Traefik trên 1 VPS, TLS Let's Encrypt |
| DB | Postgres 16 (shared container) |
| IdP source | Google Workspace OIDC |
| MFA | Bật policy: passkey ưu tiên, TOTP fallback |
| App OIDC mẫu | 1 app demo (Next.js hoặc app team đang có sẵn) tích OIDC redirect |
| App forward-auth mẫu | 1 app zero-auth (vd static dashboard / Grafana / pgAdmin) protect qua proxy |
| Domain | `auth.<internal>.example` cho gateway, `app1.<internal>.example` / `app2.<internal>.example` |

### POC-A: Authentik
- 1 docker-compose: `traefik + postgres + authentik-server + authentik-worker + redis`
- Cấu hình Google Federation source
- Tạo 1 OIDC Provider (cho app OIDC) + 1 Proxy Provider Outpost (cho app forward-auth)
- Đo: thời gian onboard app mới, RAM/CPU steady-state, số lần restart, dev experience

### POC-B: Zitadel + oauth2-proxy
- 1 docker-compose: `traefik + postgres + zitadel + oauth2-proxy`
- Cấu hình Google IDP trong Zitadel
- Tạo Project + 2 Application (1 OIDC web, 1 cho oauth2-proxy)
- oauth2-proxy attach Traefik forwardAuth middleware cho app zero-auth
- Đo các metric tương tự

### Tiêu chí so sánh (đánh giá khi POC xong)

| Tiêu chí | Trọng số |
|---|---|
| Số bước onboard app mới (ít hơn = tốt) | High |
| RAM/CPU steady-state | Medium |
| Forward-auth DX (header injection, error pages) | High |
| Khả năng self-serve cho dev khác | High |
| Chất lượng admin UI | Medium |
| Tài liệu & community signal | Medium |
| Số lỗi/restart trong 1 tuần chạy | High |

## 5. Architecture (chung cho cả 2 POC)

```
                    Google Workspace
                          │ OIDC federation
                          ▼
   ┌─────────────────────────────────────┐
   │  Traefik (TLS, routing, fwdAuth)    │
   └──┬──────────────┬──────────────┬────┘
      │              │              │
      ▼              ▼              ▼
  Auth Provider   App-OIDC      App-ZeroAuth
  (Authentik /    (redirect      (fwdAuth
   Zitadel)       to /auth)       middleware
      │                            checks session
      ▼                            via Outpost/
   Postgres                        oauth2-proxy)
```

## 6. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Single point of failure (1 VPS) | POC chấp nhận; production thêm replica + managed Postgres |
| Lost MFA device khi <1k users | Procedure: admin có thể disable MFA của user qua admin UI |
| AGPL exposure (POC-B) | Chỉ self-host nội bộ, không phân phối → safe |
| Vibe coders quên rotate client secrets | Dùng PKCE cho public clients, secret rotation policy 90 ngày |
| Domain cookie scoping | Tất cả apps cùng parent domain `*.<internal>.example` để fwdAuth cookie hoạt động |

## 7. Success Criteria (cho cả POC)

- [ ] Login Google Workspace → MFA prompt → vào app OIDC thành công
- [ ] Truy cập app zero-auth → bị redirect login → sau khi auth, headers user/email được inject vào upstream
- [ ] Onboard app mới (OIDC) trong <15 phút bởi 1 dev chưa từng dùng tool
- [ ] Onboard app mới (forward-auth) trong <10 phút
- [ ] Tài liệu "How to add your app" viết được trong 1 trang
- [ ] Không crash trong 7 ngày uptime POC

## 8. Next Steps

1. ✅ Brainstorm done (file này)
2. ➡️ `/ck:plan` để tạo plan triển khai 2 POC song song với phase chi tiết
3. POC implementation (2 nhánh độc lập, có thể parallel)
4. Demo + chọn winner sau 1–2 tuần
5. Plan production rollout cho winner (HA, backup, monitoring)

## 9. Open Questions

- Domain cho gateway đã có chưa? Cần Cloudflare/DNS access cho Let's Encrypt DNS-01?
- VPS spec hiện có là gì? (RAM/CPU/storage) — ảnh hưởng quyết định self-host Postgres trên cùng VM hay managed.
- Có yêu cầu audit log gửi ra SIEM/ELK không?
- Khi 1 app cần "service-to-service" auth (machine-to-machine), có yêu cầu client_credentials grant không?
