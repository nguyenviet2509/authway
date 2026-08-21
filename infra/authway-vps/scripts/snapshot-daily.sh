#!/usr/bin/env bash
# Daily snapshot of Authway state — encrypted with age, pushed to S3.
# Mirrors OneLog pattern (infra/scripts/snapshot-daily.sh) so operator uses
# one restore procedure across the ecosystem.
#
# Covers:
#   1. Postgres logical dump (Zitadel event store — CRITICAL, source of truth)
#   2. zitadel-bootstrap volume (login-client PAT — required for zitadel-login sidecar)
#   3. Traefik data (ACME certs when HTTPS is enabled; empty for HTTP pilot)
#   4. Secrets bundle (.env + runtime configs so a fresh VPS restore boots the stack)
#   5. MANIFEST + SHA256SUMS (integrity + provenance)
#
# Output is age-encrypted (asymmetric) — leaking S3 creds does NOT expose data.
# Usage:  bash snapshot-daily.sh [BACKUP_DIR]
#   BACKUP_DIR default: /opt/authway/backup
# Cron:   0 2 * * * /opt/authway/infra/authway-vps/scripts/snapshot-daily.sh >> /var/log/authway-snapshot.log 2>&1
# Retention:
#   S3 → BACKUP_S3_KEEP_DAYS in infra/authway-vps/.env (recommended: 5).
#   Local → deleted immediately after successful S3 upload; failed uploads
#           linger up to KEEP_DAYS (default 2) as a stranded-file safety net.
# Prereq: age binary + infra/backup/backup-age.pub. See infra/backup/README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"      # infra/authway-vps
REPO_DIR="${REPO_DIR:-$(cd "$INFRA_DIR/../.." && pwd)}"      # /opt/authway
BACKUP_DIR="${1:-${BACKUP_DIR:-$REPO_DIR/backup}}"
DATE="$(date +%Y%m%d-%H%M)"
STAGE="$(mktemp -d -t authwaysnap.XXXXXX)"
KEEP_DAYS="${KEEP_DAYS:-2}"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

# Load env (POSTGRES_ADMIN_USER + S3/AWS creds)
if [[ -f "$INFRA_DIR/.env" ]]; then
  set -a; . "$INFRA_DIR/.env"; set +a
fi

echo "[snapshot] $(date -Is) start → $BACKUP_DIR"

# --- 1. Postgres logical dump (Zitadel event store) ---
# Critical: Zitadel state = postgres event store. Empty dump = restore useless.
#
# TWO artifacts:
#   a) globals.sql — CREATE ROLE + CREATE DATABASE (pg_dumpall --globals-only)
#      + explicit CREATE DATABASE (pg_dumpall skips this by default).
#      Restored FIRST on fresh Postgres, before the schema dump.
#   b) zitadel.sql.gz — schema + data for `zitadel` database with --create so
#      it includes CREATE DATABASE zitadel OWNER = ${ZITADEL_DB_USER}. Uses
#      --clean --if-exists so restore is idempotent even if run twice.
echo "[1/5] pg_dumpall globals (roles + tablespaces)"
PG_CONTAINER="${PG_CONTAINER:-authway-prod-postgres-1}"
if ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -q true; then
  echo "[snapshot] ERROR $PG_CONTAINER not running" >&2
  exit 2
fi
docker exec "$PG_CONTAINER" sh -c \
  "pg_dumpall -U '${POSTGRES_ADMIN_USER:-postgres}' --globals-only --clean --if-exists" \
  > "$STAGE/globals.sql"
GLOBALS_SIZE=$(stat -c%s "$STAGE/globals.sql")
echo "  globals.sql size=$GLOBALS_SIZE bytes"

echo "[2/5] pg_dump zitadel database"
docker exec "$PG_CONTAINER" sh -c \
  "pg_dump -U '${POSTGRES_ADMIN_USER:-postgres}' -d zitadel --create --clean --if-exists" \
  | gzip -9 > "$STAGE/zitadel.sql.gz"

DUMP_SIZE=$(stat -c%s "$STAGE/zitadel.sql.gz")
if [[ "$DUMP_SIZE" -lt 10240 ]]; then
  echo "[snapshot] ERROR pg_dump too small ($DUMP_SIZE bytes — aborted)" >&2
  exit 3
fi
echo "  zitadel.sql.gz size=$DUMP_SIZE bytes"

# --- 3. Bootstrap volume (login-client PAT) ---
# Contains machine-user PAT that zitadel-login sidecar uses to talk to Zitadel.
# Docker named volume — tar via helper container that mounts it read-only.
echo "[3/5] zitadel-bootstrap volume"
VOLUME_NAME="authway-prod_zitadel-bootstrap"
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  docker run --rm -v "$VOLUME_NAME:/src:ro" -v "$STAGE:/dst" alpine:3.20 \
    tar -C /src -cf /dst/zitadel-bootstrap.tar . 2>/dev/null || true
