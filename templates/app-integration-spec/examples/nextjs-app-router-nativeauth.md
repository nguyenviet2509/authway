# Reference — Next.js App Router + Auth.js v5 (Pattern B — Native OIDC)

Full-stack React với NextAuth v5 (Auth.js). Refactor delta ~30 dòng + 1 dependency.

## Deps

```bash
npm install next-auth@beta
# hoặc
pnpm add next-auth@beta
```

**Pin version:** `^5.0.0-beta.20` — v4 syntax khác hoàn toàn, KHÔNG mix.

## `.env.example`

```env
# Cấp bởi Central RBAC portal
AUTH_ZITADEL_ID=387047455193104387          # = CLIENT_ID
AUTH_ZITADEL_SECRET=xxxxxxxxxxxxxxxxxxxxx   # = CLIENT_SECRET
AUTH_ZITADEL_ISSUER=http://10.200.0.125     # = OIDC_ISSUER

# NextAuth
AUTH_SECRET=change-me-32-random-base64-secret
AUTH_URL=https://myapp.example.com          # prod
NEXTAUTH_URL=https://myapp.example.com      # backward compat
```

Generate `AUTH_SECRET`:
```bash
openssl rand -base64 32
```

## App code

### `auth.ts` (root)

```typescript
import NextAuth from "next-auth";
import Zitadel from "next-auth/providers/zitadel";

export const { handlers, signIn, signOut, auth } = NextAuth({
  providers: [
    Zitadel({
      clientId: process.env.AUTH_ZITADEL_ID,
      clientSecret: process.env.AUTH_ZITADEL_SECRET,
      issuer: process.env.AUTH_ZITADEL_ISSUER,
      authorization: {
        params: {
          scope: "openid email profile urn:zitadel:iam:org:project:roles",
        },
      },
    }),
  ],
  callbacks: {
    async jwt({ token, profile }) {
      if (profile) {
        // Extract roles từ Zitadel claim
        const rolesClaim = profile["urn:zitadel:iam:org:project:roles"] as
          | Record<string, unknown>
          | undefined;
        token.roles = rolesClaim ? Object.keys(rolesClaim) : [];
        token.username = profile.preferred_username as string;
      }
      return token;
    },
    async session({ session, token }) {
      session.user.roles = (token.roles as string[]) || [];
      session.user.username = (token.username as string) || session.user.email;
      return session;
    },
  },
  session: { strategy: "jwt" },
});
```

### `app/api/auth/[...nextauth]/route.ts`

```typescript
export { GET, POST } from "@/auth";
```

Callback URL Central sẽ nhận: `https://myapp.example.com/api/auth/callback/zitadel`.
**Đây là REDIRECT_URL phải khai với admin khi request app.**

### `middleware.ts` (root)

```typescript
import { auth } from "@/auth";

export default auth((req) => {
  // Public routes
  const publicPaths = ["/", "/health", "/api/health"];
  if (publicPaths.includes(req.nextUrl.pathname)) return;

  // Guard others
  if (!req.auth) {
    const signInUrl = new URL("/api/auth/signin", req.nextUrl.origin);
    signInUrl.searchParams.set("callbackUrl", req.nextUrl.pathname);
    return Response.redirect(signInUrl);
  }
});

export const config = {
  matcher: ["/((?!api/auth|_next/static|_next/image|favicon.ico).*)"],
};
```

### Server Component access session

```typescript
// app/dashboard/page.tsx
import { auth } from "@/auth";
import { redirect } from "next/navigation";

export default async function DashboardPage() {
  const session = await auth();
  if (!session?.user) redirect("/api/auth/signin");

  return (
    <div>
      <h1>Hello {session.user.email}</h1>
      <p>Roles: {session.user.roles?.join(", ") || "none"}</p>
      <a href="/api/auth/signout">Sign out</a>
    </div>
  );
}
```

### Client Component

```typescript
// components/user-badge.tsx
"use client";
import { useSession } from "next-auth/react";

export function UserBadge() {
  const { data: session } = useSession();
  if (!session) return null;
  return <span>{session.user?.email}</span>;
}
```

