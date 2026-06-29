# Phase 04 — Breakglass VPN-only Fallback

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 1 ngày
- Replaces HA active-active (bỏ vì constraint 1 VPS Zitadel)
- Identity layer khi fallback: OpenVPN cert (qua VPN server log)

## Overview
**Priority**: P1

Khi Zitadel down, toggle compose chuyển app-vps từ IAP mode sang VPN-only mode. Traefik inject `X-Auth-Request-Email: breakglass-mode@authway.lab` placeholder để app code không break. Identity thật correlate qua OpenVPN log.

## Requirements
- OpenVPN/WireGuard self-host đã chạy (đã có)
- App đã/sẽ migrate IAP với contract đọc `X-Auth-Request-Email`
- Telegram bot (Phase 01)
- Vector log shipping (Phase 01) cho Traefik access log

## Architecture

| Layer | Normal mode | Breakglass mode |
|---|---|---|
| OpenVPN cert | Required | Required (không đổi) |
| Traefik IP whitelist | Subnet VPN | Subnet VPN (không đổi) |
| IAP middleware (oauth2-proxy + Zitadel forward auth) | ON | **OFF** |
| Header `X-Auth-Request-Email` | từ Zitadel session | từ Traefik customRequestHeaders placeholder |
| Per-user audit | Zitadel event log | OpenVPN server log + timestamp correlation |
| MFA | Yes (Zitadel) | No (chỉ VPN cert) |

## Files to Create
- `infra/app-vps/docker-compose.breakglass.yml` — alternative compose
- `infra/app-vps/dynamic/middlewares-breakglass.yml` — Traefik middlewares cho breakglass
- `infra/app-vps/scripts/breakglass-toggle.sh` — switcher
- `docs/breakglass-runbook.md` — quy trình
- `infra/observability/breakglass-monitor.sh` — VPS-C ping detect fallback mode active

## Implementation Steps

1. **`docker-compose.breakglass.yml`**
   - Loại bỏ service oauth2-proxy
   - Traefik labels: chain `vpn-ipwhitelist@file → inject-breakglass-identity@file → app`
   - App service không đổi

2. **`middlewares-breakglass.yml`**
   ```yaml
   http:
     middlewares:
       vpn-ipwhitelist:
         ipAllowList:
           sourceRange:
             - 10.8.0.0/24  # OpenVPN subnet
       inject-breakglass-identity:
         headers:
           customRequestHeaders:
             X-Auth-Request-Email: "breakglass-mode@authway.lab"
             X-Auth-Request-User: "breakglass"
             X-Breakglass-Active: "true"   # app có thể log warning
   ```

3. **`breakglass-toggle.sh`**
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   ACTION="${1:?usage: $0 on|off REASON}"
   REASON="${2:-no reason provided}"
   ACTOR="${SUDO_USER:-$USER}"
   TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   LOG=/var/log/breakglass.log

   tg() {
     curl -s "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
       -d chat_id="$TG_CHAT" -d parse_mode=Markdown -d text="$1" >/dev/null
   }

   cd /opt/authway/infra/app-vps

   case "$ACTION" in
     on)
       echo "$TS BREAKGLASS_ON actor=$ACTOR reason=$REASON" >> $LOG
       docker compose down
       docker compose -f docker-compose.breakglass.yml up -d
       # Schedule auto-revert 2h
       echo "/opt/authway/infra/app-vps/scripts/breakglass-toggle.sh off auto-revert" \
         | at now + 2 hours
       tg "🚨 *BREAKGLASS ON* on \`$(hostname)\`
   Actor: \`$ACTOR\`
   Reason: $REASON
   Auto-revert: 2h
   Log: \`$LOG\`"
       # Reminder cron mỗi 15 phút
       (crontab -l; echo "*/15 * * * * /opt/authway/infra/app-vps/scripts/breakglass-reminder.sh") | crontab -
       ;;
     off)
       echo "$TS BREAKGLASS_OFF actor=$ACTOR reason=$REASON" >> $LOG
       docker compose -f docker-compose.breakglass.yml down
       docker compose up -d
       crontab -l | grep -v breakglass-reminder | crontab -
       atrm $(atq | awk '/breakglass/ {print $1}') 2>/dev/null || true
       tg "✅ *BREAKGLASS OFF* on \`$(hostname)\`
   Actor: \`$ACTOR\`
   Reason: $REASON
   *Incident review required within 24h.*"
       ;;
     *)
       echo "Usage: $0 on|off REASON"; exit 1
       ;;
   esac
   ```

