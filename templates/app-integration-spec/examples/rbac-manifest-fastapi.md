# RBAC Manifest — FastAPI reference

**Framework:** FastAPI 0.100+ (Starlette-based)
**Language:** Python 3.11+
**Prerequisite:** SSO integration (Pattern A/B/C) đã done. Đọc `SPEC.md` §12 trước.

Reference implementation: file structure + code pattern có thể copy-adapt. Placeholder `<APP_SLUG>`, `<APP_URL>` — thay bằng slug thực của app member.

---

## File 1 — `app/rbac/permissions_catalog.py` (~80 LoC)

Literal list declare toàn bộ permission app support + default roles template.

```python
"""
permissions_catalog.py — RBAC manifest source of truth.

Add/remove permission = edit list below + restart app.
Boot validator sẽ cross-check declared vs routes dùng thực tế.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import date
from typing import Literal

APP_SLUG = "<APP_SLUG>"  # MUST match slug registered ở Central portal


def build_version() -> str:
    """Version string: prefer GIT_SHA env, fallback date-based YYYY-MM-DD.N"""
    sha = os.environ.get("GIT_SHA", "")
    if len(sha) >= 7:
        return sha[:8]
    return f"{date.today().isoformat()}.1"


@dataclass(frozen=True)
class PermissionEntry:
    id: str
    description: str


@dataclass(frozen=True)
class DefaultRole:
    key: str
    description: str
    permissions: list[str]


# Flat permission list — grep-friendly.
# Format: <APP_SLUG>:<resource>.<action>
# Rules: lowercase, kebab-case allowed in resource, dot separates resource from action.
PERMISSIONS: list[PermissionEntry] = [
    # === Examples — replace with actual permissions of your app ===
    PermissionEntry(id=f"{APP_SLUG}:orders.read",    description="Xem đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:orders.create",  description="Tạo đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:orders.update",  description="Sửa đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:orders.delete",  description="Xoá đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:orders.approve", description="Duyệt đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:orders.export",  description="Xuất file đơn hàng"),
    PermissionEntry(id=f"{APP_SLUG}:reports.read",   description="Xem báo cáo"),
    PermissionEntry(id=f"{APP_SLUG}:reports.export", description="Xuất báo cáo"),
]


def _is_destructive_or_user_mgmt(pid: str) -> bool:
    return (
        pid.endswith(".delete")
        or pid.endswith(".approve")
        or pid.startswith(f"{APP_SLUG}:users.")
        or pid.startswith(f"{APP_SLUG}:object-permissions.")
        or pid.startswith(f"{APP_SLUG}:user-groups.")
    )


def _is_read_or_export(pid: str) -> bool:
    return pid.endswith(".read") or pid.endswith(".export")


# 3 recommended roles — add custom roles below if needed (max 50 total)
DEFAULT_ROLES: list[DefaultRole] = [
    DefaultRole(
        key=f"{APP_SLUG}.admin",
        description="Quản trị viên — full access",
        permissions=[p.id for p in PERMISSIONS],
    ),
    DefaultRole(
        key=f"{APP_SLUG}.editor",
        description="Nghiệp vụ — CRUD trừ delete/approve/user-mgmt",
        permissions=[p.id for p in PERMISSIONS if not _is_destructive_or_user_mgmt(p.id)],
    ),
    DefaultRole(
        key=f"{APP_SLUG}.viewer",
        description="Chỉ xem — read + export",
        permissions=[p.id for p in PERMISSIONS if _is_read_or_export(p.id)],
    ),
]


def build_manifest() -> dict:
    """Build manifest dict conforming to Central RBAC schema v1."""
    return {
        "schema": "1",
        "service": APP_SLUG,
        "version": build_version(),
        "permissions": [{"id": p.id, "description": p.description} for p in PERMISSIONS],
        "default_roles": [
            {"key": r.key, "description": r.description, "permissions": r.permissions}
            for r in DEFAULT_ROLES
        ],
    }
```

---

## File 2 — `app/rbac/manifest_endpoint.py` (~30 LoC)

FastAPI router expose `GET /.well-known/rbac-permissions.json`.

```python
"""
manifest_endpoint.py — public endpoint for Central RBAC sync.
Route: GET /.well-known/rbac-permissions.json
(Nếu app dùng app.include_router(prefix="/api"), URL final: /api/.well-known/rbac-permissions.json)
"""
from __future__ import annotations

from fastapi import APIRouter, Response
from fastapi.responses import JSONResponse

from .permissions_catalog import build_manifest

router = APIRouter()

_cached_manifest: dict | None = None


@router.get("/.well-known/rbac-permissions.json", include_in_schema=False)
def get_manifest() -> Response:
    global _cached_manifest
    if _cached_manifest is None:
        _cached_manifest = build_manifest()
    return JSONResponse(
        content=_cached_manifest,
        headers={
            "Cache-Control": "public, max-age=300",
            "ETag": f'"{_cached_manifest["version"]}"',
            "X-Robots-Tag": "noindex",
        },
    )
```

**BẮT BUỘC (SPEC.md §3 rule 11 + §12.1):**
- `X-Robots-Tag: noindex` — ngăn Google/Bing index endpoint public
- KHÔNG log full response body ở access log (uvicorn/gunicorn: verify `access_log_format` không include response body cho path `.well-known/*`)

**Nếu app có SSO middleware auth-first (Depends dependency):** whitelist path `/.well-known/rbac-permissions.json` khỏi auth check. Cách nhanh nhất: mount router BEFORE global auth dependency.

**Nếu app có response middleware wrap JSON (envelope `{data, meta}`):** bypass wrapping cho manifest endpoint (Central schema validator reject nếu bị wrap).

