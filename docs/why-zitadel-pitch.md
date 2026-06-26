# Vì sao team cần Zitadel — Tài liệu thuyết phục

> Material trình bày nội bộ. Lý do đầu tư centralized auth (Zitadel) thay cho IP whitelist + shared account.

---

## 1. Bài toán

Team kỹ thuật 5 người, mỗi người build 1 app quản lý infrastructure:
- **Quản lý server** — SSH/API tới VPS production
- **Quản lý hosting** — DNS, domain
- **Quản lý mail** — đọc/quản lý mailbox công ty
- ... (các app khác tương tự)

**Auth hiện tại**: IP whitelist nội bộ HOẶC account cố định (shared/fixed credentials).

---

## 2. Risk profile — không phải app bình thường

Đây là **infrastructure management tools**, không phải app demo:

| App | Quyền hành thực tế khi bị compromise |
|---|---|
| Quản lý server | SSH/API tới VPS, xoá/restart, exfiltrate data |
| Quản lý hosting | Đổi DNS A record → MITM, phishing toàn công ty |
| Quản lý mail | Đọc OTP/reset password → **leo thang vào MỌI Google/GitHub/AWS account** |

→ **Compromise 1 app = compromise toàn bộ công ty.** Risk level: CRITICAL.

---

## 3. Rủi ro của cách auth cũ

### A. IP whitelist only — "trust the network"

1. **Office IP = god mode**
   Ai vào được mạng (intern mới, contractor, khách thử Wi-Fi, máy nhiễm malware) đều có toàn quyền vào tool quản lý server. Không có identity → không biết AI làm GÌ.

2. **Lateral movement chí mạng**
   1 laptop dev bị nhiễm malware → attacker pivot trong LAN → đụng đủ mọi tool admin → game over. Đây là pattern ransomware phổ biến nhất hiện nay.

3. **Audit trail = ZERO**
   Tool xoá VPS / đổi DNS xong sự cố nổ ra → không biết ai làm, không có forensic. Customer kiện hoặc audit → không trả lời được.

4. **Insider threat**
   Nhân viên cũ vẫn còn VPN config / ssh key → vẫn vào được mạng nội bộ → vào tool admin. **Centralized revoke không tồn tại.**

5. **WFH/remote pain**
   VPN xuống = cả team đứng việc. Dev đi công tác dùng 4G → fail. Team thường "mở rộng whitelist tạm" → mất kiểm soát.

### B. Account cố định / shared

1. **Password sharing = leak time bomb**
   5 người biết `admin/Admin@2024` → commit nhầm git, screenshot Slack, paste ChatGPT. 1 leak = toàn bộ tool admin compromise.

2. **Zero accountability**
   Log: "admin xoá database production". Là Anh A, B, C, D hay E? Không biết. Incident response = bế tắc.

3. **Offboarding = nightmare**
   Dev nghỉ việc → phải đổi password TẤT CẢ shared accounts trên TẤT CẢ apps. Thực tế: thường bỏ sót → dev cũ vẫn vào được tool admin 6 tháng sau.

4. **MFA gần như không thể**
   Shared account thì ai keep TOTP device? Mỗi lần login hỏi nhau OTP qua Slack. → Không bật MFA → password leak là xong.

5. **Password reuse**
   Dev đặt password đơn giản hoặc reuse từ account cá nhân → 1 dev bị leak ở site khác → attacker thử cùng password vào tool admin → trúng.

6. **Không có least-privilege**
   Mọi người đều "admin". Intern mới ngày đầu cũng có quyền xoá VPS production. Junior không nên touch DNS nhưng vẫn có. Vi phạm nguyên tắc bảo mật cơ bản nhất.

### C. Combine cả 2 (IP whitelist + shared account) — vẫn không cứu

- IP whitelist = lớp network, không thay được identity
- Shared account = lớp identity nhưng không có accountability
- → Vẫn KHÔNG biết ai làm gì. KHÔNG revoke nhanh. KHÔNG MFA.

---

## 4. Zitadel giúp gì cụ thể

