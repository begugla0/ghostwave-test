"""
GhostWave — сервисный слой (бизнес-логика)
"""
from __future__ import annotations
import secrets
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select, func, update, delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from panel.api.models import (
    User, Node, UserNode, TrafficLog, UserDevice,
    UserStatus, NodeStatus
)
from panel.api.schemas import UserCreate, UserUpdate, NodeCreate, NodeUpdate


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# ─────────────────────────────────────────────
# USER SERVICE
# ─────────────────────────────────────────────

class UserService:

    @staticmethod
    async def create(db: AsyncSession, data: UserCreate) -> User:
        # Проверяем уникальность username
        existing = await db.scalar(select(User).where(User.username == data.username))
        if existing:
            raise ValueError(f"Пользователь '{data.username}' уже существует")

        user = User(
            username=data.username,
            traffic_limit=data.traffic_limit,
            expires_at=data.expires_at,
            note=data.note,
            telegram_id=data.telegram_id,
        )
        db.add(user)
        await db.flush()  # получаем user.id

        # Привязываем к нодам
        if data.node_ids:
            for node_id in data.node_ids:
                db.add(UserNode(user_id=user.id, node_id=node_id))
        else:
            # Привязываем ко всем активным нодам
            nodes = await db.scalars(select(Node).where(Node.is_enabled == True))
            for node in nodes:
                db.add(UserNode(user_id=user.id, node_id=node.id))

        await db.flush()
        return user

    @staticmethod
    async def get(db: AsyncSession, user_id: int) -> Optional[User]:
        return await db.scalar(
            select(User)
            .where(User.id == user_id)
            .options(selectinload(User.nodes).selectinload(UserNode.node))
        )

    @staticmethod
    async def get_by_uuid(db: AsyncSession, uuid: str) -> Optional[User]:
        return await db.scalar(select(User).where(User.uuid == uuid))

    @staticmethod
    async def get_by_sub_token(db: AsyncSession, token: str) -> Optional[User]:
        return await db.scalar(select(User).where(User.sub_token == token))

    @staticmethod
    async def get_by_telegram(db: AsyncSession, telegram_id: int) -> Optional[User]:
        return await db.scalar(select(User).where(User.telegram_id == telegram_id))

    @staticmethod
    async def list_all(
        db: AsyncSession,
        offset: int = 0,
        limit:  int = 50,
        status: Optional[str] = None,
        search: Optional[str] = None,
    ) -> tuple[int, list[User]]:
        q = select(User)
        if status:
            q = q.where(User.status == status)
        if search:
            q = q.where(User.username.ilike(f"%{search}%"))

        total = await db.scalar(select(func.count()).select_from(q.subquery()))
        users = await db.scalars(q.offset(offset).limit(limit).order_by(User.created_at.desc()))
        return total or 0, list(users)

    @staticmethod
    async def update(db: AsyncSession, user: User, data: UserUpdate) -> User:
        if data.status is not None:
            user.status = data.status
        if data.traffic_limit is not None:
            user.traffic_limit = data.traffic_limit
        if data.expires_at is not None:
            user.expires_at = data.expires_at
        if data.note is not None:
            user.note = data.note
        if data.node_ids is not None:
            # Перезаписываем разрешённые ноды
            await db.execute(delete(UserNode).where(UserNode.user_id == user.id))
            for node_id in data.node_ids:
                db.add(UserNode(user_id=user.id, node_id=node_id))
        user.updated_at = utcnow()
        return user

    @staticmethod
    async def delete(db: AsyncSession, user: User) -> None:
        await db.delete(user)

    @staticmethod
    async def reset_traffic(db: AsyncSession, user: User) -> User:
        user.traffic_used_up   = 0
        user.traffic_used_down = 0
        user.updated_at        = utcnow()
        if user.status == UserStatus.LIMITED:
            user.status = UserStatus.ACTIVE
        return user

    @staticmethod
    async def apply_traffic(
        db: AsyncSession,
        user_uuid: str,
        node_id:   int,
        up_bytes:  int,
        down_bytes: int,
    ) -> None:
        """Вызывается при получении трафик-репорта от ноды."""
        user = await UserService.get_by_uuid(db, user_uuid)
        if not user:
            return

        user.traffic_used_up   += up_bytes
        user.traffic_used_down += down_bytes
        user.last_online        = utcnow()

        # Обновляем трафик на конкретной ноде
        await db.execute(
            update(UserNode)
            .where(UserNode.user_id == user.id, UserNode.node_id == node_id)
            .values(
                traffic_up=UserNode.traffic_up + up_bytes,
                traffic_down=UserNode.traffic_down + down_bytes,
                last_connected=utcnow(),
            )
        )

        # Проверяем лимит
        if user.traffic_limit > 0 and user.traffic_used >= user.traffic_limit:
            user.status = UserStatus.LIMITED

        # Пишем лог
        db.add(TrafficLog(
            user_id=user.id,
            node_id=node_id,
            traffic_up=up_bytes,
            traffic_down=down_bytes,
        ))

    @staticmethod
    async def get_allowed_uuids_for_node(db: AsyncSession, node_id: int) -> list[str]:
        """Список UUID пользователей которым разрешён доступ к этой ноде."""
        result = await db.execute(
            select(User.uuid)
            .join(UserNode, UserNode.user_id == User.id)
            .where(
                UserNode.node_id == node_id,
                UserNode.is_enabled == True,
                User.status == UserStatus.ACTIVE,
            )
        )
        return [row[0] for row in result.fetchall()]

    @staticmethod
    async def sync_status(db: AsyncSession) -> int:
        """
        Периодически вызывается планировщиком.
        Помечает expired пользователей.
        """
        now = utcnow()
        result = await db.execute(
            update(User)
            .where(User.expires_at < now, User.status == UserStatus.ACTIVE)
            .values(status=UserStatus.EXPIRED)
            .returning(User.id)
        )
        return len(result.fetchall())


