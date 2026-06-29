# Multi-stage Dockerfile cho Django + gunicorn
# Build: docker build -t myapp-django:latest .
# Lưu ý: settings.py cần ALLOWED_HOSTS, CSRF_TRUSTED_ORIGINS, USE_X_FORWARDED_HOST
# (xem settings-snippet.py để biết IAP integration points)

# ─── Stage 1: build ───────────────────────────────────────
FROM python:3.12-slim AS build
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --user -r requirements.txt

# ─── Stage 2: runtime ─────────────────────────────────────
FROM python:3.12-slim AS runtime
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH=/home/app/.local/bin:$PATH
ENV DJANGO_SETTINGS_MODULE=myapp.settings

# Runtime system deps (libpq cho psycopg, dropping build-essential)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r app && useradd -r -g app -m -u 1001 app

COPY --from=build --chown=app:app /root/.local /home/app/.local
COPY --chown=app:app . .

# Static files collection (chạy lúc build để không cần writable filesystem prod)
RUN mkdir -p staticfiles && \
    python manage.py collectstatic --noinput --clear

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health/').read()" || exit 1

# gunicorn workers tune theo (2*CPU + 1). Production env có DB → tăng workers.
# --forwarded-allow-ips="*" để Django trust X-Forwarded-* từ Traefik
CMD ["gunicorn", "myapp.wsgi:application", \
     "--bind", "0.0.0.0:3000", \
     "--workers", "3", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--forwarded-allow-ips=*"]