else
  echo "  ($VOLUME_NAME missing — skipped)"
fi

# --- Traefik data volume (ACME certs when HTTPS enabled) ---
# HTTP pilot: volume mostly empty. Included for forward-compat when TLS lands.
TRAEFIK_VOLUME="authway-prod_traefik-logs"
if docker volume inspect "$TRAEFIK_VOLUME" >/dev/null 2>&1; then
  docker run --rm -v "$TRAEFIK_VOLUME:/src:ro" -v "$STAGE:/dst" alpine:3.20 \
    tar -C /src -cf /dst/traefik-logs.tar . 2>/dev/null || true
fi

# --- 4. Static configs + secrets bundle (self-contained restore) ---
# Bundle EVERY file needed to boot the stack on a fresh VPS without git access:
#   configs/  = static YAML + templates + scripts + docker-compose.yml (from repo)
#   secrets/  = .env + rendered runtime configs (contain secrets)
# Combined size <100KB — cheap insurance against GitHub unavailability.
echo "[4/5] configs + secrets bundle"
mkdir -p "$STAGE/configs" "$STAGE/configs/dynamic" "$STAGE/configs/scripts" "$STAGE/secrets"

# Static configs from repo (docker-compose + templates + traefik + middlewares + scripts)
for f in docker-compose.yml traefik.yml zitadel-config.yaml zitadel-steps.yaml; do
  [[ -f "$INFRA_DIR/$f" ]] && cp -p "$INFRA_DIR/$f" "$STAGE/configs/$f"
done
[[ -d "$INFRA_DIR/dynamic" ]] && cp -rp "$INFRA_DIR/dynamic/." "$STAGE/configs/dynamic/"
[[ -d "$INFRA_DIR/scripts" ]] && cp -rp "$INFRA_DIR/scripts/." "$STAGE/configs/scripts/"
# vector.yaml added by monitor plan 260821-1013 — include if present
[[ -f "$INFRA_DIR/vector.yaml" ]] && cp -p "$INFRA_DIR/vector.yaml" "$STAGE/configs/vector.yaml"

# Secrets + rendered runtime configs
for f in .env zitadel-config.runtime.yaml zitadel-steps.runtime.yaml; do
  [[ -f "$INFRA_DIR/$f" ]] && cp -p "$INFRA_DIR/$f" "$STAGE/secrets/$f"
done

# --- RESTORE.md — step-by-step recovery (embedded in archive) ---
# Operator opens this FIRST during disaster recovery. Everything needed to boot
# a fresh VPS is either in this archive or referenced by exact command.
cat > "$STAGE/RESTORE.md" <<'RESTORE_EOF'
# Authway snapshot — RESTORE procedure

Archive format: `authway-YYYYMMDD-HHMM.tar.gz.age` (age-encrypted).

## Prerequisites on fresh VPS

- Debian/Ubuntu with Docker Engine + Docker Compose plugin
- `age` binary (`apt-get install age`)
- Private age key on operator laptop (`~/.secrets/onelog-backup-master.key`)
- Optional: aws cli if downloading from S3

## Step 1 — Decrypt + extract

```bash
age -d -i ~/.secrets/onelog-backup-master.key authway-YYYYMMDD-HHMM.tar.gz.age \
  | tar -xzf - -C /tmp/restore
cd /tmp/restore
cat MANIFEST.json    # sanity check: git_commit, image_tags, timestamp
sha256sum -c SHA256SUMS
```

## Step 2 — Provision /opt/authway

```bash
mkdir -p /opt/authway/infra/authway-vps
cp -r configs/. /opt/authway/infra/authway-vps/
cp -r secrets/. /opt/authway/infra/authway-vps/
# Verify:
ls /opt/authway/infra/authway-vps/
#   .env  docker-compose.yml  dynamic/  scripts/  traefik.yml
#   vector.yaml  zitadel-config.yaml  zitadel-config.runtime.yaml
#   zitadel-steps.yaml  zitadel-steps.runtime.yaml
```

## Step 3 — Boot Postgres ONLY + restore data

```bash
cd /opt/authway/infra/authway-vps
docker compose up -d postgres
sleep 10  # wait healthy
docker compose ps postgres  # STATUS = healthy

# Load env for POSTGRES_ADMIN_USER
set -a; . .env; set +a

# Load globals (CREATE ROLE zitadel + tablespaces) FIRST
cat /tmp/restore/globals.sql | docker compose exec -T postgres \
  psql -U "$POSTGRES_ADMIN_USER" -d postgres

# Load schema+data (CREATE DATABASE zitadel included via --create flag)
gunzip -c /tmp/restore/zitadel.sql.gz | docker compose exec -T postgres \
  psql -U "$POSTGRES_ADMIN_USER" -d postgres

# Verify counts
docker compose exec postgres psql -U "$POSTGRES_ADMIN_USER" -d zitadel \
  -c "SELECT count(*) FROM eventstore.events2;"
```

