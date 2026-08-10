8---
status: pending
created: 2026-06-30
type: recovery
---

# Zitadel Admin Recovery — Nuke & Reinit

**Context:** [Brainstorm report](../reports/brainstorm-260630-1430-zitadel-admin-recovery-nuke-reinit.md)
**Target:** Lab VPS 192.168.122.54, Zitadel v4.15.3
**Root cause:** `render-config.sh` không guard directory rác do Docker auto-tạo khi compose up trước render → `--steps` bị skip → instance bootstrap nửa vời, PAT orphan.

## Phases

| # | Phase | Status | File |
|---|---|---|---|
| 1 | Pre-flight snapshot | pending | [phase-01-pre-flight-snapshot.md](phase-01-pre-flight-snapshot.md) |
| 2 | Fix script + nuke & reinit | pending | [phase-02-fix-and-reinit.md](phase-02-fix-and-reinit.md) |
| 3 | Verify & login | pending | [phase-03-verify-and-login.md](phase-03-verify-and-login.md) |
| 4 | Hardening | pending | [phase-04-hardening.md](phase-04-hardening.md) |

## Dependencies

- SSH access vietnt@192.168.122.54
- `.env` còn lưu `ZITADEL_ADMIN_USERNAME` + `ZITADEL_ADMIN_PASSWORD` để biết credentials post-reset
- `scripts/render-config.sh` fix đã commit local — cần push/scp lên VPS

## Risks

- Mất data lab (chấp nhận được, vài OIDC client)
- Nếu `.env` không có admin password → không login được sau reset → phải re-set qua DB hoặc re-render với password mới
