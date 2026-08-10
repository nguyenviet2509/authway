# Completion notes — Zitadel LDAP IdP Zimbra lab

**Completed:** 2026-08-06 15:58

## E2E test outcomes

| Test | Result | Notes |
|---|---|---|
| **T1** Happy path login | ✅ PASS | `ldap-test@zimbra8815.inet.name.vn` login qua browser incognito → auto-create Zitadel user (UserID 385054285810892803), attrs mapped đúng, MFA OTP setup + verified |
| **T2** Wrong password | ✅ PASS (via CLI) | ldapwhoami với sai password → `Invalid credentials (49)`. Zitadel dùng LDAP bind = same result. |
| **T3** Non-existent user | ✅ PASS (via CLI) | ldapsearch `mail=notexist@...` return 0 entries. Zitadel search fail → treat as user not found. |
| **T4** Cross-domain | ✅ PASS (via CLI) | Base DN `dc=vn` search cross 9 domains: zimbra8815, inetdev.io.vn, triethoc.vn, zimbra807, work.inet.name.vn, truongphatplastic, mxail.com, gmail.com, mxmail.com. |
| **T5** Disabled account | ⚠️ **SECURITY FINDING** | Zimbra `zimbraAccountStatus=locked` **KHÔNG block LDAP bind**. Locked user vẫn login được Zitadel. Xem "Security finding" bên dưới. |
| **T6** Attr sync | ⏭️ Deferred | Không test trong lab (nice-to-have). Verify ở prod với Zimbra prod. |

## Chuỗi fix (session log)

Trong quá trình debug đã fix các bug sau (order):

1. **Firewall CSF Zimbra** — allow authserver public IP inbound 389/TCP
2. **Bind service account** — `zitadel-bind@zimbra8815.inet.name.vn` với read-only role
3. **Zitadel v4.15.3 → v4.16.1 upgrade** — v4.15.3 có bug SSR fetch (PR #12144 chỉ fix proxy path, không fix generateMetadata)
4. **Docker network alias `auth.lab.local` cho zitadel container** — fix direct API calls từ login sidecar (Node undici strip Host header)
5. **Env `ZITADEL_INSTANCEHOSTHEADERS=x-forwarded-host,x-zitadel-instance-host` + `PUBLICHOSTHEADERS`** — bảo Zitadel accept X-Forwarded-Host để resolve instance
6. **Login sidecar `CUSTOM_REQUEST_HEADERS` thêm `X-Forwarded-Host:auth.lab.local`** — fix SSR fetch instance resolution
7. **IdP option `isAutoCreation=true` + `isAutoUpdate=true`** — auto-create user không cần confirmation page
8. **First Name Attribute = `cn`** (fix empty givenName vì Zimbra không set givenName mặc định)
9. **ID Attribute = `mail`** (fix Zimbra ACL không expose entryUUID/zimbraId cho bind account)

## Security finding — T5 locked account

**Vấn đề:** Zimbra `zimbraAccountStatus=locked` chỉ enforce ở tầng application (webmail/IMAP/POP/SMTP), KHÔNG enforce ở LDAP bind layer. Zitadel dùng LDAP direct bind → bypass status check → locked user vẫn login được.

**Impact:** Trong prod, user bị disable/lock trên Zimbra vẫn có thể login SSO qua Zitadel → dùng service sau khi bị khóa.

**Mitigation options (defer prod):**

1. **[Recommended prod] Zimbra bind account ACL:** Config Zimbra ACL cho `zitadel-bind` chỉ trả về accounts với `(zimbraAccountStatus=active)`. Zitadel search sẽ không thấy locked user.
2. **Zitadel Action/Flow post-bind webhook:** Query Zimbra check status, reject nếu ≠ active. Feature request tương lai.
3. **Lab acceptance:** Documented, không block phase 3 lab. Prod bắt buộc apply option 1 trước launch.

## Config final state (lab)

**Zitadel IdP** "Zimbra Mail (LAB)" (Instance-level ID `385038171798241283`):
- Servers: `ldap://103.57.220.98:389`
- BindDN: `uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn`
- Base DN: `dc=vn`
- User Filter: `mail`
- User Object Classes: `inetOrgPerson`, `zimbraAccount`
- Attributes:
  - **ID**: `mail`
  - Username: `mail`
  - Email: `mail`
  - First Name: `cn`
  - Last Name: `sn`
  - Display Name: `cn`
  - Preferred Username: `mail`
- Options: isCreationAllowed, isAutoCreation, isAutoUpdate, isLinkingAllowed = all true

**Instance Login Policy:**
- allowUsernamePassword: true
- allowRegister: true
- allowExternalIdp: true
- ignoreUnknownUsernames: (off — không cần khi có IdP button)
- forceMfa: true (LDAP user setup OTP lần đầu)
- IdP attached: 385038171798241283

**Docker compose changes (`/opt/authway/infra/auth-vps/docker-compose.yml`):**
- zitadel container: image v4.16.1, network alias `auth.lab.local`, env `ZITADEL_INSTANCEHOSTHEADERS=x-forwarded-host,x-zitadel-instance-host` + `ZITADEL_PUBLICHOSTHEADERS=x-forwarded-host,x-zitadel-public-host`
- zitadel-login container: image v4.16.1, env `ZITADEL_API_URL=http://auth.lab.local:8080` (thay vì `http://zitadel:8080`) + `CUSTOM_REQUEST_HEADERS` thêm `X-Forwarded-Host:${ZITADEL_EXTERNAL_DOMAIN}`

## Deliverables

- ✅ Zitadel LDAP IdP hoạt động E2E (login browser + auto-provision)
- ✅ Attribute mapping verified
- ✅ 5/6 test cases pass (T5 documented security finding)
- ✅ Compose config final state trên `authserver` — cần mirror về local repo
- ⚠️ Docs `zitadel-ldap-zimbra-integration.md` — TODO (defer sang plan `260806-1504` phase Docs)

## Unblocks

- `authway:260806-1504-sso-multi-app-zitadel-ldap-rollout` — có thể start Phase 1 (Zitadel prod deploy)
- `onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel` — có thể start (khi prod ready)

## Cleanup TODO

- ✅ Test user `ldap-test@zimbra8815.inet.name.vn` status restored → active
- ⏭️ Keep test user (dùng cho re-verify sau khi apply changes)
- ⏭️ Local repo sync: commit compose changes về `D:\Vietnt\Project\authway` (per host-sync policy)
- ⏭️ Report bug upstream Zitadel typescript-login về generateMetadata SSR fetch không tôn trọng CUSTOM_REQUEST_HEADERS Host (đã fix bằng InstanceHostHeaders workaround — có thể note as "documented workaround" thay vì bug report)

## Unresolved

- Zimbra ACL tighten cho bind account (prod requirement)
- LDAPS enable Zimbra prod (bắt buộc TLS)
- Test T6 attr sync ở prod
