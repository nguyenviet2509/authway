# Django settings snippet cho IAP integration với oauth2-proxy.
# Copy/merge các block dưới vào settings.py của app.

import os

# ─── 1. Trust Traefik forward headers ───────────────────────
# Traefik + oauth2-proxy đặt Host, X-Forwarded-Proto, X-Forwarded-For.
# Django mặc định KHÔNG trust → CSRF + scheme detection fail.

USE_X_FORWARDED_HOST = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

# ─── 2. ALLOWED_HOSTS ────────────────────────────────────────
# Lấy từ env (set trong docker-compose.yml service `app:` block environment).
# Lab: thêm 'localhost', '127.0.0.1' khi dev local.

ALLOWED_HOSTS = [
    os.environ.get("APP_HOSTNAME", ""),
    "localhost",
    "127.0.0.1",
]

# ─── 3. CSRF trusted origins ────────────────────────────────
# Django ≥4 yêu cầu khai báo origins trust cho CSRF.

CSRF_TRUSTED_ORIGINS = [
    f"https://{os.environ.get('APP_HOSTNAME', '')}",
]

# ─── 4. IAP middleware — đọc header → set REMOTE_USER ───────
# Django built-in RemoteUserMiddleware đọc REMOTE_USER, ta cần shim
# map X-Auth-Request-Email → REMOTE_USER trước.

# Tạo file myapp/middleware.py:
#
#   class ZitadelHeaderMiddleware:
#       def __init__(self, get_response):
#           self.get_response = get_response
#       def __call__(self, request):
#           email = request.META.get("HTTP_X_AUTH_REQUEST_EMAIL")
#           if email:
#               request.META["REMOTE_USER"] = email
#           return self.get_response(request)

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "myapp.middleware.ZitadelHeaderMiddleware",                       # <— THÊM
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.auth.middleware.RemoteUserMiddleware",            # <— THÊM
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

AUTHENTICATION_BACKENDS = [
    "django.contrib.auth.backends.RemoteUserBackend",                 # <— DUY NHẤT
]

# RemoteUserBackend mặc định auto-tạo user khi login lần đầu — OK cho IAP.
# User instance: username = email. Tuỳ chỉnh thêm field bằng cách subclass:
#
#   class AuthwayBackend(RemoteUserBackend):
#       def configure_user(self, request, user, created=False):
#           # Lưu zitadel_subject (immutable) vào profile
#           sub = request.META.get("HTTP_X_AUTH_REQUEST_USER")
#           name = request.META.get("HTTP_X_AUTH_REQUEST_PREFERRED_USERNAME")
#           if sub:
#               user.first_name = name or ""
#               # Profile model lưu zitadel_subject
#           user.save()
#           return user

# ─── 5. Static files (nếu serve qua app — production thường để Traefik) ─
STATIC_URL = "/static/"
STATIC_ROOT = "/app/staticfiles"

# ─── 6. Logout URL ──────────────────────────────────────────
# Template render link: <a href="{% url 'logout' %}">  → /oauth2/sign_out
LOGOUT_REDIRECT_URL = "/oauth2/sign_out"

# Trong urls.py:
#   path("oauth2/sign_out", RedirectView.as_view(url="/oauth2/sign_out", permanent=False))
# (Django KHÔNG handle /oauth2/sign_out — oauth2-proxy bắt request này trước
#  khi đụng Django. Nhưng cần stub URL nếu reverse() được gọi.)

# ─── 7. KHÔNG dùng các thứ sau ──────────────────────────────
# - django-allauth, django-rest-auth, social-auth-app-django
# - django-axes (đã có lockout ở Zitadel)
# - django.contrib.auth views: LoginView, LogoutView form-based
#   (vì user không login qua Django form nữa)
