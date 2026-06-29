# Multi-stage Dockerfile cho Go (net/http, Gin, Echo, Fiber)
# Build static binary → image final ~10MB (distroless) hoặc scratch
# Build: docker build -t myapp-go:latest .

# ─── Stage 1: build ───────────────────────────────────────
FROM golang:1.22-alpine AS build
WORKDIR /src

# Cache go.mod download separate from source
COPY go.mod go.sum ./
RUN go mod download

# Build static binary (CGO_ENABLED=0 để dùng được scratch image)
COPY . .
ENV CGO_ENABLED=0
ENV GOOS=linux
RUN go build -ldflags="-s -w" -trimpath -o /out/app ./cmd/server
# Nếu main package ở root:  -o /out/app .
# Nếu trong folder khác:    -o /out/app ./path/to/main

# ─── Stage 2: runtime (distroless — có ca-certificates + tzdata) ─
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/app /app/app

# Distroless `nonroot` image dùng uid 65532 mặc định
USER nonroot:nonroot

EXPOSE 3000

# Distroless không có shell/curl/wget. Healthcheck cần Go binary tự expose
# /health endpoint, hoặc bỏ HEALTHCHECK + rely vào Docker restart policy.
# Nếu cần healthcheck, dùng image alpine thay vì distroless:
#   FROM alpine:3.19
#   RUN apk add --no-cache wget && adduser -D -u 1001 app
#   COPY --from=build /out/app /app/app
#   USER app
#   HEALTHCHECK CMD wget -qO- http://127.0.0.1:3000/health || exit 1

# Entry — app phải listen 0.0.0.0:PORT (đọc từ env PORT)
ENTRYPOINT ["/app/app"]
