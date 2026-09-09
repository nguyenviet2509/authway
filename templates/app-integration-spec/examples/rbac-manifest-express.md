# RBAC Manifest — Express / Fastify / Koa reference

**Framework:** Express 4+, Fastify 4+, Koa 2+ (Node backend generic)
**Language:** TypeScript hoặc JavaScript
**Prerequisite:** SSO integration (Pattern A/B/C) đã done. Đọc `SPEC.md` §12 trước.

Reference implementation: file structure + code pattern có thể copy-adapt. Placeholder `<APP_SLUG>`, `<APP_URL>` — thay bằng slug thực của app member.

---

## File 1 — `src/rbac/permissions-catalog.ts` (~80 LoC)

Literal array declare toàn bộ permission app support + default roles template. Framework-agnostic (Node runtime).

```typescript
/**
 * permissions-catalog.ts — RBAC manifest source of truth.
 *
 * Add/remove permission = edit array below + restart app.
 * Boot validator sẽ cross-check declared vs routes dùng thực tế.
 */

export const APP_SLUG = '<APP_SLUG>'; // MUST match slug registered ở Central portal

/** Version string: prefer GIT_SHA env, fallback date-based YYYY-MM-DD.N */
export function buildVersion(): string {
  const sha = process.env.GIT_SHA;
  if (sha && sha.length >= 7) return sha.slice(0, 8);
  const now = new Date();
  const d = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  return `${d}.1`;
}

export interface PermissionEntry {
  id: string;
  description: string;
}

export interface DefaultRole {
  key: string;
  description: string;
  permissions: string[];
}

/**
 * Flat permission list — grep-friendly.
 * Format: <APP_SLUG>:<resource>.<action>
 * Rules: lowercase, kebab-case allowed in resource, dot separates resource from action.
 */
export const PERMISSIONS: PermissionEntry[] = [
  // === Examples — replace with actual permissions of your app ===
  { id: `${APP_SLUG}:orders.read`,      description: 'Xem đơn hàng' },
  { id: `${APP_SLUG}:orders.create`,    description: 'Tạo đơn hàng' },
  { id: `${APP_SLUG}:orders.update`,    description: 'Sửa đơn hàng' },
  { id: `${APP_SLUG}:orders.delete`,    description: 'Xoá đơn hàng' },
  { id: `${APP_SLUG}:orders.approve`,   description: 'Duyệt đơn hàng' },
  { id: `${APP_SLUG}:orders.export`,    description: 'Xuất file đơn hàng' },
  { id: `${APP_SLUG}:reports.read`,     description: 'Xem báo cáo' },
  { id: `${APP_SLUG}:reports.export`,   description: 'Xuất báo cáo' },
];

/** Helper filters for building 3 default roles */
function isDestructiveOrUserMgmt(id: string): boolean {
  return /\.(delete|approve)$/.test(id)
    || id.startsWith(`${APP_SLUG}:users.`)
    || id.startsWith(`${APP_SLUG}:object-permissions.`)
    || id.startsWith(`${APP_SLUG}:user-groups.`);
}

function isReadOrExport(id: string): boolean {
  return /\.(read|export)$/.test(id);
}

/** 3 recommended roles — add custom roles below if needed (max 50 total) */
export const DEFAULT_ROLES: DefaultRole[] = [
  {
    key: `${APP_SLUG}.admin`,
    description: 'Quản trị viên — full access',
    permissions: PERMISSIONS.map((p) => p.id),
  },
  {
    key: `${APP_SLUG}.editor`,
    description: 'Nghiệp vụ — CRUD trừ delete/approve/user-mgmt',
    permissions: PERMISSIONS.filter((p) => !isDestructiveOrUserMgmt(p.id)).map((p) => p.id),
  },
  {
    key: `${APP_SLUG}.viewer`,
    description: 'Chỉ xem — read + export',
    permissions: PERMISSIONS.filter((p) => isReadOrExport(p.id)).map((p) => p.id),
  },
];

export interface RbacManifest {
  schema: '1';
  service: string;
  version: string;
  permissions: PermissionEntry[];
  default_roles: DefaultRole[];
}

/** Build manifest object. Memoize caller-side. */
export function buildManifest(): RbacManifest {
  return {
    schema: '1',
    service: APP_SLUG,
    version: buildVersion(),
    permissions: PERMISSIONS,
    default_roles: DEFAULT_ROLES,
  };
}
```

