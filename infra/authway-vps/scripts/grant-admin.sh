#!/usr/bin/env bash
# grant-admin.sh — Cấp quyền super-admin cho 1 user Zitadel.
#
# Usage:
#   ./grant-admin.sh <email>
#
# Ví dụ:
#   ./grant-admin.sh newadmin@inet.vn
#
# Grant bao gồm:
#   - IAM_OWNER (toàn quyền Zitadel instance)
#   - Project OneLog        role admin
#   - Project OneMCP Portal role onemcp.admin
#   - Project central-rbac  role rbac.admin (via project_grant)
#
# Prerequisite:
#   - User đã tồn tại trong Zitadel (login qua GitLab SSO 1 lần → auto-provision).
#   - Chạy trên authway-vps (hoặc host reach zitadel.000nethost.com qua 10.200.0.125).
#   - File /opt/central-rbac/.env chứa ZITADEL_SA_PAT (PAT của central-rbac-sa với IAM_OWNER role).

set -euo pipefail

EMAIL="${1:-}"
if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 <email>" >&2
  echo "Ví dụ: $0 newadmin@inet.vn" >&2
  exit 1
fi

# ── Config (project IDs cố định — chỉ đổi khi tạo project mới) ─────────────
ZITADEL_HOST="zitadel.000nethost.com"
ZITADEL_INTERNAL_IP="10.200.0.125"
AUTHWAY_ORG_ID="385591139173990404"          # Authway Internal (org của real users)
SPIKE_ORG_ID="387656897144029188"            # spike-test (org chứa project central-rbac)
ONELOG_PROJECT_ID="385600666015367171"
ONEMCP_PROJECT_ID="385595003772076035"
CENTRAL_RBAC_PROJECT_ID="387779900762750980"
CENTRAL_RBAC_GRANT_ID="389697087106711557"   # project_grant spike-test → Authway Internal (roleKeys: rbac.admin, rbac.viewer)

# ── PAT lookup ────────────────────────────────────────────────────────────
SAPAT="${ZITADEL_SA_PAT:-}"
if [[ -z "$SAPAT" ]]; then
  if [[ -f /opt/central-rbac/.env ]]; then
    SAPAT=$(grep -E '^ZITADEL_SA_PAT=' /opt/central-rbac/.env | cut -d= -f2-)
  fi
fi
if [[ -z "$SAPAT" ]]; then
  echo "ERROR: ZITADEL_SA_PAT không tìm thấy. Set env hoặc chạy trên authway-vps." >&2
  exit 1
fi

api() {
  curl -sk --resolve "${ZITADEL_HOST}:443:${ZITADEL_INTERNAL_IP}" \
    -H "Authorization: Bearer $SAPAT" \
    -H "Content-Type: application/json" \
    "$@"
}

# ── Step 1: tìm user_id theo email/login-name ─────────────────────────────
echo "→ Tìm user với login-name = $EMAIL ..."
USER_RESP=$(api -X POST "https://${ZITADEL_HOST}/v2/users" -d "{\"queries\":[{\"loginNameQuery\":{\"loginName\":\"$EMAIL\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}")
USER_ID=$(echo "$USER_RESP" | grep -oE '"userId":"[0-9]+"' | head -1 | cut -d'"' -f4)

if [[ -z "$USER_ID" ]]; then
  echo "ERROR: User $EMAIL chưa tồn tại. Bảo user login GitLab SSO 1 lần trước (auto-provision), rồi rerun script." >&2
  echo "Debug response: $USER_RESP" >&2
  exit 1
fi
echo "  user_id = $USER_ID"

# ── Step 2: grant IAM_OWNER (idempotent — API trả lỗi ALREADY_EXISTS nếu đã có, mình vẫn tiếp) ──
echo "→ Grant IAM_OWNER ..."
api -X POST "https://${ZITADEL_HOST}/admin/v1/members" \
  -d "{\"userId\":\"$USER_ID\",\"roles\":[\"IAM_OWNER\"]}" | head -c 200; echo

# ── Step 3-5: grant project roles ─────────────────────────────────────────
grant_project() {
  local project_id="$1" role="$2" label="$3" extra="${4:-}"
  echo "→ Grant $label (role=$role) ..."
  api -X POST -H "x-zitadel-orgid: $AUTHWAY_ORG_ID" \
    "https://${ZITADEL_HOST}/management/v1/users/$USER_ID/grants" \
    -d "{\"projectId\":\"$project_id\",\"roleKeys\":[\"$role\"]${extra}}" | head -c 200; echo
}

grant_project "$ONELOG_PROJECT_ID"      "admin"        "OneLog"
grant_project "$ONEMCP_PROJECT_ID"      "onemcp.admin" "OneMCP Portal"
grant_project "$CENTRAL_RBAC_PROJECT_ID" "rbac.admin"  "central-rbac" ",\"projectGrantId\":\"$CENTRAL_RBAC_GRANT_ID\""

echo
echo "✅ Done. $EMAIL now has IAM_OWNER + all project admin roles."
echo "Verify: user logout & login lại qua GitLab SSO để nhận JWT với role claims mới."
