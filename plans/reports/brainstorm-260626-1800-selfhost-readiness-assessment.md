# Brainstorm — AuthWay Selfhost Readiness & Sensitive Data Risk

**Date:** 2026-06-26 18:00 (Asia/Saigon)
**Scope:** Đánh giá AuthWay (Zitadel self-host IAP stack) có chuẩn self-host chưa + risk dữ liệu nhạy cảm
**Target:** Production cho team kỹ thuật 5 người, 10 app infra-critical, nội bộ công ty

---

## 1. Verdict tổng

- **Lab/POC:** 8/10 — architecture đúng, hardening cơ bản OK
- **Production team 5:** **CHƯA chuẩn** — thiếu 6 mảng cần fix
- Effort tới production-ready: **5.5–8.5 ngày người**

## 2. Stack hiện tại (snapshot)

- VPS-A (192.168.122.54): Zitadel v2.66 + Postgres 16 + Traefik v3.2 + Mailhog
- VPS-B (192.168.122.55): Traefik + 2 oauth2-proxy (Next.js + static) — IAP pattern
- TLS: self-signed lab; Force MFA TOTP; IP whitelist subnet
- Backup: pg_dump local, 30 ngày retention, no encryption, no offsite
- Secrets: `.env` plaintext trên VPS

## 3. Dữ liệu nhạy cảm đang nắm giữ

| Loại | Lưu ở | Bảo vệ |
|---|---|---|
| Password hash | Postgres | bcrypt |
| TOTP secret, WebAuthn keys | Postgres | mã hoá bởi `ZITADEL_MASTERKEY` |
| OIDC client_secret | Postgres | mã hoá bởi masterkey |
| Refresh tokens, sessions | Postgres + oauth2-proxy cookie | masterkey / cookie_secret |
| Audit log (login, IP, UA, email) | Postgres `LogStore.Access` | plaintext, không ship ra ngoài |
| SMTP / IdP federation creds | Postgres | masterkey |
| PII (email, username, name) | Postgres | plaintext |
| **MASTERKEY** | `.env` cùng VPS với DB | **chmod default, plaintext** |
| Backup dumps | local disk VPS | **không encrypt, local-only** |
| Self-signed CA private key | `tls/auth.key` VPS | file trên disk |

## 4. Risk theo severity

### 🔴 CRITICAL

1. **Masterkey + DB cùng VPS, key plaintext** → compromise 1 host = giải mã được TOTP/refresh token toàn user → impersonate mọi app
2. **Backup local-only, không encrypt** → VPS hỏng/ransomware = mất toàn bộ identity + audit log
3. **Audit log không ship ra ngoài** → attacker compromise Zitadel có thể tampere log; DB chết = mất forensic

### 🟠 HIGH

4. **Postgres SSL disable** giữa Zitadel ↔ Postgres (cùng docker net OK lab, không best practice)
5. **Single VPS, no HA** — RTO target 5 phút không khả thi với cold standby
6. **SSH trực tiếp không bastion** — workstation compromise → SSH key → root auth-vps → game over

### 🟡 MEDIUM

7. Docker socket mount vào Traefik (giảm bằng socket-proxy)
8. Không có secret rotation policy (`client_secret`, masterkey, Postgres pwd, cookie_secret)
9. MFA lab TOTP ↔ prod Passkey: enrollment không carry, cần plan migration
10. Refresh token / session TTL default có thể quá dài cho app infra-critical
11. Zitadel pin version không có process check CVE / upgrade

### 🟢 OK rồi

- Postgres không bind host port
- Mailhog UI, Traefik dashboard chỉ 127.0.0.1
- UFW deny default + subnet allow only
- `strip-auth-in` trước `iap-auth` (chống header spoof)
- Force MFA, lockout 5, password complexity 12+
- IP whitelist + IAP layered
- TLS terminate ở Traefik, Zitadel HTTP nội bộ

## 5. Constraints từ team

| Item | Giá trị | Tác động |
|---|---|---|
| Backup destination | **S3 nội bộ có sẵn** | rclone `s3:` thẳng |
| RTO | **5 phút** | Đạt qua break-glass fallback (degrade security tạm), KHÔNG qua HA |
| Zitadel topology | **1 VPS only — KHÔNG HA** | Bỏ Patroni/managed PG; dựa vào snapshot + restore + fallback |
| Provider snapshot | **Có (DO/Vultr/Hetzner)** | Bật daily snapshot, restore VM ~5 phút |
| SSH access | Direct từ workstation, no bastion | Cần SSH cert + audit hoặc dựng bastion |
| Alerting | **Telegram** | Vector→Telegram bot |
| Compliance | Nội bộ only | Retention 90d daily + 12m monthly đủ |
| Fallback policy | **Break-glass IP whitelist only khi auth down** | Cần script toggle + alert + time-box + audit |

## 6. Plan ưu tiên (thứ tự thực hiện)