---

## File 2 — `src/rbac/manifest-endpoint.ts`

Route handler expose `GET /.well-known/rbac-permissions.json`. 3 variant (Express / Fastify / Koa).

### Express variant

```typescript
import type { Router, Request, Response } from 'express';
import { buildManifest, type RbacManifest } from './permissions-catalog';

let cached: RbacManifest | null = null;

export function registerManifestEndpoint(router: Router): void {
  router.get('/.well-known/rbac-permissions.json', (_req: Request, res: Response) => {
    if (!cached) cached = buildManifest();
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'public, max-age=300');
    res.setHeader('ETag', `"${cached.version}"`);
    res.setHeader('X-Robots-Tag', 'noindex');
    res.status(200).json(cached);
  });
}
```

### Fastify variant

```typescript
import type { FastifyInstance } from 'fastify';
import { buildManifest, type RbacManifest } from './permissions-catalog';

let cached: RbacManifest | null = null;

export async function registerManifestEndpoint(app: FastifyInstance): Promise<void> {
  app.get('/.well-known/rbac-permissions.json', async (_req, reply) => {
    if (!cached) cached = buildManifest();
    return reply
      .header('Content-Type', 'application/json; charset=utf-8')
      .header('Cache-Control', 'public, max-age=300')
      .header('ETag', `"${cached.version}"`)
      .header('X-Robots-Tag', 'noindex')
      .send(cached);
  });
}
```

### Koa variant

```typescript
import type Router from '@koa/router';
import { buildManifest, type RbacManifest } from './permissions-catalog';

let cached: RbacManifest | null = null;

export function registerManifestEndpoint(router: Router): void {
  router.get('/.well-known/rbac-permissions.json', (ctx) => {
    if (!cached) cached = buildManifest();
    ctx.set('Content-Type', 'application/json; charset=utf-8');
    ctx.set('Cache-Control', 'public, max-age=300');
    ctx.set('ETag', `"${cached.version}"`);
    ctx.set('X-Robots-Tag', 'noindex');
    ctx.body = cached;
  });
}
```

**BẮT BUỘC (SPEC.md §3 rule 11 + §12.1):**
- `X-Robots-Tag: noindex` — ngăn Google/Bing index endpoint public (đã thêm ở 3 variant trên)
- KHÔNG log full response body ở access log (morgan/pino: verify custom serializer không dump body cho path `.well-known/*`)

**Nếu app có SSO middleware auth-first:** mount manifest endpoint BEFORE auth middleware, hoặc whitelist path `.well-known/*` trong auth middleware.

**Nếu app có response middleware wrap JSON (envelope `{data, meta}`):** bypass wrapping cho manifest endpoint (Central schema validator reject nếu bị wrap).

---

## File 3 — `src/rbac/boot-validator.ts` (~70 LoC)

Cross-check declared permissions vs routes dùng thực tế, set /ready state.

Pattern: mỗi route dùng `requirePermission('<id>')` middleware. Validator scan qua router stack sau khi app bind route xong.

