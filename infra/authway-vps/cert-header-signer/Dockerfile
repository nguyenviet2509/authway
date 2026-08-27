# cert-header-signer sidecar — Phase 06 Step 7.
# Signs X-Client-Cert-CN with rotating HMAC secret from /run/secrets/cert_hmac.
# Called by Traefik forwardauth middleware; response headers forwarded to backend.

FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY tsconfig.json server.ts ./
RUN npx tsc

FROM node:22-alpine AS runtime
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./
USER node
EXPOSE 8090
CMD ["node", "dist/server.js"]

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8090/health >/dev/null 2>&1 || exit 1
