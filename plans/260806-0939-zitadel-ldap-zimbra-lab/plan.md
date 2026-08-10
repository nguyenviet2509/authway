---
title: Zitadel LDAP IdP Integration with Zimbra (Lab)
date: 2026-08-06
status: completed
completedDate: 2026-08-06
mode: sequential
blockedBy: []
blocks: [onelog:260805-1409-onemcp-migrate-gitlab-to-zitadel, authway:260806-1504-sso-multi-app-zitadel-ldap-rollout]
supersedes: []
tags: [zitadel, ldap, zimbra, authway, lab]
---

# Zitadel LDAP IdP Integration with Zimbra — Lab Setup

## Objective
Cấu hình Zitadel (auth-server 192.168.122.54 lab) làm OIDC IdP với backend là Zimbra LDAP (mail.zimbra8815.inet.name.vn / 103.57.220.98:389). User của Zimbra (5 mail domains) sẽ login được vào Zitadel bằng credentials Zimbra hiện có, sau đó Zitadel issue OIDC token cho downstream apps (đầu tiên là OneMCP qua plan onelog:260805-1409).

## Context

**Zimbra facts (thu thập 2026-08-06):**
- Version: 8.8.15 FOSS, RHEL7, patch P46
- Host: mail.zimbra8815.inet.name.vn (103.57.220.98)
- LDAP: `ldap://mail.zimbra8815.inet.name.vn:389` (plaintext, listening public)
- LDAPS: chưa enable
- Domains (5): zimbra8815.inet.name.vn, inetdev.io.vn, truongphatplastic.com.vn, work.inet.name.vn, hoandat.tech, +v.v.
- User schema: `objectClass: inetOrgPerson, zimbraAccount`, attrs: `uid`, `mail`, `cn`, `sn`
- Cert TLS: self-signed
- Base DN per domain: `dc=<component1>,dc=<component2>,...,dc=<tld>`

**Zitadel facts:**
- Lab @ 192.168.122.54, private subnet
- Access via Traefik reverse proxy, self-signed cert (`auth.authway.lab`)
- Reference: `authway/plans/260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md`

**Network:**
- Zitadel host (192.168.122.54) outbound Internet qua lab NAT → có thể reach Zimbra public 103.57.220.98:389 (verify Phase 1)
- Ngược lại (Zimbra → Zitadel private) không reach (không cần cho LDAP)

## Non-goals (chốt cứng)
- ❌ Prod deploy (plan này chỉ lab, prod plan riêng sau)
- ❌ Enable LDAPS trên Zimbra (dùng LDAP+StartTLS hoặc plaintext lab)
- ❌ Sync ngược Zitadel → Zimbra (chỉ 1 chiều, Zimbra source of truth)
- ❌ Migrate password Zimbra sang Zitadel (bind-verify pattern, password ở Zimbra)
- ❌ Custom schema Zimbra (dùng chuẩn `uid` + `mail`)
- ❌ Multi-domain routing logic phức tạp (chọn 1-2 domain làm scope lab)

## In-scope
- ✅ Zimbra: tạo bind service account read-only (`zitadel-bind@<domain>`)
- ✅ Zimbra: verify LDAP query từ localhost + từ Zitadel host
- ✅ Zimbra: firewall/network allow Zitadel host → 389 (nếu chưa)
- ✅ Zitadel: add LDAP IdP với connection params + attribute mapping
- ✅ Zitadel: enable auto-registration + linking
- ✅ Test: user Zimbra login qua Zitadel UI → OIDC session issued
- ✅ Doc: `docs/zitadel-ldap-zimbra-integration.md`

## Phases

| # | Phase | Effort | Status |
|---|---|---|---|
| 01 | [Network + Zimbra bind prep](phase-01-zimbra-bind-prep.md) | 0.5d | pending |
| 02 | [Zitadel LDAP IdP config](phase-02-zitadel-ldap-idp.md) | 0.5d | pending |
| 03 | [E2E test + docs](phase-03-e2e-test-docs.md) | 0.5d | pending |

**Total:** 1-1.5 ngày

## Success criteria
- Từ Zitadel host: `ldapsearch -x -H ldap://103.57.220.98:389 -D "<bind-dn>" -w "<pass>" -b "<base-dn>" "(uid=admin)"` return entry với attributes đúng
- Zitadel Admin UI → IdP → "Test connection" pass
- User Zimbra (VD `admin@zimbra8815.inet.name.vn`) login vào Zitadel login page với password Zimbra → success → Zitadel user auto-created với `email=admin@zimbra8815.inet.name.vn`, `username=admin`, `displayName=Hoan Dat`
- Zitadel session issued (JWT có claim email, sub)
- Docs `zitadel-ldap-zimbra-integration.md` verified bằng "1 dev pilot đọc + tự setup được env clone"

## Risks

| Risk | Mitigation |
|---|---|
| Network timeout Zitadel → Zimbra 389 (giống case gitlabs firewall) | Phase 1 verify TRƯỚC bất kỳ config nào. Nếu fail → block, cần iNET IT/routing fix. |
| Multi-domain confusion (5 mail domains) | Chọn 1-2 domain làm scope lab (`zimbra8815.inet.name.vn` + `inetdev.io.vn`), user filter `(mail=*)` cross-domain |
| Bind account bị lock hoặc mất | Backup: 2 bind account (1 primary, 1 hot spare), lưu password Bitwarden |
| Zitadel LDAP IdP UI khác giữa v2/v3 | Ref docs Zitadel version tương ứng (đang chạy v4 per plan 260630-0826-zitadel-bump-to-v4) |
| Self-signed cert Zimbra (nếu enable LDAPS) → Zitadel container không trust | Lab: dùng LDAP plaintext (389), không cần cert. Prod sau: import CA cert vào Zitadel container. |
| Password test user sai / bị lock sau nhiều fail attempt | Dùng test account riêng, không dùng admin account |

## Rollback
- Delete IdP config trong Zitadel Admin UI
- Delete bind service account: `zmprov da zitadel-bind@<domain>` trên Zimbra
- Firewall revert (nếu đã open port cho Zitadel)
- Không đụng runtime data — rollback ≤ 5 phút

## Unresolved questions
1. **Domain scope lab:** dùng 1-2 domain (recommend `zimbra8815.inet.name.vn` + `inetdev.io.vn`) hay tất cả 5 domains? Càng nhiều domain, filter càng phức tạp.
2. **Zitadel version:** đang v2 hay v4? UI khác giữa version (LDAP IdP config path khác).
3. **Zitadel host outbound routing:** authserver 192.168.122.54 có gateway outbound Internet chưa? Nếu chưa, không reach được Zimbra public.
4. **Test user cho E2E:** dùng account nào (không phải admin) để test? Anh cung cấp 1 email + password Zimbra để em test end-to-end.
5. **LDAPS timeline:** khi nào enable Zimbra LDAPS (lab bỏ qua, prod cần)? Có coordinate được với Zimbra ops team không?

## Next steps
1. Verify Zitadel version + admin console access
2. Execute Phase 1 (Zimbra prep) manual — dev/ops confirm bind account tạo được
3. Kick cook phase-by-phase
4. Sau khi ship: unblock plan onelog:260805-1409 (OneMCP migrate)