---

## File 3 — `app/rbac/boot_validator.py` (~70 LoC)

Cross-check declared permissions vs routes dùng thực tế, set /ready state.

Pattern: mỗi route dùng `Depends(require_permission("<id>"))`. Validator scan tất cả routes qua `app.routes`, extract permission id từ closure của Depends factory.

```python
"""
boot_validator.py — verify declared PERMISSIONS matches routes usage.
Run once at startup. Fail = set READY_STATE=UNHEALTHY → /ready returns 503.
"""
from __future__ import annotations

import logging
from typing import Literal

from fastapi import FastAPI

from .permissions_catalog import PERMISSIONS

log = logging.getLogger("rbac-manifest")

# Global ready state — GET /ready reads this
READY_STATE: dict[str, Literal["STARTING", "HEALTHY", "UNHEALTHY"]] = {"value": "STARTING"}


def require_permission(permission_id: str):
    """
    Depends factory. Attach permission id to __rbac_permission__ for validator scan.
    Runtime permission check qua Central RBAC API — out of scope Phase 4.
    """
    def _dep():
        # TODO: call Central RBAC API to verify current user has permission_id
        return permission_id

    _dep.__rbac_permission__ = permission_id  # type: ignore[attr-defined]
    return _dep


def _scan_route_permissions(app: FastAPI) -> set[str]:
    """Walk app.routes, collect permission ids from Depends factories."""
    used: set[str] = set()
    for route in app.routes:
        if not hasattr(route, "dependant"):
            continue
        for dep in getattr(route.dependant, "dependencies", []):
            call = getattr(dep, "call", None)
            perm = getattr(call, "__rbac_permission__", None)
            if perm:
                used.add(perm)
    return used


def run_validator(app: FastAPI) -> None:
    """Call in FastAPI startup event."""
    declared = {p.id for p in PERMISSIONS}
    actual = _scan_route_permissions(app)

    missing = actual - declared
    unused = declared - actual

    if missing:
        log.error("Routes use undeclared permissions: %s", sorted(missing))
        log.error("Fix: add to PERMISSIONS list in permissions_catalog.py")
        READY_STATE["value"] = "UNHEALTHY"
        return

    if unused:
        log.warning("Declared but unused (dead code): %s", sorted(unused))
    log.info("Catalog OK — %d permissions declared, %d used by routes", len(declared), len(actual))
    READY_STATE["value"] = "HEALTHY"
```

---

## File 4 — `app/rbac/readiness_endpoint.py` (~20 LoC)

Endpoint `/ready` đọc READY_STATE, return 503 khi UNHEALTHY.

```python
"""readiness_endpoint.py — GET /ready reflects RBAC boot validator state."""
from fastapi import APIRouter, HTTPException

from .boot_validator import READY_STATE

router = APIRouter()


@router.get("/ready", include_in_schema=False)
def ready() -> dict:
    if READY_STATE["value"] != "HEALTHY":
        raise HTTPException(status_code=503, detail={"status": READY_STATE["value"]})
    return {"status": "HEALTHY"}
```

---

## APPEND wiring — `app/main.py`

```python
from fastapi import FastAPI

from .rbac.manifest_endpoint import router as rbac_manifest_router
from .rbac.readiness_endpoint import router as readiness_router
from .rbac.boot_validator import run_validator

app = FastAPI()

# === Existing routes / middleware — DO NOT modify ===
# ...

# === RBAC Phase 4 wiring (append only) ===
app.include_router(rbac_manifest_router)   # + /.well-known/rbac-permissions.json
app.include_router(readiness_router)       # + /ready


@app.on_event("startup")
def _rbac_boot_check() -> None:
    run_validator(app)
```

**Nếu app dùng `app.include_router(prefix="/api")` cho tất cả:** manifest URL sẽ là `/api/.well-known/rbac-permissions.json` — khai đúng vào Central portal `manifest_url` field.

**Nếu app đã có `/ready` endpoint:** merge state — thay vì tạo router mới, append check `READY_STATE["value"] != "HEALTHY"` vào existing handler.

---

## Sample route dùng permission decorator

```python
from fastapi import APIRouter, Depends
from app.rbac.boot_validator import require_permission

router = APIRouter()


@router.get("/orders")
def list_orders(_perm: str = Depends(require_permission(f"{APP_SLUG}:orders.read"))):
    return {"orders": [...]}


@router.post("/orders")
def create_order(_perm: str = Depends(require_permission(f"{APP_SLUG}:orders.create"))):
    ...
```

Validator sẽ tự pick up permission id từ `__rbac_permission__` attribute của Depends factory.

---

## Verify

```bash
# Local
curl -sSL http://127.0.0.1:<PORT>/api/.well-known/rbac-permissions.json | jq .
# Expect: valid JSON, schema="1", service="<APP_SLUG>", permissions[], default_roles[]

curl -sSL http://127.0.0.1:<PORT>/ready
# Expect: 200 { "status": "HEALTHY" }

# Boot log expect line:
# rbac-manifest INFO Catalog OK — N permissions declared, M used by routes

# Test drift detection: remove 1 entry từ PERMISSIONS → restart → /ready phải 503
```

---

## Django variant note

Django không phải FastAPI-style — pattern tương tự:
- `permissions_catalog.py` — identical (pure Python, no framework dep)
- Endpoint qua Django view + URLconf: `path('.well-known/rbac-permissions.json', manifest_view)`
- Validator scan `django.urls.get_resolver()` + custom `@permission_required('<id>')` decorator attribute
- `/ready` via Django health check view

Cùng file layout `app/rbac/`, cùng logic — chỉ đổi framework glue code.