### Phase 1 — Quick wins (2 ngày + 5 phút)

**P1.0 Bật daily VM snapshot ở provider (5 phút)**
- DO/Vultr/Hetzner UI → enable daily snapshot ($1–2/tháng)
- Retention 7 ngày
- Restore VM ~5 phút khi cần
- Cộng với pg_dump hourly → RPO 1h cho data, 24h cho VM state


**P1.1 Audit log shipping + Telegram alert (1 ngày)**
- Vector tail Zitadel container log → ship 2 nơi: Loki (query 30d), S3 nội bộ (retention 12m, parquet)
- Vector route alert rules → Telegram bot:
  - ≥5 lockout / 5 phút (brute force)
  - `IAM_OWNER` role grant
  - Admin login IP ngoài subnet
  - Zitadel restart / healthcheck fail
  - Backup job fail
- Loki + Vector chạy trên VPS thứ 3 (observability host) — KHÔNG cùng VPS-A
- Acceptance: tampere thử log local trên VPS-A → vẫn thấy bản gốc trên Loki

**P1.2 Offsite encrypted backup + restore drill (1 ngày)**
- Script: `pg_dump --format=custom | age -r $OFFSITE_PUBKEY | rclone rcat s3:authway/zitadel-$(date +%F-%H%M).dump.age`
- Cron: **hourly** (RPO 1h vì chỉ có 1 VPS, không thể chậm hơn), retention GFS (24 hourly + 30 daily + 12 weekly + 12 monthly)
- Restore drill: cron weekly → VPS staging restore full + smoke test login API → kết quả ship qua Telegram
- Age private key: cất offline 2 nơi (Bitwarden + sealed envelope), KHÔNG trên VPS auth
- Acceptance: drill pass 3 tuần liên tiếp; thử restore từ scratch trên VPS mới < 30 phút

### Phase 2 — Secrets + Break-glass (2 ngày)

**P2.1 SOPS + age secrets pipeline (1 ngày)**
- `.env.sops.yaml` mã hoá bằng age pubkey VPS
- Systemd `authway.service`: `ExecStartPre=sops -d ... > /run/authway/.env` (tmpfs)
- Age private key chỉ tồn tại trên VPS, backup offline 2 nơi (Bitwarden + sealed envelope)
- Repo commit được `.env.sops.yaml`; git history = audit secret change
- Rotation runbook: `client_secret` 90d, Postgres pwd 180d, masterkey yearly với migration plan
- Acceptance: reboot VPS → `.env` plaintext không tồn tại trên disk

**P2.2 Break-glass fallback (VPN-only mode khi Zitadel down) (1 ngày)**

Context: team đã có **OpenVPN/WireGuard self-host** + app chưa migrate (còn legacy auth). User KHÔNG muốn maintain dual-auth code → chọn pure VPN-only fallback.

Architecture layered:

| Layer | Normal | Breakglass |
|---|---|---|
| L1 OpenVPN cert | Always required | Always required (không đổi) |
| L2 Traefik IP whitelist subnet VPN | ON | ON (không đổi) |
| L3 IAP (oauth2-proxy + Zitadel) | ON | **OFF** |
| L4 App reads `X-Auth-Request-Email` | từ oauth2-proxy (Zitadel session) | từ Traefik header injection (placeholder `breakglass-mode@authway.lab`) |
| Identity audit | Zitadel event log | OpenVPN server log + timestamp correlation |

Design:
- 2 compose file mỗi app-vps:
  - `docker-compose.yml` — chain `strip-auth-in → iap-auth → app`
  - `docker-compose.breakglass.yml` — chain `vpn-ipwhitelist → inject-breakglass-identity → app`
- `inject-breakglass-identity` middleware (Traefik): `customRequestHeaders` set `X-Auth-Request-Email: breakglass-mode@authway.lab` → app code không cần biết về breakglass mode
- Script `breakglass-toggle.sh on|off`:
  - Yêu cầu actor + reason argument, log `/var/log/breakglass.log`
  - Telegram alert ngay khi bật + nhắc mỗi 15 phút tới khi tắt
  - Schedule `at` job auto-revert sau **2h** (chống quên tắt)
  - Ship toàn bộ Traefik access log sang VPS-C Loki realtime trong giai đoạn fallback
- Runbook quy trình:
  1. Verify Zitadel thật sự down (không phải attacker DoS để force fallback)
  2. Notify team channel
  3. Actor (founder hoặc 1 senior) bấm toggle on với reason
  4. Restore Zitadel song song
  5. Toggle off khi Zitadel up
  6. Incident review trong 24h: correlate OpenVPN log ↔ Traefik access log ↔ app log
  7. "High-trust window" rule: KHÔNG deploy code, KHÔNG thao tác sensitive (xoá VPS/đổi DNS) trong giai đoạn fallback
- Quarterly drill: toggle on→off staging, verify alert + log + auto-revert + forensic correlation

