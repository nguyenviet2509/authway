---
phase: 04
title: Migrate first 2–3 real apps + retrospective
status: pending
priority: P0
effort: 1.5d + 7d soak
blockedBy: [03]
---

# Phase 04 — Migrate Real Apps

## Context
- Reference + playbook đã ready
- Migrate app thật để validate pattern dưới load thực tế

## Overview
Chọn 2–3 app vibe-code đang chạy IP-whitelist-only, migrate qua Zitadel IAP. 1 app dạng static (vibe-code thuần), 1 app Next.js/Node có session phức tạp hơn. Quan sát 7 ngày, retro, quyết định rollout phần còn lại.

## Migration patterns (Nhóm A vs Nhóm B)
Chi tiết: [../reports/brainstorm-260626-1328-legacy-app-migration.md](../reports/brainstorm-260626-1328-legacy-app-migration.md)

Tóm tắt:
- **Nhóm A** (IP whitelist, no users): 0 code change, chỉ infra
- **Nhóm B** (DB users): bỏ login/password, trust header, auto-provision. **KHÔNG TRUNCATE**. Thay vào: <!-- red-team #5 -->
  - Per-app **FK audit BẮT BUỘC** trước cutover: liệt kê mọi bảng tham chiếu `users.id`, ownership/role columns, default role cho auto-provision
  - **Rename** `users` → `users_legacy` (giữ data, rollback = RENAME ngược, không cần pg_restore)
  - Tạo `users` mới với `external_subject` (Zitadel sub) làm key
  - First-login: match by email → re-link record từ `users_legacy` → migrate FK
  - Auto-provision với **lowest privilege**, admin upgrade thủ công
  - Email immutability trong Zitadel: không cho user tự đổi email (tránh account takeover qua email change)
  - **Owner sign-off bằng văn bản** trước khi chạy migration script

## Selection criteria cho 3 app pilot (validated 2026-06-26)
**Mix chốt:** 1 Nhóm A static + 1 Nhóm B đơn giản + 1 Nhóm B phức tạp nhất
- Sử dụng thật bởi >2 thành viên team (có signal về DX)
- Không phải critical-path (chấp nhận downtime ngắn để debug)
- Owner mỗi app sign-off bằng văn bản (Nhóm B BẮT BUỘC do liên quan DB migration)

## Requirements
- Mỗi app pilot tích đúng template phase 03
- IP whitelist GIỮ trên VPS (defense in depth)
- Old auth (nếu có) chạy song song 1 tuần đầu, sau đó tắt
- Metric capture: login success rate, MFA prompt count, error 4xx/5xx, complaints

## Files to Create
- `migrations/app-A/` — diff & notes
- `migrations/app-B/` — diff & notes
- `migrations/app-C/` (optional)
- `docs/migration-retrospective.md` — sau 7-day soak

## Implementation Steps
1. Chọn 2–3 ứng viên (sync với team owner mỗi app)
2. Tạo Application trong Zitadel cho mỗi app
3. Apply template từ phase 03 vào repo từng app
4. Deploy staging-like (nếu có) hoặc canary trên cùng VPS với route prefix
5. Notify users, document login flow mới
6. **Pre-cutover safety** (BẮT BUỘC cho Nhóm B): <!-- red-team #5 -->
   - FK audit doc completed + owner sign-off
   - Snapshot DB app: `pg_dump <app-db> > backup-precut-$(date +%F).sql` lưu offsite
   - Snapshot file uploads / state nếu có
   - **App vào read-only/maintenance mode** trong cutover window (bound rollback delta)
   - Rename strategy: `ALTER TABLE users RENAME TO users_legacy` (rollback = RENAME ngược, ~giây)
   - **Rollback dry-run trên staging copy** — đo wall-clock thực tế, update target (15 phút là optimistic, thực tế 30–90 phút bao gồm DNS TTL + cache invalidation)
   - Define "point of no return": sau X giờ post-cutover, rollback = data loss acceptance
7. Cutover: switch DNS / Traefik rule sang stack mới
8. Monitor 7 ngày:
   - Login success rate
   - Số ticket support liên quan
   - Restart count oauth2-proxy
   - Header propagation issues
9. Retrospective:
   - DX cho dev migrate: chấm 1–5
   - Onboard time thực tế vs target 15 min
   - Pain points lặp lại → cải tiến template
   - Quyết định rollout phần còn lại (timeline, ai làm)
10. Document lessons learned

## Todo
- [ ] 2–3 app selected, owner sign-off
- [ ] Zitadel applications created
- [ ] Each app migrated theo template
- [ ] Old auth chạy song song lúc đầu
- [ ] DB snapshot pre-cutover taken (Nhóm B)
- [ ] Rollback steps documented + dry-run tested
- [ ] Cutover done
- [ ] 7-day soak metrics collected
- [ ] Retrospective doc written
- [ ] Decision: rollout phần còn lại hay điều chỉnh template trước

## Success Criteria
- 2–3 app pilot hoạt động ổn sau 7 ngày
- 0 incident security
- Login success rate ≥95% (failure thường là user MFA mới setup)
- Dev migrate cho từng app <30 phút (chậm hơn target 15min do app có legacy code)
- Retrospective + lessons → template v2 (nếu cần)

## Risks
| Risk | Mitigation |
|---|---|
| User pushback (MFA setup phiền) | Onboarding session 30min với team, hỗ trợ trực tiếp |
| App có internal session conflict với oauth2-proxy cookie | Test trên staging trước cutover |
| MFA device lost trong soak | Admin reset workflow đã có từ phase 03 |
| Performance regression | oauth2-proxy ~5ms overhead/request, monitor p95 latency |

## Next Steps (out of scope POC)
- Rollout phần còn lại các app (7 app sau)
- HA cho Zitadel central (replica + managed Postgres)
- Terraform Zitadel provider để IaC việc tạo Application
- Audit log shipping ra log central (nếu có)
- M2M client_credentials cho CI/CD nếu cần