Wrap app trong `<SessionProvider>`:
```typescript
// app/layout.tsx (client wrapper)
import { SessionProvider } from "next-auth/react";
export default function RootLayout({ children }) {
  return (
    <html>
      <body>
        <SessionProvider>{children}</SessionProvider>
      </body>
    </html>
  );
}
```

### Sign-out chain (Zitadel end_session)

Auth.js v5 sign-out mặc định KHÔNG call Zitadel `end_session` → Zitadel session vẫn còn.

Force end_session redirect:

```typescript
// app/api/auth/signout-full/route.ts
import { signOut } from "@/auth";
import { NextResponse } from "next/server";

export async function POST() {
  await signOut({ redirect: false });
  const endSessionUrl = new URL("/oidc/v1/end_session", process.env.AUTH_ZITADEL_ISSUER);
  endSessionUrl.searchParams.set("client_id", process.env.AUTH_ZITADEL_ID!);
  endSessionUrl.searchParams.set(
    "post_logout_redirect_uri",
    process.env.AUTH_URL!,
  );
  return NextResponse.redirect(endSessionUrl);
}
```

Logout link:
```html
<form action="/api/auth/signout-full" method="post">
  <button type="submit">Sign out</button>
</form>
```

## Types (extend Session)

```typescript
// types/next-auth.d.ts
import "next-auth";
declare module "next-auth" {
  interface Session {
    user: {
      email?: string | null;
      name?: string | null;
      image?: string | null;
      username?: string;
      roles?: string[];
    };
  }
}
```

## Deploy notes

Next.js listen `3000` mặc định. Reverse proxy Caddy/Nginx phải:
- Pass `X-Forwarded-Proto: https` (Auth.js dùng để build callback URL)
- Pass `X-Forwarded-Host` (nếu app host khác internal)

Caddyfile:
```
https://myapp.example.com {
  reverse_proxy 127.0.0.1:3000 {
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host {host}
  }
}
```

Next.js bind `127.0.0.1`:
```json
// package.json
{
  "scripts": {
    "start": "next start -H 127.0.0.1 -p 3000"
  }
}
```

## What AI must NOT change

- React component tree ngoài auth-related
- Data fetching (fetch/SWR/TanStack Query) trừ khi swap `useSession` cho auth check
- Route file structure ngoài `app/api/auth/*`
- Styling / Tailwind config

## Refactor delta

1. Add: `next-auth@beta` dependency
2. Add: `auth.ts`, `app/api/auth/[...nextauth]/route.ts`, `middleware.ts`, `types/next-auth.d.ts` (~50 dòng tổng)
3. Add: `signout-full` route cho full chain sign-out
4. Update: Server Component dùng `await auth()` thay session cũ
5. Update: Client Component dùng `useSession()` từ `next-auth/react`
6. Update: package.json script bind `127.0.0.1`
7. Xoá: session logic cũ (VD custom JWT verify, iron-session, next-session)

## Validation

```bash
# 1. Bind local
curl -sI http://127.0.0.1:3000/
# Expect: 200 hoặc redirect signin

# 2. Discovery
curl -s http://10.200.0.125/.well-known/openid-configuration | jq .issuer
# Expect: "http://10.200.0.125"

# 3. Browser flow
# → https://myapp.example.com → redirect signin → Zitadel → callback → dashboard
```

## Common issues

| Symptom | Fix |
|---|---|
| `redirect_uri_mismatch` | REDIRECT_URL khai với admin phải EXACT = `https://<host>/api/auth/callback/zitadel` |
| Session không có roles | Verify `jwt` callback extract `urn:zitadel:iam:org:project:roles` — enable trong Zitadel project setting |
| Sign-out không clear Zitadel | Dùng `/api/auth/signout-full` route, không phải `signOut()` mặc định |
| `AUTH_SECRET` missing | Set `AUTH_SECRET` env — generate `openssl rand -base64 32` |
| HTTPS behind proxy Auth.js dùng http URL | Set `AUTH_URL=https://<host>` env explicit |
