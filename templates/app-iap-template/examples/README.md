# Dockerfile Examples — App IAP

Sample Dockerfile cho các stack phổ biến. Copy folder tương ứng vào project app, đổi tên thành `Dockerfile` ở root, build → tag → push registry → fill `APP_IMAGE` trong `.env` của template.

## Quy ước chung cho mọi Dockerfile

- **Multi-stage build** — image production nhỏ, không kèm build tools
- **Non-root user** — chạy app với uid riêng (security)
- **Listen `0.0.0.0:$APP_PORT`** — container internal, oauth2-proxy gọi qua docker network
- **HEALTHCHECK** — Docker daemon biết container ready, restart nếu unhealthy
- **`.dockerignore`** — loại bỏ `.git`, `node_modules`, `.env`, build artifacts khỏi context

## Pick stack

| Stack | Folder | Notes |
|---|---|---|
| Node.js Express / Fastify / NestJS | [nodejs-express/](nodejs-express/) | Pattern phổ thông |
| Next.js (App Router, SSR) | [nodejs-nextjs/](nodejs-nextjs/) | Standalone output mode (Next ≥13) |
| Go (net/http, Gin, Echo, Fiber) | [go/](go/) | Static binary, image final ~10MB |
| Python FastAPI + uvicorn | [python-fastapi/](python-fastapi/) | Async pattern |
| Python Django + gunicorn | [python-django/](python-django/) | + `settings-snippet.py` cho IAP |
| Python Flask + gunicorn | [python-flask/](python-flask/) | Sync, WSGI |

## Build + push registry workflow

```bash
# Build local
cd /path/to/your-app
docker build -t ghcr.io/team/myapp:latest .

# Tag với version
docker tag ghcr.io/team/myapp:latest ghcr.io/team/myapp:v1.0.0

# Push (login trước nếu chưa)
docker login ghcr.io
docker push ghcr.io/team/myapp:latest
docker push ghcr.io/team/myapp:v1.0.0

# Trong template .env trên VPS:
# APP_IMAGE=ghcr.io/team/myapp:v1.0.0
```

## Build local thay vì push registry (KISS)

Sửa `docker-compose.yml` trong template:
```yaml
app:
  # image: ${APP_IMAGE}    # comment dòng này
  build:
    context: ./app-src     # path tới source code app
    dockerfile: Dockerfile
```

Trade-off: VPS phải build → cần ≥1GB RAM build time, lần đầu chậm.

## Trường hợp đặc biệt — cần đụng oauth2-proxy config

| App pattern | Sửa gì trong `docker-compose.yml` |
|---|---|
| WebSocket (Socket.IO, ws, Phoenix LiveView) | Thêm `--upstream-timeout=86400s` flag |
| SSE / streaming response | Thêm `--upstream-timeout=300s`, set Traefik streaming |
| Large file upload (>1MB) | Thêm Traefik middleware `buffering.maxRequestBodyBytes=...` |
| gRPC server | KHÔNG dùng oauth2-proxy — bypass, app tự verify OIDC token |

## Lưu ý CHUNG cho app code khi đọc identity

App container nhận 3 header từ oauth2-proxy:

| Header | Nội dung |
|---|---|
| `X-Auth-Request-Email` | Email user (vd `john@company.com`) |
| `X-Auth-Request-User` | UUID immutable từ Zitadel (`sub`) — dùng làm primary key DB |
| `X-Auth-Request-Preferred-Username` | Display name |

App phải:
1. Đọc header ở mọi protected route (middleware-level)
2. Bind theo `X-Auth-Request-User` (immutable), KHÔNG bind theo email (user có thể đổi email)
3. Trả 401 nếu header thiếu (nghĩa là không có session, oauth2-proxy chưa inject)
4. Logout link `<a href="/oauth2/sign_out">Logout</a>` (oauth2-proxy handle)

App KHÔNG cần:
- Cài OIDC library
- Implement `/oauth2/callback`
- Verify JWT
- Quản session/cookie
