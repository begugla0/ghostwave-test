"""
GhostWave Panel — API роутеры
"""
from __future__ import annotations
from datetime import datetime, timezone, timedelta
from typing import Optional, Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
import bcrypt
import jwt

from panel.api.core.config import get_settings
from panel.api.core.database import get_db
from panel.api.models import Admin, Node, NodeStatus
from panel.api.schemas import (
    AdminLogin, TokenResponse,
    NodeCreate, NodeUpdate, NodeOut,
    UserCreate, UserUpdate, UserOut, UserListOut, TrafficResetResponse,
    SystemStats, NodeHeartbeat, NodeHeartbeatResponse, NodeTrafficReport,
)
from panel.api.services.services import UserService, NodeService

settings   = get_settings()
oauth2     = OAuth2PasswordBearer(tokenUrl="/api/auth/login")
DB         = Annotated[AsyncSession, Depends(get_db)]

router_auth  = APIRouter(prefix="/api/auth",  tags=["Auth"])
router_users = APIRouter(prefix="/api/users", tags=["Users"])
router_nodes = APIRouter(prefix="/api/nodes", tags=["Nodes"])
router_stats = APIRouter(prefix="/api/stats", tags=["Stats"])
router_node_agent = APIRouter(prefix="/api/node", tags=["Node Agent"])


# ─────────────────────────────────────────────
# AUTH HELPERS
# ─────────────────────────────────────────────

def make_token(admin_id: int) -> str:
    payload = {
        "sub": str(admin_id),
        "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.JWT_EXPIRE_MINUTES),
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm="HS256")


async def get_current_admin(token: Annotated[str, Depends(oauth2)], db: DB) -> Admin:
    try:
        payload = jwt.decode(token, settings.JWT_SECRET, algorithms=["HS256"])
        admin_id = int(payload["sub"])
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
    admin = await db.get(Admin, admin_id)
    if not admin:
        raise HTTPException(status_code=401, detail="Admin not found")
    return admin


CurrentAdmin = Annotated[Admin, Depends(get_current_admin)]


# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────

@router_auth.post("/login", response_model=TokenResponse)
async def login(form: OAuth2PasswordRequestForm = Depends(), db: DB = Depends(get_db)):
    admin = await db.scalar(select(Admin).where(Admin.username == form.username))
    if not admin:
        raise HTTPException(status_code=401, detail="Wrong credentials")
    if not bcrypt.checkpw(form.password.encode(), admin.hashed_password.encode()):
        raise HTTPException(status_code=401, detail="Wrong credentials")
    admin.last_login = datetime.now(timezone.utc)
    return TokenResponse(access_token=make_token(admin.id))


@router_auth.get("/me")
async def me(admin: CurrentAdmin):
    return {"id": admin.id, "username": admin.username, "is_superadmin": admin.is_superadmin}


# ─────────────────────────────────────────────
# USERS
# ─────────────────────────────────────────────

@router_users.post("", response_model=UserOut, status_code=201)
async def create_user(data: UserCreate, db: DB, _: CurrentAdmin):
    try:
        user = await UserService.create(db, data)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return user


@router_users.get("", response_model=UserListOut)
async def list_users(
    db: DB, _: CurrentAdmin,
    offset: int = Query(0, ge=0),
    limit:  int = Query(50, ge=1, le=500),
    status: Optional[str] = None,
    search: Optional[str] = None,
):
    total, users = await UserService.list_all(db, offset, limit, status, search)
    return UserListOut(total=total, users=users)


