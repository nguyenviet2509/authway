# Multi-stage Dockerfile cho Flask + gunicorn (WSGI sync)
# Build: docker build -t myapp-flask:latest .
# App code structure giả định: app.py có `app = Flask(__name__)`

# ─── Stage 1: build deps ──────────────────────────────────
FROM python:3.12-slim AS build
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --user -r requirements.txt

# ─── Stage 2: runtime ─────────────────────────────────────
FROM python:3.12-slim AS runtime
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH=/home/app/.local/bin:$PATH

RUN groupadd -r app && useradd -r -g app -m -u 1001 app

COPY --from=build --chown=app:app /root/.local /home/app/.local
COPY --chown=app:app . .

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health').read()" || exit 1

# gunicorn workers (2*CPU+1). Lưu ý: --forwarded-allow-ips="*" để trust Traefik X-Forwarded-*
# Adjust app:app theo file:variable thực tế (vd `wsgi:app`, `myapp:create_app()`).
CMD ["gunicorn", "app:app", \
     "--bind", "0.0.0.0:3000", \
     "--workers", "3", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--forwarded-allow-ips=*"]
