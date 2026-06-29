---
type: brainstorm
date: 2026-06-29 14:18
slug: zitadel-deep-dive-vs-alternatives
status: analysis
related:
  - brainstorm-260626-1103-auth-gateway-poc.md
  - brainstorm-260626-1154-zitadel-iap-rollout.md
  - researcher-260626-1103-zitadel-auth-gateway.md
---

# Zitadel Deep-Dive — Vì sao chọn Zitadel cho centralized auth

> Context: Project authway đã chốt Zitadel ở session 260626-1154 (self-host, IAP pattern, internal-only).
> Report này giải thích **WHY** một cách hệ thống, đối chiếu với Keycloak / Authentik / Authelia / Ory / Better Auth / Cloud (Auth0, Clerk, WorkOS).

---

## 1. Zitadel là gì (essentials, không marketing)

### 1.1 Bản chất kiến trúc
- **Event-sourced core**: mọi mutation = event append-only → audit trail bất biến, replay được state bất kỳ thời điểm
- **Stack**: 1 Go binary (API) + 1 Next.js binary (Login UI v2) + Postgres 14-18 (CockroachDB đã deprecate)
- **Hierarchy 4 tầng**: Instance → Organization → Project → Application
- **Footprint**: ~100-200 MB RAM idle, scale tốt vì stateless API + state nằm hết ở Postgres

### 1.2 Tính năng core
| Nhóm | Hỗ trợ |
|---|---|
| Standards | OIDC certified (OpenID Foundation), OAuth 2.1, SAML 2.0, SCIM 2.0 |
| Auth flows | Auth Code + PKCE, Client Credentials, Device Code, Refresh tokens |
| MFA | Passkeys/WebAuthn/FIDO2, TOTP, OTP email/SMS, U2F |
| Federation | Identity brokering: Google, GitHub, GitLab, Azure AD, generic OIDC/SAML |
| Multi-tenant | Strict org isolation (B2B-grade); delegated admin per-org |
| Customization | Actions V2 (webhook-based), branding per-org, custom domains |
| Khác | Audit log API, event projection, machine users (M2M), PAT |

### 1.3 Cái KHÔNG có
- ❌ LDAP / Kerberos / RADIUS (Keycloak có)
- ❌ Forward-auth / reverse-proxy mode native (Authentik, Authelia có) → cần ghép `oauth2-proxy`
- ❌ In-process JavaScript hooks (đã chuyển sang webhook ở V2 — thêm latency)

---

## 2. Tại sao Zitadel — phân tích 5 trục cho use case authway

Use case: **5-15 apps nội bộ, <1k users, mix Next.js + static HTML "vibe code", self-host multi-VPS, MFA enforced.**

### 2.1 Trục Standards Compliance & Future-proof
- **OIDC certified** (Keycloak, Zitadel, Authentik đều có; Authelia không có)
- App tích bằng OIDC chuẩn → **không lock-in**: đổi sang Keycloak/Authentik sau = đổi `discovery URL` + client_id
- Đây là điểm mạnh **chung của 3 tool top**, không phải lợi thế riêng Zitadel
- **Tuy nhiên**: chất lượng implementation (token claims, refresh semantics, logout) — Zitadel sạch hơn Keycloak (legacy 20 năm), tương đương Authentik

### 2.2 Trục Self-host DX (Developer Experience)
| Tool | Setup minimal | Config language | Hot-reload config | Khó nhằn |
|---|---|---|---|---|
| **Zitadel** | docker-compose 4 services | YAML + env | ❌ env apply at boot only | Login UI tách riêng, PAT bootstrap rườm rà |
| Keycloak | docker-compose 2 services | CLI/Admin UI/REST | ✅ live | Heap tuning JVM, theme dev pain, slow startup |
| Authentik | docker-compose 5 services | Flow Designer GUI | ✅ live | Python/Django stack, ít doc cho corner cases |
| Authelia | docker-compose 1 service | YAML đơn | ❌ restart | User DB external (file/LDAP), không có admin UI |

