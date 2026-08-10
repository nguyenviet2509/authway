# Zitadel log viewing guide

Cheat sheet để debug Zitadel + LDAP IdP flow trên `authserver` lab (và prod sau này).

## 1. Log realtime (theo dõi khi test)

```bash
ssh authserver

# Zitadel main (core, LDAP bind, OIDC flows)
docker logs authway-auth-zitadel-1 -f

# Login sidecar (typescript UI, SSR errors)
docker logs authway-auth-zitadel-login-1 -f
```

Ctrl+C để thoát.

## 2. Log gần đây (không realtime)

```bash
# 100 dòng cuối
docker logs authway-auth-zitadel-1 --tail 100

# 5 phút gần đây
docker logs authway-auth-zitadel-1 --since 5m

# Từ timestamp cụ thể
docker logs authway-auth-zitadel-1 --since 2026-08-06T10:00:00
```

## 3. Filter hữu ích

```bash
# Chỉ LDAP-related events
docker logs authway-auth-zitadel-1 --since 10m 2>&1 | grep -iE "ldap|idp|intent"

# Chỉ errors + warnings
docker logs authway-auth-zitadel-1 --since 10m 2>&1 | grep -iE "level=(error|warn)|error="

# LDAP bind fail (password sai)
docker logs authway-auth-zitadel-1 --since 10m 2>&1 | grep "ldap user bind failed"

# Login sidecar Next.js SSR errors
docker logs authway-auth-zitadel-login-1 --since 10m 2>&1 | grep -iE "error|fail"

# Instance domain resolution issues
docker logs authway-auth-zitadel-1 --since 10m 2>&1 | grep -iE "instance.notfound|::1"
```

## 4. Tail cả 2 container song song

```bash
docker compose -f /opt/authway/infra/auth-vps/docker-compose.yml logs -f zitadel zitadel-login
```

## 5. Bảng ý nghĩa event

| Log pattern | Ý nghĩa | Action |
|---|---|---|
| `StartIdentityProviderIntent code=code_0` | ✅ LDAP flow bắt đầu OK | — |
| `RetrieveIdentityProviderIntent code=code_0` | ✅ Retrieve intent OK | — |
| `code_0` (bất kỳ endpoint) | ✅ Success (grpc code 0) | — |
| `ldap user bind failed ... Code 49` | ❌ Password sai | User gõ sai / autofill wrong |
| `Login at External IDP failed (COMMAND-nzun2i)` | ❌ Wrapper error | Xem `ldap user bind failed` phía trên |
| `Instance.NotFound QUERY-1kIjX` | ❌ Zitadel không resolve instance | Check `ZITADEL_INSTANCEHOSTHEADERS` env + network alias |
| `unable to set instance ... instanceDomain [::1]:3000` | ❌ Host header issue (Node fetch strip) | Verify env `ZITADEL_INSTANCEHOSTHEADERS=x-forwarded-host` + login sidecar `CUSTOM_REQUEST_HEADERS` có `X-Forwarded-Host` |
| `invalid AddHumanUserRequest.Profile GivenName` | ❌ First Name mapping empty | Set First Name Attribute = `cn` |
| `invalid AddHumanUserRequest.IdpLinks[0]: UserId ... length 1-200` | ❌ ID Attribute empty | Đổi ID Attribute từ `entryUUID` → `mail` (Zimbra ACL không expose entryUUID) |
| `IDP intent missing userId, cannot redirect to complete registration` | ❌ Auto-create chưa bật | Bật `isAutoCreation` trong IdP options |
| `fetch() returned undefined` (login sidecar) | ❌ SSR fetch fail | Zitadel v4 login sidecar bug, apply host header workaround |

## 6. Cheat sheet 1 dòng — test login với log tail

```bash
# Tail 60s + filter LDAP events (chạy song song với test browser)
ssh authserver 'timeout 60 docker logs authway-auth-zitadel-1 --since 5s -f 2>&1 | grep -iE "ldap|idp|intent|error"'
```

## 7. Verify config đang apply

```bash
# Zitadel main container env
docker exec authway-auth-zitadel-1 printenv 2>/dev/null | grep -iE "INSTANCEHOSTHEADERS|PUBLICHOSTHEADERS|EXTERNALDOMAIN"

# Login sidecar env
docker exec authway-auth-zitadel-login-1 printenv | grep -iE "CUSTOM_REQUEST|ZITADEL_API"

# Zitadel version
docker inspect authway-auth-zitadel-1 --format "{{.Config.Image}}"
```

## 8. Direct LDAP bind test (không qua Zitadel)

Verify bind account + user password thực tế trên Zimbra LDAP:

```bash
# Service account bind test
ssh authserver 'docker run --rm alpine sh -c "apk add --no-cache openldap-clients >/dev/null 2>&1 && ldapwhoami -x -H ldap://103.57.220.98:389 -D uid=zitadel-bind,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn -w /EHNOQ98k/mXpVVv7b2IXAeVZwqXh1A8"'

# User password bind test
ssh authserver 'docker run --rm alpine sh -c "apk add --no-cache openldap-clients >/dev/null 2>&1 && ldapwhoami -x -H ldap://103.57.220.98:389 -D uid=<user>,ou=people,dc=zimbra8815,dc=inet,dc=name,dc=vn -w <password>"'
```

Exit 0 + return DN = bind OK. Exit 49 = wrong password. Timeout = network/firewall issue.

## 9. Zimbra-side check (khi cần)

```bash
ssh zimbra-mail

# Account status
sudo -u zimbra /opt/zimbra/bin/zmprov ga <user>@zimbra8815.inet.name.vn zimbraAccountStatus

# Reset password test user
sudo -u zimbra /opt/zimbra/bin/zmprov sp <user>@zimbra8815.inet.name.vn '<new-password>'

# List all attributes (visible to admin, may differ from bind account view)
sudo -u zimbra /opt/zimbra/bin/zmprov ga <user>@zimbra8815.inet.name.vn
```

## Related

- Plan hoàn tất lab: `authway/plans/260806-0939-zitadel-ldap-zimbra-lab/completion-notes.md`
- Plan prod rollout: `authway/plans/260806-1504-sso-multi-app-zitadel-ldap-rollout/`
- Compose config: `authway/infra/auth-vps/docker-compose.yml`
- Zitadel version hiện tại: v4.16.1 (upgrade từ v4.15.3 vì bug SSR)
