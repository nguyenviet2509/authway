# RBAC Manifest — NestJS reference

**Framework:** NestJS 10+ (Fastify hoặc Express adapter)
**Language:** TypeScript
**Prerequisite:** SSO integration (Pattern A/B/C) đã done. Đọc `SPEC.md` §12 trước.

Reference implementation: file structure + code pattern có thể copy-adapt. Placeholder `<APP_SLUG>`, `<APP_URL>` — thay bằng slug thực của app member.

---

## File 1 — `src/rbac/permissions-catalog.ts` (~80 LoC)

Literal array declare toàn bộ permission app support + default roles template.

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

## File 2 — `src/rbac/manifest-endpoint.controller.ts` (~30 LoC)

NestJS controller expose route `GET /.well-known/rbac-permissions.json`.

```typescript
/**
 * manifest-endpoint.controller.ts — public endpoint for Central RBAC sync.
 * Route: GET /.well-known/rbac-permissions.json
 * (Nếu app dùng setGlobalPrefix('api'), URL final: /api/.well-known/rbac-permissions.json)
 */
import { Controller, Get, Header, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify'; // hoặc `import type { Response } from 'express'`
import { buildManifest, type RbacManifest } from './permissions-catalog';

@Controller('.well-known')
export class RbacManifestController {
  private cached: RbacManifest | null = null;

  @Get('rbac-permissions.json')
  @Header('Content-Type', 'application/json; charset=utf-8')
  @Header('Cache-Control', 'public, max-age=300')
  getManifest(@Res({ passthrough: true }) reply: FastifyReply): RbacManifest {
    if (!this.cached) this.cached = buildManifest();
    reply.header('ETag', `"${this.cached.version}"`);
    return this.cached;
  }
}
```

**Nếu app KHÔNG có `@Public()` decorator (SSO middleware auth-first):** thêm `@Public()` (hoặc `@SkipAuth()` — tên tuỳ project) để endpoint public.

**Nếu app có response interceptor wrap JSON (VD envelope `{ data, meta }`):** thêm `@SkipResponseInterceptor()` để trả raw JSON.

---

## File 3 — `src/rbac/boot-validator.ts` (~70 LoC)

Cross-check declared permissions vs routes dùng thực tế, set /ready state.

**Nếu app có custom `@RequirePermission('<id>')` decorator:** scan qua Reflector. Nếu chưa có: dùng grep-based static analysis hoặc offer scaffold decorator mới.

```typescript
/**
 * boot-validator.ts — verify declared PERMISSIONS matches routes usage.
 * Run once at boot. Fail = set READY_STATE=UNHEALTHY → /ready returns 503.
 */
import { Injectable, Logger, type OnApplicationBootstrap } from '@nestjs/common';
import { DiscoveryService, MetadataScanner, Reflector } from '@nestjs/core';
import { PERMISSIONS } from './permissions-catalog';

/** Decorator key — nếu app đã có @RequirePermission dùng đúng key này */
export const REQUIRE_PERMISSION_KEY = 'require_permission';

/** Global ready state — GET /ready reads this */
export const READY_STATE = { value: 'STARTING' as 'STARTING' | 'HEALTHY' | 'UNHEALTHY' };

@Injectable()
export class RbacBootValidator implements OnApplicationBootstrap {
  private readonly log = new Logger('rbac-manifest');

  constructor(
    private readonly discovery: DiscoveryService,
    private readonly scanner: MetadataScanner,
    private readonly reflector: Reflector,
  ) {}

  onApplicationBootstrap(): void {
    const declared = new Set(PERMISSIONS.map((p) => p.id));
    const actual = this.scanRoutePermissions();

    const missing = [...actual].filter((id) => !declared.has(id));
    const unused = [...declared].filter((id) => !actual.has(id));

    if (missing.length > 0) {
      this.log.error(`Routes use undeclared permissions: ${missing.join(', ')}`);
      this.log.error(`Fix: add to PERMISSIONS array in permissions-catalog.ts`);
      READY_STATE.value = 'UNHEALTHY';
      return;
    }

    if (unused.length > 0) {
      this.log.warn(`Declared but unused (dead code): ${unused.join(', ')}`);
    }
    this.log.log(`Catalog OK — ${declared.size} permissions declared, ${actual.size} used by routes`);
    READY_STATE.value = 'HEALTHY';
  }

  /** Walk all controllers, extract @RequirePermission('<id>') metadata */
  private scanRoutePermissions(): Set<string> {
    const used = new Set<string>();
    const controllers = this.discovery.getControllers();

    for (const wrapper of controllers) {
      if (!wrapper.instance) continue;
      const proto = Object.getPrototypeOf(wrapper.instance);
      this.scanner.getAllMethodNames(proto).forEach((method) => {
        const perm = this.reflector.get<string>(REQUIRE_PERMISSION_KEY, proto[method]);
        if (perm) used.add(perm);
      });
    }
    return used;
  }
}
```