```typescript
/**
 * boot-validator.ts — verify declared PERMISSIONS matches routes usage.
 * Run once at startup (sau khi tất cả routes registered).
 * Fail = set READY_STATE=UNHEALTHY → /ready returns 503.
 */
import { PERMISSIONS } from './permissions-catalog';

export const READY_STATE = { value: 'STARTING' as 'STARTING' | 'HEALTHY' | 'UNHEALTHY' };

/**
 * Middleware factory. Attach permission id to fn.__rbacPermission for validator scan.
 * Runtime permission check qua Central RBAC API — out of scope Phase 4.
 */
export function requirePermission(permissionId: string) {
  const mw = (req: any, _res: any, next: any) => {
    // TODO: call Central RBAC API to verify current user has permissionId
    next();
  };
  (mw as any).__rbacPermission = permissionId;
  return mw;
}

/** Framework-specific route scanner — implement per adapter below */
export type RouteScanner = () => Set<string>;

export function runValidator(scan: RouteScanner): void {
  const declared = new Set(PERMISSIONS.map((p) => p.id));
  const actual = scan();

  const missing = [...actual].filter((id) => !declared.has(id));
  const unused = [...declared].filter((id) => !actual.has(id));

  const log = (level: 'INFO' | 'WARN' | 'ERROR', msg: string) =>
    console.log(`[rbac-manifest] ${level} ${msg}`);

  if (missing.length > 0) {
    log('ERROR', `Routes use undeclared permissions: ${missing.join(', ')}`);
    log('ERROR', `Fix: add to PERMISSIONS array in permissions-catalog.ts`);
    READY_STATE.value = 'UNHEALTHY';
    return;
  }

  if (unused.length > 0) {
    log('WARN', `Declared but unused (dead code): ${unused.join(', ')}`);
  }
  log('INFO', `Catalog OK — ${declared.size} permissions declared, ${actual.size} used by routes`);
  READY_STATE.value = 'HEALTHY';
}
```

### Route scanner adapters

**Express:**
```typescript
import type { Express } from 'express';

export function makeExpressScanner(app: Express): RouteScanner {
  return () => {
    const used = new Set<string>();
    const stack = (app._router?.stack ?? []) as any[];
    const walk = (layers: any[]) => {
      for (const layer of layers) {
        if (layer.route?.stack) {
          for (const s of layer.route.stack) {
            const perm = s.handle?.__rbacPermission;
            if (perm) used.add(perm);
          }
        }
        if (layer.handle?.stack) walk(layer.handle.stack); // nested router
      }
    };
    walk(stack);
    return used;
  };
}
```

**Fastify:**
```typescript
import type { FastifyInstance } from 'fastify';

export function makeFastifyScanner(app: FastifyInstance): RouteScanner {
  return () => {
    const used = new Set<string>();
    // Fastify exposes routes via app.printRoutes() or route hook — use onRoute
    // Simpler: track permissions at register time via app.decorate
    const registered: string[] = (app as any).__rbacRegistered ?? [];
    registered.forEach((p) => used.add(p));
    return used;
  };
}

// Hook to auto-register — call ONCE in bootstrap
export function installFastifyHook(app: FastifyInstance): void {
  (app as any).__rbacRegistered = [];
  app.addHook('onRoute', (routeOptions) => {
    const handlers = Array.isArray(routeOptions.preHandler)
      ? routeOptions.preHandler
      : [routeOptions.preHandler].filter(Boolean);
    for (const h of handlers) {
      const perm = (h as any)?.__rbacPermission;
      if (perm) (app as any).__rbacRegistered.push(perm);
    }
  });
}
```

**Koa:**
```typescript
import type Router from '@koa/router';

export function makeKoaScanner(router: Router): RouteScanner {
  return () => {
    const used = new Set<string>();
    for (const layer of router.stack) {
      for (const mw of layer.stack) {
        const perm = (mw as any).__rbacPermission;
        if (perm) used.add(perm);
      }
    }
    return used;
  };
}
```

---

## File 4 — `src/rbac/readiness-endpoint.ts`

Endpoint `/ready` đọc READY_STATE. Express variant (adapt cho Fastify/Koa tương tự):

```typescript
import type { Router, Request, Response } from 'express';
import { READY_STATE } from './boot-validator';

export function registerReadinessEndpoint(router: Router): void {
  router.get('/ready', (_req: Request, res: Response) => {
    if (READY_STATE.value !== 'HEALTHY') {
      res.status(503).json({ status: READY_STATE.value });
      return;
    }
    res.status(200).json({ status: 'HEALTHY' });
  });
}
```

---

## APPEND wiring — Express

