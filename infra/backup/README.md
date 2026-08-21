# Authway backup age key

Uses the same master key as OneLog (`onelog-backup-master.key`) — one operator,
one custody chain. See `../../../onelog/infra/backup/README.md` for key generation
+ rotation + Bitwarden/QR safe custody procedure.

Snapshot script: [`../authway-vps/scripts/snapshot-daily.sh`](../authway-vps/scripts/snapshot-daily.sh)

## Runtime install on authway-vps

```bash
sudo apt-get install -y age awscli
```

## Verify round-trip

```bash
echo hello | age -R infra/backup/backup-age.pub \
  | age -d -i ~/.secrets/onelog-backup-master.key
# → hello
```

## Restore

```bash
# On any host with age binary + private key
aws --endpoint-url https://drive-storagehns3st.000nethost.com s3 cp \
  s3://backups-authway-server/daily/authway-YYYYMMDD-0200.tar.gz.age .
age -d -i ~/.secrets/onelog-backup-master.key \
  authway-YYYYMMDD-0200.tar.gz.age > authway.tar.gz
tar -tzf authway.tar.gz    # inspect
tar -xzf authway.tar.gz    # extract → contains zitadel.sql.gz + secrets/ + MANIFEST.json

# Import Postgres dump (on fresh authway-vps)
gunzip -c zitadel.sql.gz | docker exec -i authway-prod-postgres-1 \
  psql -U "$POSTGRES_ADMIN_USER" -d zitadel
```
