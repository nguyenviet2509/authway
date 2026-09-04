# Reference — SPA React/Vue + oidc-client-ts + PKCE (Pattern B, browser-side)

SPA thuần (không backend đi kèm) dùng `oidc-client-ts` — framework-agnostic. **KHÔNG dùng `CLIENT_SECRET`** trong browser.

## Deps

```bash
npm install oidc-client-ts
# hoặc
pnpm add oidc-client-ts
```

Pin `^3.0.1`.

## Zitadel app config

**Khi request admin đăng ký:**
- App type: **SPA** (Public client — no secret)
- Auth method: **PKCE only**
- Redirect URI: `https://<spa-host>/callback` (path bạn tự chọn, EXACT match)
- Post logout URI: `https://<spa-host>/`

## `.env.example`

```env
# Vite/CRA prefix env với VITE_ hoặc REACT_APP_ để expose browser
VITE_OIDC_ISSUER=http://10.200.0.125
VITE_OIDC_CLIENT_ID=387047455193104387
VITE_APP_HOST=https://myapp.example.com
```

**KHÔNG có secret.** Public client.

## App code (React — Vue tương tự chỉ khác framework wrapper)

### `src/auth/oidc-manager.ts`

```typescript
import { UserManager, WebStorageStateStore, type UserManagerSettings } from "oidc-client-ts";

const settings: UserManagerSettings = {
  authority: import.meta.env.VITE_OIDC_ISSUER,
  client_id: import.meta.env.VITE_OIDC_CLIENT_ID,
  redirect_uri: `${import.meta.env.VITE_APP_HOST}/callback`,
  post_logout_redirect_uri: `${import.meta.env.VITE_APP_HOST}/`,
  response_type: "code",
  scope: "openid email profile urn:zitadel:iam:org:project:roles",
  automaticSilentRenew: true,
  loadUserInfo: true,
  // Store user trong sessionStorage — tab-scoped
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
};

export const userManager = new UserManager(settings);

export async function login() {
  await userManager.signinRedirect();
}

export async function handleCallback() {
  return await userManager.signinRedirectCallback();
}

export async function logout() {
  await userManager.signoutRedirect();
}

export async function getUser() {
  return await userManager.getUser();
}
```

### `src/auth/auth-context.tsx` (React Context)

```typescript
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { User } from "oidc-client-ts";
import { userManager, login, logout, getUser } from "./oidc-manager";

interface AuthContextValue {
  user: User | null;
  loading: boolean;
  login: () => Promise<void>;
  logout: () => Promise<void>;
  roles: string[];
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getUser().then((u) => {
      setUser(u);
      setLoading(false);
    });

    // Listen silent renew
    userManager.events.addUserLoaded((u) => setUser(u));
    userManager.events.addUserUnloaded(() => setUser(null));
  }, []);

  const roles = user?.profile
    ? Object.keys((user.profile["urn:zitadel:iam:org:project:roles"] as Record<string, unknown>) || {})
    : [];

  return (
    <AuthContext.Provider value={{ user, loading, login, logout, roles }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be inside AuthProvider");
  return ctx;
}
```

### `src/routes/callback.tsx` (route `/callback`)

```typescript
import { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { handleCallback } from "@/auth/oidc-manager";

export default function CallbackPage() {
  const navigate = useNavigate();
  useEffect(() => {
    handleCallback()
      .then(() => navigate("/", { replace: true }))
      .catch((err) => {
        console.error("OIDC callback failed:", err);
        navigate("/?error=auth", { replace: true });
      });
  }, [navigate]);
  return <div>Signing in…</div>;
}
```

### `src/routes/protected.tsx` (guard component)

```typescript
import type { ReactNode } from "react";
import { useAuth } from "@/auth/auth-context";

export function Protected({ children }: { children: ReactNode }) {
  const { user, loading, login } = useAuth();
  if (loading) return <div>Loading…</div>;
  if (!user) {
    login();  // redirect Zitadel
    return <div>Redirecting…</div>;
  }
  return <>{children}</>;
}
```

### `src/App.tsx`

