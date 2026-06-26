# Zitadel as Centralized Auth Gateway: Research Report

## Executive Summary

**Verdict:** Zitadel is a strong candidate for multi-project SSO in a small team, but AGPL 3.0 licensing (May 2025) introduces legal risk, and operational complexity on self-hosting is non-trivial. Better fit than Keycloak for this use case; comparable to Authentik (which has MIT license + proxy mode). Recommend Authentik as safer default unless multi-tenancy hierarchy is critical.

---

## 1. Core Architecture & Capabilities

**Architecture:**
- Event-driven, immutable audit trail (all mutations are events)
- Single Go binary + Next.js UI + PostgreSQL (CockroachDB deprecated)
- Hierarchy: Instance → Organizations → Projects → Applications
- OIDC certified (OpenID Foundation), supports OAuth 2.0, SAML 2.0, identity brokering

**Auth Flows:**
- Authorization Code Flow + PKCE (primary)
- Client Credentials (M2M)
- Refresh tokens, device authorization
- Passkeys/FIDO2, WebAuthn, U2F
- OTP (email, SMS, authenticator)
- Social login via identity brokers
- No LDAP/Kerberos/RADIUS

**Multi-Tenancy Model** (standout feature):
- Strict isolation: Instance > Org > Project > App
- Each org owns users, branding, security policy, external IdP config
- Grant projects to other orgs without duplication
- Delegated admin (ORG_OWNER can assign roles, configure SSO)
- Ideal for B2B; overkill for small team using single namespace

---

## 2. Deployment & Operations

### Self-Hosting Requirements

**Database:**
- PostgreSQL 14–18 required (CockroachDB no longer default)
- Single-node testing acceptable; production requires 3+ replicas

**Infrastructure:**
- Docker Compose: Minimal setup (API + Login UI + Postgres)
- Kubernetes: Helm charts provided; 3-node reference architecture; requires HTTP/2 (h2c) support
- Resource footprint: ~100 MB RAM for API, network calls from Login UI to API

**Estimated Setup Effort:**
- ~2–4 hours: Docker Compose POC on local machine
- ~1–2 days: Production-grade Kubernetes with monitoring, SSL, backups, failover

### Operational Complexity (High Alert)

**Known Pitfalls:**
1. **Init-time env behavior:** Environment variables applied only at boot; config mistakes hard to diagnose
2. **Actions V2 webhook model:** JavaScript execution migrated to external webhooks; adds latency, failure modes, operational overhead
3. **API lifecycle churn:** Legacy v1 surfaces deprecated/removed; v2 user API silently skips email verification
4. **Security patch burden:** High-severity issues (SSRF, account takeover, auth bypass) require disciplined upgrade cadence
5. **Documentation gaps:** Guides assume Zitadel Cloud; self-hosting setup for email, branding, social login under-documented
6. **Two-container architecture:** Login UI as separate service; volume permissions, PAT exchange, complexity
7. **Breaking changes:** May 2025 AGPL switch; recent major versions require migration planning

**Reference:** A 2025 field report noted self-hosting "feels brittle" due to architectural churn (Login V2 split, Actions runtime ambiguity, configuration fragility).

---

## 3. Integration Effort

**Downstream App Integration (Low barrier):**
- Standard OIDC client setup: register redirect URI, client ID, client secret
- Discovery endpoint auto-resolves login/logout/token endpoints
- SDKs available: Go, Node.js, Python, Java, Rust, PHP, Ruby, Elixir, Dart/Flutter
- OIDC libraries work with Zitadel out-of-box (no vendor lock-in)
- Estimated per-app effort: 2–4 hours (OIDC setup + redirect URI config + local test)

**Multi-Project Setup:**
- Create Organization → Project → Application per downstream app
- Assign roles, grant org access, configure IdP per org
- Admin delegation possible (small team can self-serve after initial setup)
- Effort: ~30 min per app after first one

---

## 4. Competitive Landscape

| Feature | Zitadel | Keycloak | Authentik | Authelia |
|---------|---------|----------|-----------|----------|
| **License** | AGPL 3.0 (was Apache 2.0) | Apache 2.0 | MIT | MIT |
| **Multi-tenancy** | Built-in hierarchy | Realms (basic) | Organizations (newer) | Not designed for it |
| **Proxy mode** | No | No | Yes (differentiator) | Yes (lightweight) |
| **OIDC/OAuth2** | Certified | Yes | Yes | Yes |
| **Passkeys/MFA** | Yes | Yes | Yes | Partial |
| **Self-host complexity** | Medium-high | High | Medium | Low |
| **Resource footprint** | Low–Med | High | Medium | Very low (<30 MB) |
| **B2B readiness** | Strong | Adequate | Growing | No |
| **Community maturity** | 2019+, high velocity | 2005+, large | 2020+, moderate | 2017+, niche |

**Recommendation by Use Case:**
- **B2B SaaS, multi-org isolation required:** Zitadel (if AGPL acceptable)
- **Small team, multiple projects, simplicity priority:** Authentik (MIT license, proxy mode bonus)
- **Lightweight, reverse-proxy only, zero custom config:** Authelia
- **Broad extensibility, large community, avoid AGPL:** Keycloak

---

## 5. Licensing Impact (Critical)