| Vấn đề cũ | Zitadel giải |
|---|---|
| Không biết ai làm gì | **Identity per person** — mỗi dev account riêng, audit log gắn tên cụ thể |
| Password leak là xong | **MFA bắt buộc** (Passkey/TOTP) — leak password vẫn không vào được |
| Offboarding sót | **Centralized revoke** — disable 1 click → mất quyền tất cả app ngay |
| Intern và senior cùng god mode | **Role/grants** — read-only cho intern, admin cho senior (least privilege) |
| Forensic = 0 | **Event-sourced audit log** — mọi login/permission change immutable, exportable |
| Laptop bị mượn lúc đi WC | **Session timeout** — hết giờ phải login + MFA lại |
| Password yếu/reuse | **Password policy** + check haveibeenpwned built-in |
| Compliance (ISO27001/SOC2) fail | **Audit-ready** — log đủ qua audit |

---

## 5. Tại sao IP whitelist vẫn nên GIỮ song song

**Defense in depth** — không thay thế, cộng dồn:

| Layer | Cơ chế | Chặn gì |
|---|---|---|
| 1. Network | IP whitelist + VPN | Attacker ngoài mạng không đụng được URL login |
| 2. Identity | Zitadel + MFA | Attacker trong mạng vẫn cần credential + MFA |
| 3. Authorization | App-level role/grants | Vào được hệ thống cũng chỉ làm phần được grant |

1 layer fail, 2 layer còn lại đỡ. Hiện tại chỉ có 1 layer (network) — nếu fail là **trắng tay**.

---

## 6. Cost vs Risk

| Khoản | Cost |
|---|---|
| VPS Zitadel (4GB RAM) | ~$10–20/tháng |
| Setup ban đầu | ~1 tuần (1 dev part-time) |
| Migrate 10 app | ~3–5 ngày tổng (chi tiết trong [Legacy app migration brainstorm](../plans/reports/brainstorm-260626-1328-legacy-app-migration.md)) |
| Onboard app mới sau khi có template | 5–15 phút/app |

**So sánh với 1 incident**:
- Mất 1 ngày downtime hosting do DNS bị đổi: tổn thất uy tín + khách hàng
- Mail admin bị compromise → leo thang AWS → bill DDoS / mining → vài chục triệu đến vài trăm triệu
- Customer data leak → kiện, GDPR, mất hợp đồng

→ **Zitadel rẻ hơn 1 incident.**

---

## 7. Verdict — One-liner cho stakeholder

> "5 app này nắm chìa khoá toàn công ty. Cách auth hiện tại không biết ai làm gì, không revoke được nhanh, không có MFA. 1 laptop nhiễm malware là mất tất cả. Zitadel = identity + MFA + audit log + 1-click revoke với chi phí $20/tháng và 1 tuần setup."

---

## 8. Liên kết tài liệu kỹ thuật

- Architecture & rollout plan: [plans/260626-1154-zitadel-iap-rollout/plan.md](../plans/260626-1154-zitadel-iap-rollout/plan.md)
- Brainstorm gốc về kiến trúc IAP: [plans/reports/brainstorm-260626-1154-zitadel-iap-rollout.md](../plans/reports/brainstorm-260626-1154-zitadel-iap-rollout.md)
- Migration patterns cho app cũ: [plans/reports/brainstorm-260626-1328-legacy-app-migration.md](../plans/reports/brainstorm-260626-1328-legacy-app-migration.md)

---

## 9. Câu hỏi thường gặp (FAQ)

**Q: Sao không dùng Google Workspace SSO trực tiếp?**
A: Google chỉ là IdP, không có forward-auth proxy cho app zero-auth, không có audit centralized cho action trong app. Có thể dùng Google làm federation source CỦA Zitadel sau này.

**Q: Sao không dùng Cloudflare Access?**
A: SaaS — phụ thuộc internet, dữ liệu login đi qua Cloudflare. Self-host Zitadel = full control. Lựa chọn được nếu chấp nhận SaaS.

**Q: Zitadel down thì cả team không vào được app?**
A: Đúng — single point of failure. Mitigation: HA setup (replica + managed Postgres) trong giai đoạn rollout production. POC chấp nhận 1 instance.

**Q: Dev quên Passkey/MFA device?**
A: Admin reset trong Zitadel <1 phút. Workflow document trong admin runbook.

**Q: Bao giờ ROI?**
A: Ngay lần offboarding đầu tiên (tiết kiệm 2–3 giờ đổi password manual + closure các sót). Hoặc ngay lần incident đầu cần audit log (vô giá).
