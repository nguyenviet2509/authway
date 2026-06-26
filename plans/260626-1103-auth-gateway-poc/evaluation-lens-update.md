---
type: addendum
date: 2026-06-26 11:39
parent: phase-04-evaluation-and-decision.md
---

# Evaluation Lens Update — Scale & Longevity

Sau brainstorm bổ sung (260626-1139), thêm context cho phase 04 evaluation:

## Business constraints xác nhận
- **Internal-only forever** (không bao giờ thành B2B SaaS / B2C)
- **Ưu tiên 5-year stability** ("xây nền vững, không phải thay")
- **Zero-auth ratio uncertain** (chưa biết app legacy chiếm bao %)

## Hệ quả lên scoring

### Trọng số mới cho 7 criteria (override §4 brainstorm gốc)

| # | Criterion | Trọng số cũ | Trọng số mới | Lý do thay đổi |
|---|---|---|---|---|
| 1 | Onboard steps | High | **High** | Giữ nguyên |
| 2 | RAM/CPU | Medium | Low | Scale nhỏ, không bottleneck |
| 3 | Forward-auth DX | High | **Critical** | Zero-auth ratio unknown → cần flexibility |
| 4 | Self-serve viability | High | **Critical** | Team 5 người, vibe-coder tự xài |
| 5 | Admin UI | Medium | Medium | Giữ nguyên |
| 6 | Docs & community | Medium | **High** | Longevity proxy |
| 7 | Stability (7d uptime) | High | High | Giữ nguyên |

### Tiêu chí bổ sung
- **C8 — Escape hatch quality**: app có thể migrate sang auth provider khác dễ không?
  - Test: thử export config dưới dạng IaC (Authentik blueprint / Zitadel YAML init)
  - App downstream chỉ phụ thuộc OIDC chuẩn, không xài proprietary extension

## Định hướng nghiêng

Trước data thực tế từ POC, **expectation của tôi**:
- Authentik **thắng** ở criteria 1, 3, 4 (DX, forward-auth, self-serve)
- Zitadel **thắng** ở criteria 6, 7 nếu commercial backing + audit log quan trọng
- Tie ở C8 nếu cả 2 đều export được IaC

→ Nếu POC ra kết quả Authentik thắng C1+C3+C4 với khoảng cách rõ → chốt Authentik.
→ Nếu Zitadel surprise (DX tốt hơn dự kiến) → cân nhắc lại.

## Rule cứng cho cả 2 POC

**Tất cả sample app downstream PHẢI**:
1. Dùng OIDC client library standard (`openid-client` / NextAuth / oauth2-proxy) — KHÔNG xài SDK proprietary
2. Config (client_id, secret, discovery_url, redirect_uri) lưu dưới dạng env vars, không hardcode
3. Document "how to switch auth provider" trong README mỗi app

→ Đảm bảo escape hatch luôn mở, bất kể chọn tool nào.