@router_users.get("/{user_id}", response_model=UserOut)
async def get_user(user_id: int, db: DB, _: CurrentAdmin):
    user = await UserService.get(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router_users.patch("/{user_id}", response_model=UserOut)
async def update_user(user_id: int, data: UserUpdate, db: DB, _: CurrentAdmin):
    user = await UserService.get(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return await UserService.update(db, user, data)


@router_users.delete("/{user_id}", status_code=204)
async def delete_user(user_id: int, db: DB, _: CurrentAdmin):
    user = await UserService.get(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    await UserService.delete(db, user)


@router_users.post("/{user_id}/reset-traffic", response_model=TrafficResetResponse)
async def reset_traffic(user_id: int, db: DB, _: CurrentAdmin):
    user = await UserService.get(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    await UserService.reset_traffic(db, user)
    return TrafficResetResponse(
        user_id=user.id,
        username=user.username,
        message="Traffic reset successfully"
    )


@router_users.post("/{user_id}/revoke-sub", response_model=UserOut)
async def revoke_sub_token(user_id: int, db: DB, _: CurrentAdmin):
    """Перегенерировать subscription token."""
    import secrets
    user = await UserService.get(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.sub_token = secrets.token_urlsafe(32)
    return user


# ─────────────────────────────────────────────
# NODES
# ─────────────────────────────────────────────

@router_nodes.post("", response_model=NodeOut, status_code=201)
async def create_node(data: NodeCreate, db: DB, _: CurrentAdmin):
    node = await NodeService.create(db, data)
    return node


@router_nodes.get("", response_model=list[NodeOut])
async def list_nodes(db: DB, _: CurrentAdmin):
    return await NodeService.list_all(db)


@router_nodes.get("/{node_id}", response_model=NodeOut)
async def get_node(node_id: int, db: DB, _: CurrentAdmin):
    node = await NodeService.get(db, node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    return node


@router_nodes.patch("/{node_id}", response_model=NodeOut)
async def update_node(node_id: int, data: NodeUpdate, db: DB, _: CurrentAdmin):
    node = await NodeService.get(db, node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    return await NodeService.update(db, node, data)


@router_nodes.delete("/{node_id}", status_code=204)
async def delete_node(node_id: int, db: DB, _: CurrentAdmin):
    node = await NodeService.get(db, node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    await NodeService.delete(db, node)


@router_nodes.get("/{node_id}/users")
async def node_users(node_id: int, db: DB, _: CurrentAdmin):
    """Список пользователей разрешённых на данной ноде."""
    uuids = await UserService.get_allowed_uuids_for_node(db, node_id)
    return {"node_id": node_id, "allowed_users": uuids, "count": len(uuids)}


# ─────────────────────────────────────────────
# STATS
# ─────────────────────────────────────────────

@router_stats.get("", response_model=SystemStats)
async def get_stats(db: DB, _: CurrentAdmin):
    from sqlalchemy import func
    from panel.api.models import User, UserStatus

    total_users   = await db.scalar(select(func.count(User.id)))
    active_users  = await db.scalar(select(func.count(User.id)).where(User.status == UserStatus.ACTIVE))
    expired_users = await db.scalar(select(func.count(User.id)).where(User.status == UserStatus.EXPIRED))
    limited_users = await db.scalar(select(func.count(User.id)).where(User.status == UserStatus.LIMITED))

    total_traffic = await db.scalar(
        select(func.sum(User.traffic_used_up + User.traffic_used_down))
    )

    node_stats = await NodeService.get_stats(db)

    return SystemStats(
        total_users=total_users or 0,
        active_users=active_users or 0,
        expired_users=expired_users or 0,
        limited_users=limited_users or 0,
        total_nodes=node_stats["total"],
        online_nodes=node_stats["online"],
        total_traffic=total_traffic or 0,
        traffic_today=0,  # TODO: из TrafficLog за сегодня
    )


# ─────────────────────────────────────────────
# NODE AGENT API (вызывается самими нодами)
# ─────────────────────────────────────────────

async def verify_node_key(
    node_id: int,
    db: AsyncSession,
    api_key: str,
) -> Node:
    node = await NodeService.get(db, node_id)
    if not node or node.api_key != api_key:
        raise HTTPException(status_code=401, detail="Invalid node credentials")
    return node


@router_node_agent.post("/heartbeat", response_model=NodeHeartbeatResponse)
async def node_heartbeat(data: NodeHeartbeat, db: DB):
    """
    Node → Panel: сообщает что жива + статистику.
    Panel → Node: возвращает список разрешённых UUID.
    """
    node = await db.scalar(select(Node).where(Node.id == data.node_id))
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    await NodeService.heartbeat(
        db, node,
        load_avg=data.load_avg,
        memory_usage=data.memory_usage,
        online_users=data.online_users,
    )

    allowed = await UserService.get_allowed_uuids_for_node(db, node.id)
    return NodeHeartbeatResponse(ok=True, active_users=allowed)


@router_node_agent.post("/traffic")
async def node_traffic_report(data: NodeTrafficReport, db: DB):
    """Node → Panel: отчёт по потреблённому трафику."""
    node = await db.scalar(select(Node).where(Node.id == data.node_id))
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    for entry in data.traffic:
        await UserService.apply_traffic(
            db,
            user_uuid=entry["user_uuid"],
            node_id=node.id,
            up_bytes=entry.get("up_bytes", 0),
            down_bytes=entry.get("down_bytes", 0),
        )
    return {"ok": True, "processed": len(data.traffic)}
