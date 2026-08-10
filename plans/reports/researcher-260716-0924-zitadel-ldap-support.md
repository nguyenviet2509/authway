# Zitadel LDAP Support Research

**Date:** 2026-07-16  
**Status:** COMPLETE

---

## 1. LDAP as Identity Provider (Users authenticate via corporate LDAP)

**Supported:** YES, GA status.

Zitadel supports LDAP as an external identity provider. Users can log in with their corporate LDAP/Active Directory credentials, and Zitadel federates authentication to the LDAP server. This is the primary supported use case.

**Supported LDAP Servers:** Active Directory, OpenLDAP, FreeIPA, and other LDAP-compliant directories.

**Deployment Requirement:** Self-hosted Zitadel only. LDAP identity provider requires direct network access from the Zitadel instance to the LDAP server, so this is not available in Zitadel Cloud.

---

## 2. LDAP Server Mode (Legacy apps bind to Zitadel using LDAP)

**Supported:** NO.

Zitadel **cannot act as an LDAP server**. Legacy applications cannot bind to Zitadel using the LDAP protocol. This is a known limitation with active community interest (GitHub discussion #1929 since Sept 2020). The Zitadel team acknowledges the feature but states: "We currently lack the capacity to implement the LDAP server."

**Workaround:** Use a separate LDAP proxy/gateway (e.g., GlAuth) as an intermediary to serve LDAP while authenticating against Zitadel via OIDC/OAuth2.

---

## 3. LDAP Identity Provider Configuration

### Connection Setup
- **Server Format:** `ldaps://host:port` or `ldap://host:port`
- **Security:** LDAPS (recommended) or StartTLS. Plain LDAP transmits passwords in cleartext and is unsuitable for production.
- **Binding:** Use BindDN and BindPassword for administrative service account to perform user lookups.

### Attribute Mapping (Required)
- **ID Attribute** (mandatory): Unique identifier from LDAP (typically `uid` or `distinguishedName`)
- **First Name Attribute:** Maps to ZITADEL given name
- **Last Name Attribute:** Maps to ZITADEL family name
- **Email Attribute:** For email address
- **Preferred Username Attribute:** For login username

### User Search & Authentication
- **User Filter:** OR logic to match login credentials across multiple attributes (e.g., search by uid or mail)
- **BaseDN:** Directory search root (e.g., `ou=users,dc=example,dc=com`)

### Account Provisioning (JIT)
- **Automatic Creation:** If enabled, users are created automatically in Zitadel on first login if they don't exist. Requires mapping given name, family name, email, and preferred username attributes.
- **Automatic Update:** If enabled, user attributes sync on every login if changed in LDAP.
- **Account Linking:** Alternatively, existing Zitadel accounts can be linked to LDAP identities.
- **Requirement:** At least one of automatic creation or account linking must be enabled.

### Activation
- Provider must be explicitly activated after creation (UI or API)
- Organization's login policy must explicitly allow external identity provider authentication

---

## 4. Known Limitations & Gotchas

| Item | Detail |
|------|--------|
| **No LDAP Server Mode** | Zitadel cannot serve LDAP protocol to legacy apps. Not planned. |
| **Cloud Limitations** | LDAP IdP only works with self-hosted Zitadel, not Zitadel Cloud. |
| **No Plain LDAP** | Production deployments require LDAPS or StartTLS. Plain LDAP insecure. |
| **Self-Signed Certs** | Known issue: LDAPS with self-signed certs may fail with "certificate signed by unknown authority" (GitHub issue #7888). Workaround via custom CA trust. |
| **User Sync Only** | Zitadel does NOT sync all LDAP users to its database; only attributes of users who authenticate are copied. No directory sync feature. |
| **Unidirectional** | Changes in Zitadel user profiles are not written back to LDAP. |
| **Service Account Required** | Must provision a service account in LDAP for Zitadel to perform searches. |

---

## 5. Version Requirements

No specific version constraints documented. LDAP provider has been available since early Zitadel releases and is included in current stable versions (4.15+). Recent bug fixes include username filter escaping in LDAP authentication flow.

---

## 6. Official Documentation

- [Configure LDAP as an Identity Provider in ZITADEL](https://zitadel.com/docs/guides/integrate/identity-providers/ldap)
- [OpenLDAP Identity Provider Setup in ZITADEL](https://zitadel.com/docs/guides/integrate/identity-providers/openldap)
- GitHub Discussion: [ZITADEL as LDAP Server #1929](https://github.com/zitadel/zitadel/discussions/1929)
- GitHub Discussion: [A real LDAP integration? #6007](https://github.com/zitadel/zitadel/discussions/6007)

---

## Summary

**For authway project:**
- ✅ If users need to log in via corporate LDAP/AD → Zitadel supports this as IdP (self-hosted only)
- ❌ If legacy apps require LDAP server protocol to Zitadel → Not supported; needs external LDAP gateway
- 🔧 JIT provisioning is available; automatic user creation + attribute mapping works
- ⚠️ Production requires LDAPS/StartTLS and proper CA certificate management

**Recommendation:** Use LDAP as identity provider for user authentication. For legacy LDAP-only apps, deploy GlAuth or similar LDAP gateway as intermediary.

