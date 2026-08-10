# Phase 3 — E2E test + documentation

**Effort:** 0.5d
**Status:** pending
**Depends on:** Phase 2 (LDAP IdP configured)

## Context
- Plan: [../plan.md](../plan.md)
- Zitadel LDAP IdP đã live sau Phase 2

## Objective
Verify end-to-end login flow (user Zimbra → Zitadel session), edge cases, và write doc để dev khác reproduce.

## E2E test matrix

Test bằng 3 loại user:

| Case | User | Password | Expected |
|---|---|---|---|
| **T1** — Happy path | `admin@zimbra8815.inet.name.vn` | (correct password) | Login success, Zitadel user auto-created với attrs mapped |
| **T2** — Wrong password | `admin@zimbra8815.inet.name.vn` | `wrong-pass` | Login fail with "Invalid credentials" message |
| **T3** — Non-existent user | `notexist@zimbra8815.inet.name.vn` | (any) | Login fail with "User not found" (không leak user existence) |
| **T4** — Cross-domain (nếu enable) | `admin@inetdev.io.vn` | (correct) | Login success, distinct Zitadel user với email khác |
| **T5** — Disabled Zimbra account | `<disabled-user>` | (correct) | Login fail (Zimbra reject bind) |
| **T6** — Re-login (update sync) | T1 user sau khi update `displayName` trên Zimbra | (correct) | Zitadel user displayName updated tự động |

## Test scripts

**T1 happy path (manual via browser):**
1. Open incognito browser → `https://auth.authway.lab/ui/login`
2. Click "Zimbra Mail (LAB)"
3. Nhập `admin@zimbra8815.inet.name.vn` + password
4. Expected: redirect success page với session token
5. Verify Zitadel Admin Console → Users → tìm `admin@zimbra8815.inet.name.vn`
6. Kiểm attributes: `email`, `firstName`, `lastName`, `displayName` map đúng

**T2 wrong password:**
- Same steps, wrong password
- Expected: error message, NO user created trong Zitadel

**T6 attribute sync:**
```bash
# Trên Zimbra
ssh zimbra-mail
sudo su - zimbra
zmprov ma admin@zimbra8815.inet.name.vn displayName "Hoan Dat Updated"

# Sau đó logout Zitadel + login lại
# Verify displayName trong Zitadel updated
```

## Debug commands

**Nếu login fail, check Zitadel logs:**
```bash
ssh authserver
docker logs zitadel --tail 50 2>&1 | grep -iE "ldap|bind|auth"
```

**Nếu bind fail, verify LDAP connectivity từ Zitadel container:**
```bash
docker exec -it zitadel sh -c 'nc -zv 103.57.220.98 389'
docker exec -it zitadel sh -c 'ldapsearch -x -H ldap://103.57.220.98:389 -D "uid=zitadel-bind,..." -w "..." -b "..." "(uid=admin)"'
```

Zitadel container có thể không có `ldapsearch` binary — install debug tool:
```bash
docker exec -it zitadel apk add openldap-clients
# Hoặc dùng ldap-utils nếu Debian-based
```

## Documentation

Create `authway/docs/zitadel-ldap-zimbra-integration.md` với sections:

1. **Overview** — 3-line summary, use case
2. **Architecture diagram** — Browser ↔ Zitadel ↔ Zimbra LDAP flow (ASCII)
3. **Prerequisites**:
   - Zimbra 8.x với LDAP port accessible
   - Zitadel v2+ với admin access
   - Network path Zitadel → Zimbra:389
4. **Zimbra setup**:
   - Create bind account (zmprov ca)
   - Get Base DN
   - Firewall allow
5. **Zitadel setup**:
   - Add LDAP IdP với params
   - Attribute mapping table
   - Enable on Login Policy
6. **Verification** — ldapsearch commands + browser test
7. **Multi-domain notes**
8. **Troubleshooting** table:
   - "Can't contact LDAP server" → check port + firewall
   - "Invalid credentials" (unexpected) → verify bind DN case-sensitive
   - "User not found" → check filter + Base DN
   - "Attribute mapping empty" → LDAP entry thiếu attr, thêm manual hoặc fallback
9. **Rollback**
10. **Security considerations** — plaintext LDAP 389 chỉ dùng lab, prod bắt buộc LDAPS
11. **Prod migration checklist** (out of scope này nhưng note trước)

## Rollback strategy

Nếu E2E fail hoàn toàn:
1. Delete Zitadel IdP config
2. Delete auto-provisioned Zitadel users (nếu tạo lỗi)
3. Keep Zimbra bind account (không xóa, useful cho retry sau)
4. Document lessons learned trong plan report

## Success criteria (Phase 3 done)
- ✅ Test T1-T6 pass hoặc documented behavior
- ✅ `authway/docs/zitadel-ldap-zimbra-integration.md` complete
- ✅ Doc "smoke reproduce" — 1 dev khác đọc + tự setup được clone
- ✅ Plan status → completed
- ✅ Unblock signal cho `onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel`

## Post-completion

- Update plan.md status: `pending → completed`
- Send notification to OneMCP team: "Zitadel LDAP live, ready cho OneMCP OIDC integration"
- Provide Zitadel:
  - Issuer URL (VD `https://auth.authway.lab`)
  - Note: OneMCP client_id + secret sẽ tạo trong plan onelog:260805-1409 Phase 1
- Journal entry trong authway/docs/journals/ (nếu có convention đó)

## Deferred (out of scope, log lại)
- LDAPS enable trên Zimbra (prod scope)
- Group sync (Zimbra groups → Zitadel roles) — feature request tương lai
- MFA layer trên Zitadel cho LDAP users (Zitadel policy config, không phải LDAP)
- Password change flow (user muốn đổi password → chỉ đổi trên Zimbra, Zitadel không có UI)
