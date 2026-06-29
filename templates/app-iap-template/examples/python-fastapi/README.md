# FastAPI + uvicorn — IAP Setup

Workflow setup FastAPI app để chạy phía sau oauth2-proxy.

## File structure giả định

```
my-fastapi-app/
├── requirements.txt
├── main.py             # FastAPI() instance ở đây
└── routers/
```

## 1. Dependency đọc IAP header

```python
# main.py
from fastapi import FastAPI, Header, HTTPException, Depends
from typing import Annotated

app = FastAPI()

class User:
    def __init__(self, email: str, sub: str | None, name: str | None):
        self.email = email
        self.sub = sub
        self.name = name

def get_current_user(
    x_auth_request_email: Annotated[str | None, Header()] = None,
    x_auth_request_user: Annotated[str | None, Header()] = None,
    x_auth_request_preferred_username: Annotated[str | None, Header()] = None,
) -> User:
    if not x_auth_request_email:
        raise HTTPException(status_code=401, detail="unauthorized")
    return User(
        email=x_auth_request_email,
        sub=x_auth_request_user,                          # UUID immutable
        name=x_auth_request_preferred_username,
    )

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/")
def home(user: Annotated[User, Depends(get_current_user)]):
    return {"hello": user.email, "sub": user.sub}
```

## 2. Apply globally (option)

Nếu muốn mọi route đều yêu cầu auth (trừ `/health`, `/docs`):

```python
from fastapi import Request

@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    if request.url.path in ("/health", "/docs", "/openapi.json"):
        return await call_next(request)
    if not request.headers.get("x-auth-request-email"):
        return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)
```

## 3. Async DB auto-provision (nếu nhóm B)

```python
from sqlalchemy.ext.asyncio import AsyncSession

async def get_or_create_user(db: AsyncSession, email: str, sub: str) -> User:
    # Bind theo sub (immutable), KHÔNG bind email
    user = await db.scalar(select(User).where(User.zitadel_subject == sub))
    if user is None:
        user = User(email=email, zitadel_subject=sub)
        db.add(user)
        await db.commit()
    return user
```

## 4. Copy Dockerfile + requirements + .dockerignore

```bash
cp ./Dockerfile ~/my-fastapi-app/
cp ./.dockerignore ~/my-fastapi-app/
cp ./requirements.txt.example ~/my-fastapi-app/requirements.txt
# Edit requirements.txt thêm libs theo app (sqlalchemy, asyncpg, ...)
```

Sửa Dockerfile nếu cần:
- Entry module khác `main:app` → đổi CMD `uvicorn <module>:<var>`
- Cần build deps cho lib native (psycopg, lxml) → thêm `apt-get install` trong build stage

## 5. Build + push

```bash
cd ~/my-fastapi-app
docker build -t ghcr.io/team/my-fastapi-app:v1.0.0 .

# Test local
docker run -p 3000:3000 ghcr.io/team/my-fastapi-app:v1.0.0
curl http://localhost:3000/health
curl http://localhost:3000/   # → 401
curl http://localhost:3000/ -H "X-Auth-Request-Email: test@example.com"
# → {"hello":"test@example.com","sub":null}

docker push ghcr.io/team/my-fastapi-app:v1.0.0
```

## 6. Deploy với template

```dotenv
# .env trong template
APP_HOSTNAME=my-fastapi-app.company.com
APP_IMAGE=ghcr.io/team/my-fastapi-app:v1.0.0
APP_PORT=3000
```

```bash
docker compose pull && docker compose up -d
```

## 7. Gỡ auth library cũ

Nếu app đang dùng:
- `python-jose`, `passlib`, `authlib` — gỡ khỏi requirements
- `fastapi-users`, `fastapi-login` — gỡ
- `OAuth2PasswordBearer`, `OAuth2AuthorizationCodeBearer` — thay bằng `Depends(get_current_user)`

## Special case: WebSocket

FastAPI WebSocket KHÔNG nhận `Header()` dependency trực tiếp. Đọc từ `websocket.headers`:

```python
@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    email = websocket.headers.get("x-auth-request-email")
    if not email:
        await websocket.close(code=4001); return
    await websocket.accept()
    # ...
```

Compose cần thêm `--upstream-timeout=86400s` cho oauth2-proxy để long-lived connection không bị cắt.

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| `uvicorn: command not found` | Pip install chưa add vào PATH → verify `ENV PATH=/home/app/.local/bin:$PATH` |
| `ImportError: cannot import name 'app' from 'main'` | Entry module sai → đổi CMD theo `<filename>:<FastAPI var>` |
| 502 từ oauth2-proxy | App chưa start xong. Tăng `--start-period=30s` trong HEALTHCHECK |
| Identity header lowercase / uppercase | FastAPI Header() tự convert. Verify spell underscore khớp |
