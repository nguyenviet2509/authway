# Zitadel Database Query Guide

Hướng dẫn truy vấn dữ liệu trong Postgres của Zitadel (auth server).

> ⚠️ **CẢNH BÁO:** Zitadel dùng **event sourcing**. KHÔNG sửa data trong `projections.*` trực tiếp — projections được rebuild từ `eventstore.events2`, mọi thay đổi sẽ bị overwrite hoặc gây inconsistent. Thay đổi state qua API/Console.

---

## Kết nối

### Trên auth VPS (qua container)

```bash
cd /opt/authway/infra/auth-vps

# Tìm tên container postgres
docker ps | grep postgres

# Vào psql (admin user)
docker exec -it authway-auth-postgres-1 psql -U postgres -d zitadel

# Hoặc vào với user zitadel (read-mostly)
docker exec -it authway-auth-postgres-1 psql -U zitadel -d zitadel
```

Password lấy từ `/opt/authway/infra/auth-vps/.env`:
- `POSTGRES_ADMIN_PASSWORD` cho user `postgres`
- `ZITADEL_DB_PASSWORD` cho user `zitadel`

### One-shot query (không vào shell)

```bash
docker exec -i authway-auth-postgres-1 psql -U postgres -d zitadel -c "SELECT count(*) FROM projections.users14;"
```

### Từ host (nếu expose port 5432)

```bash
PGPASSWORD='<password>' psql -h <auth-vps-ip> -p 5432 -U postgres -d zitadel
```

---

## Khám phá schema

```sql
\dn                              -- list schemas
\dt projections.*                -- read models (query data ở đây)
\dt eventstore.*                 -- raw events
\d projections.users14           -- xem cấu trúc table
```

**Cấu trúc chính:**

| Schema | Vai trò |
|--------|---------|
| `eventstore` | Source of truth — mọi state change là 1 event |
| `projections` | Read models build từ events (snapshot) |
| `system` | Cấu hình instance, encryption keys |
| `adminapi`, `auth` | Internal Zitadel state |

> Tên table trong `projections.*` có **suffix version** (vd. `users14`, `sessions8`). Số thay đổi theo phiên bản Zitadel. Luôn `\dt projections.users*` để tìm đúng tên hiện hành.

---

## Query phổ biến (one-liner, paste vào psql)

> Mỗi query 1 dòng. Trong psql có thể bật `\x` để xem dạng vertical khi cột nhiều: `\x auto`.
> State codes user: `0=unspecified, 1=active, 2=inactive, 3=deleted, 4=locked, 5=initial`.

### 1. Users

```sql
SELECT u.id, u.username, u.state, u.creation_date, u.resource_owner AS org_id FROM projections.users14 u ORDER BY u.creation_date DESC;
```
```sql
SELECT u.id, u.username, h.first_name, h.last_name, h.email, h.is_email_verified, u.state FROM projections.users14 u JOIN projections.users14_humans h ON u.id = h.user_id ORDER BY u.creation_date DESC;
```
```sql
SELECT u.id, u.username, m.name, m.description, u.state FROM projections.users14 u JOIN projections.users14_machines m ON u.id = m.user_id;
```
```sql
SELECT u.id, u.username, h.email FROM projections.users14 u JOIN projections.users14_humans h ON u.id = h.user_id WHERE h.email ILIKE '%@lab.local';
```

### 2. Login names

```sql
SELECT user_id, login_name, is_primary FROM projections.login_names3 WHERE user_id = '<user_id>';
```
```sql
SELECT user_id, login_name FROM projections.login_names3 WHERE login_name = 'admin@lab.local';
```

### 3. Organizations

```sql
SELECT id, name, primary_domain, state, creation_date FROM projections.orgs1 ORDER BY creation_date;
```
```sql
SELECT org_id, domain, is_primary, is_verified FROM projections.org_domains2 WHERE org_id = '<org_id>';
```

### 4. Projects & Applications (OIDC/SAML)

```sql
SELECT id, name, state, resource_owner AS org_id FROM projections.projects4;
```
```sql
SELECT p.name AS project, a.name AS app, a.state, oc.client_id, oc.redirect_uris, oc.response_types, oc.grant_types, oc.application_type, oc.auth_method_type FROM projections.apps7 a JOIN projections.projects4 p ON a.project_id = p.id LEFT JOIN projections.apps7_oidc_configs oc ON a.id = oc.app_id ORDER BY p.name, a.name;
```
```sql
SELECT a.id, a.name, p.name AS project FROM projections.apps7_oidc_configs oc JOIN projections.apps7 a ON oc.app_id = a.id JOIN projections.projects4 p ON a.project_id = p.id WHERE oc.client_id = '<client_id>';
```

### 5. Sessions

```sql
SELECT id, user_id, user_agent_fingerprint_id, creation_date, change_date FROM projections.sessions8 WHERE state = 1 ORDER BY change_date DESC LIMIT 20;
```
```sql
SELECT id, creation_date, change_date, state, expiration FROM projections.sessions8 WHERE user_id = '<user_id>' ORDER BY change_date DESC;
```

### 6. Auth methods (MFA)

> Method types: `1=OTP_TOTP, 2=U2F, 3=PASSKEY, 4=OTP_SMS, 5=OTP_EMAIL`.

```sql
SELECT user_id, method_type, state, name, creation_date FROM projections.user_auth_methods4 ORDER BY user_id;
```
```sql
SELECT method_type, count(DISTINCT user_id) FROM projections.user_auth_methods4 WHERE state = 1 GROUP BY method_type;
```

### 7. Tokens & Refresh tokens

