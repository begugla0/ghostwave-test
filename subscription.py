"""
Subscription endpoint — генерация конфигов для клиентов
Один URL → все ноды пользователя в нужном формате
"""
from __future__ import annotations
import base64
import json
import secrets
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from panel.api.core.config import get_settings
from panel.api.core.database import get_db
from panel.api.models import User, Node, UserNode, UserStatus

settings = get_settings()
router_sub = APIRouter(prefix="/sub", tags=["Subscription"])

DB = Depends(get_db)


# ─────────────────────────────────────────────
# ВЫЧИСЛЯЕМ TEMPORAL TOKEN для GhostNet
# ─────────────────────────────────────────────

import hmac
import hashlib
import math
import time


def compute_ghostnet_token(secret: str, domain: str) -> str:
    """Текущий temporal HMAC токен для подключения к ноде."""
    slot = int(time.time()) // 30
    data = f"{slot}:{domain}".encode()
    digest = hmac.new(secret.encode(), data, hashlib.sha256).digest()
    value = int.from_bytes(digest[:6], 'big')
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = []
    while value:
        result.append(chars[value % 36])
        value //= 36
    return ''.join(reversed(result)).zfill(10)


# ─────────────────────────────────────────────
# ГЕНЕРАЦИЯ КОНФИГОВ
# ─────────────────────────────────────────────

def make_ghostnet_config(user: User, node: Node) -> dict:
    """
    Конфиг для одной ноды в формате GhostNet.
    Клиентская библиотека читает этот JSON.
    """
    return {
        "protocol":      "ghostnet",
        "version":       "1.0",
        "server_host":   node.address,
        "server_port":   node.ghostnet_port,
        "domain":        node.ghostnet_domain or node.address,
        "shared_secret": node.ghostnet_secret,
        "user_uuid":     user.uuid,
        "remarks":       f"{node.flag_emoji} {node.name}",
        "node_id":       node.id,
    }


def make_ghostnet_uri(user: User, node: Node) -> str:
    """
    Компактный URI для QR-кода и импорта в клиент.
    Формат: ghostnet://base64(json)#remarks
    """
    cfg = make_ghostnet_config(user, node)
    payload = base64.urlsafe_b64encode(
        json.dumps(cfg, separators=(",", ":")).encode()
    ).decode()
    remarks = f"{node.flag_emoji} {node.name}"
    return f"ghostnet://{payload}#{remarks}"


def make_clash_config(user: User, nodes: list[Node]) -> str:
    """Clash/Mihomo совместимый YAML с кастомным прокси-типом."""
    proxies = []
    for node in nodes:
        proxies.append({
            "name":   f"{node.flag_emoji} {node.name}",
            "type":   "ghostnet",
            "server": node.address,
            "port":   node.ghostnet_port,
            "uuid":   user.uuid,
            "domain": node.ghostnet_domain or node.address,
            "secret": node.ghostnet_secret,
        })

    proxy_names = [p["name"] for p in proxies]

    lines = [
        "# GhostWave Subscription",
        f"# User: {user.username}",
        f"# Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        "",
        "mixed-port: 7890",
        "allow-lan: false",
        "mode: rule",
        "log-level: info",
        "",
        "proxies:",
    ]
    for p in proxies:
        lines += [
            f"  - name: \"{p['name']}\"",
            f"    type: ghostnet",
            f"    server: {p['server']}",
            f"    port: {p['port']}",
            f"    uuid: {p['uuid']}",
            f"    domain: {p['domain']}",
        ]

    lines += [
        "",
        "proxy-groups:",
        "  - name: 🚀 Proxy",
        "    type: select",
        "    proxies:",
    ] + [f"      - \"{n}\"" for n in proxy_names]

    lines += [
        "",
        "rules:",
        "  - MATCH,🚀 Proxy",
    ]

    return "\n".join(lines)


def make_singbox_config(user: User, nodes: list[Node]) -> dict:
    """sing-box JSON конфигурация."""
    outbounds = []
    for node in nodes:
        outbounds.append({
            "type":   "ghostnet",
            "tag":    f"{node.flag_emoji} {node.name}",
            "server": node.address,
            "port":   node.ghostnet_port,
            "uuid":   user.uuid,
            "domain": node.ghostnet_domain or node.address,
            "secret": node.ghostnet_secret,
        })

    outbound_tags = [o["tag"] for o in outbounds]
    outbounds.append({
        "type":      "selector",
        "tag":       "proxy",
        "outbounds": outbound_tags,
    })
    outbounds.append({"type": "direct", "tag": "direct"})

    return {
        "log": {"level": "info"},
        "inbounds": [
            {"type": "tun", "tag": "tun-in",
             "inet4_address": "172.19.0.1/30",
             "auto_route": True, "strict_route": True},
            {"type": "socks", "tag": "socks-in",
             "listen": "127.0.0.1", "listen_port": 1080},
        ],
        "outbounds": outbounds,
        "route": {
            "rules": [{"outbound": "direct", "geoip": ["private"]}],
            "final": "proxy",
        },
    }