## Step 4 — Restore volumes (bootstrap PAT + traefik)

```bash
# Bootstrap volume (contains login-client PAT)
docker volume create authway-prod_zitadel-bootstrap
docker run --rm -v authway-prod_zitadel-bootstrap:/dst \
  -v /tmp/restore:/src alpine:3.20 \
  tar -C /dst -xf /src/zitadel-bootstrap.tar

# Traefik logs volume (usually empty for HTTP pilot)
docker volume create authway-prod_traefik-logs
docker run --rm -v authway-prod_traefik-logs:/dst \
  -v /tmp/restore:/src alpine:3.20 \
  tar -C /dst -xf /src/traefik-logs.tar || true
```

## Step 5 — Boot full stack (SKIP zitadel-init/setup — data already restored)

```bash
docker compose up -d zitadel zitadel-login traefik mailhog
sleep 30
docker compose ps

# Health check
curl -sf http://<vps-ip>/.well-known/openid-configuration | jq .issuer
```

**Important:** Do NOT run `docker compose up -d` blindly — that will re-execute
`zitadel-init` + `zitadel-setup` which are one-shot bootstrap. They will fail
harmlessly (idempotent) but log noise. Compose orders them via `depends_on`
so the safer path is to start `zitadel` directly (its `depends_on:
zitadel-setup.condition: service_completed_successfully` may block — if so,
temporarily comment that block, boot zitadel, then uncomment).

## Step 6 — DNS + external

Point `ZITADEL_EXTERNAL_DOMAIN` (from `.env`) at the new VPS IP. Verify:

```bash
curl -sf http://$ZITADEL_EXTERNAL_DOMAIN/.well-known/openid-configuration
```

## Rollback

If restore fails midway, wipe and retry:

```bash
cd /opt/authway/infra/authway-vps && docker compose down -v
docker volume rm authway-prod_postgres-data authway-prod_zitadel-bootstrap authway-prod_traefik-logs
# Then restart from Step 3.
```

## Verify integrity

```bash
sha256sum -c SHA256SUMS   # inside extracted archive dir
```

If any line reports FAILED → archive corrupted, use previous day's snapshot.
RESTORE_EOF

