# Zitadel User Metadata Convention

Quy ước chung cho việc gắn metadata lên user trong Zitadel. Mỗi lần set/remove metadata sẽ tạo event `user.metadata.set` / `user.metadata.removed` → xuất hiện trong **Last Changes** trên user profile UI, đồng thời query được qua API và Postgres.

## Vì sao dùng metadata

- Zitadel **không cho thêm event type mới** vào event store.
- Metadata là cơ chế chính thức để ghi business fact lên user mà vẫn xuất hiện trong audit timeline.
- Đọc/ghi qua Management API hoặc Postgres (`projections.user_metadata5`).

## Naming rule

- **snake_case**, ASCII, ≤ 64 ký tự.
- Key giữ ổn định — đổi key = event mới + history rỗng cho key cũ.
- Value: plain string, UTF-8. Script tự base64 khi gọi API.

## Keys chuẩn

| Key | Value format | Ai set | Mục đích |
|---|---|---|---|
| `employee_id` | `INET-1234` | HR khi onboard | Map sang HR system |
| `department` | `eng` / `ops` / `pm` / `sales` | Lead | Filter user theo team |
| `job_title` | `Senior Backend Engineer` | Lead | Hiển thị / report |
| `onboarded_by` | username lead | Lead | Audit ai approve |
| `onboarded_at` | `2026-06-30` (ISO date) | Lead | Tính seniority |
| `offboarded_at` | `2026-12-31` | Lead khi nghỉ | Trigger revoke app grant |
| `kyc_status` | `pending` / `approved` / `rejected` | Compliance | Gate truy cập app nhạy cảm |
| `nda_signed_at` | `2026-06-30` | Legal | Compliance |
| `apps_allowed` | CSV: `gitlab,grafana,wiki` | Lead | Hint cho oauth2-proxy (không thay role) |
| `mfa_grace_until` | `2026-07-15` | Ops | Cho user mới chưa enroll MFA |

**Lưu ý:** metadata KHÔNG thay thế role/grant. Role/grant vẫn quản qua Project → Roles → Authorization. Metadata chỉ là tag bổ sung.

## Lifecycle

1. **Onboard:** HR/Lead chạy `set-user-metadata.sh` set `employee_id`, `department`, `job_title`, `onboarded_by`, `onboarded_at`.
2. **Compliance check:** Compliance set `kyc_status=approved`, `nda_signed_at`.
3. **Role change:** đổi `job_title`, `department`. Last Changes ghi lại.
4. **Offboard:** set `offboarded_at` → trigger script revoke grant + deactivate user.

## Verify

UI: User profile → Last Changes → thấy `Metadata set` entries.

SQL:
```sql
SELECT key, convert_from(value, 'UTF8') AS value, change_date
FROM projections.user_metadata5
WHERE user_id = '<userId>'
ORDER BY change_date DESC;
```

API:
```bash
curl -H "Authorization: Bearer $ZITADEL_PAT" \
  https://auth.lab.local/management/v1/users/<userId>/metadata/_search
```

## Helper script

`infra/auth-vps/scripts/set-user-metadata.sh` — wrap API call, tự base64, validate key snake_case.

## Setup service user (1 lần)

1. Console → Users → **+ New** → kind: **Machine User** → username `metadata-bot`.
2. Authentication → **+ New token** (PAT) → copy token.
3. Org → Members → add `metadata-bot` với role `ORG_USER_MANAGER` (đủ quyền user metadata, không quá rộng).
4. Lưu PAT vào `infra/auth-vps/.env`:
   ```
   ZITADEL_PAT=<token>
   ZITADEL_API=https://auth.lab.local
   ```
5. `.env` đã có trong `.gitignore` — không commit.