# ─────────────────────────────────────────────
# NODE SERVICE
# ─────────────────────────────────────────────

class NodeService:

    @staticmethod
    async def create(db: AsyncSession, data: NodeCreate) -> Node:
        api_key = secrets.token_hex(32)
        node = Node(
            name=data.name,
            address=data.address,
            port=data.port,
            api_key=api_key,
            country=data.country,
            city=data.city,
            flag_emoji=data.flag_emoji,
            ghostnet_port=data.ghostnet_port,
            ghostnet_domain=data.ghostnet_domain,
            ghostnet_secret=data.ghostnet_secret or secrets.token_hex(32),
        )
        db.add(node)
        await db.flush()
        return node

    @staticmethod
    async def get(db: AsyncSession, node_id: int) -> Optional[Node]:
        return await db.scalar(select(Node).where(Node.id == node_id))

    @staticmethod
    async def list_all(db: AsyncSession) -> list[Node]:
        return list(await db.scalars(select(Node).order_by(Node.name)))

    @staticmethod
    async def update(db: AsyncSession, node: Node, data: NodeUpdate) -> Node:
        for field, value in data.model_dump(exclude_none=True).items():
            setattr(node, field, value)
        return node

    @staticmethod
    async def delete(db: AsyncSession, node: Node) -> None:
        await db.delete(node)

    @staticmethod
    async def heartbeat(
        db: AsyncSession,
        node: Node,
        load_avg:     float,
        memory_usage: float,
        online_users: int,
    ) -> None:
        node.status       = NodeStatus.ONLINE
        node.load_avg     = load_avg
        node.memory_usage = memory_usage
        node.online_users = online_users
        node.last_seen    = utcnow()

    @staticmethod
    async def mark_offline(db: AsyncSession) -> None:
        """Помечает оффлайн ноды у которых не было heartbeat > 60 секунд."""
        from datetime import timedelta
        threshold = utcnow() - timedelta(seconds=60)
        await db.execute(
            update(Node)
            .where(Node.last_seen < threshold, Node.status == NodeStatus.ONLINE)
            .values(status=NodeStatus.OFFLINE)
        )

    @staticmethod
    async def get_stats(db: AsyncSession) -> dict:
        total  = await db.scalar(select(func.count(Node.id)))
        online = await db.scalar(
            select(func.count(Node.id)).where(Node.status == NodeStatus.ONLINE)
        )
        return {"total": total or 0, "online": online or 0}
