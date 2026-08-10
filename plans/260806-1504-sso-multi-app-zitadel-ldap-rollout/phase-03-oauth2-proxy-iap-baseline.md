# Phase 3 — oauth2-proxy IAP baseline

**Effort:** 1d
**Status:** pending
**Depends on:** Phase 2 (Zitadel LDAP working)

## Context
- Plan: [../plan.md](../plan.md)
- Reference: `authway/plans/260626-1154-zitadel-iap-rollout/` (prior IAP work)
- Template: `authway/templates/app-iap-template/`

## Objective
Deploy oauth2-proxy như IAP layer trước Zitadel, config Traefik forwardAuth middleware. Verify flow: `Traefik → oauth2-proxy → Zitadel → LDAP` end-to-end với 1 dummy endpoint.

## Steps

### 1. Zitadel OIDC client cho oauth2-proxy
Console → Projects → New project "IAP" → Applications → New (Web app):
- Name: `oauth2-proxy-iap`
- Grant types: Authorization Code + Refresh Token
- Auth method: `Basic` hoặc `client_secret_post`
- Redirect URIs: `https://<oauth2-proxy-domain>/oauth2/callback` (VD `https://iap.inet.vn/oauth2/callback`)
- Post logout redirect: `https://<oauth2-proxy-domain>/`
- Save → note `client_id` + `client_secret`

### 2. oauth2-proxy config
File `oauth2-proxy.cfg` (hoặc env vars):
```
provider = "oidc"
oidc_issuer_url = "https://auth.inet.vn"
client_id = "<from step 1>"
client_secret = "<from step 1>"
cookie_secret = "<generate 32-byte base64>"
cookie_domains = [".inet.vn"]  # SSO across subdomains
whitelist_domains = [".inet.vn"]
email_domains = ["*"]  # tất cả user LDAP, restrict sau
upstreams = ["static://202"]  # forwardAuth-only mode
reverse_proxy = true
skip_provider_button = true  # LDAP-only, skip Zitadel button chọn IdP
set_xauthrequest = true
pass_access_token = true
```

### 3. Deploy oauth2-proxy container
Add vào `authway/infra/auth-vps/docker-compose.yml`:
```yaml
oauth2-proxy:
  image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
  restart: unless-stopped
  networks: [edge]
  environment:
    OAUTH2_PROXY_CONFIG: /etc/oauth2-proxy.cfg
  volumes:
    - ./oauth2-proxy.cfg:/etc/oauth2-proxy.cfg:ro
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.iap.rule=Host(`iap.inet.vn`)"
    - "traefik.http.routers.iap.entrypoints=websecure"
    - "traefik.http.routers.iap.tls=true"
    - "traefik.http.services.iap.loadbalancer.server.port=4180"
```

### 4. Traefik forwardAuth middleware
`authway/infra/auth-vps/dynamic/middlewares.yml` — add:
```yaml
http:
  middlewares:
    iap-auth:
      forwardAuth:
        address: "http://oauth2-proxy:4180/oauth2/auth"
        trustForwardHeader: true
        authResponseHeaders:
          - "X-Auth-Request-Email"
          - "X-Auth-Request-User"
          - "X-Auth-Request-Preferred-Username"
```

### 5. Dummy test app
Deploy 1 echo container để verify flow:
```yaml
echo:
  image: ealen/echo-server:latest
  networks: [edge]
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.echo.rule=Host(`echo.inet.vn`)"
    - "traefik.http.routers.echo.middlewares=iap-auth@file"
    - "traefik.http.services.echo.loadbalancer.server.port=80"
```

### 6. E2E test
- Browser → `https://echo.inet.vn/` incognito
- Expected: redirect qua `https://iap.inet.vn/oauth2/start` → Zitadel login → LDAP → callback → back to echo
- Echo response phải có header `X-Auth-Request-Email: <user email>`

### 7. Logout flow
- Visit `https://iap.inet.vn/oauth2/sign_out?rd=https://auth.inet.vn/oidc/v1/end_session`
- Verify cookie clear + Zitadel session terminate

### 8. Cookie security
- `cookie_secure = true`, `cookie_samesite = "lax"`
- `cookie_expire = "168h"` (7 days)
- `cookie_refresh = "15m"` — refresh token silently

## Deliverables
- oauth2-proxy container running healthy
- Traefik middleware `iap-auth@file` available
- Dummy echo endpoint verified E2E
- OIDC client `oauth2-proxy-iap` documented + secret Bitwarden
- Config file `oauth2-proxy.cfg` committed authway repo

## Success criteria
- ✅ Incognito → echo.inet.vn → auto redirect Zitadel → login LDAP → about echo header có email user
- ✅ Logout clean (cookie + Zitadel session)
- ✅ Refresh token silent (không re-login trong 7 ngày)
- ✅ Header X-Auth-Request-* set đúng

## Risks

| Risk | Mitigation |
|---|---|
| Cookie domain conflict giữa apps | `cookie_domains=.inet.vn` chung cho tất cả subdomains |
| oauth2-proxy single point of failure | Chấp nhận cho lab/small prod; scale ra HA sau nếu cần |
| Bug SSR Zitadel còn → user không login được | Fallback OIDC direct (bypass IAP) cho pilot app tạm |
| Header spoofing từ ngoài | Firewall app container port, chỉ Traefik reach được |

## Next → Phase 4
Integrate pilot app (OneMCP hoặc OneLog) với `iap-auth@file` middleware.