4. **`breakglass-reminder.sh`**
   - Chạy mỗi 15 phút khi breakglass active
   - Đọc `/var/log/breakglass.log` lấy thời điểm bật
   - Telegram nhắc: "⏰ Breakglass đã active X phút. Auto-revert lúc Y."

5. **App code contract**
   - App đọc `X-Auth-Request-Email` như bình thường
   - Optional: nếu thấy `X-Breakglass-Active: true` → log warning + show banner "Breakglass mode active"

6. **Traefik access log → Loki realtime**
   - Phase 01 Vector đã setup; verify access log capture đủ: source IP, user-agent, path, status, response time
   - Tag `breakglass=true` khi `X-Breakglass-Active` present để filter forensic

7. **OpenVPN log correlation prep**
   - Verify OpenVPN server log có: connect timestamp, cert CN, source IP, allocated VPN IP
   - Ship OpenVPN log sang VPS-C Loki (cùng Phase 01 pipeline)
   - Document join key cho forensic: VPN IP ↔ cert CN ↔ Traefik source IP

8. **VPS-C monitoring**: `breakglass-monitor.sh`
   - Mỗi 5 phút HTTP GET app endpoint
   - Check response header `X-Breakglass-Active`
   - Nếu detect → Telegram alert (redundant với toggle script, đề phòng toggle script log fail)

9. **Runbook** `docs/breakglass-runbook.md`
   - Authority: ai có quyền bấm? (founder + 1 senior — list rõ tên)
   - Pre-check: investigate root cause Zitadel down (5 phút) trước khi bấm
   - "High-trust window" rule:
     - KHÔNG deploy code mới
     - KHÔNG thao tác sensitive (xoá VPS, đổi DNS, tạo user mới)
     - Tập trung restore Zitadel
   - Incident review template:
     - Timeline (UTC)
     - Root cause Zitadel down
     - Forensic correlation OpenVPN ↔ Traefik
     - Bất thường nếu có
     - Action items

10. **Quarterly drill SOP**
    - Staging environment riêng
    - Toggle on → verify alert nhận đủ → check app vẫn login được qua VPN
    - Toggle off → verify cleanup
    - Force timeout test: bỏ qua manual off → at job tự revert sau 2h
    - Forensic drill: pick 1 random user action trong giai đoạn breakglass → correlate ra user thật từ OpenVPN log < 10 phút

## Todo
- [ ] Write `docker-compose.breakglass.yml`
- [ ] Write `middlewares-breakglass.yml`
- [ ] Write `breakglass-toggle.sh` + `breakglass-reminder.sh`
- [ ] Install `at` daemon trên app-vps
- [ ] Test toggle on/off trên staging
- [ ] Test auto-revert sau 2h
- [ ] Setup VPS-C `breakglass-monitor.sh` cron
- [ ] Ship OpenVPN log → Loki
- [ ] Write runbook + authority list
- [ ] Train founder + senior 30 phút procedure
- [ ] Quarterly drill: schedule first one Q3 2026
- [ ] Forensic correlation drill: pick action → trace user thật

## Success Criteria
- Toggle on → app login lại qua VPN-only trong < 30s
- Telegram nhận alert đầy đủ: on, reminder mỗi 15', off
- Auto-revert 2h pass (test với at job 5 phút)
- Forensic: pick request log Traefik trong breakglass → match được OpenVPN cert CN < 10 phút
- Drill quarterly pass

## Risks
- **Attacker DoS Zitadel để ép bật fallback** → mitigation: runbook bắt buộc investigate trước khi toggle
- **VPN cert leak**: 1 cert leak = full app access lúc fallback. Mitigation: cert TTL 90d, revoke offboarding < 1h
- **App không handle `breakglass-mode@authway.lab` placeholder**: vd app expect format email cụ thể → break. Mitigation: contract document + test mỗi app integration
- **Founder/senior cùng vắng mặt** lúc Zitadel down: ai bấm? Mitigation: list authority có 3 người, không chỉ 2
- **at job không trigger** (atd disabled) → quên off → breakglass mãi mãi. Mitigation: VPS-C monitor detect breakglass > 2h30 → escalate
- **Multiple app-vps** → toggle phải từng VPS hoặc có orchestrator. Phase này chỉ scope 1 app-vps, scale sau bằng Ansible/script.

## Reference
- Brainstorm decision: [../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md](../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md) section "Final design"
- Existing IAP setup: `infra/app-vps/docker-compose.yml`
