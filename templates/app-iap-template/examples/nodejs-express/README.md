# Node.js Express / Fastify / NestJS — IAP Setup

Workflow setup app Node.js để chạy phía sau oauth2-proxy.

## File structure giả định

```
my-express-app/
├── package.json
├── server.js               # entry, listens process.env.PORT
├── routes/
└── ... (logic app)
```

## 1. Sửa entry point listen `0.0.0.0:PORT`

App phải listen `0.0.0.0` (không phải `127.0.0.1`) để Docker network reach được.

```js
// server.js
const express = require('express');
const app = express();

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Listening on 0.0.0.0:${PORT}`);
});
```

## 2. Thêm middleware đọc IAP header (~15 LOC)

```js
// Đặt TRƯỚC mọi route protected (idealy app.use ở root)
app.use((req, res, next) => {
  const email = req.get('X-Auth-Request-Email');
  if (!email) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  req.user = {
    email,
    sub: req.get('X-Auth-Request-User'),               // UUID immutable
    name: req.get('X-Auth-Request-Preferred-Username'),
  };
  next();
});

// Health endpoint — KHÔNG protected
app.get('/health', (req, res) => res.json({ ok: true }));

// Logout — chỉ là HTML link, không phải route handler
// Trong template HTML/EJS/React: <a href="/oauth2/sign_out">Logout</a>
```

**KHÔNG** cài `passport`, `next-auth`, `jsonwebtoken`. oauth2-proxy đã handle hết.

## 3. Health endpoint

Thêm endpoint `/health` trả 200 (Dockerfile HEALTHCHECK gọi vào):

```js
app.get('/health', (req, res) => res.json({ ok: true, ts: Date.now() }));
```

Phải đặt **TRƯỚC** middleware auth (để Docker daemon health check không cần header).

## 4. Copy Dockerfile + .dockerignore

```bash
cp ./Dockerfile ~/my-express-app/
cp ./.dockerignore ~/my-express-app/
```

Sửa nếu cần:
- TypeScript build → uncomment `RUN npm run build` + COPY dist
- Server entry path → đổi `CMD ["node", "server.js"]` thành path thực

## 5. Build + push image

```bash
cd ~/my-express-app
docker build -t ghcr.io/team/my-express-app:v1.0.0 .

# Login + push
docker login ghcr.io
docker push ghcr.io/team/my-express-app:v1.0.0

# Test local trước khi push lên prod:
docker run -p 3000:3000 -e PORT=3000 ghcr.io/team/my-express-app:v1.0.0
# Browser: http://localhost:3000/health → {"ok":true}
# Browser: http://localhost:3000/ → 401 (vì không có X-Auth-Request-Email header)
```

## 6. Deploy với template `app-iap-template/`

Trên VPS, trong folder template:

```dotenv
# .env
APP_HOSTNAME=my-express-app.company.com
APP_IMAGE=ghcr.io/team/my-express-app:v1.0.0
APP_PORT=3000
# ... (các biến Zitadel còn lại)
```

```bash
docker compose pull
docker compose up -d
```

## 7. Smoke test

```bash
# Browser incognito → https://my-express-app.company.com/
# Expect: redirect Zitadel login → MFA → back to app
```

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| Container exit ngay sau khi start | Verify CMD entry path: `docker logs <container>` |
| Healthcheck unhealthy | `/health` route đặt SAU middleware auth → đổi thứ tự |
| `EADDRINUSE: address already in use 0.0.0.0:3000` | App config listen 127.0.0.1 thay vì 0.0.0.0 |
| Identity = undefined trong app | Verify oauth2-proxy upstream trỏ đúng port app (4180 → 3000) |
