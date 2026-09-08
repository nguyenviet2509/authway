# Reference — Federated Login (Pattern C, add-only)

> ⚠️ **This is ONE example** — NestJS + Prisma + zustand + JWT (từ real implementation E2E verified 2026-09-07 on an internal asset-management app).
> **Your stack likely differs.** Adapt using the "Stack adaptation" table at bottom.
> Discovery Script trong `SPEC.md §2.5` / `bootstrap/CLAUDE.md` sẽ giúp AI detect stack anh + suggest deps phù hợp.

## When Pattern C fits

- App có auth phức tạp muốn GIỮ NGUYÊN: password + JWT rotation + 2FA/TOTP + Passkey/WebAuthn + fine-grained RBAC + user DB with permissions
- Add SSO như IdP thứ 2 song song, không thay auth cũ
- Refactor delta: 3-6 files NEW + 4-8 files APPEND wiring (0 logic modified)

## Deps (example stack — Node/NestJS)

Backend:
- `jose@^5` — JWKS fetch + JWT verify (Node)

Frontend:
- `oidc-client-ts@^3.0.1` — PKCE OIDC flow (React/Vanilla JS)

**Discovery script sẽ suggest equivalent deps cho stack khác — xem adaptation table cuối.**

## Backend files (concrete NestJS example)

### `src/common/utils/sso-config.util.ts` (NEW)

Load 4 SSO env vars, auto-derive JWKS URI, không fail-fast lúc boot (SSO là optional):

```typescript
export interface SsoConfig {
  enabled: boolean;
  issuer: string;
  clientId: string;
  jwksUri: string;
  redirectUri: string;
}

export function loadSsoConfig(): SsoConfig {
  const issuer = (process.env.SSO_ZITADEL_ISSUER || '').replace(/\/+$/, '');
  const clientId = process.env.SSO_ZITADEL_CLIENT_ID || '';
  const jwksUri = process.env.SSO_JWKS_URI || (issuer ? `${issuer}/oauth/v2/keys` : '');
  const redirectUri = process.env.SSO_REDIRECT_URI || '';
  const enabled = !!(issuer && clientId && jwksUri && redirectUri);
  return { enabled, issuer, clientId, jwksUri, redirectUri };
}
```

### `src/auth/sso.service.ts` (NEW)

Core SSO logic — JWKS verify + user lookup + REUSE existing `TokenService.authenticated()`:

```typescript
@Injectable()
export class SsoService implements OnModuleInit {
  private jwks!: ReturnType<typeof createRemoteJWKSet>;

  constructor(
    private readonly config: ConfigService,
    private readonly prisma: PrismaService,
    private readonly tokens: TokenService,           // REUSE existing primitive — do NOT reimplement
    private readonly telegram: TelegramService,
  ) {}

  onModuleInit() {
    if (!this.config.get('sso.enabled')) return;
    this.jwks = createRemoteJWKSet(new URL(this.config.get('sso.jwksUri')));
  }

  async loginWithIdToken(idToken: string, req: any) {
    const { payload } = await jwtVerify(idToken, this.jwks, {
      issuer: this.config.get('sso.issuer'),
      audience: this.config.get('sso.clientId'),
    });
    const email = String(payload.email || '').toLowerCase();

    let user = await this.prisma.user.findFirst({ where: { email } });
    if (!user) {
      // Auto-provision với fail-safe 0-role → 403
      user = await this.autoProvisionFromClaims(email, payload);
    }
    if (!user.isActive) throw new AppException('FORBIDDEN', 'Account inactive', 403);

    return this.tokens.authenticated(user, req);  // REUSE — same primitive as password login
  }

  private async autoProvisionFromClaims(email: string, payload: Record<string, unknown>) {
    const rolesClaim = payload['urn:zitadel:iam:org:project:roles'] as Record<string, unknown> | undefined;
    const roles = rolesClaim ? Object.keys(rolesClaim) : [];
    if (roles.length === 0) {
      throw new AppException('FORBIDDEN', 'Chưa được cấp role trong Central RBAC', 403);
    }
    const isSuperuser = roles.some((r) => r.toLowerCase().includes('admin'));
    return this.prisma.user.create({
      data: {
        email,
        fullName: (payload.name as string) || email.split('@')[0],
        passwordHash: await hashPassword(randomToken(32)),  // random, không dùng (user login SSO)
        isSuperuser,
        isActive: true,
      },
    });
  }
}
```

### `src/auth/sso.controller.ts` (NEW)