**May 2025 License Change:**
- Zitadel switched from Apache 2.0 to AGPL 3.0
- AGPL copyleft: modifications must be disclosed; "Zitadel as part of application" may trigger open-source requirement
- SDKs, selected directories retain Apache 2.0/MIT
- **Risk for closed-source company:** Requires legal review before embedding in proprietary systems (e.g., ERPs)
- **Self-hosted internal tool:** Lower risk, but still a compliance obligation

**Competitors:**
- Authentik: MIT (very permissive)
- Keycloak: Apache 2.0 (standard permissive)
- Authelia: MIT

---

## 6. Vietnam/SEA Context

**Latency:** No documented regional hosting in Vietnam; Zitadel Cloud regions are US, EU, Switzerland, Australia. Self-hosting on local VPS eliminates latency.

**Language Support:** English primary; no evidence of Vietnamese UI. Not a blocker for internal tooling.

**Compliance:** Zitadel (Swiss company) simplifies EU GDPR; no special advantage for Vietnam/SEA jurisdiction.

---

## 7. Recommended Setup (if proceeding with Zitadel)

1. **Self-host on Docker Compose** (dev/test): Quick POC, understand operational surface
2. **Kubernetes Helm** (production): 3-node cluster, managed Postgres, S3 backups, monitoring
3. **Minimal config:** One org, one project, ~3–5 apps; avoid custom Actions (webhook overhead)
4. **Integration pattern:** Each downstream app = OIDC client; login redirects to Zitadel
5. **Ops cadence:** Monthly security patch reviews; upgrade quarterly

---

## 8. Known Gotchas & Mitigation

| Gotcha | Impact | Mitigation |
|--------|--------|-----------|
| Init-time env variables | Config mistakes survive restart | Document all env vars; use ConfigMap in k8s |
| Login V2 split | Complex architecture | Stick to standard OIDC flows; avoid custom UI |
| Actions V2 webhooks | Latency, operational burden | Use pre-built flows; avoid custom webhook actions |
| API deprecation (v1→v2) | Breaking integration | Target v2 APIs early; monitor release notes |
| AGPL compliance | Legal review needed | Consult counsel; consider Authentik if risk-averse |
| PostgreSQL version mismatch | Startup failures | Run PG 14–18; verify before upgrade |

---

## 9. Adoption Risk Assessment

| Dimension | Risk | Notes |
|-----------|------|-------|
| **Maturity** | Low | Stable core, but active churn in extensions/actions |
| **Community** | Medium | Smaller than Keycloak; response times variable |
| **Ops complexity** | Medium-High | Self-hosting is tested as afterthought per field reports |
| **Vendor** | Medium | Team-driven; no SLA except commercial support plan |
| **Breaking changes** | Medium | License switch, API deprecations, v1→v2 migration |
| **Security** | Low-Medium | Regular patches; recent high-severity findings; upgrade discipline required |

---

## 10. Unresolved Questions

1. Does your team have legal review capacity for AGPL compliance? (If no, prefer Authentik/Keycloak)
2. Is multi-org hierarchy (Zitadel's killer feature) needed, or is single namespace sufficient?
3. How many downstream apps are we securing? (5–10 = straightforward; 50+ = automation needed)
4. Can team handle weekly security patch reviews? (Zitadel patch cadence is not trivial)
5. Is self-hosting mandatory (cost, compliance) or is managed SaaS acceptable? (Zitadel Cloud free tier: 100 DAU)

---

## Conclusion

Zitadel is **viable for small-team multi-project SSO** if:
- AGPL licensing is acceptable (internal tool or legal review done)
- Multi-org isolation is desirable (even if not immediately used)
- Team can tolerate medium operational complexity
- Downstream apps can use standard OIDC

Otherwise, **Authentik is the safer choice** (MIT license, proxy mode, lower ops burden).

**Next steps:** POC Docker Compose setup (2 hrs) to evaluate operational fit; parallel legal review of AGPL terms if proprietary integration is planned.

---

**Sources:**
- [Zitadel GitHub](https://github.com/zitadel/zitadel)
- [Zitadel vs. Keycloak Comparison](https://zitadel.com/blog/zitadel-vs-keycloak)
- [Authentik vs. Zitadel 2026 Comparison](https://wz-it.com/en/blog/authentik-vs-zitadel-identity-provider-comparison/)
- [Keycloak vs Authentik vs Zitadel 2026 Deep Dive](https://blog.houseoffoss.com/post/keycloak-vs-authentik-vs-zitadel-2026-which-open-source-login-tool-should-you-use)
- [Brittle Zitadel: Self-Hosting Field Report](https://medium.com/@nirajkvinit/brittle-zitadel-why-self-hosting-feels-brittle-and-what-to-do-next-70566cfc43a1)
- [Why We Stopped Recommending ZITADEL for Self-Hosting](https://dev.to/nirajkvinit1/why-we-stopped-recommending-zitadel-for-self-hosting-a-developers-field-report-4fdl)
- [Zitadel Deployment Documentation](https://zitadel.com/docs/self-hosting/deploy/overview)
- [OIDC Integration Guide](https://zitadel.com/docs/guides/integrate/login/oidc/login-users)
- [Multi-Tenancy and Delegated Access](https://zitadel.com/blog/multi-tenancy-with-organizations)
- [Production Checklist](https://zitadel.com/docs/self-hosting/manage/productionchecklist)

**Status:** DONE
