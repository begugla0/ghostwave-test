"""
GhostWave — модели базы данных
"""
import uuid
import secrets
from datetime import datetime, timezone
from sqlalchemy import (
    String, Integer, BigInteger, Boolean, DateTime,
    ForeignKey, Text, Enum as SAEnum, Float, JSON
)
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
import enum

from panel.api.core.database import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# ─────────────────────────────────────────────
# ENUMS
# ─────────────────────────────────────────────

class UserStatus(str, enum.Enum):
    ACTIVE   = "active"
    DISABLED = "disabled"
    EXPIRED  = "expired"
    LIMITED  = "limited"   # превышен трафик


class NodeStatus(str, enum.Enum):
    ONLINE   = "online"
    OFFLINE  = "offline"
    DISABLED = "disabled"


class UserNodeStatus(str, enum.Enum):
    CONNECTED    = "connected"
    DISCONNECTED = "disconnected"


# ─────────────────────────────────────────────
# ADMIN
# ─────────────────────────────────────────────

class Admin(Base):
    __tablename__ = "admins"

    id:            Mapped[int]      = mapped_column(Integer, primary_key=True)
    username:      Mapped[str]      = mapped_column(String(64), unique=True, nullable=False)
    hashed_password: Mapped[str]   = mapped_column(String(256), nullable=False)
    is_superadmin: Mapped[bool]     = mapped_column(Boolean, default=True)
    telegram_id:   Mapped[int|None] = mapped_column(BigInteger, nullable=True, unique=True)
    created_at:    Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_login:    Mapped[datetime|None] = mapped_column(DateTime(timezone=True), nullable=True)


# ─────────────────────────────────────────────
# NODES (VPN серверы)
# ─────────────────────────────────────────────

