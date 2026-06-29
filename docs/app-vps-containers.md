# App-VPS Containers — Member Project

> Tổng hợp các container chạy trên **app-vps** (VPS của member chạy ứng dụng được bảo vệ bởi Authway IAP).

## 3 pattern triển khai

| Pattern | Use case | Số container |
|---|---|---|
| **A. Template 1 app** ([`templates/app-iap-template/`](../templates/app-iap-template/docker-compose.yml)) | App có Dockerfile, chuẩn cho member | **3** |
| **B. Lab demo 2 app** ([`infra/app-vps/`](../infra/app-vps/docker-compose.yml)) | Reference stack — Next.js + static | **5** |
| **C. App native host** (xem [§ C](#c-app-native-trên-host--2-container)) | App chạy thẳng trên host (Node/PHP/Python/Go), không Docker | **2** |

**Công thức (pattern A, B):** `N container = 1 (Traefik) + 2 × (số app trong Docker)`

**Nguyên tắc:** 1 app = 1 OIDC client = 1 oauth2-proxy = 1 cookie-domain riêng. Không có SSO cookie cross-app (do public-suffix); SSO chung qua **Zitadel session**.

## Kiến trúc tổng quan

```
Internet ──HTTPS──► Traefik (sole ingress, TLS)
                      │
          ┌───────────┴───────────┐    ← N nhánh = N app
          ▼                       ▼
    oauth2-proxy-A          oauth2-proxy-B       ← IAP gate (OIDC với Zitadel)
          │                       │
          ▼                       ▼
        app-A                   app-B            ← App nội bộ (network: internal)

                  ▲
                  │ OIDC (issuer)
                  ▼
            Zitadel @ auth-vps
```

---

## A. Template — 1 app (3 container)

Đây là cấu hình **member sẽ dùng** khi copy `templates/app-iap-template/` lên VPS riêng.

| # | Service | Image | Vai trò |
|---|---|---|---|
| 1 | `traefik` | `traefik:v3.4` | **Sole ingress**. Bind `:80`/`:443`, terminate TLS, route `Host(${APP_HOSTNAME})` → oauth2-proxy. |
| 2 | `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:v7.7.1` | **IAP gate**. Handle toàn bộ OIDC flow với Zitadel. Inject header `X-Auth-Request-*` xuống app. KHÔNG pass access token. Forward upstream `http://app:${APP_PORT}`. |
| 3 | `app` | `${APP_IMAGE}` (member tự chọn / build) | **App của member**. Network `internal` only, **không** có Traefik label → chỉ reachable qua oauth2-proxy. |

### Env vars bắt buộc (template)

```env
APP_HOSTNAME=app.example.com
APP_IMAGE=ghcr.io/yourorg/yourapp:tag
APP_PORT=3000

APP_CLIENT_ID=...
APP_CLIENT_SECRET=...
APP_COOKIE_SECRET=...           # openssl rand -base64 32

ZITADEL_ISSUER_URL=https://auth.example.com
ZITADEL_HOSTNAME=auth.example.com
ZITADEL_IP=<auth-vps IP>        # chỉ cần ở lab (self-signed cert) — production xoá
```

---

## B. Lab demo `infra/app-vps` — 2 app (5 container)

Stack tham chiếu trên VPS lab — chạy đồng thời 2 sample app để verify pattern multi-app.

| # | Container | Image | Service | Vai trò |
|---|---|---|---|---|
| 1 | `authway-app-traefik-1` | `traefik:v3.4` | `traefik` | Ingress duy nhất. |
| 2 | `authway-app-oauth2-proxy-nextjs-1` | `oauth2-proxy:v7.7.1` | `oauth2-proxy-nextjs` | IAP gate cho Next.js app. |
| 3 | `authway-app-nextjs-demo-1` | `authway-app-nextjs-demo` (build từ `sample-apps/nextjs-iap-demo`) | `nextjs-demo` | App Next.js, `internal` only. |
| 4 | `authway-app-oauth2-proxy-static-1` | `oauth2-proxy:v7.7.1` | `oauth2-proxy-static` | IAP gate cho static app (client_id/cookie riêng). |
| 5 | `authway-app-static-demo-1` | `nginx:1.27-alpine` | `static-demo` | Static HTML demo, `internal` only. |

### Vì sao 2 app phải tách 2 oauth2-proxy riêng

- Mỗi app có `client_id` / `client_secret` / `cookie-secret` riêng.
- `cookie-domain` = hostname app → không share cookie giữa 2 TLD khác nhau.
- `cookie-refresh=1h` → revoke từ Zitadel propagate < 1h.
- `whitelist-domain=${ZITADEL_HOSTNAME}` → cho phép logout redirect về Zitadel.

---

## C. App native trên host — 2 container

Khi app **không chạy trong Docker** (Node `pm2`, PHP-FPM, Python `gunicorn`, Go binary, …), chỉ cần 2 container Docker: `traefik` + `oauth2-proxy`. App chạy native, oauth2-proxy trỏ upstream về host.

### Sửa compose từ template

```yaml
oauth2-proxy:
  command:
    # ... giữ nguyên các flag OIDC ...
    - --upstream=http://host.docker.internal:${APP_PORT}   # ← trỏ về host
  extra_hosts:
    - "host.docker.internal:host-gateway"                   # ← Linux bắt buộc
    - "${ZITADEL_HOSTNAME}:${ZITADEL_IP:-127.0.0.1}"

# Xoá hẳn service `app:` và network `internal`
```

### ⚠️ CRITICAL: App BẮT BUỘC bind `127.0.0.1`

Nếu sai → **IAP bị bypass hoàn toàn**.

| App bind | Hậu quả |
|---|---|
| `127.0.0.1:<port>` | ✅ Chỉ oauth2-proxy (qua `host-gateway`) reach được |
| `0.0.0.0:<port>` | ❌ Internet hit thẳng `http://vps-ip:<port>`, **bypass oauth2-proxy** |

Ví dụ:

```bash
node server.js --host 127.0.0.1 --port 3000
gunicorn -b 127.0.0.1:3000 app:app
# Go: http.ListenAndServe("127.0.0.1:3000", ...)
```

**Verify:** `curl http://<vps-ip>:<port>` từ máy ngoài phải **timeout / refused**. Chỉ `https://${APP_HOSTNAME}` qua Traefik mới vào được. Bổ sung firewall cho chắc: `ufw deny <APP_PORT>`.

### Trade-off pattern C

| Mất | Được |
|---|---|
| Network isolation tự động (phải kỷ luật bind 127.0.0.1) | Khỏi đóng image |
| Restart/health check thống nhất (tự quản qua systemd/pm2) | Iterate nhanh khi dev |
| Reproducibility (dependencies trên host) | Hợp app legacy / PHP-FPM |

**Khuyến nghị:** production nên ưu tiên pattern A (Docker). Pattern C dùng cho dev hoặc app legacy không thể container hoá.

---

## Network layout (pattern A, B)

| Network | Thành viên | Mục đích |
|---|---|---|
| `edge` | traefik, các oauth2-proxy | Public-facing — Traefik ↔ oauth2-proxy |
| `internal` | các oauth2-proxy, các app | Private — oauth2-proxy ↔ upstream app |

App upstream **chỉ** ở `internal` → không có route public → không thể bypass IAP.

---

## Quy trình deploy cho member (dùng template)

1. Copy `templates/app-iap-template/` lên VPS.
2. Tạo OIDC client trên Zitadel → lấy `APP_CLIENT_ID` + `APP_CLIENT_SECRET`.
3. Sinh `APP_COOKIE_SECRET`: `openssl rand -base64 32`.
4. Fill `.env` (xem mục env vars phía trên) + đặt `APP_IMAGE`/`APP_PORT`.
5. Cấu hình DNS `${APP_HOSTNAME}` → IP app-vps + cert TLS.
6. `docker compose up -d` → 3 container chạy.

### Thêm app thứ 2 trở đi

Lặp pattern lab demo: thêm 1 cặp `oauth2-proxy-<app>` + `<app>` (với client_id/cookie riêng) vào cùng compose. Số container tăng thêm 2.
