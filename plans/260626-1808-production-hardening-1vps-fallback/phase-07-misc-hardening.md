# Phase 07 — Misc Hardening (PG SSL + Socket Proxy + Microseg + Upgrade SOP)

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 0.5 ngày

## Overview
**Priority**: P3

4 hardening items nhỏ, gom 1 phase. Mỗi cái standalone, có thể skip/defer.

## Items

### 7.1 Postgres SSL nội bộ

**Vấn đề**: Zitadel ↔ Postgres dùng `SSL: Mode: disable`. Cùng docker network OK lab, nhưng nếu container khác bị compromise → MITM nội bộ.

**Fix**: bật SSL self-signed nội bộ.

Steps:
1. Generate self-signed cert cho `postgres` CN bên trong container
   ```
   openssl req -new -x509 -days 3650 -nodes -text \
     -out server.crt -keyout server.key -subj '/CN=postgres'
   ```
2. Mount vào postgres container `/var/lib/postgresql/server.crt`, `server.key`
3. Postgres `postgresql.conf`: `ssl = on`, `ssl_cert_file`, `ssl_key_file`
4. Zitadel config:
   ```yaml
   User:
     SSL: { Mode: verify-ca, RootCert: /certs/server.crt }
   ```
5. Test connection

**Alternative đơn giản hơn**: Unix socket
- Postgres listen unix socket, Zitadel connect qua socket → không có TCP traffic → no SSL needed
- Trade-off: setup volume mount socket path, debug khó hơn

**Decision**: bật SSL self-signed (chuẩn hơn, dễ scale ra multi-host sau)

### 7.2 Docker socket-proxy

**Vấn đề**: Traefik mount `/var/run/docker.sock:ro`. RCE Traefik → đọc env mọi container.

**Fix**: thay bằng `tecnativa/docker-socket-proxy`

Steps:
1. Add service `docker-socket-proxy`:
   ```yaml
   docker-socket-proxy:
     image: tecnativa/docker-socket-proxy:latest
     environment:
       CONTAINERS: 1
       NETWORKS: 1
       SERVICES: 1
       # everything else 0
     volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]
     networks: [internal]
   ```
2. Traefik config: `endpoint: tcp://docker-socket-proxy:2375`, bỏ docker.sock mount
3. Test: Traefik vẫn discover services OK

### 7.3 Microsegmentation app-vps ↔ auth-vps

**Vấn đề**: cả 2 VPS cùng subnet OpenVPN; nếu app-vps compromise → có thể SSH/ICMP/scan port auth-vps.

**Fix**: UFW rules chặt
- App-vps → auth-vps: chỉ allow TCP 443 (Zitadel OIDC)
- App-vps → auth-vps: deny SSH, ICMP, all other
- Auth-vps → app-vps: deny all (auth-vps không cần gọi xuống app-vps)
- SSH chỉ từ bastion IP (đã có ở Phase 05)

Steps:
1. Trên auth-vps:
   ```
   sudo ufw deny from <app-vps-ip>
   sudo ufw allow from <app-vps-ip> to any port 443 proto tcp
   sudo ufw allow from <bastion-ip> to any port 22 proto tcp
   ```
2. Trên app-vps tương tự với auth-vps là source
3. Test: từ app-vps `nc -zv auth-vps 22` → blocked; `curl https://auth.../...` → OK

### 7.4 Zitadel upgrade SOP

**Vấn đề**: Pin v4.15.3 (latest stable 2026-06-22) sau bump từ v2.66.0 EOL. Cần process check CVE + quarterly bump drill.

**Fix**: document SOP
1. **Weekly check** (cron): script pull GitHub releases Zitadel → diff với current → Telegram alert nếu có new release
2. **CVE monitor**: GitHub watch security advisories repo zitadel/zitadel
3. **Upgrade procedure**:
   - Read changelog full
   - Backup DB ngay trước upgrade
   - Upgrade staging trước → soak 24h
   - Maintenance window công bố 24h trước (vì Zitadel down = mọi app down)
   - Tag git release cho config hiện tại
   - Upgrade production
   - Smoke test login + MFA
   - Rollback plan: docker compose down → restore DB → tag cũ
4. **Schedule**: minor version mỗi quý, major version đánh giá riêng

## Todo
- [ ] PG SSL self-signed setup + test
- [ ] Socket-proxy replace docker.sock mount
- [ ] UFW microseg rules app-vps ↔ auth-vps
- [ ] Upgrade SOP doc + cron check
- [ ] Quarterly upgrade drill: bump v4.x → v4 latest patch, document timing

## Success Criteria
- Postgres connection từ Zitadel dùng SSL (verify với `pg_stat_ssl`)
- Traefik vẫn route OK sau khi thay socket-proxy
- Microseg test: từ app-vps SSH auth-vps → timeout. HTTPS auth-vps → OK
- Cron weekly check Telegram: alert có release mới (test với fake hook)
- Drill upgrade staging pass

## Risks
- **PG SSL break Zitadel** nếu config sai → mitigation: test staging trước, dễ rollback (đổi mode disable + restart)
- **Socket-proxy quá restrictive** → Traefik không discover service → mitigation: test ngay sau apply
- **UFW microseg block OpenVPN routing** → mitigation: rule allow VPN subnet trước, test workstation vẫn vào được
- **Zitadel upgrade break migration** → mitigation: backup trước, staging test, rollback procedure

## Reference
- Postgres SSL: https://www.postgresql.org/docs/16/ssl-tcp.html
- tecnativa/docker-socket-proxy: https://github.com/Tecnativa/docker-socket-proxy
- Zitadel releases: https://github.com/zitadel/zitadel/releases
