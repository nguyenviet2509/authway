# Brainstorm — Primer section cho `authway-app-migration-guide.html`

**Date:** 2026-06-30 16:18 (Asia/Saigon)
**Target file:** `mockups/authway-app-migration-guide.html`
**Owner:** vietnt

## Problem
Migration guide hiện chỉ là operational doc (config 3 nơi + AI prompts). Member/lead/PM mở file không nắm context "Zitadel là gì, kiến trúc ra sao" trước khi vào phần migrate. Hai file kia (`system-explainer`, `services-detail`) có nhưng quá chi tiết để dùng làm intro.

## Decisions
- **Approach:** Thêm 1 section "Primer" ngắn ở đầu file migration-guide, không nhân bản nội dung 2 file kia, chỉ cross-link.
- **Audience:** Mix dev + non-tech (lead/PM) → tránh YAML/code dài, dùng diagram + bullet ngắn.
- **Depth Zitadel:** 1-pager (vai trò + 3 lý do + 1 sơ đồ infra rút gọn). Không deep dive OIDC/PKCE/grants.

## Approaches considered
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| Primer section đầu migration-guide | Member đọc 1 file đủ context; ít drift | Cần cross-link rõ | **CHỌN** |
| Chỉ callout link sang 2 file kia | Zero duplication | Bắt user nhảy file khi present | Bỏ |
| Rewrite thành all-in-one deck | 1 file present | Phá cấu trúc hiện tại, maintain nặng | Bỏ |

## Final design

**Vị trí chèn:** sau header (~line 65), trước section "Mỗi app 1 VPS riêng".

**Length budget:** ~150–200 dòng HTML, total file < 1300 dòng.

**4 block:**
1. **"Authway là gì?"** — tagline 1 câu + diagram `[User] → [Auth VPS] ← OIDC → [App VPS 1..N]`.
2. **"Zitadel đóng vai gì?"** — 3 bullet: IdP / Admin Console / SSO + Session.
3. **"Sao chọn Zitadel?"** — 3 lý do non-tech: self-host (cost), MFA + audit sẵn (compliance), OIDC chuẩn (no lock-in).
4. **"Infra 1 hình"** — Auth VPS box (Traefik + Zitadel + Postgres + backup) ↔ App VPS box (Traefik + oauth2-proxy + app). Caption cross-link `services-detail.html` + `system-explainer.html`.

**Style constraint:** dùng lại Tailwind classes + color tokens (`acc/ok/vio/warn/err`) đã có, không thêm dependency.

## Risks
- **Drift 3 file:** mitigated bằng cách vẽ Block 4 rất rút gọn (không IP/port cụ thể).
- **File phình to:** budget cứng < 1300 dòng total.

## Success criteria
- Member/PM mở 1 mình file migration-guide vẫn hiểu được "đây là cái gì" trong < 2 phút.
- Không nhân bản câu/diagram đã có ở 2 file kia.
- Visual đồng bộ phần còn lại của file (cùng palette + spacing).

## Unresolved
1. Block 4 dùng **SVG inline** hay **ASCII trong `<pre>`**?
2. Có cần dòng "owner/runbook link" cuối Primer không?

## Next
Hỏi user có muốn `/ck:plan` để tách phase implement, hay chỉ implement luôn (scope nhỏ, 1 file).