Trade-off chấp nhận:
- ✅ App code clean, không dual-auth
- ✅ Loại bỏ risk dev "tiện tay" bypass IAP
- ⚠️ Breakglass mode KHÔNG có MFA (chỉ có VPN cert)
- ⚠️ Per-user audit trong app log = placeholder; user thật phải correlate OpenVPN log
- ⚠️ Forensic complexity tăng (~10 phút correlation)

Risk còn lại:
- Attacker DoS Zitadel để ép bật fallback. **Quy trình: investigate down cause TRƯỚC khi bấm toggle.**
- VPN cert leak trong giai đoạn fallback = quyền tương đương dev. → Hardening VPN: cert TTL 90 ngày, revoke khi nghỉ việc, audit OpenVPN connection log.

### Phase 3 — Hardening (1.5 ngày)

**P3.1 Bastion SSH + break-glass (0.5 ngày)**
- Bastion VPS thứ 4 (cheap, $5/tháng) — chỉ host này có SSH key vào VPS-A/B
- SSH cert-based (Vault SSH CA hoặc Teleport CE)
- Break-glass admin: tài khoản riêng, TOTP device cất safe, KHÔNG dùng Passkey (giảm laptop attack surface), test 6 tháng/lần
- Offboarding SLA: < 1 giờ kể từ HR notify; script `zitadel-cli deactivate <user>`

**P3.2 Session / token hardening (0.5 ngày)**
- Access token: 1h
- Refresh token: 8h (giảm từ default 30d)
- Session inactive timeout: 4h
- Force re-MFA: daily
- oauth2-proxy: verify `--cookie-secure`, `--cookie-httponly`, `--cookie-samesite=lax`, `--cookie-refresh` < access token TTL

**P3.3 Misc hardening (0.5 ngày)**
- Replace docker socket mount → `tecnativa/docker-socket-proxy`
- Postgres SSL bật giữa Zitadel ↔ DB (self-signed CA nội bộ hoặc Unix socket)
- Microsegmentation: app-vps chỉ allow gọi auth-vps:443, deny SSH/ICMP/other
- Zitadel upgrade SOP: weekly CVE check, staging test, maintenance window

## 7. Success criteria

- [ ] Telegram nhận alert trong test scenario (lockout brute force, admin login ngoài subnet)
- [ ] Backup file mới nhất trên S3 < 25h tuổi, age-encrypted
- [ ] Restore drill pass weekly, kết quả ship Telegram
- [ ] Reboot VPS-A → không tìm thấy plaintext masterkey trên disk
- [ ] Kill Zitadel container chính → app vẫn login được trong < 5 phút (Option A/B) hoặc 10 phút (Option C)
- [ ] Audit log tampere local vẫn thấy bản gốc trên Loki/S3
- [ ] SSH thử trực tiếp từ workstation (không qua bastion) → bị deny
- [ ] User test offboarding: deactivate < 1 giờ, verify không login được mọi app
- [ ] Spoof header test pass, logout chain pass (đã có ✅)

## 8. Cost estimate

| Item | Monthly |
|---|---|
| VPS-A auth (4GB) | ~$15 |
| VPS-B app (đã có) | — |
| VPS-C observability (Loki + Vector + Telegram) | ~$10 |
| VPS-D bastion (1GB) | ~$5 |
| 2nd VPS Zitadel replica | ~$15 |
| Managed Postgres (Option A) | ~$15–30 |
| S3 nội bộ | đã có |
| **Total Option A** | **~$60/tháng** |
| **Total Option B (self-host PG)** | **~$60/tháng + 2 VPS PG standby = ~$90** |

Vs cost 1 incident (mail admin compromise → AWS bill DDoS vài chục triệu): vẫn rẻ.

## 9. Risk còn lại sau khi fix hết

- **Provider lock-in** (Option A) — managed PG migration ra ngoài đau
- **Telegram bot token compromise** → attacker mute alert trước khi tấn công → cần thêm channel backup (email/PagerDuty free tier)
- **Bastion là SPoF của ops access** — phải có offline emergency access (console provider)
- **age private key mất** = backup vô dụng — yêu cầu 2-of-3 key sharing (Shamir SSS) nếu paranoid

## 10. Unresolved questions

1. Policy có cho phép managed Postgres bên thứ 3 (Aiven/DO) không? → quyết định Option A vs B vs C
2. S3 nội bộ là MinIO trên VPS riêng hay storage hosting có sẵn? Có versioning + object lock không?
3. Có sẵn VPS observability hay phải tạo mới? (Loki + Vector ~2GB RAM)
4. Team có on-call rotation, hay best-effort? — ảnh hưởng SLA alert response
5. Founder/sếp có sẵn TOTP device riêng để break-glass không, hay phải mua YubiKey?
6. Có hệ thống HR notify offboarding tự động hay manual? — quyết định automation level
7. Masterkey rotation: chấp nhận maintenance window 1h/năm không?
