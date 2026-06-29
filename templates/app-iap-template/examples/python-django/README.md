# Django + gunicorn — IAP Setup

Workflow setup Django app để chạy phía sau oauth2-proxy. Đây là stack phức tạp nhất vì Django có nhiều integration point.

## File structure giả định

```
my-django-app/
├── manage.py
├── requirements.txt
├── myapp/                  # Django project root
│   ├── __init__.py
│   ├── settings.py
│   ├── urls.py
│   ├── wsgi.py
│   └── middleware.py       # CẦN TẠO MỚI (ZitadelHeaderMiddleware)
└── core/                   # Django app modules
```

## 1. Merge `settings-snippet.py` vào `settings.py`

File [`settings-snippet.py`](settings-snippet.py) trong folder này có 7 block cần merge:

1. `USE_X_FORWARDED_HOST`, `SECURE_PROXY_SSL_HEADER` — trust Traefik
2. `ALLOWED_HOSTS = [os.environ['APP_HOSTNAME'], ...]`
3. `CSRF_TRUSTED_ORIGINS = [f"https://{APP_HOSTNAME}"]`
4. Middleware chain — thêm `ZitadelHeaderMiddleware` + `RemoteUserMiddleware`
5. `AUTHENTICATION_BACKENDS = ["django.contrib.auth.backends.RemoteUserBackend"]`
6. `STATIC_ROOT`, `LOGOUT_REDIRECT_URL`
7. Danh sách package KHÔNG dùng nữa

**Mở file lên đọc + copy từng block** vào `myapp/settings.py`. Đây là phần quan trọng nhất.

## 2. Tạo file `myapp/middleware.py`

```python
# myapp/middleware.py
class ZitadelHeaderMiddleware:
    """
    Map X-Auth-Request-Email từ oauth2-proxy sang META['REMOTE_USER']
    để RemoteUserMiddleware built-in của Django auto-login user.
    """
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        email = request.META.get("HTTP_X_AUTH_REQUEST_EMAIL")
        if email:
            request.META["REMOTE_USER"] = email
            # Save sub + display name vào request để view dùng
            request.zitadel_sub = request.META.get("HTTP_X_AUTH_REQUEST_USER")
            request.zitadel_username = request.META.get("HTTP_X_AUTH_REQUEST_PREFERRED_USERNAME")
        return self.get_response(request)
```

## 3. Tạo health endpoint không yêu cầu auth

```python
# myapp/urls.py
from django.http import JsonResponse
from django.urls import path

def health(request):
    return JsonResponse({"ok": True})

urlpatterns = [
    path("health/", health),
    # ... rest
]
```

## 4. Tuỳ chỉnh user model (option)

Mặc định `RemoteUserBackend` tạo `User` với `username = email`. Nếu cần lưu `zitadel_subject` immutable:

```python
# myapp/backends.py
from django.contrib.auth.backends import RemoteUserBackend
from django.contrib.auth import get_user_model

class AuthwayBackend(RemoteUserBackend):
    def configure_user(self, request, user, created=False):
        if created:
            # Lần đầu user login → fill metadata từ Zitadel header
            user.first_name = getattr(request, 'zitadel_username', '') or ''
            user.save()
        return user

# settings.py:
# AUTHENTICATION_BACKENDS = ["myapp.backends.AuthwayBackend"]
```

Nếu cần field `zitadel_subject`, dùng AbstractUser hoặc Profile model:

```python
# core/models.py
from django.contrib.auth.models import AbstractUser
class User(AbstractUser):
    zitadel_subject = models.CharField(max_length=255, unique=True, null=True)
# settings.py: AUTH_USER_MODEL = "core.User"
```

## 5. Copy Dockerfile + requirements + .dockerignore

```bash
cp ./Dockerfile ~/my-django-app/
cp ./.dockerignore ~/my-django-app/
cp ./requirements.txt.example ~/my-django-app/requirements.txt
cp ./settings-snippet.py ~/my-django-app/   # reference, không phải import
```

