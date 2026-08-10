# Phase 1 — Network verify + Zimbra bind account prep

**Effort:** 0.5d
**Status:** pending
**Owner:** ops (Zitadel host) + Zimbra admin

## Context
- Plan: [../plan.md](../plan.md)
- Zimbra host: `mail.zimbra8815.inet.name.vn` (103.57.220.98)
- Zitadel host: `authserver` (192.168.122.54)
- LDAP URL: `ldap://mail.zimbra8815.inet.name.vn:389`

## Objective
Verify network + tạo bind service account `zitadel-bind` trên Zimbra để Zitadel dùng cho LDAP search/verify.

## Gate — network verify (BLOCKING)

Chạy trên Zitadel host (192.168.122.54):

```bash
# TCP reachability
nc -zv 103.57.220.98 389 -w 5
# Expected: Connection to 103.57.220.98 389 port [tcp/*] succeeded!

# LDAP bind test (chưa có bind account thật, dùng anonymous)
ldapsearch -x -H ldap://103.57.220.98:389 -b "" -s base namingContexts
# Expected: return list of namingContexts (base DNs của các domain)
```

**Nếu fail:**
- Timeout → firewall Zimbra chặn Zitadel outbound IP → coordinate với Zimbra ops mở port 389 cho IP outbound của Zitadel host
- "Can't contact LDAP server" → check Zimbra `slapd` running: `ssh zimbra-mail 'ss -tlnp | grep 389'`
- Anonymous bind blocked → OK, next step create bind account

## Steps

### 1. Tạo bind service account (trên Zimbra)

SSH vào Zimbra:
```bash
ssh zimbra-mail
sudo su - zimbra
```

Chọn domain host cho bind account (recommend `zimbra8815.inet.name.vn` — domain default):
```bash
DOMAIN=zimbra8815.inet.name.vn
BIND_PASSWORD=$(openssl rand -base64 24)
echo "Bind password (LƯU AN TOÀN): $BIND_PASSWORD"

# Tạo account read-only, disable mail features
zmprov ca zitadel-bind@$DOMAIN "$BIND_PASSWORD" \
  displayName "Zitadel LDAP Bind Service" \
  zimbraMailStatus disabled \
  zimbraFeatureMailEnabled FALSE \
  zimbraFeatureCalendarEnabled FALSE \
  zimbraFeatureContactsEnabled FALSE \
  description "Read-only bind account for Zitadel LDAP IdP integration"

# Lấy DN
BIND_DN=$(zmprov ga zitadel-bind@$DOMAIN | grep -i "^# name" | awk '{print $3}')
# Fallback nếu format khác:
zmprov -l gaa | grep zitadel-bind
```

**Ghi lại 3 giá trị:**
- Bind DN: `uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn` (verify format thực tế)
- Bind password: `$BIND_PASSWORD`
- Base DN: `dc=zimbra8815,dc=inet,dc=name,dc=vn`

### 2. Verify bind + search (từ Zimbra localhost)

```bash
# Từ Zimbra host, bind với account vừa tạo
ldapsearch -x -H ldap://localhost:389 \
  -D "uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn" \
  -w "$BIND_PASSWORD" \
  -b "dc=zimbra8815,dc=inet,dc=name,dc=vn" \
  "(uid=admin)" mail cn uid sn objectClass
```

Expected output có entry `admin@zimbra8815.inet.name.vn` với attrs `uid: admin`, `mail: admin@zimbra8815.inet.name.vn`, `cn: Hoan Dat`.

### 3. Firewall: allow Zitadel host reach 389

Cần biết outbound IP của Zitadel lab (khi request qua Internet). Có thể là:
- Public IP của gateway NAT (kiểm bằng `curl ifconfig.me` trên Zitadel host)
- Hoặc range IP của iNET lab

```bash
# Trên Zimbra host, thêm firewall rule
ZITADEL_OUTBOUND_IP=$(ssh authserver 'curl -s ifconfig.me')
sudo firewall-cmd --add-rich-rule="rule family=ipv4 source address=$ZITADEL_OUTBOUND_IP port port=389 protocol=tcp accept" --permanent
sudo firewall-cmd --reload
# Hoặc nếu dùng ufw:
sudo ufw allow from $ZITADEL_OUTBOUND_IP to any port 389 proto tcp
```

### 4. Verify từ Zitadel host

Trên Zitadel host `192.168.122.54`:
```bash
ldapsearch -x -H ldap://103.57.220.98:389 \
  -D "uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn" \
  -w '<paste-password>' \
  -b "dc=zimbra8815,dc=inet,dc=name,dc=vn" \
  "(uid=admin)" mail cn uid sn
```

Nếu return entry đúng → Phase 1 ✅ done. Nếu timeout → back to gate step.

### 5. Multi-domain search test (nếu scope > 1 domain)

Zimbra multi-domain — mỗi domain 1 subtree LDAP riêng. Search với base là `dc=vn` (broader) hoặc `dc=inet,dc=name,dc=vn` (parent nhiều domain):

```bash
# Search cross-domain
ldapsearch -x -H ldap://103.57.220.98:389 \
  -D "<bind-dn>" -w "<password>" \
  -b "dc=vn" \
  "(&(objectClass=inetOrgPerson)(mail=admin@*))" mail uid | head -20
```

Nếu Zimbra bind account có quyền cross-domain search → return entries từ nhiều domain. Nếu chỉ trong domain của bind account → cần bind account global admin (rủi ro cao) hoặc tạo bind account per domain.

**Recommend lab:** scope 1-2 domain, tạo 1 bind account thuộc domain đó, search chỉ trong domain đó.

## Deliverables

Lưu vào Bitwarden (hoặc secure store):
- Bind DN
- Bind password
- Base DN (per domain)
- Firewall rule ID (cho rollback)

Update plan.md với resolved values.

## Rollback

```bash
ssh zimbra-mail
sudo su - zimbra
zmprov da zitadel-bind@zimbra8815.inet.name.vn
# Firewall
sudo ufw delete allow from $ZITADEL_OUTBOUND_IP to any port 389 proto tcp
```

## Success criteria
- ✅ TCP 389 reachable từ Zitadel host
- ✅ Bind account tạo được, password strong
- ✅ ldapsearch từ Zitadel host return entry `admin` với đầy đủ attrs
- ✅ Bind account KHÔNG có quyền write, chỉ read
- ✅ Password lưu Bitwarden, không log

## Next → Phase 2
Đưa 3 giá trị (Bind DN, password, Base DN) vào Zitadel Admin UI để add LDAP IdP.
