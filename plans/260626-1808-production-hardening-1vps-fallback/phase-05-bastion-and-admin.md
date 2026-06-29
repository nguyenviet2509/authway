# Phase 05 — Bastion SSH + Break-glass Admin Sealing

## Context
- Parent plan: [plan.md](plan.md)
- Effort: 0.5 ngày

## Overview
**Priority**: P2

SSH trực tiếp từ workstation → root VPS-A là gap. Workstation compromise = root auth-vps = decrypt masterkey = game over. Thêm bastion làm choke point + audit. Break-glass admin account hoá rõ ràng + sealed credential.

## Requirements
- 1 VPS-D nhỏ (1GB, ~$5/tháng) hoặc tái sử dụng VPS-C
- 5 dev có SSH pubkey
- 1 founder + 1 senior cho break-glass admin Zitadel

## Files to Create
- `/etc/ssh/sshd_config.d/bastion.conf` trên VPS-A/B (chỉ accept SSH từ bastion IP)
- `/etc/ssh/ssh-ca/` trên bastion (SSH CA pubkey distribute tới VPS-A/B)
- `docs/admin-break-glass-runbook.md`

## Implementation Steps

1. **Provision VPS-D bastion** (Ubuntu 24.04, 1GB)
   - UFW: allow SSH 22 từ workstation IP (static) hoặc OpenVPN subnet only
   - fail2ban + auditd
   - Logs ship sang VPS-C Loki

2. **SSH cert-based**
   - Bastion làm SSH CA: `ssh-keygen -f /root/.ssh/ssh-ca`
   - VPS-A/B `sshd_config`: `TrustedUserCAKeys /etc/ssh/ssh-ca.pub`
   - User cấp cert có TTL 8h: `ssh-keygen -s ssh-ca -I "user-$USER" -V +8h -n authops user_pubkey.pub`
   - Auto-renew script lúc login bastion

3. **VPS-A/B sshd hardening**
   - `PasswordAuthentication no`
   - `PermitRootLogin no`
   - `AllowUsers authops` only (qua cert)
   - `Match Address <bastion_ip>` → other addresses denied
   - Reload sshd

4. **Workstation flow**
   ```
   workstation → SSH bastion (key auth) → bastion SSH cert sign → ssh authops@vps-a (cert auth)
   ```

5. **Break-glass admin Zitadel**
   - Tạo 2 admin Zitadel:
     - **Primary**: senior dev, daily use
     - **Break-glass**: founder. TOTP device riêng (Yubikey hoặc TOTP app trên thiết bị KHÔNG dùng hàng ngày). Password trong sealed envelope.
   - Procedure sealing:
     1. Founder set password mạnh + bind TOTP
     2. In credential ra giấy
     3. Cho vào envelope, dán seal có chữ ký
     4. Cất safe văn phòng
     5. Test recovery 6 tháng/lần: mở envelope, login, đổi password, seal lại
   - Break-glass admin có quyền: `IAM_OWNER`, KHÔNG dùng cho daily ops

6. **Offboarding workflow** doc
   - Trigger: HR notify
   - SLA < 1h:
     1. Zitadel: deactivate user (UI hoặc CLI)
     2. OpenVPN: revoke cert + CRL update
     3. Bastion: remove pubkey + revoke SSH cert
     4. Git/GitHub: remove access
   - Document checklist
   - Quarterly review: list user inactive > 90d → auto-disable

7. **Monthly review**
   - VPN cert holder list
   - Bastion user list
   - Zitadel admin list
   - Cross-check với HR roster

## Todo
- [ ] Provision VPS-D bastion
- [ ] Generate SSH CA, distribute pubkey VPS-A/B
- [ ] Lock down sshd VPS-A/B (no password, cert only, from bastion)
- [ ] Test workstation → bastion → VPS-A flow
- [ ] Test direct SSH workstation → VPS-A bypass: must be denied
- [ ] Tạo break-glass admin Zitadel + seal credential
- [ ] Test recovery procedure 1 lần
- [ ] Write offboarding runbook + checklist
- [ ] Schedule first quarterly review

## Success Criteria
- SSH direct workstation → VPS-A: connection refused
- SSH workstation → bastion → VPS-A: success, audit log đầy đủ trên bastion
- Bastion logs visible trong Loki
- Break-glass envelope tồn tại physical, founder verify recovery procedure
- Offboarding test: deactivate user e2e < 1h

## Risks
- **Bastion = SPoF ops access** → mitigation: emergency console access qua provider web (out-of-band), document trong runbook
- **SSH CA private key leak** → toàn bộ VPS compromise. Mitigation: CA key offline, sign cert qua secure HSM-style script
- **Break-glass envelope mất** → founder không recovery được. Mitigation: 2 envelope tại 2 nơi (văn phòng + nhà founder)
- **Founder mất TOTP device** → break-glass bricked. Mitigation: TOTP seed in sealed envelope cùng password

## Reference
- SSH cert auth: https://man.openbsd.org/ssh-keygen#CERTIFICATES
- Zitadel IAM_OWNER role docs