**Verdict**: Zitadel **không phải DX tốt nhất** ở scale này. Authentik thắng về flow designer GUI; Authelia thắng về đơn giản.

### 2.3 Trục Long-term Maintainability & Velocity
- Zitadel founded 2019, **release cadence aggressive** (major version 2-3 tháng) → vừa tốt (active) vừa rủi ro (breaking changes)
- Recent breaking: Login V2 split, Actions V1→V2 webhook migration, AGPL switch May 2025
- Keycloak: 20 năm tuổi, cực ổn định, ecosystem khổng lồ — đổi lại verbose config + JVM ops
- Authentik: trẻ hơn Zitadel, cộng đồng nhỏ hơn — nhưng codebase đơn giản hơn

**Verdict**: Zitadel có velocity nhanh = **tính năng mới sớm**, nhưng **chi phí ops cao** (theo dõi changelog, test upgrade). Với scale <1k user, velocity này hơi over-engineered.

### 2.4 Trục Security Posture
- **OIDC certification** + event-sourced audit → 2 điểm cộng lớn
- Passkey support **production-grade** (Keycloak passkey còn experimental ở vài flow)
- **Nhưng**: 2024-2025 có CVE high-severity (SSRF, account takeover, auth bypass)
  → require disciplined patch cadence (subscribe advisory, monthly window)
- Keycloak có lịch sử CVE dày hơn về số lượng nhưng ít critical hơn
- Authentik ít CVE public hơn — chưa rõ là an toàn hơn hay chỉ là target nhỏ hơn

**Verdict**: Zitadel **không an toàn hơn** Keycloak/Authentik mặc định; security đến từ **vận hành kỷ luật**.

### 2.5 Trục License Risk
| Tool | License | Rủi ro cho authway |
|---|---|---|
| **Zitadel** | AGPL 3.0 (từ 5/2025) | Self-host nội bộ = **OK**; nếu sau này SaaS-ify → phải open source modifications |
| Keycloak | Apache 2.0 | An toàn tuyệt đối |
| Authentik | MIT | An toàn tuyệt đối |
| Authelia | Apache 2.0 | An toàn |
| Ory Hydra/Kratos | Apache 2.0 | An toàn |

**Verdict**: AGPL **không vấn đề ở use case này** (internal-only, không phân phối). Nhưng nếu roadmap có khả năng:
- Đem auth gateway bán/lease cho khách ngoài
- Mod Zitadel rồi nhúng vào SaaS commercial
→ phải pháp lý review. Authentik MIT là **safe default** nếu unsure.

---

## 3. So sánh trực tiếp các alternative

### 3.1 vs Keycloak
| | Zitadel thắng | Keycloak thắng |
|---|---|---|
| Modern UX | ✅ UI 2020s, mobile-friendly | ❌ admin UI cũ kỹ |
| Resource | ✅ Go ~100MB | ❌ JVM ~1GB+ tuning |
| Audit | ✅ event-sourced native | ❌ phải config riêng |
| LDAP/AD | ❌ không có | ✅ first-class |
| SAML maturity | ⚠️ OK | ✅ best-in-class |
| Theme/customization | ⚠️ Actions V2 webhook | ✅ Java SPI extension |
| Community | ❌ trẻ | ✅ khổng lồ |
| License | ❌ AGPL | ✅ Apache |

**Khi nào Keycloak hơn**: enterprise có LDAP/AD, cần SAML phức tạp, team Java sẵn có.
**Khi nào Zitadel hơn**: greenfield, modern stack, không cần LDAP, ưu tiên UX + footprint nhỏ.