2 endpoint song song với existing `AuthController` (không thay):

```typescript
@Controller('auth/sso')
export class SsoController {
  constructor(private readonly sso: SsoService, private readonly config: ConfigService) {}

  @Public()
  @Get('config')
  config() {
    // SPA fetch runtime → tránh Vite hard-embed (Trap #5)
    return {
      enabled: this.config.get('sso.enabled'),
      issuer: this.config.get('sso.issuer'),
      clientId: this.config.get('sso.clientId'),
      redirectUri: this.config.get('sso.redirectUri'),
    };
  }

  @Public()
  @Post('callback')
  @HttpCode(200)
  callback(@Body() dto: { idToken: string }, @Req() req: any) {
    return this.sso.loginWithIdToken(dto.idToken, req);
  }
}
```

### `src/auth/auth.module.ts` (APPEND wiring — 0 line modified logic)

```typescript
// Append imports (existing imports intact)
import { SsoController } from './sso.controller';
import { SsoService } from './sso.service';

@Module({
  controllers: [AuthController, /* ...existing intact */, SsoController],
  providers: [AuthService, /* ...existing intact */, SsoService],
})
```

### `src/config/configuration.ts` (APPEND)

```typescript
return {
  // ...existing config keys intact
  sso: {
    enabled: !!(process.env.SSO_ZITADEL_ISSUER && process.env.SSO_ZITADEL_CLIENT_ID),
    issuer: (process.env.SSO_ZITADEL_ISSUER || '').replace(/\/+$/, ''),
    clientId: process.env.SSO_ZITADEL_CLIENT_ID || '',
    jwksUri: process.env.SSO_JWKS_URI || `${process.env.SSO_ZITADEL_ISSUER}/oauth/v2/keys`,
    redirectUri: process.env.SSO_REDIRECT_URI || '',
  },
};
```

## Frontend files (React SPA example)

### `src/lib/sso-manager.ts` (NEW)

OIDC PKCE wrapper với runtime config fetch (tránh Vite hard-embed):

```typescript
import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

let manager: UserManager | null = null;
let cachedConfig: any = null;

async function fetchSsoConfig() {
  if (cachedConfig) return cachedConfig;
  const res = await fetch('/api/auth/sso/config');
  const body = await res.json();
  cachedConfig = body?.data ?? body;
  return cachedConfig;
}

async function getManager() {
  const cfg = await fetchSsoConfig();
  if (!cfg.enabled) return null;
  if (manager) return manager;
  manager = new UserManager({
    authority: cfg.issuer,
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    response_type: 'code',
    scope: 'openid email profile urn:zitadel:iam:org:project:roles',
    userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  });
  return manager;
}

export async function isSsoAvailable() {
  return !!(await fetchSsoConfig())?.enabled;
}
export async function startSsoLogin() {
  const mgr = await getManager();
  if (!mgr) throw new Error('SSO chưa cấu hình');
  await mgr.signinRedirect();
}
export async function handleSsoCallback() {
  const mgr = await getManager();
  if (!mgr) throw new Error('SSO chưa cấu hình');
  const user = await mgr.signinRedirectCallback();
  return user.id_token!;
}
```

### `src/components/SsoLoginButton.tsx` (NEW)

Button UI, tự ẩn nếu backend `enabled=false`:

```tsx
export function SsoLoginButton() {
  const [available, setAvailable] = useState(false);
  useEffect(() => { isSsoAvailable().then(setAvailable); }, []);
  if (!available) return null;
  return (
    <button onClick={() => startSsoLogin()}>
      Đăng nhập với Central SSO (GitLab)
    </button>
  );
}
```

### `src/pages/SsoCallbackPage.tsx` (NEW)

Route `/sso/callback` — hoàn tất PKCE, swap id_token → local JWT, REUSE existing auth store:

```tsx
export function SsoCallbackPage() {
  const nav = useNavigate();
  const store = useAuthStore();  // REUSE existing store — do NOT create new
  useEffect(() => {
    (async () => {
      const idToken = await handleSsoCallback();
      const res = await api.post('/auth/sso/callback', { idToken });
      const d = res.data?.data;
      store.setAuthenticated(d.accessToken, d.refreshToken, d.user);  // REUSE existing action
      nav('/', { replace: true });
    })();
  }, []);
  return <div>Đang xử lý đăng nhập Central SSO…</div>;
}
```

### `src/App.tsx` (APPEND wiring)

