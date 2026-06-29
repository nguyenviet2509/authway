# Phase 01 — Audit Log Shipping + Telegram Alert

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 1 ngày
- Trust boundary: VPS-C tách riêng khỏi VPS-A để attacker compromise Zitadel không xoá được log

## Overview
**Priority**: P1 (làm trước Phase 02 vì giá trị forensic cao nhất + đơn giản nhất)

Setup VPS-C observability host chạy Vector + Loki + Telegram alert. Vector tail container log của Zitadel + Traefik trên VPS-A/B qua remote syslog hoặc Vector agent → ship sang Loki (query 30d) + S3 archive (parquet, retention 12m).

## Requirements
- 1 VPS mới (2GB RAM, $10/tháng) hoặc tái sử dụng host monitoring có sẵn
- Telegram bot token + group chat_id (đã tạo theo phase rollout)
- S3 nội bộ credential write-only cho log archive

## Architecture
```
VPS-A (zitadel) ─┐
                  ├─→ Vector agent → VPS-C (Loki + Vector aggregator) ─┬─→ Loki (30d query)
VPS-B (oauth2)  ─┘                                                     ├─→ S3 parquet (12m)
                                                                       └─→ Telegram bot (alert rules)
```

## Files to Create
- `infra/observability/docker-compose.yml` — Vector aggregator + Loki + Grafana
- `infra/observability/vector-agent.toml` — chạy trên VPS-A/B, tail docker container logs
- `infra/observability/vector-aggregator.toml` — VPS-C, route Loki + S3 + Telegram
- `infra/observability/alert-rules.toml` — alert thresholds
- `docs/observability-runbook.md` — operational doc

## Implementation Steps

1. **Provision VPS-C** (Ubuntu 24.04, 2GB)
   - UFW: allow Vector ingestion port (vd 9000) từ VPS-A/B IP only
   - Docker + compose

2. **Loki + Grafana stack** trên VPS-C
   - Loki single-instance mode (no Promtail, dùng Vector thay thế)
   - Grafana datasource Loki
   - Grafana access qua SSH tunnel only (không expose web)

3. **Vector aggregator** trên VPS-C
   - Source: `vector` socket TCP 9000
   - Transforms: parse zitadel JSON log, extract event fields
   - Sinks:
     - `loki` (label by container/event_type)
     - `aws_s3` parquet rolling hourly partition
     - `http` Telegram bot khi alert match

4. **Vector agent** trên VPS-A, VPS-B
   - Source: `docker_logs` (tail container stdout)
   - Sink: TCP 9000 sang VPS-C
   - Buffer disk 1GB phòng VPS-C down

5. **Alert rules** (Vector route conditions)
   - `lockout_count > 5 trong 5m` → Telegram "🚨 Brute force suspect"
   - `event_type == "user.granted" && role == "IAM_OWNER"` → Telegram "⚠️ Privilege escalation"
   - `event_type == "user.human.added" && source_ip NOT IN subnet` → Telegram "⚠️ Admin login từ IP lạ"
   - `zitadel container restart > 2 trong 1h` → Telegram "🚨 Zitadel instability"
   - `backup_age > 25h` → Telegram "🚨 Backup stale"

6. **Telegram bot integration**
   - Token + chat_id qua SOPS-managed env (sau Phase 03; tạm `.env` chmod 600)
   - Test: trigger manual event → verify Telegram message
   - Format: emoji + timestamp + event detail + Grafana link

7. **Tampere test**
   - Trên VPS-A: `docker exec zitadel rm -rf /tmp/access.log` (giả lập)
   - Verify Loki vẫn có bản gốc → tampere không thành công

## Todo
- [ ] Provision VPS-C, UFW config
- [ ] Deploy Loki + Grafana + Vector aggregator
- [ ] Deploy Vector agent trên VPS-A
- [ ] Deploy Vector agent trên VPS-B
- [ ] Configure 5 alert rules
- [ ] Test Telegram bot e2e
- [ ] Tampere test pass
- [ ] Document runbook: query log, mute alert, alert rule edit
- [ ] Verify log volume estimate (vd 100MB/ngày × 30 = 3GB Loki OK với 2GB RAM)

## Success Criteria
- Loki query: thấy event Zitadel login real-time (< 5s lag)
- Telegram nhận test alert cho cả 5 rule
- Tampere test: log local xoá nhưng Loki vẫn còn
- VPS-A down 10 phút: Vector agent buffer → khi up lại flush log không mất
- Grafana dashboard "Zitadel activity" có panel: login/min, MFA verify rate, error 5xx

## Risks
- **Vector buffer disk full**: monitor `/var/lib/vector` size, alert > 80%
- **Loki single-instance retention**: 30d × 100MB/ngày = 3GB OK; nếu log spike → có thể OOM. Mitigation: limits config + S3 archive là source-of-truth
- **Telegram bot token leak**: token nằm trong SOPS sau Phase 03; rotate khi nghi ngờ
- **Alert fatigue**: rule quá nhạy → ignore. Mitigation: tune sau 1 tuần soak

## Reference
- Vector docs: https://vector.dev/docs/
- Loki docs: https://grafana.com/docs/loki/
- Zitadel event log schema: existing `LogStore.Access` trong `zitadel-config.yaml`