Sửa Dockerfile:
- `DJANGO_SETTINGS_MODULE=myapp.settings` → đổi `myapp` theo tên project thật
- `gunicorn myapp.wsgi:application` → đổi theo project name
- Nếu app KHÔNG dùng PostgreSQL → bỏ `libpq-dev` / `libpq5`

## 6. Migration + Build + push

```bash
cd ~/my-django-app

# Test migration local
python manage.py makemigrations
python manage.py migrate

# Build image
docker build -t ghcr.io/team/my-django-app:v1.0.0 .

# Test container local (giả lập env var như compose)
docker run -p 3000:3000 \
  -e APP_HOSTNAME=localhost \
  -e DJANGO_SETTINGS_MODULE=myapp.settings \
  -e SECRET_KEY=test \
  -e DATABASE_URL=... \
  ghcr.io/team/my-django-app:v1.0.0

curl http://localhost:3000/health/   # → {"ok":true}
curl http://localhost:3000/ -H "X-Auth-Request-Email: test@example.com"
# → 200 với user tự auto-create

docker push ghcr.io/team/my-django-app:v1.0.0
```

## 7. Deploy với template

```dotenv
# .env trong template
APP_HOSTNAME=my-django-app.company.com
APP_IMAGE=ghcr.io/team/my-django-app:v1.0.0
APP_PORT=3000
```

Thêm vào `docker-compose.yml` block `app:` environment vars Django cần:

```yaml
app:
  image: ${APP_IMAGE}
  environment:
    APP_HOSTNAME: ${APP_HOSTNAME}
    DJANGO_SETTINGS_MODULE: myapp.settings
    SECRET_KEY: ${DJANGO_SECRET_KEY}
    DATABASE_URL: postgresql://user:pass@db:5432/myapp
```

```bash
docker compose pull && docker compose up -d
docker compose exec app python manage.py migrate   # chạy migration lần đầu
```

## 8. Gỡ auth packages cũ

Trong `requirements.txt` và `settings.py.INSTALLED_APPS`:

- ❌ `django-allauth`
- ❌ `django-rest-auth` / `dj-rest-auth`
- ❌ `social-auth-app-django`
- ❌ `djangorestframework-simplejwt`
- ❌ `django-axes` (Zitadel đã có lockout)
- ❌ Custom `LoginView`/`LogoutView` form-based

Trong `urls.py` xoá:
- `path('accounts/', include('allauth.urls'))`
- `path('api/auth/', include('dj_rest_auth.urls'))`
- Custom login/register/reset routes

## Special case: Django REST Framework API

DRF endpoint cũng đọc `request.user` (đã auto-set bởi RemoteUserMiddleware):

```python
# views.py
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated

class MeView(APIView):
    permission_classes = [IsAuthenticated]
    def get(self, request):
        return Response({"email": request.user.email})
```

DRF settings:

```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.RemoteUserAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
}
```

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| `DisallowedHost` exception | Verify `ALLOWED_HOSTS` chứa `APP_HOSTNAME` từ env |
| CSRF token missing/incorrect | Set `CSRF_TRUSTED_ORIGINS=[f"https://{APP_HOSTNAME}"]` |
| `RemoteUserMiddleware` không activate | Verify thứ tự middleware: ZitadelHeaderMiddleware TRƯỚC `AuthenticationMiddleware` |
| User tạo nhưng `is_active=False` | RemoteUserBackend mặc định `is_active=True`. Verify không có signal block |
| `collectstatic` fail trong Dockerfile build | Thiếu `STATIC_ROOT` setting hoặc DB connection trong settings — wrap migration check |
| Migration không chạy | `docker compose exec app python manage.py migrate` thủ công lần đầu |
| Static file 404 | Traefik không serve static. Dùng whitenoise hoặc mount static folder vào Traefik |