```tsx
// Append import + 1 route (existing routes intact)
import { SsoCallbackPage } from './pages/SsoCallbackPage';
// Trong <Routes>, thêm 1 dòng:
<Route path="/sso/callback" element={<SsoCallbackPage />} />
```

### `src/pages/LoginPage.tsx` (APPEND button dưới form)

```tsx
// Append import + render dưới password form (form intact 100%)
import { SsoLoginButton } from '../components/SsoLoginButton';
// Trong JSX, dưới password form:
<SsoLoginButton />
```

## Docker Compose env (APPEND)

```yaml
services:
  api:
    environment:
      # ...existing env intact
      SSO_ZITADEL_ISSUER: ${SSO_ZITADEL_ISSUER:-}
      SSO_ZITADEL_CLIENT_ID: ${SSO_ZITADEL_CLIENT_ID:-}
      SSO_JWKS_URI: ${SSO_JWKS_URI:-}
      SSO_REDIRECT_URI: ${SSO_REDIRECT_URI:-}
```

## `.env.example` (APPEND)

```env
# Central SSO (Zitadel + GitLab federated) — optional
SSO_ZITADEL_ISSUER=
SSO_ZITADEL_CLIENT_ID=
SSO_JWKS_URI=
SSO_REDIRECT_URI=https://<app-host>/sso/callback
```

## Test procedure

1. Register app trên Central RBAC portal → nhận `CLIENT_ID`
2. Zitadel Console: đổi Auth Method = **None (PKCE)** + Additional Origins + Add Roles To ID Token *(6 traps SPEC.md §11)*
3. Fill `.env` với 4 SSO vars
4. Docker: `docker compose up -d --build --force-recreate api web`
5. Verify log: `Central SSO enabled: issuer=...`
6. **Fresh incognito** → `https://<app-host>/login` → click SSO button → GitLab → callback → dashboard (không double-prompt 2FA)
7. Regression: login local password + 2FA/Passkey → phải intact

## Rollback

**Trước merge master:**
```bash
git checkout master
git branch -D feat/authway-sso-integration
git push origin --delete feat/authway-sso-integration
```

**Sau merge (soft toggle):**
```bash
# SSH prod, empty SSO_ZITADEL_ISSUER trong .env → SSO auto-disabled runtime
sed -i 's|^SSO_ZITADEL_ISSUER=.*|SSO_ZITADEL_ISSUER=|' .env
docker compose up -d --force-recreate api
```

## Stack adaptation

| Your stack | JWKS verify lib | Frontend state store | Token issuance primitive |
|---|---|---|---|
| Node/Express | `jose` | (backend-rendered) | custom `jwt.sign` |
| Node/NestJS *(this example)* | `jose` | — | `@nestjs/jwt` + `TokenService.authenticated()` |
| Python/FastAPI | `authlib` or `python-jose` | — | `jose.jwt.encode` |
| Python/Django | `mozilla-django-oidc` (all-in-one) | — | `django.contrib.auth.login` |
| Go/Gin | `github.com/coreos/go-oidc` | — | custom + `golang-jwt` |
| Java/Spring | `nimbus-jose-jwt` | — | `JwtEncoder` (Spring Security) |
| Ruby/Rails | `openid_connect` gem | — | Devise `sign_in` |
| .NET/ASP.NET | `Microsoft.IdentityModel` | — | `IdentityServer` or custom |
| React SPA *(this example)* | — | zustand/redux/context | (via oidc-client-ts) |
| Vue SPA | — | Pinia | `oidc-client-vue` |
| Angular SPA | — | NgRx or service | `angular-oauth2-oidc` |
| Svelte SPA | — | Svelte stores | `oidc-client-ts` |

## What AI must NOT change (Pattern C invariants)

- Existing auth controller / service / strategy files
- Existing token issuance primitive (chỉ REUSE, không sửa signature)
- Existing user DB schema (chỉ INSERT rows mới qua auto-provision)
- Existing SPA login form (password fields, submit handler)
- Existing 2FA/Passkey/MFA pages và flow
- Existing auth state store shape

## Common Traps quick-reference

Xem `SPEC.md §11` chi tiết 6 traps:
1. Wizard tạo BASIC → phải Zitadel Console đổi None (PKCE)
2. CORS Additional Origins chưa whitelist SPA origin
3. DNS mismatch giữa deploy target và domain
4. Zitadel session collision (fresh incognito bắt buộc)
5. Vite hard-embed thay runtime config fetch
6. Zitadel "Add Roles To ID Token = OFF" → auto-provision fail-safe 403