**Sample `/ready` controller (create nếu chưa có):**
```typescript
import { Controller, Get, HttpCode, HttpException } from '@nestjs/common';
import { READY_STATE } from './boot-validator';

@Controller()
export class ReadinessController {
  @Get('ready')
  @HttpCode(200)
  ready() {
    if (READY_STATE.value !== 'HEALTHY') {
      throw new HttpException({ status: READY_STATE.value }, 503);
    }
    return { status: 'HEALTHY' };
  }
}
```

---

## File 4 — `src/rbac/rbac.module.ts` (~15 LoC)

Wire controller + service + validator.

```typescript
import { Module } from '@nestjs/common';
import { DiscoveryModule } from '@nestjs/core';
import { RbacManifestController } from './manifest-endpoint.controller';
import { RbacBootValidator } from './boot-validator';
import { ReadinessController } from './readiness.controller';

@Module({
  imports: [DiscoveryModule],
  controllers: [RbacManifestController, ReadinessController],
  providers: [RbacBootValidator],
})
export class RbacModule {}
```

---

## APPEND wiring — `src/app.module.ts` (+1 line)

```typescript
import { RbacModule } from './rbac/rbac.module';

@Module({
  imports: [
    // ... existing modules
    RbacModule,   // <-- ADD THIS LINE
  ],
})
export class AppModule {}
```

---

## Optional: `@RequirePermission()` decorator (nếu app chưa có)

Nếu app chưa có permission check pattern nào, tạo decorator + guard trước khi validator work:

```typescript
// src/rbac/require-permission.decorator.ts
import { SetMetadata } from '@nestjs/common';
import { REQUIRE_PERMISSION_KEY } from './boot-validator';

export const RequirePermission = (permissionId: string) =>
  SetMetadata(REQUIRE_PERMISSION_KEY, permissionId);
```

Guard implementation (check permission qua Central RBAC API sau khi có JWT identity) — out of scope Phase 4, xem `SPEC.md` §12.1 note "runtime permission check qua Central API".

---

## Verify

```bash
# Local
curl -sSL http://127.0.0.1:<PORT>/api/.well-known/rbac-permissions.json | jq .
# Expect: valid JSON, schema="1", service="<APP_SLUG>", permissions[], default_roles[]

curl -sSL http://127.0.0.1:<PORT>/api/ready
# Expect: 200 { "status": "HEALTHY" }

# Boot log expect line:
# [rbac-manifest] Catalog OK — N permissions declared, M used by routes

# Test drift detection: remove 1 entry từ PERMISSIONS → restart → /ready phải 503
```

---

## Advanced variant — auto-scan (skip manual declare)

Nếu team quen NestJS Reflector pattern, có thể build `PERMISSIONS` array TỰ ĐỘNG từ decorator scan (thay vì literal declare):

- Boot: walk tất cả controllers → collect `@RequirePermission('<id>')` metadata → build `PERMISSIONS = [{id, description}]`
- Description sinh từ format `<action> <resource>` hoặc từ decorator metadata mở rộng `@RequirePermission({ id, description })`
- Trade: 0 drift, nhưng phải maintain description ở mỗi decorator call site (thay vì 1 file)

Ưu tiên default manual declare cho grep-friendly. Auto-scan optional nếu team có kỷ luật decorator.
