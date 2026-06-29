# Multi-stage Dockerfile cho Node.js Express / Fastify / NestJS
# Build: docker build -t myapp:latest .
# Listen: 0.0.0.0:${APP_PORT} (default 3000)

# ─── Stage 1: deps ────────────────────────────────────────
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# ─── Stage 2: build (nếu có TypeScript/bundler) ───────────
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
# Bỏ comment nếu có build step (TS compile, bundle...)
# RUN npm run build

# ─── Stage 3: runtime ─────────────────────────────────────
FROM node:20-alpine AS runtime
WORKDIR /app

# Non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S -u 1001 -G nodejs app
USER app

# Production deps + built artifacts
COPY --from=deps --chown=app:nodejs /app/node_modules ./node_modules
COPY --chown=app:nodejs . .
# Nếu có build output (vd TypeScript → dist/), COPY thêm:
# COPY --from=build --chown=app:nodejs /app/dist ./dist

ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000

# Healthcheck — adjust path theo app (vd /health, /api/ping)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

# Entry — adjust theo project (vd "node dist/server.js" nếu TypeScript build)
CMD ["node", "server.js"]