class Node(Base):
    __tablename__ = "nodes"

    id:           Mapped[int]       = mapped_column(Integer, primary_key=True)
    name:         Mapped[str]       = mapped_column(String(128), nullable=False)
    address:      Mapped[str]       = mapped_column(String(256), nullable=False)  # IP или hostname
    port:         Mapped[int]       = mapped_column(Integer, default=2095)         # agent API port
    api_key:      Mapped[str]       = mapped_column(String(128), nullable=False)   # shared secret
    country:      Mapped[str]       = mapped_column(String(64), default="")        # "RU", "NL", etc.
    city:         Mapped[str]       = mapped_column(String(64), default="")
    flag_emoji:   Mapped[str]       = mapped_column(String(8), default="🌐")
    is_enabled:   Mapped[bool]      = mapped_column(Boolean, default=True)
    status:       Mapped[NodeStatus] = mapped_column(
        SAEnum(NodeStatus), default=NodeStatus.OFFLINE
    )
    # Статистика (обновляется heartbeat'ом)
    load_avg:     Mapped[float]     = mapped_column(Float, default=0.0)
    memory_usage: Mapped[float]     = mapped_column(Float, default=0.0)  # %
    online_users: Mapped[int]       = mapped_column(Integer, default=0)
    last_seen:    Mapped[datetime|None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at:   Mapped[datetime]  = mapped_column(DateTime(timezone=True), default=utcnow)

    # GhostNet настройки на этой ноде
    ghostnet_port:   Mapped[int]  = mapped_column(Integer, default=443)
    ghostnet_domain: Mapped[str]  = mapped_column(String(256), default="")
    ghostnet_secret: Mapped[str]  = mapped_column(String(256), default="")

    users: Mapped[list["UserNode"]] = relationship("UserNode", back_populates="node")

    @property
    def is_online(self) -> bool:
        return self.status == NodeStatus.ONLINE


# ─────────────────────────────────────────────
# USERS (VPN клиенты)
# ─────────────────────────────────────────────

class User(Base):
    __tablename__ = "users"

    id:          Mapped[int]        = mapped_column(Integer, primary_key=True)
    uuid:        Mapped[str]        = mapped_column(
        String(36), unique=True, nullable=False,
        default=lambda: str(uuid.uuid4())
    )
    username:    Mapped[str]        = mapped_column(String(128), unique=True, nullable=False)
    status:      Mapped[UserStatus] = mapped_column(
        SAEnum(UserStatus), default=UserStatus.ACTIVE
    )

    # Трафик (байты)
    traffic_limit:    Mapped[int]  = mapped_column(BigInteger, default=0)   # 0 = безлимит
    traffic_used_up:  Mapped[int]  = mapped_column(BigInteger, default=0)   # upload
    traffic_used_down: Mapped[int] = mapped_column(BigInteger, default=0)   # download

    # Срок действия
    expires_at:  Mapped[datetime|None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Subscription token (уникальный URL для получения конфигов)
    sub_token:   Mapped[str]  = mapped_column(
        String(64), unique=True, nullable=False,
        default=lambda: secrets.token_urlsafe(32)
    )

    # Telegram
    telegram_id:    Mapped[int|None] = mapped_column(BigInteger, nullable=True, unique=True)
    telegram_username: Mapped[str|None] = mapped_column(String(128), nullable=True)

    # Метаданные
    note:        Mapped[str]  = mapped_column(Text, default="")
    created_at:  Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at:  Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    last_online: Mapped[datetime|None] = mapped_column(DateTime(timezone=True), nullable=True)

    nodes:   Mapped[list["UserNode"]]  = relationship("UserNode",  back_populates="user")
    devices: Mapped[list["UserDevice"]] = relationship("UserDevice", back_populates="user")

    @property
    def traffic_used(self) -> int:
        return self.traffic_used_up + self.traffic_used_down

    @property
    def traffic_remaining(self) -> int:
        if self.traffic_limit == 0:
            return -1  # безлимит
        return max(0, self.traffic_limit - self.traffic_used)

    @property
    def is_active(self) -> bool:
        if self.status != UserStatus.ACTIVE:
            return False
        if self.expires_at and self.expires_at < utcnow():
            return False
        if self.traffic_limit > 0 and self.traffic_used >= self.traffic_limit:
            return False
        return True


# ─────────────────────────────────────────────
# USER ↔ NODE (разрешения и трафик per-node)
# ─────────────────────────────────────────────

class UserNode(Base):
    __tablename__ = "user_nodes"

    id:      Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))

    is_enabled:     Mapped[bool] = mapped_column(Boolean, default=True)
    traffic_up:     Mapped[int]  = mapped_column(BigInteger, default=0)
    traffic_down:   Mapped[int]  = mapped_column(BigInteger, default=0)
    last_connected: Mapped[datetime|None] = mapped_column(DateTime(timezone=True), nullable=True)

    user: Mapped["User"] = relationship("User", back_populates="nodes")
    node: Mapped["Node"] = relationship("Node", back_populates="users")


# ─────────────────────────────────────────────
# USER DEVICES (HWID — ограничение устройств)
# ─────────────────────────────────────────────

class UserDevice(Base):
    __tablename__ = "user_devices"

    id:         Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id:    Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    hwid:       Mapped[str] = mapped_column(String(128), nullable=False)
    name:       Mapped[str] = mapped_column(String(128), default="")  # "iPhone 15", etc.
    first_seen: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_seen:  Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    is_banned:  Mapped[bool]    = mapped_column(Boolean, default=False)

    user: Mapped["User"] = relationship("User", back_populates="devices")


# ─────────────────────────────────────────────
# TRAFFIC LOGS (детальная история)
# ─────────────────────────────────────────────

class TrafficLog(Base):
    __tablename__ = "traffic_logs"

    id:         Mapped[int]      = mapped_column(Integer, primary_key=True)
    user_id:    Mapped[int]      = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    node_id:    Mapped[int]      = mapped_column(ForeignKey("nodes.id", ondelete="SET NULL"), nullable=True)
    traffic_up: Mapped[int]      = mapped_column(BigInteger, default=0)
    traffic_down: Mapped[int]    = mapped_column(BigInteger, default=0)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


# ─────────────────────────────────────────────
# SYSTEM SETTINGS (key-value хранилище)
# ─────────────────────────────────────────────

class SystemSetting(Base):
    __tablename__ = "system_settings"

    key:   Mapped[str] = mapped_column(String(128), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")
