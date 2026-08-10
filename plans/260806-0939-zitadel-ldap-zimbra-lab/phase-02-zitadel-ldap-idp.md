# Phase 2 — Zitadel LDAP IdP configuration

**Effort:** 0.5d
**Status:** pending
**Depends on:** Phase 1 (bind account + network verified)

## Context
- Plan: [../plan.md](../plan.md)
- Zitadel host: `authserver` (192.168.122.54), admin console qua Traefik
- Zitadel version: cần confirm (v2 hoặc v4 — UI khác)

## Objective
Add Zimbra LDAP làm External Identity Provider trong Zitadel Instance. Config attribute mapping. Enable auto-registration.

## Steps

### 1. Open Zitadel Admin Console

Browser → `https://auth.authway.lab` (thêm `/etc/hosts` entry nếu chưa: `192.168.122.54 auth.authway.lab`).

Login với admin account Zitadel (thường `zitadel-admin@auth.authway.lab` — verify với `authway/plans/260626-1154-zitadel-iap-rollout/phase-01-zitadel-central.md`).

### 2. Navigate → Instance Settings → Identity Providers

Path phụ thuộc version:
- **Zitadel v2:** Console → Instance → Providers → New
- **Zitadel v3/v4:** Console → System / Instance → Identity Providers → Create

Chọn provider type: **LDAP** (hoặc "Active Directory / LDAP")

### 3. Điền config LDAP

**Connection:**
| Field | Value |
|---|---|
| Name | `Zimbra Mail (LAB)` |
| Servers | `ldap://103.57.220.98:389` (lab, plaintext) |
| StartTLS | ❌ Off (lab, self-signed) |
| BaseDN | `dc=zimbra8815,dc=inet,dc=name,dc=vn` (từ Phase 1) |
| BindDN | `uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn` |
| Bind Password | `<password từ Phase 1>` (từ Bitwarden) |
| Timeout | 5s |

**User query:**
| Field | Value |
|---|---|
| User Base | `ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn` |
| User Filter | `(&(objectClass=inetOrgPerson)(mail=%s))` |
| User Object Classes | `inetOrgPerson,zimbraAccount` |

**Note filter:** `%s` = user input. Nếu user nhập email (`admin@zimbra8815.inet.name.vn`) → filter match `mail` attr. Nếu muốn user nhập uid ngắn (`admin`) → dùng filter `(&(objectClass=inetOrgPerson)(uid=%s))` nhưng cần map uid → domain riêng.

**Recommend:** dùng `mail=%s` để user nhập email (dễ nhớ, unique cross-domain).

### 4. Attribute mapping

| Zitadel Field | LDAP Attribute | Ghi chú |
|---|---|---|
| ID Attribute | `entryUUID` | Unique immutable ID (recommend hơn `uid` vì `uid` có thể trùng cross-domain) |
| Username Attribute | `mail` | Dùng email làm username (unique) |
| Email Attribute | `mail` | |
| First Name Attribute | `givenName` | Fallback empty nếu không có |
| Last Name Attribute | `sn` | |
| Display Name Attribute | `cn` | |
| Phone Attribute | `telephoneNumber` | Optional |
| Preferred Username Attribute | `mail` | |
| Preferred Language Attribute | (bỏ trống) | |
| Avatar URL Attribute | (bỏ trống) | Zimbra không có |

### 5. Options

| Option | Setting |
|---|---|
| Automatic Creation | ✅ ON (auto-create Zitadel user khi login lần đầu) |
| Automatic Update | ✅ ON (sync attrs mỗi lần login) |
| Allow Linking | ✅ ON (link tài khoản LDAP với Zitadel user hiện có) |
| Allow External Login (auto-provisioning) | ✅ ON |

### 6. Save + Test Connection

Zitadel Admin UI có button "Test Connection" — click để verify bind + search.

Nếu button không có, test thủ công bằng cách bấm "Save" và check Zitadel logs:
```bash
ssh authserver 'docker logs zitadel 2>&1 | grep -iE "ldap|idp" | tail -20'
```

### 7. Enable on Login Policy

Path: Console → Instance → Login Policy → **Login Methods** → Add IdP → chọn `Zimbra Mail (LAB)` → Save.

Nếu policy đang scope theo Organization, apply cho Organization "Instance" hoặc org đang dùng cho OneMCP.

### 8. Verify trên login page

Browser → `https://auth.authway.lab/ui/login/login?authRequestID=...` (hoặc trigger từ 1 app):
- Login page giờ có option "Zimbra Mail (LAB)" (button/link)
- Click → form nhập email + password
- Nhập email Zimbra thật + password → submit
- Nếu OK → redirect callback + Zitadel user tạo/updated

## Multi-domain notes

Nếu muốn support nhiều Zimbra domain (VD user `admin@zimbra8815.inet.name.vn` + `admin@inetdev.io.vn`), có 2 approaches:

**Approach A — Broader Base DN + email filter:**
- BaseDN: `dc=vn` (common ancestor của các domain có tld `.vn`)
- User Filter: `(mail=%s)` — Zimbra store email vào `mail` attr, unique cross-domain

**Approach B — Multiple IdP instances:**
- 1 IdP per domain, user chọn domain trên login page
- Rườm rà, không recommend cho lab

**Recommend A** — 1 IdP, filter theo `mail`, cross-domain naturally.

## Rollback

Zitadel Admin UI → Instance → Identity Providers → `Zimbra Mail (LAB)` → Delete.

Zitadel users đã auto-provisioned từ LDAP sẽ còn lại nhưng không login được (link source deleted). Xóa users thủ công nếu muốn clean slate.

## Success criteria
- ✅ IdP config saved without error
- ✅ Test Connection pass (nếu có button)
- ✅ Login page hiển thị "Zimbra Mail (LAB)" option
- ✅ Zitadel logs: `ldap_bind_success user=<test-email>` sau khi click login

## Unresolved
1. Zitadel version chính xác — cần confirm để reference đúng docs
2. Organization scope — apply IdP cho org nào (default hay riêng cho OneMCP)?

## Next → Phase 3
E2E test với 1-2 test user + write doc.