```typescript
import { AuthProvider, useAuth } from "@/auth/auth-context";
import { Protected } from "@/routes/protected";
import CallbackPage from "@/routes/callback";
import { BrowserRouter, Route, Routes } from "react-router-dom";

function Home() {
  const { user, logout, roles } = useAuth();
  return (
    <div>
      <h1>Welcome {user?.profile.email}</h1>
      <p>Roles: {roles.join(", ") || "none"}</p>
      <button onClick={() => logout()}>Sign out</button>
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/callback" element={<CallbackPage />} />
          <Route path="/" element={<Protected><Home /></Protected>} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}
```

## Vue equivalent

Swap `AuthProvider` cho `provide/inject` hoặc Pinia store. `oidc-manager.ts` không đổi. Route `/callback` gọi `handleCallback()`.

## Call API downstream (nếu SPA có backend riêng)

```typescript
const { user } = useAuth();
const response = await fetch("https://api.example.com/data", {
  headers: { Authorization: `Bearer ${user?.access_token}` },
});
```

Backend verify `access_token` qua JWKS (giống Pattern B backend example — không phải file này).

## PKCE — điều tự động

`oidc-client-ts` mặc định enable PKCE (`response_type: "code"` + auto code_challenge). **KHÔNG disable.**

## Silent token renew

`automaticSilentRenew: true` mặc định — library refresh trước khi hết hạn. Nếu Zitadel session expired → user redirect login. UX tốt.

## Deploy notes

SPA build → static files → serve qua Caddy/Nginx/CDN:

```
https://myapp.example.com {
  root * /var/www/myapp/dist
  file_server
  try_files {path} /index.html
}
```

`try_files ... /index.html` — REQUIRED cho SPA client-side routing (VD `/callback` hit server 404 nếu thiếu).

**KHÔNG** cần bind `127.0.0.1` (static server public). **KHÔNG** cần oauth2-proxy.

## Security invariants (SPA-specific)

- **KHÔNG** lưu `access_token` trong `localStorage` — dùng `sessionStorage` (tab-scoped, clear on close)
- **KHÔNG** gửi `client_secret` — SPA = public client
- **KHÔNG** disable PKCE hay state
- **KHÔNG** trust `access_token` từ URL hash (Implicit flow) — bắt buộc Authorization Code + PKCE
- **CSP header** khuyến nghị: `default-src 'self' {OIDC_ISSUER}` — chặn XSS steal token

## What AI must NOT change

- Component tree ngoài `/callback` route và `<Protected>` guard
- API client base URL / interceptors ngoài `Authorization` header
- Router config ngoài add `/callback` route

## Refactor delta

1. Add: `oidc-client-ts` dependency
2. Add: `auth/oidc-manager.ts`, `auth/auth-context.tsx`, `routes/callback.tsx`, `routes/protected.tsx` (~120 dòng tổng)
3. Wrap app trong `<AuthProvider>`
4. Wrap protected routes trong `<Protected>`
5. Replace hardcoded auth check bằng `useAuth()`
6. Update logout button → `logout()` (redirect Zitadel end_session tự động)
7. `.env` prefix biến với `VITE_` (Vite) hoặc `REACT_APP_` (CRA)

## Validation

```bash
# 1. Build SPA
npm run build
ls -la dist/index.html

# 2. Discovery reachable
curl -s http://10.200.0.125/.well-known/openid-configuration | jq .authorization_endpoint

# 3. Browser flow
# → https://myapp.example.com/ → auto-redirect Zitadel authorize (PKCE challenge in URL)
# → login → callback → /callback processes code → back to / with user
```

## Common issues

| Symptom | Fix |
|---|---|
| `invalid_request no code_challenge` | oidc-client-ts config sai `response_type` — phải `"code"` không phải `"token"` |
| Callback URL 404 sau LE hit Nginx | Thiếu `try_files ... /index.html` — SPA client routing |
| Access token expired mid-session | `automaticSilentRenew` disabled — bật lại |
| Roles empty dù user có role | Scope thiếu `urn:zitadel:iam:org:project:roles` — add vào `scope` config |
| CORS block token endpoint | Zitadel phải whitelist SPA origin — báo admin add trong Additional Origins |