```sql
SELECT user_id, client_id, scope, expiration, creation_date FROM projections.refresh_tokens3 WHERE expiration > now() ORDER BY creation_date DESC LIMIT 20;
```
```sql
SELECT user_id, scopes, expiration, creation_date FROM projections.personal_access_tokens3;
```

### 8. IAM/Org membership

```sql
SELECT m.user_id, u.username, h.email, m.roles, m.creation_date FROM projections.instance_members4 m JOIN projections.users14 u ON m.user_id = u.id LEFT JOIN projections.users14_humans h ON u.id = h.user_id;
```
```sql
SELECT m.org_id, o.name AS org, m.user_id, u.username, m.roles FROM projections.org_members4 m JOIN projections.orgs1 o ON m.org_id = o.id JOIN projections.users14 u ON m.user_id = u.id;
```
```sql
SELECT pm.project_id, p.name AS project, pm.user_id, u.username, pm.roles FROM projections.project_members4 pm JOIN projections.projects4 p ON pm.project_id = p.id JOIN projections.users14 u ON pm.user_id = u.id;
```

### 9. Audit qua eventstore

`eventstore.events2` là source of truth — mọi action lưu ở đây.

```sql
SELECT created_at, event_type, aggregate_type, payload FROM eventstore.events2 WHERE aggregate_id = '<user_id>' ORDER BY created_at DESC LIMIT 50;
```
```sql
SELECT created_at, aggregate_id AS user_id, event_type, payload FROM eventstore.events2 WHERE event_type IN ('user.human.password.check.failed','user.human.mfa.otp.check.failed','user.human.mfa.u2f.check.failed') ORDER BY created_at DESC LIMIT 30;
```
```sql
SELECT event_type, count(*) FROM eventstore.events2 WHERE created_at > now() - interval '24 hours' GROUP BY event_type ORDER BY count DESC;
```
```sql
SELECT created_at, event_type, payload FROM eventstore.events2 WHERE aggregate_type = 'project' AND payload::jsonb @> '{"clientId":"<client_id>"}' ORDER BY created_at DESC;
```

### 10. Login/Password policies

```sql
SELECT aggregate_id AS org_id, allow_username_password, allow_register, allow_external_idps, force_mfa, passwordless_type FROM projections.login_policies5;
```
```sql
SELECT aggregate_id, min_length, has_uppercase, has_lowercase, has_number, has_symbol FROM projections.password_complexity_policies2;
```

### 11. Identity Providers (IDPs)

```sql
SELECT id, name, type, state, resource_owner AS org_id FROM projections.idps3;
```
```sql
SELECT idp_id, issuer, client_id, scopes FROM projections.idps3_oidc;
```

### 12. Quotas & Limits

```sql
SELECT instance_id, unit, amount, from_anchor, interval FROM projections.quotas;
```
```sql
SELECT instance_id, unit, usage, period_start FROM projections.quotas_periods;
```

---

## Use cases thường gặp

### Đếm số user theo trạng thái

```sql
SELECT state, CASE state WHEN 1 THEN 'active' WHEN 2 THEN 'inactive' WHEN 3 THEN 'deleted' WHEN 4 THEN 'locked' WHEN 5 THEN 'initial' END AS state_name, count(*) FROM projections.users14 GROUP BY state ORDER BY state;
```

### Top user theo số lần login thành công 7 ngày

```sql
SELECT aggregate_id AS user_id, count(*) AS logins FROM eventstore.events2 WHERE event_type = 'user.human.password.check.succeeded' AND created_at > now() - interval '7 days' GROUP BY aggregate_id ORDER BY logins DESC LIMIT 20;
```

### Apps có nhiều redirect URI nhất

```sql
SELECT a.name, array_length(oc.redirect_uris, 1) AS uri_count, oc.redirect_uris FROM projections.apps7_oidc_configs oc JOIN projections.apps7 a ON oc.app_id = a.id ORDER BY uri_count DESC NULLS LAST LIMIT 10;
```

### User chưa verify email

```sql
SELECT u.username, h.email, u.creation_date FROM projections.users14 u JOIN projections.users14_humans h ON u.id = h.user_id WHERE h.is_email_verified = false AND u.state = 1 ORDER BY u.creation_date;
```

### Backup nhanh trước khi nâng cấp

```bash
docker exec authway-auth-postgres-1 \
  pg_dump -U postgres -d zitadel --schema=eventstore --schema=system \
  > zitadel-backup-$(date +%Y%m%d).sql

# Lưu ý: chỉ cần backup eventstore + system. Projections rebuild được từ eventstore.
```

---

## Performance tips

- `eventstore.events2` lớn dần theo thời gian. Luôn filter `created_at` hoặc `aggregate_id`.
- Index có sẵn trên `aggregate_id`, `aggregate_type`, `event_type`, `created_at`, `instance_id`.
- Query JSON payload (`payload::jsonb @>`) chậm — tránh dùng trong production traffic.
- Projections có index trên FK chính (user_id, project_id, org_id).

## Troubleshooting

**Table không tồn tại (`projections.users14` not found):**
- Phiên bản khác có thể là `users15`, `users13`... Chạy `\dt projections.users*`.

**Projection lệch event:**
```sql
-- Xem trạng thái projection
SELECT projection_name, last_updated, last_event_position
FROM projections.current_states;

-- Trigger reproject (qua admin API, KHÔNG truncate table)
```

**Lock connection:**
```sql
SELECT pid, query, state, wait_event FROM pg_stat_activity WHERE datname='zitadel';
SELECT pg_terminate_backend(<pid>);
```

---

## Tham khảo

- Zitadel source: https://github.com/zitadel/zitadel (xem `internal/query/projection/`)
- Event types: `internal/repository/<aggregate>/eventstore.go`
- Database scheme: `cmd/setup/`
