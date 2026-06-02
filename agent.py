"""
GhostWave Node Agent
Запускается на каждом VPN-сервере.
Задачи:
  1. Запускает/перезапускает GhostNet daemon
  2. Heartbeat → Panel каждые 15с (отправляет статистику, получает список разрешённых UUID)
  3. Принимает конфиг от Panel и применяет его
  4. Считает трафик и репортует в Panel
"""
import asyncio
import json
import logging
import os
import psutil
import secrets
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Header, Depends
from pydantic import BaseModel
from pydantic_settings import BaseSettings

log = logging.getLogger("ghostwave.node")


# ─────────────────────────────────────────────
# КОНФИГУРАЦИЯ АГЕНТА
# ─────────────────────────────────────────────

class NodeSettings(BaseSettings):
    NODE_ID:      int    = 1
    NODE_API_KEY: str    = ""          # shared secret с Panel
    PANEL_URL:    str    = "https://panel.example.com"
    AGENT_PORT:   int    = 2095        # порт агента (слушает запросы от Panel)
    AGENT_HOST:   str    = "0.0.0.0"

    # GhostNet daemon
    GHOSTNET_BIN:    str = "/usr/local/bin/ghostnet-server"
    GHOSTNET_PORT:   int = 443
    GHOSTNET_DOMAIN: str = ""
    GHOSTNET_SECRET: str = ""

    # Интервалы
    HEARTBEAT_INTERVAL:     int = 15   # секунд
    TRAFFIC_REPORT_INTERVAL: int = 60  # секунд

    class Config:
        env_file = ".env.node"


node_settings = NodeSettings()


# ─────────────────────────────────────────────
# СОСТОЯНИЕ АГЕНТА
# ─────────────────────────────────────────────

class AgentState:
    def __init__(self):
        self.allowed_uuids:     set[str]  = set()
        self.active_sessions:   dict[str, float] = {}   # uuid → last_seen
        self.traffic_delta:     dict[str, dict]  = {}   # uuid → {up, down}
        self.ghostnet_proc:     Optional[asyncio.subprocess.Process] = None
        self.ghostnet_config:   dict      = {}
        self.started_at:        float     = time.time()

    def record_traffic(self, user_uuid: str, up: int, down: int):
        if user_uuid not in self.traffic_delta:
            self.traffic_delta[user_uuid] = {"up": 0, "down": 0}
        self.traffic_delta[user_uuid]["up"]   += up
        self.traffic_delta[user_uuid]["down"] += down
        self.active_sessions[user_uuid] = time.time()

    def flush_traffic(self) -> list[dict]:
        """Возвращает накопленный трафик и сбрасывает счётчики."""
        result = [
            {"user_uuid": uuid, "up_bytes": v["up"], "down_bytes": v["down"]}
            for uuid, v in self.traffic_delta.items()
            if v["up"] + v["down"] > 0
        ]
        self.traffic_delta.clear()
        return result

    @property
    def online_users(self) -> int:
        now = time.time()
        return sum(1 for t in self.active_sessions.values() if now - t < 120)

    def get_system_stats(self) -> dict:
        cpu   = psutil.cpu_percent(interval=0.1)
        mem   = psutil.virtual_memory()
        return {
            "load_avg":     cpu,
            "memory_usage": mem.percent,
            "online_users": self.online_users,
        }


state = AgentState()


# ─────────────────────────────────────────────
# GHOSTNET DAEMON УПРАВЛЕНИЕ
# ─────────────────────────────────────────────

async def write_ghostnet_config(cfg: dict):
    """Записывает конфиг GhostNet daemon в файл."""
    config_path = "/etc/ghostnet/config.json"
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as f:
        json.dump({
            "secret":       cfg.get("ghostnet_secret", node_settings.GHOSTNET_SECRET),
            "domain":       cfg.get("ghostnet_domain", node_settings.GHOSTNET_DOMAIN),
            "port":         cfg.get("ghostnet_port",   node_settings.GHOSTNET_PORT),
            "allowed_users": cfg.get("allowed_users", []),
            "tun_network":  "10.8.0.0/24",
            "log_level":    "info",
        }, f, indent=2)
    log.info(f"GhostNet config written: {len(cfg.get('allowed_users', []))} users")


