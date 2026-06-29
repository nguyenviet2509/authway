# Phase 00 — Enable Provider VM Snapshot

## Context
- Parent plan: [plan.md](plan.md)
- Brainstorm: [../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md](../reports/brainstorm-260626-1800-selfhost-readiness-assessment.md)
- Effort: 5 phút

## Overview
**Priority**: P0 (do trước mọi phase khác — chi phí gần 0, DR baseline)

Bật daily VM snapshot ở provider (DO/Vultr/Hetzner/AWS) cho cả VPS-A (auth) và VPS-B (app). Đây là DR baseline đơn giản nhất, restore < 5 phút khi VM corrupt.

## Requirements
- Provider UI / API access
- Retention 7 ngày
- Verify snapshot list không bị stuck

## Implementation Steps
1. Login provider console
2. VPS-A → Backups/Snapshots → Enable daily auto-snapshot, retention 7 ngày
3. VPS-B → tương tự
4. Note cost vào budget tracker (~$1–2/VPS/tháng)
5. Verify snapshot đầu tiên xuất hiện sau 24h
6. Document trong runbook: link restore từ snapshot, ETA, cost

## Todo
- [ ] Enable snapshot VPS-A
- [ ] Enable snapshot VPS-B
- [ ] Document restore procedure trong `docs/auth-vps-runbook.md`
- [ ] Verify 1st snapshot xuất hiện trong 24h
- [ ] Test restore drill: restore VPS-A vào staging IP → boot → verify Zitadel up (làm 1 lần đầu)

## Success Criteria
- Snapshot list provider có ≥1 entry tuổi <25h, mỗi ngày
- Restore drill test pass: VM restore → boot < 5 phút → Zitadel container start OK

## Risks
- Snapshot bao gồm `.env` plaintext nếu Phase 03 chưa làm → snapshot leak = key leak. **Mitigation:** ưu tiên Phase 03 SOPS chạy SỚM sau phase 00.
- Provider snapshot không phải backup thật (cùng provider failure domain) → vẫn cần Phase 02 offsite S3.

## Reference
- Provider docs cho snapshot feature
