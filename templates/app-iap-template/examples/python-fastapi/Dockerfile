# Multi-stage Dockerfile cho FastAPI + uvicorn
# Build: docker build -t myapp-fastapi:latest .

# ─── Stage 1: build deps ──────────────────────────────────
FROM python:3.12-slim AS build
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps cho build (psycopg, lxml,...) — adjust theo lib app
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

# Non-root user
RUN groupadd -r app && useradd -r -g app -m -u 1001 app

# Copy installed packages từ build stage
COPY --from=build --chown=app:app /root/.local /home/app/.local

# Copy source code
COPY --chown=app:app . .

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health').read()" || exit 1

# Listen 0.0.0.0 (container internal). Workers tune theo CPU.
# Production: --workers 2-4, --no-access-log (để Traefik log thay)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000", "--workers", "2"]
