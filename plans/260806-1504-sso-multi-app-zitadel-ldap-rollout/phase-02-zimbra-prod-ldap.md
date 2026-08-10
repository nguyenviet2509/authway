# Phase 2 — Zimbra prod LDAP integration

**Effort:** 0.5d
**Status:** pending
**Depends on:** Phase 1 (Zitadel prod running) + Zimbra prod ready

## Context
- Plan: [../plan.md](../plan.md)
- Lab reference: `authway/plans/260806-0939-zitadel-ldap-zimbra-lab/` (đã verify end-to-end)
- Zimbra prod: host + admin access (user cung cấp)

## Objective
Config Zitadel prod → Zimbra prod LDAP IdP, hoạt động end-to-end. Bắt buộc LDAPS (không plaintext LDAP).

## Prerequisites
- ✅ Zimbra prod running
- ✅ Zimbra admin CLI access
- ✅ Firewall Zimbra: allow inbound 636/TCP từ Zitadel prod IP
- ✅ Zimbra LDAPS cert valid (self-signed OK nếu trust ở Zitadel side)

## Steps

### 1. Zimbra bind service account (prod)
```bash
ssh zimbra-mail-prod
sudo -u zimbra bash
BIND_PW=$(openssl rand -base64 24)
zmprov ca zitadel-bind@<prod-domain> "$BIND_PW" \
  displayName "Zitadel LDAP Bind Service (prod)" \
  zimbraMailStatus disabled \
  zimbraFeatureMailEnabled FALSE \
  description "Read-only bind for Zitadel prod IdP"
echo "$BIND_PW"  # LƯU BITWARDEN NGAY
```

### 2. LDAPS verify (từ Zitadel prod)
```bash
ssh <zitadel-prod-vps>
docker run --rm alpine sh -c "apk add --no-cache openldap-clients ca-certificates >/dev/null 2>&1 && ldapwhoami -x -H ldaps://<zimbra-prod-host>:636 -D 'uid=zitadel-bind,ou=people,dc=<prod-domain>' -w '<paste-pw>' -o tls_reqcert=allow"
```

Expected: `dn:uid=zitadel-bind,ou=people,dc=<prod-domain>` — bind OK.

### 3. Cross-domain search test
```bash
ldapsearch -x -H ldaps://<zimbra-prod-host>:636 \
  -D 'uid=zitadel-bind,ou=people,dc=<prod-domain>' -w '<pw>' \
  -b 'dc=<top-tld>' '(mail=*)' mail -o tls_reqcert=allow | grep '^mail:' | wc -l
```

Verify returns > 0 entries.

### 4. Zitadel prod — Add LDAP IdP (Instance level)
Console `https://auth.inet.vn/ui/console/instance` → Identity Providers → Add → Active Directory / LDAP.

Config (kế thừa lab):
- Name: `Zimbra Mail (Prod)`
- Servers: `ldaps://<zimbra-prod-host>:636`
- StartTLS: OFF (dùng LDAPS trực tiếp)
- BaseDN: `dc=<top-tld>` (broader cho multi-domain)
- BindDN + BindPassword từ step 1
- User Base: `dc=<top-tld>`
- User Filter: `mail`
- User Object Classes: `inetOrgPerson`, `zimbraAccount`
- Timeout: 5s

Attribute mapping (từ lab):
- ID: `entryUUID`
- Username: `mail`
- Email: `mail`
- First Name: `cn` (fallback vì givenName không phổ biến trên Zimbra)
- Last Name: `sn`
- Display Name: `cn`
- Preferred Username: `mail`

Options: Automatic creation ✅, Automatic update ✅.

### 5. Instance Login Policy config
- `ignoreUnknownUsernames: true`
- `allowExternalIdp: true`
- `allowRegister: true`
- `forceMfa: false` (defer bật MFA sau khi baseline pass)
- Attach IdP "Zimbra Mail (Prod)" vào policy

### 6. E2E test T1-T6 (kế thừa từ lab)
Tạo user test prod:
```bash
sudo -u zimbra zmprov ca ldap-test@<prod-domain> 'TestSSO2026' displayName "LDAP Test" sn "Test"
```

**Test cases:**
- T1: happy path login
- T2: wrong password → reject
- T3: non-existent user → reject
- T4: cross-domain user (nếu có nhiều domain)
- T5: disabled account (`zimbraAccountStatus locked`) → reject
- T6: attr sync (update `displayName` trên Zimbra, re-login, verify Zitadel sync)

**Nếu Zitadel v4.16 vẫn có bug SSR:** dùng URL workaround từ lab (paste requestId + idpId manually) hoặc fallback OIDC direct.

Cleanup: `zmprov da ldap-test@<prod-domain>`.

### 7. Firewall rule Zimbra prod
- Allow inbound 636/TCP từ Zitadel prod IP (specific /32)
- Deny 389 (plaintext) từ mọi nơi ngoài internal
- Document rule ID cho rollback

## Deliverables
- Zimbra bind account tạo + password Bitwarden
- LDAPS reachability verified
- Zitadel prod IdP "Zimbra Mail (Prod)" active
- Instance Login Policy configured
- E2E test T1-T6 pass hoặc documented workaround
- Doc: `authway/docs/zitadel-ldap-zimbra-integration.md` update sang prod values

## Success criteria
- ✅ LDAPS bind từ Zitadel prod → Zimbra prod OK
- ✅ T1 happy path pass (hoặc workaround documented)
- ✅ T2, T3, T5 reject đúng
- ✅ Attr sync T6 pass
- ✅ Doc cập nhật prod values

## Risks

| Risk | Mitigation |
|---|---|
| Zimbra LDAPS cert self-signed → Zitadel reject | Config `tls_reqcert=allow` hoặc import CA cert vào Zitadel trust store |
| Zimbra firewall block Zitadel outbound | Coordinate với Zimbra ops mở 636/TCP whitelist Zitadel IP |
| Multi-domain Base DN quá rộng → search chậm | Scope theo `dc=<company-tld>` thay vì `dc=vn` |
| Bug SSR Zitadel v4.15 vẫn còn | Track 2 fallback (OIDC direct với Zitadel local user tạm) |

## Next → Phase 3
oauth2-proxy IAP baseline deploy.
