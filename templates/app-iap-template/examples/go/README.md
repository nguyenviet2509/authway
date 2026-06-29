# Go (net/http, Gin, Echo, Fiber) — IAP Setup

Workflow setup Go app để chạy phía sau oauth2-proxy.

## File structure giả định

```
my-go-app/
├── go.mod
├── go.sum
├── cmd/
│   └── server/
│       └── main.go         # entry point
└── internal/
    └── handlers/
```

Nếu main package ở root → đổi `./cmd/server` thành `.` trong Dockerfile.

## 1. App listen `0.0.0.0:PORT` từ env

```go
package main

import (
    "log"
    "net/http"
    "os"
)

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "3000"
    }

    mux := http.NewServeMux()
    mux.HandleFunc("/health", healthHandler)
    mux.HandleFunc("/", authMiddleware(homeHandler))

    addr := "0.0.0.0:" + port
    log.Printf("listening on %s", addr)
    log.Fatal(http.ListenAndServe(addr, mux))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    _, _ = w.Write([]byte(`{"ok":true}`))
}
```

## 2. IAP middleware (~20 LOC)

```go
type ctxKey string
const userCtxKey ctxKey = "user"

type User struct {
    Email string
    Sub   string
    Name  string
}

func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        email := r.Header.Get("X-Auth-Request-Email")
        if email == "" {
            http.Error(w, "unauthorized", http.StatusUnauthorized)
            return
        }
        user := User{
            Email: email,
            Sub:   r.Header.Get("X-Auth-Request-User"),   // UUID immutable
            Name:  r.Header.Get("X-Auth-Request-Preferred-Username"),
        }
        ctx := context.WithValue(r.Context(), userCtxKey, user)
        next.ServeHTTP(w, r.WithContext(ctx))
    }
}

func GetUser(r *http.Request) User {
    return r.Context().Value(userCtxKey).(User)
}
```

## 3. Gin variant

```go
import "github.com/gin-gonic/gin"

func AuthMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        email := c.GetHeader("X-Auth-Request-Email")
        if email == "" {
            c.AbortWithStatus(http.StatusUnauthorized)
            return
        }
        c.Set("user_email", email)
        c.Set("user_sub", c.GetHeader("X-Auth-Request-User"))
        c.Next()
    }
}

// router.Use(AuthMiddleware())  // sau public routes như /health
```

## 4. Echo / Fiber

```go
// Echo
e.Use(func(next echo.HandlerFunc) echo.HandlerFunc {
    return func(c echo.Context) error {
        email := c.Request().Header.Get("X-Auth-Request-Email")
        if email == "" { return c.NoContent(401) }
        c.Set("user_email", email)
        return next(c)
    }
})

// Fiber
app.Use(func(c *fiber.Ctx) error {
    email := c.Get("X-Auth-Request-Email")
    if email == "" { return c.SendStatus(401) }
    c.Locals("user_email", email)
    return c.Next()
})
```

## 5. Copy Dockerfile + .dockerignore

```bash
cp ./Dockerfile ~/my-go-app/
cp ./.dockerignore ~/my-go-app/
```

Sửa nếu cần:
- Main package KHÔNG ở `./cmd/server` → đổi `go build -o /out/app ./cmd/server` thành path đúng
- Cần healthcheck shell → switch base image từ `distroless` sang `alpine` (xem comment trong Dockerfile)

## 6. Build + push

```bash
cd ~/my-go-app
docker build -t ghcr.io/team/my-go-app:v1.0.0 .

# Image size verify (distroless static ~10MB)
docker images ghcr.io/team/my-go-app

# Test local
docker run -p 3000:3000 -e PORT=3000 ghcr.io/team/my-go-app:v1.0.0
curl http://localhost:3000/health   # → {"ok":true}
curl http://localhost:3000/         # → unauthorized

# Push
docker push ghcr.io/team/my-go-app:v1.0.0
```

## 7. Deploy với template

```dotenv
# .env trong template
APP_HOSTNAME=my-go-app.company.com
APP_IMAGE=ghcr.io/team/my-go-app:v1.0.0
APP_PORT=3000
```

```bash
docker compose pull && docker compose up -d
```

## Special case: gRPC

Nếu app là gRPC server, oauth2-proxy KHÔNG proxy được. 2 lựa chọn:

1. **App verify OIDC token trực tiếp** — bypass oauth2-proxy:
   ```go
   import "github.com/coreos/go-oidc/v3/oidc"
   verifier := provider.Verifier(&oidc.Config{ClientID: "..."})
   idToken, _ := verifier.Verify(ctx, bearerToken)
   ```
   Client gọi gRPC kèm `Authorization: Bearer <token>` lấy từ Zitadel.

2. **Tách REST API qua oauth2-proxy** + **gRPC bypass** dùng port khác + IP whitelist VPN.

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| Image build "no Go files" | Dockerfile `go build` path sai → verify main package location |
| Distroless container exit code 127 | Distroless không có shell, sai entry path — check ENTRYPOINT |
| Healthcheck fail trên distroless | Distroless không có wget/curl. Switch sang `gcr.io/distroless/static-debian12:debug` (có sh) hoặc dùng alpine |
| Port không listen | App đang listen 127.0.0.1 thay vì 0.0.0.0 — fix `addr := "0.0.0.0:" + port` |