async def start_ghostnet():
    """Запускает GhostNet daemon."""
    if state.ghostnet_proc and state.ghostnet_proc.returncode is None:
        return  # уже запущен

    bin_path = node_settings.GHOSTNET_BIN
    if not os.path.exists(bin_path):
        log.warning(f"GhostNet binary not found: {bin_path} (demo mode)")
        return

    state.ghostnet_proc = await asyncio.create_subprocess_exec(
        bin_path, "--config", "/etc/ghostnet/config.json",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    log.info(f"GhostNet daemon started (pid={state.ghostnet_proc.pid})")


async def reload_ghostnet(new_config: dict):
    """Применяет новый конфиг — пишет файл и перезапускает daemon."""
    await write_ghostnet_config(new_config)
    state.ghostnet_config = new_config

    if state.ghostnet_proc and state.ghostnet_proc.returncode is None:
        state.ghostnet_proc.terminate()
        try:
            await asyncio.wait_for(state.ghostnet_proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            state.ghostnet_proc.kill()

    await start_ghostnet()


# ─────────────────────────────────────────────
# ВЗАИМОДЕЙСТВИЕ С PANEL
# ─────────────────────────────────────────────

async def panel_heartbeat():
    """
    Отправляем heartbeat в Panel.
    Panel отвечает актуальным списком разрешённых UUID.
    """
    stats = state.get_system_stats()
    payload = {
        "node_id":        node_settings.NODE_ID,
        "status":         "online",
        "load_avg":       stats["load_avg"],
        "memory_usage":   stats["memory_usage"],
        "online_users":   stats["online_users"],
        "active_sessions": list(state.active_sessions.keys()),
    }

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{node_settings.PANEL_URL}/api/node/heartbeat",
                json=payload,
                headers={"X-Node-Key": node_settings.NODE_API_KEY},
            )
        if resp.status_code == 200:
            data = resp.json()
            new_uuids = set(data.get("active_users", []))
            if new_uuids != state.allowed_uuids:
                log.info(f"Allowed UUIDs updated: {len(new_uuids)} users")
                state.allowed_uuids = new_uuids
                # Обновляем конфиг GhostNet с новым списком пользователей
                config = dict(state.ghostnet_config)
                config["allowed_users"] = list(new_uuids)
                await reload_ghostnet(config)
        else:
            log.warning(f"Heartbeat failed: {resp.status_code}")
    except Exception as e:
        log.error(f"Heartbeat error: {e}")


async def panel_traffic_report():
    """Отправляем накопленный трафик в Panel."""
    traffic = state.flush_traffic()
    if not traffic:
        return

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{node_settings.PANEL_URL}/api/node/traffic",
                json={"node_id": node_settings.NODE_ID, "traffic": traffic},
                headers={"X-Node-Key": node_settings.NODE_API_KEY},
            )
        if resp.status_code == 200:
            log.debug(f"Traffic report: {len(traffic)} users")
        else:
            log.warning(f"Traffic report failed: {resp.status_code}")
    except Exception as e:
        log.error(f"Traffic report error: {e}")


# ─────────────────────────────────────────────
# ФОНОВЫЕ ПЕТЛИ
# ─────────────────────────────────────────────

async def heartbeat_loop():
    while True:
        await asyncio.sleep(node_settings.HEARTBEAT_INTERVAL)
        await panel_heartbeat()


async def traffic_loop():
    while True:
        await asyncio.sleep(node_settings.TRAFFIC_REPORT_INTERVAL)
        await panel_traffic_report()


async def watchdog_loop():
    """Перезапускает GhostNet daemon если он упал."""
    while True:
        await asyncio.sleep(10)
        if state.ghostnet_proc:
            if state.ghostnet_proc.returncode is not None:
                log.warning("GhostNet daemon exited unexpectedly, restarting…")
                await start_ghostnet()


# ─────────────────────────────────────────────
# AGENT HTTP API (Panel → Node)
# ─────────────────────────────────────────────

def verify_panel_key(x_node_key: str = Header(...)):
    if x_node_key != node_settings.NODE_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid key")


class ConfigPushRequest(BaseModel):
    ghostnet_secret: str
    ghostnet_domain: str
    ghostnet_port:   int
    allowed_users:   list[str]  # список UUID


class TrafficEntry(BaseModel):
    user_uuid:  str
    up_bytes:   int
    down_bytes: int


@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s")
    log.info(f"GhostWave Node Agent starting (node_id={node_settings.NODE_ID})")

    # Первоначальная конфигурация из env
    await write_ghostnet_config({
        "ghostnet_secret": node_settings.GHOSTNET_SECRET,
        "ghostnet_domain": node_settings.GHOSTNET_DOMAIN,
        "ghostnet_port":   node_settings.GHOSTNET_PORT,
        "allowed_users":   [],
    })
    await start_ghostnet()

    # Фоновые задачи
    tasks = [
        asyncio.create_task(heartbeat_loop()),
        asyncio.create_task(traffic_loop()),
        asyncio.create_task(watchdog_loop()),
    ]

    # Первый heartbeat сразу
    await panel_heartbeat()

    log.info("Node Agent ready.")
    yield

    for t in tasks:
        t.cancel()
    if state.ghostnet_proc:
        state.ghostnet_proc.terminate()
    log.info("Node Agent shutdown.")


agent_app = FastAPI(title="GhostWave Node Agent", lifespan=lifespan)


@agent_app.get("/health")
async def health():
    stats = state.get_system_stats()
    return {
        "status":         "ok",
        "node_id":        node_settings.NODE_ID,
        "online_users":   stats["online_users"],
        "load_avg":       stats["load_avg"],
        "memory_usage":   stats["memory_usage"],
        "ghostnet_running": (
            state.ghostnet_proc is not None
            and state.ghostnet_proc.returncode is None
        ),
    }


@agent_app.post("/config", dependencies=[Depends(verify_panel_key)])
async def push_config(req: ConfigPushRequest):
    """Panel → Node: обновить конфигурацию GhostNet."""
    await reload_ghostnet(req.model_dump())
    return {"ok": True, "users_count": len(req.allowed_users)}


@agent_app.post("/traffic/ingest", dependencies=[Depends(verify_panel_key)])
async def ingest_traffic(entries: list[TrafficEntry]):
    """
    Внешний источник (GhostNet daemon) сообщает трафик.
    В production GhostNet daemon вызывает этот endpoint напрямую.
    """
    for e in entries:
        if e.user_uuid in state.allowed_uuids:
            state.record_traffic(e.user_uuid, e.up_bytes, e.down_bytes)
    return {"ok": True}


@agent_app.get("/status", dependencies=[Depends(verify_panel_key)])
async def get_status():
    return {
        "node_id":        node_settings.NODE_ID,
        "allowed_users":  len(state.allowed_uuids),
        "online_users":   state.online_users,
        "uptime_seconds": int(time.time() - state.started_at),
        **state.get_system_stats(),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        agent_app,
        host=node_settings.AGENT_HOST,
        port=node_settings.AGENT_PORT,
    )
