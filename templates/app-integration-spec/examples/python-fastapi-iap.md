# Reference — Python FastAPI + oauth2-proxy IAP (Pattern A)

App backend Python dùng FastAPI/Flask/Django. Refactor delta ~5 dòng.

## Deps

**KHÔNG add OIDC library.** oauth2-proxy sidecar handle. FastAPI built-in Header dependency đủ.

## `.env.example`

```env
# Cấp bởi Central RBAC portal
OIDC_ISSUER=http://10.200.0.125
CLIENT_ID=387047455193104387
CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxx

# App
APP_HOST=myapp.example.com
APP_PORT=8000

# oauth2-proxy
COOKIE_SECRET=change-me-32-random-bytes-base64
```

## App code (FastAPI)

```python
# main.py
from fastapi import FastAPI, Header, HTTPException, Depends
from typing import Annotated, Optional
from dataclasses import dataclass
import os

app = FastAPI()


@dataclass
class User:
    email: str
    username: str
    roles: list[str]


async def get_current_user(
    x_auth_request_email: Annotated[Optional[str], Header()] = None,
    x_auth_request_preferred_username: Annotated[Optional[str], Header()] = None,
    x_auth_request_groups: Annotated[Optional[str], Header()] = None,
) -> Optional[User]:
    if not x_auth_request_email:
        return None
    roles = [r for r in (x_auth_request_groups or "").split(",") if r]
    return User(
        email=x_auth_request_email,
        username=x_auth_request_preferred_username or x_auth_request_email.split("@")[0],
        roles=roles,
    )


async def require_auth(user: Annotated[Optional[User], Depends(get_current_user)]) -> User:
    if not user:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return user


# Bypass IAP cho ops monitor
@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready():
    return {"status": "ready"}


@app.get("/")
def index(user: Annotated[User, Depends(require_auth)]):
    logout_url = f"/oauth2/sign_out?rd=https%3A%2F%2F{os.environ['APP_HOST']}%2F"
    return {"message": f"Hello {user.email}", "logout": logout_url}


@app.get("/api/me")
def me(user: Annotated[User, Depends(require_auth)]):
    return {"email": user.email, "username": user.username, "roles": user.roles}


# Nếu dùng uvicorn — CRITICAL bind 127.0.0.1
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("APP_PORT", 8000)))
```

## Run

```bash
# Development
uvicorn main:app --host 127.0.0.1 --port 8000

# Production (gunicorn + uvicorn worker)
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 127.0.0.1:8000
```

**CRITICAL: `--bind 127.0.0.1`** — NEVER `0.0.0.0`.

## Django notes

Nếu app Django:
- Add middleware `RemoteUserMiddleware`
- Set `AUTHENTICATION_BACKENDS = ['django.contrib.auth.backends.RemoteUserBackend']`
- Custom middleware map `X-Auth-Request-Email` → `request.META['REMOTE_USER']`

```python
# middleware.py
class OAuth2ProxyHeaderMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        email = request.headers.get('X-Auth-Request-Email')
        if email:
            request.META['REMOTE_USER'] = email
        return self.get_response(request)
```

Add trước `RemoteUserMiddleware` trong `MIDDLEWARE` list.

## Flask notes

```python
from flask import Flask, request, g, abort

app = Flask(__name__)

@app.before_request
def load_user():
    email = request.headers.get('X-Auth-Request-Email')
    if email:
        g.user = {
            'email': email,
            'username': request.headers.get('X-Auth-Request-Preferred-Username', email.split('@')[0]),
            'roles': [r for r in request.headers.get('X-Auth-Request-Groups', '').split(',') if r],
        }
    else:
        g.user = None

@app.route('/api/me')
def me():
    if not g.user:
        abort(401)
    return g.user

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8000)
```

## oauth2-proxy config + Caddyfile

Giống Node reference — xem `nodejs-express-iap.md` sections "oauth2-proxy config" và "Caddyfile". Chỉ đổi upstream port `3000` → `8000`.

## What AI must NOT change

- Pydantic models / SQLAlchemy models
- Existing DB migrations (alembic)
- Business logic endpoints (chỉ add `Depends(require_auth)`)
- Middleware ngoài auth (CORS, GZip, etc.)

## Refactor delta

1. Xoá: session middleware cũ (VD `starlette-session`, `flask-login`), passport-like packages, login form endpoints
2. Add: `get_current_user` + `require_auth` dependencies (20 dòng)
3. Add: `Depends(require_auth)` vào endpoint cần bảo vệ
4. Update: uvicorn/gunicorn bind `127.0.0.1`
5. Update: logout link → `/oauth2/sign_out?rd=...`

## Validation

```bash
# 1. App bind local only
ss -tlnp | grep 8000
# Expect: 127.0.0.1:8000

# 2. Direct app hit với header giả
curl -H "X-Auth-Request-Email: test@example.com" http://127.0.0.1:8000/api/me
# Expect: {"email":"test@example.com",...}

# 3. Reverse proxy public
curl -sI https://myapp.example.com/
# Expect: 302 Location /oauth2/start?rd=...
```