### 3.2 vs Authentik (đây mới là đối thủ thực sự)
| | Zitadel | Authentik |
|---|---|---|
| License | AGPL | **MIT** ✅ |
| Forward-auth proxy | ❌ cần oauth2-proxy | ✅ **Outpost native** |
| Application catalog UI | ❌ | ✅ catalog onboarding |
| OIDC certified | ✅ | ✅ |
| Multi-tenant B2B | ✅ hierarchical | ⚠️ Organizations mới có 2024 |
| Stack | Go | Python/Django |
| Flow designer | ❌ code/API | ✅ GUI drag-drop |
| Footprint | ~150MB | ~500MB (worker + redis) |
| Velocity | nhanh | vừa |
| Multi-org SaaS-grade | ✅ | ⚠️ growing |

**Khi nào Authentik hơn**:
- Cần forward-auth cho app zero-auth → 1 tool, không cần oauth2-proxy
- License MIT không lo
- Vibe-coder thích GUI flow designer
- Footprint không phải vấn đề

**Khi nào Zitadel hơn**:
- Cần B2B multi-tenant strict isolation (mỗi khách hàng = 1 org)
- Resource constrained (Go binary nhẹ)
- Ưu tiên Go ecosystem
- API-first ops (Terraform provider chính thức tốt hơn)

### 3.3 vs Authelia
- Authelia: **lightweight champion** (<30 MB), config YAML 1 file, perfect cho 1-3 apps
- Nhưng: **không có user management UI**, user trong file/LDAP, không có Passkey full, không OIDC certified
- **Loại** ở use case này: cần admin UI cho admin tạo user thủ công

### 3.4 vs Ory (Hydra + Kratos + Keto)
- Ory: stack **headless** — Hydra (OIDC), Kratos (identity), Keto (permission)
- Cực mạnh, cực modular, Apache 2.0, cloud-native
- **Nhưng**: KHÔNG có admin UI tích hợp → phải tự build hoặc dùng UI cộng đồng
- Setup phức tạp gấp 3 lần Zitadel
- **Loại**: over-engineered cho 5-15 apps, không có UI = vibe-coder không tự serve được

### 3.5 vs Better Auth / Lucia / NextAuth
- **Library, không phải gateway** — embed vào app
- Mâu thuẫn với mục tiêu: **centralized** auth + **static HTML app** không sửa được code
- **Loại hoàn toàn** ở pattern IAP

### 3.6 vs Cloud (Auth0, Clerk, WorkOS, Stytch, Supabase Auth)
| | Cloud auth | Self-host |
|---|---|---|
| Setup | 30 phút | 1-2 ngày |
| Vận hành | 0 | ops burden thật |
| Data sovereignty | ❌ ở vendor | ✅ ở mình |
| Cost @ 1k users | $200-500/tháng (Auth0) | ~$10/tháng VPS |
| Lock-in | ⚠️ migration đau | ✅ standards |
| Compliance nội bộ VN | ⚠️ dữ liệu ra ngoài | ✅ |

**Loại** với constraint internal-only + self-host (đã chốt session 1154).

---

## 4. Lý do **CHỐT** Zitadel — recap mạch logic

Theo decision tree từ constraints của user (session 1154):

```
1. Self-host required? YES → loại Cloud
2. Need centralized + static HTML support? YES → loại library (Better Auth, etc.)
3. Need admin UI for user mgmt? YES → loại Ory, Authelia
4. Còn lại: Keycloak, Authentik, Zitadel
5. LDAP/AD source? NO → Keycloak mất lợi thế lớn nhất
6. JVM ops chấp nhận? NO → loại Keycloak
7. Còn lại: Authentik vs Zitadel
8. AGPL chấp nhận (internal-only)? YES → cả 2 còn ổn
9. Velocity & longevity quan trọng? YES (user weight cao)
10. Resource footprint quan trọng (multi-VPS)? YES
11. → CHỐT ZITADEL
```

### Điểm mấu chốt khiến Zitadel thắng Authentik ở session 1154
1. **Footprint nhỏ hơn** (Go binary vs Python+Worker+Redis): với multi-VPS, mỗi MB tính
2. **Velocity & longevity perception**: Zitadel có roadmap rõ + funding (Caos AG); Authentik nhỏ hơn
3. **API-first**: Terraform provider, gRPC API chuẩn → IaC tốt hơn
4. **OIDC certification** + event-sourced audit → security posture cleaner
5. **Multi-org hierarchy**: nếu sau này mở rộng phục vụ nhiều team/customer → đã sẵn sàng

