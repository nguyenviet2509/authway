# Next.js (App Router) — IAP Setup

Workflow setup Next.js để chạy phía sau oauth2-proxy.

## Pre-requisite Next.js config

Next.js ≥13 với App Router. `next.config.mjs` PHẢI có `output: 'standalone'`:

```js
// next.config.mjs
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',   // BẮT BUỘC cho Dockerfile multi-stage
  reactStrictMode: true,
};
export default nextConfig;
```

Standalone mode tạo `.next/standalone/` với `server.js` + minimal deps → image production nhỏ ~200MB.

## File structure giả định

```
my-nextjs-app/
├── package.json
├── next.config.mjs
├── app/
│   ├── layout.tsx
│   ├── page.tsx
│   └── api/
└── public/
```

## 1. Đọc IAP header trong Server Component

App Router cho phép đọc header trực tiếp trong Server Component:

```tsx
// app/page.tsx
import { headers } from 'next/headers';

export default function Home() {
  const h = headers();
  const email = h.get('x-auth-request-email') ?? '(missing)';
  const sub   = h.get('x-auth-request-user') ?? '';
  const name  = h.get('x-auth-request-preferred-username') ?? '';

  return (
    <main>
      <h1>Hello {name || email}</h1>
      <a href="/oauth2/sign_out">Logout</a>
    </main>
  );
}
```

## 2. Middleware protect routes (optional)

Nếu muốn 401 explicit thay vì Next render với `email = '(missing)'`:

```ts
// middleware.ts (root project)
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(req: NextRequest) {
  // Bỏ qua health check
  if (req.nextUrl.pathname === '/health') return NextResponse.next();

  const email = req.headers.get('x-auth-request-email');
  if (!email) {
    return new NextResponse('Unauthorized', { status: 401 });
  }
  return NextResponse.next();
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
```

## 3. API routes / Server Actions

```ts
// app/api/me/route.ts
import { headers } from 'next/headers';
import { NextResponse } from 'next/server';

export const dynamic = 'force-dynamic';

export function GET() {
  const h = headers();
  return NextResponse.json({
    email: h.get('x-auth-request-email'),
    sub: h.get('x-auth-request-user'),
  });
}
```

## 4. Client Component muốn dùng identity

Server Component đọc header rồi pass xuống qua props:

```tsx
// app/page.tsx (Server)
import ClientGreeting from './client-greeting';
import { headers } from 'next/headers';

export default function Page() {
  const email = headers().get('x-auth-request-email') ?? '';
  return <ClientGreeting email={email} />;
}
```

Hoặc Client fetch `/api/me`:

```tsx
'use client';
import { useEffect, useState } from 'react';
export default function Greeting() {
  const [email, setEmail] = useState('');
  useEffect(() => {
    fetch('/api/me').then(r => r.json()).then(d => setEmail(d.email));
  }, []);
  return <div>Hello {email}</div>;
}
```

## 5. Health endpoint

```ts
// app/health/route.ts
import { NextResponse } from 'next/server';
export const dynamic = 'force-dynamic';
export function GET() {
  return NextResponse.json({ ok: true });
}
```

**Quan trọng:** trong middleware `matcher`, exclude `/health` để Docker daemon healthcheck không bị 401.

## 6. Gỡ NextAuth (nếu đang dùng)

```bash
npm uninstall next-auth @auth/core
rm -rf app/api/auth/   # xoá [...nextauth]/route.ts
```

Tìm và xoá:
- `<SessionProvider>` trong `app/layout.tsx`
- `useSession()`, `signIn()`, `signOut()` từ `next-auth/react`
- Mọi `getServerSession()` trong server components → thay bằng `headers().get('x-auth-request-email')`

## 7. Copy Dockerfile + .dockerignore + build

```bash
cp ./Dockerfile ~/my-nextjs-app/
cp ./.dockerignore ~/my-nextjs-app/

cd ~/my-nextjs-app
docker build -t ghcr.io/team/my-nextjs-app:v1.0.0 .
docker push ghcr.io/team/my-nextjs-app:v1.0.0
```

Lưu ý: Next.js build cần ≥2GB RAM → VPS nhỏ không build local được, dùng GitHub Actions / build local rồi push.

## 8. Deploy với template

```dotenv
# .env trong template app-iap-template
APP_HOSTNAME=my-nextjs-app.company.com
APP_IMAGE=ghcr.io/team/my-nextjs-app:v1.0.0
APP_PORT=3000
```

```bash
docker compose pull && docker compose up -d
```

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| Build fail `Cannot find module 'server.js'` | Thiếu `output: 'standalone'` trong next.config |
| `Hydration failed` warnings | Server Component đọc headers ≠ Client → đảm bảo dùng `dynamic = 'force-dynamic'` cho route đọc headers |
| 404 cho static asset `/next/static/...` | Standalone Dockerfile cần COPY `.next/static` riêng (đã có trong template) |
| `headers()` throw error trong Client Component | Chỉ dùng trong Server Component / Route Handler |