```typescript
// src/app.ts
import express from 'express';
import { registerManifestEndpoint } from './rbac/manifest-endpoint';
import { registerReadinessEndpoint } from './rbac/readiness-endpoint';
import { runValidator, makeExpressScanner } from './rbac/boot-validator';

const app = express();

// === Existing routes / middleware — DO NOT modify ===
// ...

// === RBAC Phase 4 wiring (append only) ===
registerManifestEndpoint(app as any);
registerReadinessEndpoint(app as any);

// Run validator AFTER all routes registered
runValidator(makeExpressScanner(app));

app.listen(Number(process.env.APP_PORT ?? 3000), '127.0.0.1');
```

## APPEND wiring — Fastify

```typescript
// src/app.ts
import Fastify from 'fastify';
import { registerManifestEndpoint } from './rbac/manifest-endpoint';
import { runValidator, makeFastifyScanner, installFastifyHook, READY_STATE } from './rbac/boot-validator';

const app = Fastify();
installFastifyHook(app); // MUST be called BEFORE routes register

// === Existing routes / plugins — DO NOT modify ===
// ...

await registerManifestEndpoint(app);
app.get('/ready', async (_req, reply) => {
  if (READY_STATE.value !== 'HEALTHY') return reply.code(503).send({ status: READY_STATE.value });
  return { status: 'HEALTHY' };
});

await app.ready();
runValidator(makeFastifyScanner(app));

await app.listen({ host: '127.0.0.1', port: Number(process.env.APP_PORT ?? 3000) });
```

## APPEND wiring — Koa

```typescript
// src/app.ts
import Koa from 'koa';
import Router from '@koa/router';
import { registerManifestEndpoint } from './rbac/manifest-endpoint';
import { runValidator, makeKoaScanner, READY_STATE } from './rbac/boot-validator';

const app = new Koa();
const router = new Router();

// === Existing routes / middleware — DO NOT modify ===
// ...

registerManifestEndpoint(router);
router.get('/ready', (ctx) => {
  if (READY_STATE.value !== 'HEALTHY') {
    ctx.status = 503;
    ctx.body = { status: READY_STATE.value };
    return;
  }
  ctx.body = { status: 'HEALTHY' };
});

app.use(router.routes()).use(router.allowedMethods());

runValidator(makeKoaScanner(router));

app.listen(Number(process.env.APP_PORT ?? 3000), '127.0.0.1');
```

---

## Sample route dùng middleware

### Express
```typescript
import { requirePermission } from './rbac/boot-validator';

router.get('/orders', requirePermission(`${APP_SLUG}:orders.read`), (req, res) => {
  res.json({ orders: [...] });
});
```

### Fastify
```typescript
app.get('/orders', {
  preHandler: [requirePermission(`${APP_SLUG}:orders.read`)],
}, async () => ({ orders: [...] }));
```

### Koa
```typescript
router.get('/orders', requirePermission(`${APP_SLUG}:orders.read`), async (ctx) => {
  ctx.body = { orders: [...] };
});
```

---

## Verify

```bash
# Local
curl -sSL http://127.0.0.1:<PORT>/.well-known/rbac-permissions.json | jq .
# Expect: valid JSON, schema="1", service="<APP_SLUG>", permissions[], default_roles[]

curl -sSL http://127.0.0.1:<PORT>/ready
# Expect: 200 { "status": "HEALTHY" }

# Boot log expect line:
# [rbac-manifest] INFO Catalog OK — N permissions declared, M used by routes

# Test drift detection: remove 1 entry từ PERMISSIONS → restart → /ready phải 503
```

---

## Note cho pattern member đã có permission middleware riêng

Nếu app đã có `authorize('<permission>')` / `hasPermission('<id>')` middleware khác:
- Không cần rewrite — chỉ cần attach `__rbacPermission` attribute tới middleware fn khi build
- Hoặc adapt route scanner đọc attribute khác (VD `mw.permission` thay vì `mw.__rbacPermission`)
- Miễn scanner return đúng `Set<string>` các permission id dùng thực tế → validator work