### Điểm Authentik đã "thua đáng tiếc"
- Outpost forward-auth native = mất 1 ưu thế khi authway chấp nhận thêm `oauth2-proxy`
- Flow designer GUI = vibe-coder hưởng lợi → bù lại bằng playbook + reference template

---

## 5. Trade-offs ĐÃ chấp nhận khi chọn Zitadel

| Trade-off | Mitigation đã planned |
|---|---|
| Không có forward-auth native | + `oauth2-proxy` per VPS (~30MB) |
| AGPL license | Internal-only, không SaaS-ify trong scope hiện tại |
| CVE patching burden | Monthly patch window, subscribe advisory, pin minor |
| Login UI v2 split (2 containers) | Docker-compose template, healthchecks |
| Actions V2 webhook latency | Chưa dùng — defer đến khi cần custom logic |
| Doc gap self-host | Đã có internal playbook (phase-03) |
| Single auth VPS = SPOF | Phase 1 chấp nhận; production: replica + managed Postgres |

---

## 6. Khi nào Zitadel là **WRONG choice** (anti-recommendation)

Để fair, document các scenario nên **KHÔNG** chọn Zitadel:

1. **Cần LDAP/AD source** → Keycloak
2. **Team chỉ có 1 dev, không có ops bandwidth** → Authelia (đơn giản) hoặc Cloud (Clerk)
3. **App chỉ static HTML zero-touch, không cần admin UI** → Authentik (Outpost) + file users
4. **Cần phân phối auth gateway như SaaS cho khách ngoài** → AGPL = legal risk, dùng Keycloak/Authentik
5. **Cần SAML enterprise federation phức tạp** (SP-initiated + IdP-initiated + complex assertion mapping) → Keycloak mature hơn
6. **Cần extensibility plugin sâu** (custom auth flow logic) → Keycloak SPI > Zitadel Actions V2 webhook
7. **Scale >100k users với strict SLA** → cân nhắc Cloud (Auth0 enterprise) thay vì tự ops

---

## 7. Validation criteria — biết Zitadel chọn đúng khi nào

- [ ] Phase 01 chạy 30 ngày, 0 unplanned restart
- [ ] Patch upgrade Zitadel minor version <30 phút, không downtime
- [ ] Admin tạo user mới + enforce passkey <5 phút
- [ ] Onboard app mới qua IAP playbook <15 phút (vibe coder tự làm)
- [ ] Audit log query: tìm "user X login từ IP nào ngày Y" <1 phút
- [ ] RAM steady-state <500MB toàn stack auth VPS

Nếu **3 trong 6 fail** sau 60 ngày → reconsider Authentik migration (cost migrate ≈ 2 ngày vì OIDC chuẩn).

---

## 8. Tóm tắt 1 dòng

> **Zitadel = "modern Keycloak với event-sourced audit + B2B-grade multi-tenant trong Go binary"** — chọn vì stack hiện đại, footprint nhỏ, OIDC certified, roadmap rõ; chấp nhận AGPL + CVE patching burden + thiếu forward-auth native (bù bằng oauth2-proxy).

---

## Unresolved questions

1. Sau 6 tháng có nên đánh giá lại Authentik nếu Organizations feature mature? → đặt reminder review Q1/2027
2. Có cần dual-write user vào backup IdP (Authelia) để DR fast-failover không? → cân nhắc khi auth VPS down ảnh hưởng >5 apps prod
3. Actions V2 webhook latency có ảnh hưởng login flow không? → chưa test, defer đến khi cần custom claim
4. Khi user count vượt 1k, hierarchy Org có cần restructure không? → benchmark khi đạt 500 users