# ─────────────────────────────────────────────
# ENDPOINTS
# ─────────────────────────────────────────────

async def _get_user_and_nodes(token: str, db: AsyncSession):
    """Общий хелпер: достаём пользователя и его активные ноды."""
    user = await db.scalar(
        select(User)
        .where(User.sub_token == token)
        .options(
            selectinload(User.nodes)
            .selectinload(UserNode.node)
        )
    )
    if not user:
        raise HTTPException(status_code=404, detail="Subscription not found")
    if not user.is_active:
        raise HTTPException(status_code=403, detail="Subscription expired or disabled")

    # Берём только онлайн-ноды разрешённые пользователю
    active_nodes = [
        un.node for un in user.nodes
        if un.is_enabled and un.node.is_enabled
    ]
    return user, active_nodes


@router_sub.get("/{token}")
async def subscription(
    token: str,
    db:    AsyncSession = DB,
    fmt:   str = Query("uri", description="uri | clash | singbox | json"),
):
    """
    Главный subscription endpoint.
    Клиент указывает формат через ?fmt=
    """
    user, nodes = await _get_user_and_nodes(token, db)

    if not nodes:
        raise HTTPException(status_code=503, detail="No nodes available")

    if fmt == "clash":
        content = make_clash_config(user, nodes)
        return Response(
            content=content,
            media_type="text/yaml",
            headers={
                "Content-Disposition": f'attachment; filename="ghostwave_{user.username}.yaml"',
                "Subscription-Userinfo": _sub_header(user),
            },
        )

    if fmt == "singbox":
        content = json.dumps(make_singbox_config(user, nodes), indent=2, ensure_ascii=False)
        return Response(
            content=content,
            media_type="application/json",
            headers={
                "Content-Disposition": f'attachment; filename="ghostwave_{user.username}.json"',
                "Subscription-Userinfo": _sub_header(user),
            },
        )

    if fmt == "json":
        configs = [make_ghostnet_config(user, n) for n in nodes]
        return {
            "user":    user.username,
            "status":  user.status,
            "configs": configs,
            "expires_at": user.expires_at.isoformat() if user.expires_at else None,
        }

    # По умолчанию — список URI закодированных в base64 (совместимо с v2rayN/NekoBox)
    uris = [make_ghostnet_uri(user, n) for n in nodes]
    content = base64.b64encode("\n".join(uris).encode()).decode()
    return Response(
        content=content,
        media_type="text/plain",
        headers={"Subscription-Userinfo": _sub_header(user)},
    )


@router_sub.get("/{token}/info")
async def subscription_info(token: str, db: AsyncSession = DB):
    """Публичная информация о подписке (без секретов)."""
    user, nodes = await _get_user_and_nodes(token, db)
    sub_url = f"{settings.SUB_BASE_URL}{settings.SUB_PATH}/{token}"
    return {
        "username":          user.username,
        "status":            user.status,
        "traffic_limit":     user.traffic_limit,
        "traffic_used":      user.traffic_used,
        "traffic_remaining": user.traffic_remaining,
        "expires_at":        user.expires_at.isoformat() if user.expires_at else None,
        "nodes_count":       len(nodes),
        "nodes":             [
            {"name": n.name, "country": n.country, "flag": n.flag_emoji}
            for n in nodes
        ],
        "sub_links": {
            "uri":     f"{sub_url}?fmt=uri",
            "clash":   f"{sub_url}?fmt=clash",
            "singbox": f"{sub_url}?fmt=singbox",
        },
    }


def _sub_header(user: User) -> str:
    """Заголовок Subscription-Userinfo (стандарт v2ray sub)."""
    parts = [
        f"upload={user.traffic_used_up}",
        f"download={user.traffic_used_down}",
        f"total={user.traffic_limit}",
    ]
    if user.expires_at:
        parts.append(f"expire={int(user.expires_at.timestamp())}")
    return "; ".join(parts)