# --- 5. MANIFEST + SHA256SUMS ---
echo "[5/5] manifest + checksums"
GIT_COMMIT=$(cd "$REPO_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)
IMAGE_TAGS=$(cd "$INFRA_DIR" && docker compose config --images 2>/dev/null | sort -u | paste -sd, - || echo unknown)
HAS_SECRETS=$([[ -f "$STAGE/secrets/.env" ]] && echo true || echo false)
cat > "$STAGE/MANIFEST.json" <<EOF
{
  "version": 1,
  "service": "authway",
  "created": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "git_commit": "$GIT_COMMIT",
  "image_tags": "$IMAGE_TAGS",
  "has_secrets": $HAS_SECRETS,
  "dump_size_bytes": $DUMP_SIZE
}
EOF
(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

# --- Pack + age encrypt ---
ARCHIVE="$BACKUP_DIR/authway-${DATE}.tar.gz.age"
AGE_PUB="${BACKUP_AGE_PUB:-$REPO_DIR/infra/backup/backup-age.pub}"
if [[ ! -f "$AGE_PUB" ]]; then
  echo "[snapshot] ERROR age public key missing: $AGE_PUB" >&2
  echo "[snapshot] see infra/backup/README.md" >&2
  exit 5
fi
if ! command -v age >/dev/null 2>&1; then
  echo "[snapshot] ERROR age binary missing (apt install age)" >&2
  exit 6
fi
tar -C "$STAGE" -czf - . | age -R "$AGE_PUB" -o "$ARCHIVE"
echo "[snapshot] wrote $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# --- S3 offsite push (optional) ---
# Config via infra/authway-vps/.env:
#   BACKUP_S3_ENABLE=true
#   BACKUP_S3_BUCKET=s3://backups-authway-server
#   BACKUP_S3_PREFIX=daily/
#   BACKUP_S3_ENDPOINT=https://drive-storagehns3st.000nethost.com
#   BACKUP_S3_KEEP_DAYS=5
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION already in env
if [[ "${BACKUP_S3_ENABLE:-false}" == "true" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "[snapshot] ERROR BACKUP_S3_ENABLE=true but aws cli missing" >&2
    exit 4
  fi
  : "${BACKUP_S3_BUCKET:?Set BACKUP_S3_BUCKET when BACKUP_S3_ENABLE=true}"

  S3_ENDPOINT_ARG=()
  [[ -n "${BACKUP_S3_ENDPOINT:-}" ]] && S3_ENDPOINT_ARG+=(--endpoint-url "$BACKUP_S3_ENDPOINT")

  BUCKET_URI="$BACKUP_S3_BUCKET"
  [[ "$BUCKET_URI" != s3://* ]] && BUCKET_URI="s3://$BUCKET_URI"
  S3_KEY="${BUCKET_URI%/}/${BACKUP_S3_PREFIX:-}authway-${DATE}.tar.gz.age"
  S3_KEY_PATH="${BACKUP_S3_PREFIX:-}authway-${DATE}.tar.gz.age"
  BUCKET_NAME="${BUCKET_URI#s3://}"
  BUCKET_NAME="${BUCKET_NAME%%/*}"

  echo "[snapshot] s3 preflight (list bucket)"
  set +e
  aws "${S3_ENDPOINT_ARG[@]}" s3 ls "${BUCKET_URI%/}/" >/dev/null 2>&1
  PREFLIGHT=$?
  set -e
  if [[ "$PREFLIGHT" -ne 0 ]]; then
    echo "[snapshot] WARN S3 preflight failed (exit $PREFLIGHT) — archive kept at $ARCHIVE" >&2
    echo "[snapshot] $(date -Is) done (local-only, S3 skipped)"
    exit 0
  fi

  echo "[snapshot] s3 upload → $S3_KEY"
  set +e
  aws "${S3_ENDPOINT_ARG[@]}" s3 cp "$ARCHIVE" "$S3_KEY" \
    --only-show-errors \
    --metadata "hostname=$(hostname),created=$(date -Iseconds)"
  UPLOAD_RC=$?
  set -e
  if [[ "$UPLOAD_RC" -ne 0 ]]; then
    echo "[snapshot] WARN s3 cp failed (exit $UPLOAD_RC) — archive kept at $ARCHIVE" >&2
    echo "[snapshot] $(date -Is) done (local-only, S3 upload failed)"
    exit 0
  fi

  # Verify remote size matches local (retry up to 5×2s for lagged listings)
  LOCAL_SIZE=$(stat -c%s "$ARCHIVE" 2>/dev/null || stat -f%z "$ARCHIVE")
  REMOTE_SIZE=""
  for attempt in 1 2 3 4 5; do
    REMOTE_SIZE=$(aws "${S3_ENDPOINT_ARG[@]}" s3api head-object \
      --bucket "$BUCKET_NAME" --key "$S3_KEY_PATH" \
      --query 'ContentLength' --output text 2>/dev/null || true)
    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" == "$LOCAL_SIZE" ]]; then break; fi
    sleep 2
  done

  if [[ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
    echo "[snapshot] WARN s3 verify failed (local=$LOCAL_SIZE remote=${REMOTE_SIZE:-<missing>}) — archive kept at $ARCHIVE" >&2
    exit 0
  fi

  echo "[snapshot] s3 verified ($REMOTE_SIZE bytes match)"
  rm -f "$ARCHIVE"
  echo "[snapshot] local archive purged (uploaded + verified on S3)"

  # Remote retention (best-effort — prefer bucket lifecycle rule for reliability)
  KEEP_S3="${BACKUP_S3_KEEP_DAYS:-0}"
  if [[ "$KEEP_S3" -gt 0 ]]; then
    CUTOFF_EPOCH=$(( $(date +%s) - KEEP_S3 * 86400 ))
    aws "${S3_ENDPOINT_ARG[@]}" s3 ls "${BUCKET_URI%/}/${BACKUP_S3_PREFIX:-}" 2>/dev/null \
      | awk '{print $1" "$2" "$NF}' \
      | while read -r d t f; do
          [[ "$f" =~ ^authway-.*\.tar\.gz\.age$ ]] || continue
          FILE_EPOCH=$(date -d "$d $t" +%s 2>/dev/null || echo 0)
          if [[ "$FILE_EPOCH" -gt 0 && "$FILE_EPOCH" -lt "$CUTOFF_EPOCH" ]]; then
            echo "  purge remote: $f"
            aws "${S3_ENDPOINT_ARG[@]}" s3 rm "${BUCKET_URI%/}/${BACKUP_S3_PREFIX:-}$f" --only-show-errors || true
          fi
        done
  fi
fi

# --- Local retention (safety net for stranded archives) ---
find "$BACKUP_DIR" -maxdepth 1 -name 'authway-*.tar.gz.age' -mtime "+${KEEP_DAYS}" -print -delete || true

echo "[snapshot] $(date -Is) done"
