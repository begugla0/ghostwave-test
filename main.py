"""
GhostWave Panel — самодостаточный main.py
Всё в одном файле, никаких субмодулей.
"""
import os
import secrets
import asyncio
import logging
from datetime import datetime, timezone, timedelta
from contextlib import asynccontextmanager
from typing import Optional

import jwt
import bcrypt
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy import text

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s"
)
log = logging.getLogger("ghostwave.panel")

# ─── Config (из env) ──────────────────────────────────────────────────────────
DB_URL         = os.environ["DATABASE_URL"]
REDIS_URL      = os.environ.get("REDIS_URL", "")
JWT_SECRET     = os.environ.get("JWT_SECRET", secrets.token_hex(32))
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "changeme")
NODE_API_KEY   = os.environ.get("NODE_API_KEY", "")
SUB_BASE_URL   = os.environ.get("SUB_BASE_URL", "https://example.com")
TG_TOKEN       = os.environ.get("TELEGRAM_BOT_TOKEN", "")
VERSION        = "1.0.0"

# ─── Database ─────────────────────────────────────────────────────────────────
engine       = create_async_engine(DB_URL, pool_pre_ping=True, echo=False)
AsyncSession_ = async_sessionmaker(engine, expire_on_commit=False)
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")

SCHEMA_SQL = """
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS admins (
    id               SERIAL PRIMARY KEY,
    username         VARCHAR(64)  UNIQUE NOT NULL,
    hashed_password  VARCHAR(256) NOT NULL,
    telegram_id      BIGINT       UNIQUE,
    created_at       TIMESTAMPTZ  DEFAULT NOW(),
    last_login       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS nodes (
    id               SERIAL PRIMARY KEY,
    name             VARCHAR(128) NOT NULL,
    address          VARCHAR(256) NOT NULL,
    port             INTEGER      DEFAULT 2095,
    api_key          VARCHAR(128),
    country          VARCHAR(64)  DEFAULT '',
    city             VARCHAR(64)  DEFAULT '',
    flag_emoji       VARCHAR(8)   DEFAULT '🌐',
    is_enabled       BOOLEAN      DEFAULT TRUE,
    status           VARCHAR(32)  DEFAULT 'offline',
    load_avg         FLOAT        DEFAULT 0,
    memory_usage     FLOAT        DEFAULT 0,
    online_users     INTEGER      DEFAULT 0,
    last_seen        TIMESTAMPTZ,
    ghostnet_port    INTEGER      DEFAULT 443,
    ghostnet_domain  VARCHAR(256) DEFAULT '',
    ghostnet_secret  VARCHAR(256) DEFAULT '',
    created_at       TIMESTAMPTZ  DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
    id                SERIAL PRIMARY KEY,
    uuid              VARCHAR(36)  UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
    username          VARCHAR(128) UNIQUE NOT NULL,
    status            VARCHAR(32)  DEFAULT 'active',
    traffic_limit     BIGINT       DEFAULT 0,
    traffic_used_up   BIGINT       DEFAULT 0,
    traffic_used_down BIGINT       DEFAULT 0,
    expires_at        TIMESTAMPTZ,
    sub_token         VARCHAR(64)  UNIQUE NOT NULL,
    telegram_id       BIGINT       UNIQUE,
    telegram_username VARCHAR(128),
    note              TEXT         DEFAULT '',
    created_at        TIMESTAMPTZ  DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  DEFAULT NOW(),
    last_online       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS user_nodes (
    id            SERIAL  PRIMARY KEY,
    user_id       INTEGER REFERENCES users(id) ON DELETE CASCADE,
    node_id       INTEGER REFERENCES nodes(id) ON DELETE CASCADE,
    is_enabled    BOOLEAN DEFAULT TRUE,
    traffic_up    BIGINT  DEFAULT 0,
    traffic_down  BIGINT  DEFAULT 0,
    last_connected TIMESTAMPTZ,
    UNIQUE(user_id, node_id)
);

CREATE TABLE IF NOT EXISTS traffic_logs (
    id           SERIAL  PRIMARY KEY,
    user_id      INTEGER REFERENCES users(id) ON DELETE CASCADE,
    node_id      INTEGER,
    traffic_up   BIGINT  DEFAULT 0,
    traffic_down BIGINT  DEFAULT 0,
    recorded_at  TIMESTAMPTZ DEFAULT NOW()
);
"""

async def get_db():
    async with AsyncSession_() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise

# ─── Auth helpers ─────────────────────────────────────────────────────────────
def make_jwt(admin_id: int) -> str:
    return jwt.encode(
        {"sub": str(admin_id),
         "exp": datetime.now(timezone.utc) + timedelta(hours=24)},
        JWT_SECRET, algorithm="HS256"
    )

async def get_current_admin(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db)
):
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        admin_id = int(payload["sub"])
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
    row = (await db.execute(
        text("SELECT id, username FROM admins WHERE id = :id"), {"id": admin_id}
    )).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Admin not found")
    return {"id": row[0], "username": row[1]}

# ─── Lifespan ─────────────────────────────────────────────────────────────────
async def _scheduler():
    """Периодически помечает expired пользователей и offline ноды."""
    while True:
        await asyncio.sleep(30)
        try:
            async with AsyncSession_() as db:
                await db.execute(text("""
                    UPDATE users SET status='expired'
                    WHERE expires_at < NOW() AND status = 'active'
                """))
                await db.execute(text("""
                    UPDATE nodes SET status='offline'
                    WHERE last_seen < NOW() - INTERVAL '60 seconds'
                      AND status = 'online'
                """))
                await db.commit()
        except Exception as e:
            log.error(f"Scheduler error: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"GhostWave Panel v{VERSION} starting…")

    # Инициализируем схему БД
    async with engine.begin() as conn:
        await conn.execute(text(SCHEMA_SQL))
    log.info("Database schema ready")

    # Создаём admin если нет
    async with AsyncSession_() as db:
        row = (await db.execute(
            text("SELECT id FROM admins WHERE username = :u"), {"u": ADMIN_USERNAME}
        )).fetchone()
        if not row:
            hp = bcrypt.hashpw(ADMIN_PASSWORD.encode(), bcrypt.gensalt()).decode()
            await db.execute(text(
                "INSERT INTO admins(username, hashed_password) VALUES(:u, :p)"
            ), {"u": ADMIN_USERNAME, "p": hp})
            await db.commit()
            log.info(f"Admin '{ADMIN_USERNAME}' created")

    scheduler_task = asyncio.create_task(_scheduler())

    # Telegram bot (если токен задан)
    bot_task = None
    if TG_TOKEN:
        try:
            from telegram_bot import start_bot
            bot_task = asyncio.create_task(start_bot())
            log.info("Telegram bot started")
        except ImportError:
            log.warning("telegram_bot.py not found, bot disabled")

    log.info("Panel ready.")
    yield

    scheduler_task.cancel()
    if bot_task:
        bot_task.cancel()
    log.info("Panel shutdown.")

# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="GhostWave Panel",
    version=VERSION,
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Healthcheck ──────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "version": VERSION}

# ─── Auth ─────────────────────────────────────────────────────────────────────
@app.post("/api/auth/login")
async def login(
    form: OAuth2PasswordRequestForm = Depends(),
    db: AsyncSession = Depends(get_db)
):
    row = (await db.execute(
        text("SELECT id, hashed_password FROM admins WHERE username = :u"),
        {"u": form.username}
    )).fetchone()
    if not row or not bcrypt.checkpw(form.password.encode(), row[1].encode()):
        raise HTTPException(status_code=401, detail="Wrong credentials")
    await db.execute(
        text("UPDATE admins SET last_login = NOW() WHERE id = :id"), {"id": row[0]}
    )
    return {"access_token": make_jwt(row[0]), "token_type": "bearer"}

@app.get("/api/auth/me")
async def me(admin=Depends(get_current_admin)):
    return admin

# ─── Nodes ────────────────────────────────────────────────────────────────────
class NodeCreate(BaseModel):
    name:            str
    address:         str
    port:            int = 2095
    country:         str = ""
    city:            str = ""
    flag_emoji:      str = "🌐"
    ghostnet_port:   int = 443
    ghostnet_domain: str = ""
    ghostnet_secret: str = ""

class NodeUpdate(BaseModel):
    name:            Optional[str]  = None
    address:         Optional[str]  = None
    port:            Optional[int]  = None
    country:         Optional[str]  = None
    city:            Optional[str]  = None
    flag_emoji:      Optional[str]  = None
    is_enabled:      Optional[bool] = None
    ghostnet_port:   Optional[int]  = None
    ghostnet_domain: Optional[str]  = None
    ghostnet_secret: Optional[str]  = None

@app.get("/api/nodes")
async def list_nodes(db: AsyncSession = Depends(get_db), _=Depends(get_current_admin)):
    rows = (await db.execute(text(
        "SELECT * FROM nodes ORDER BY name"
    ))).mappings().all()
    return [dict(r) for r in rows]

@app.post("/api/nodes", status_code=201)
async def create_node(
    data: NodeCreate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    api_key = secrets.token_hex(32)
    gn_secret = data.ghostnet_secret or secrets.token_hex(32)
    row = (await db.execute(text("""
        INSERT INTO nodes
          (name, address, port, api_key, country, city, flag_emoji,
           ghostnet_port, ghostnet_domain, ghostnet_secret)
        VALUES
          (:name, :address, :port, :api_key, :country, :city, :flag_emoji,
           :ghostnet_port, :ghostnet_domain, :ghostnet_secret)
        RETURNING id, name, address, status, api_key, ghostnet_secret
    """), {
        "name": data.name, "address": data.address, "port": data.port,
        "api_key": api_key, "country": data.country, "city": data.city,
        "flag_emoji": data.flag_emoji, "ghostnet_port": data.ghostnet_port,
        "ghostnet_domain": data.ghostnet_domain, "ghostnet_secret": gn_secret,
    })).mappings().fetchone()
    return dict(row)

@app.get("/api/nodes/{node_id}")
async def get_node(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    row = (await db.execute(
        text("SELECT * FROM nodes WHERE id = :id"), {"id": node_id}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Node not found")
    return dict(row)

@app.patch("/api/nodes/{node_id}")
async def update_node(
    node_id: int,
    data: NodeUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    fields = {k: v for k, v in data.model_dump().items() if v is not None}
    if not fields:
        raise HTTPException(400, "Nothing to update")
    sets = ", ".join(f"{k} = :{k}" for k in fields)
    fields["id"] = node_id
    row = (await db.execute(
        text(f"UPDATE nodes SET {sets} WHERE id = :id RETURNING *"), fields
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Node not found")
    return dict(row)

@app.delete("/api/nodes/{node_id}", status_code=204)
async def delete_node(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("DELETE FROM nodes WHERE id = :id"), {"id": node_id})

@app.get("/api/nodes/{node_id}/users")
async def node_users(
    node_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    rows = (await db.execute(text("""
        SELECT u.uuid FROM users u
        JOIN user_nodes un ON un.user_id = u.id
        WHERE un.node_id = :nid AND un.is_enabled = TRUE AND u.status = 'active'
    """), {"nid": node_id})).fetchall()
    uuids = [r[0] for r in rows]
    return {"node_id": node_id, "allowed_users": uuids, "count": len(uuids)}

# ─── Users ────────────────────────────────────────────────────────────────────
class UserCreate(BaseModel):
    username:      str
    traffic_limit: int = 0
    expires_at:    Optional[str] = None
    note:          str = ""
    node_ids:      list[int] = []
    telegram_id:   Optional[int] = None

class UserUpdate(BaseModel):
    status:        Optional[str] = None
    traffic_limit: Optional[int] = None
    expires_at:    Optional[str] = None
    note:          Optional[str] = None
    node_ids:      Optional[list[int]] = None

@app.get("/api/users")
async def list_users(
    offset: int = 0,
    limit:  int = 50,
    status: Optional[str] = None,
    search: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    where = "WHERE 1=1"
    params: dict = {}
    if status:
        where += " AND status = :status"
        params["status"] = status
    if search:
        where += " AND username ILIKE :search"
        params["search"] = f"%{search}%"
    total = (await db.execute(text(f"SELECT COUNT(*) FROM users {where}"), params)).scalar()
    params["limit"] = limit
    params["offset"] = offset
    rows = (await db.execute(
        text(f"SELECT * FROM users {where} ORDER BY created_at DESC LIMIT :limit OFFSET :offset"),
        params
    )).mappings().all()
    return {"total": total, "users": [dict(r) for r in rows]}

@app.post("/api/users", status_code=201)
async def create_user(
    data: UserCreate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    existing = (await db.execute(
        text("SELECT id FROM users WHERE username = :u"), {"u": data.username}
    )).fetchone()
    if existing:
        raise HTTPException(400, f"User '{data.username}' already exists")

    sub_token = secrets.token_urlsafe(32)
    row = (await db.execute(text("""
        INSERT INTO users(username, traffic_limit, expires_at, note, telegram_id, sub_token)
        VALUES(:username, :traffic_limit, :expires_at, :note, :telegram_id, :sub_token)
        RETURNING *
    """), {
        "username": data.username, "traffic_limit": data.traffic_limit,
        "expires_at": data.expires_at, "note": data.note,
        "telegram_id": data.telegram_id, "sub_token": sub_token,
    })).mappings().fetchone()
    user_id = row["id"]

    # Привязываем к нодам
    if data.node_ids:
        for nid in data.node_ids:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": nid})
    else:
        # Все активные ноды
        nodes = (await db.execute(
            text("SELECT id FROM nodes WHERE is_enabled = TRUE")
        )).fetchall()
        for n in nodes:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": n[0]})

    return dict(row)

@app.get("/api/users/{user_id}")
async def get_user(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    row = (await db.execute(
        text("SELECT * FROM users WHERE id = :id"), {"id": user_id}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "User not found")
    return dict(row)

@app.patch("/api/users/{user_id}")
async def update_user(
    user_id: int,
    data: UserUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    fields = {k: v for k, v in data.model_dump().items()
              if v is not None and k != "node_ids"}
    if fields:
        fields["updated_at"] = datetime.now(timezone.utc).isoformat()
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        fields["id"] = user_id
        await db.execute(text(f"UPDATE users SET {sets} WHERE id = :id"), fields)
    if data.node_ids is not None:
        await db.execute(
            text("DELETE FROM user_nodes WHERE user_id = :id"), {"id": user_id}
        )
        for nid in data.node_ids:
            await db.execute(text(
                "INSERT INTO user_nodes(user_id, node_id) VALUES(:u, :n) ON CONFLICT DO NOTHING"
            ), {"u": user_id, "n": nid})
    row = (await db.execute(
        text("SELECT * FROM users WHERE id = :id"), {"id": user_id}
    )).mappings().fetchone()
    return dict(row)

@app.delete("/api/users/{user_id}", status_code=204)
async def delete_user(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("DELETE FROM users WHERE id = :id"), {"id": user_id})

@app.post("/api/users/{user_id}/reset-traffic")
async def reset_traffic(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    await db.execute(text("""
        UPDATE users
        SET traffic_used_up = 0, traffic_used_down = 0, updated_at = NOW()
        WHERE id = :id
    """), {"id": user_id})
    return {"ok": True, "user_id": user_id}

@app.post("/api/users/{user_id}/revoke-sub")
async def revoke_sub(
    user_id: int,
    db: AsyncSession = Depends(get_db),
    _=Depends(get_current_admin)
):
    new_token = secrets.token_urlsafe(32)
    await db.execute(text(
        "UPDATE users SET sub_token = :t WHERE id = :id"
    ), {"t": new_token, "id": user_id})
    return {"ok": True, "sub_token": new_token}

# ─── Stats ────────────────────────────────────────────────────────────────────
@app.get("/api/stats")
async def stats(db: AsyncSession = Depends(get_db), _=Depends(get_current_admin)):
    r = lambda q: db.execute(text(q))
    total_users   = (await r("SELECT COUNT(*) FROM users")).scalar()
    active_users  = (await r("SELECT COUNT(*) FROM users WHERE status='active'")).scalar()
    expired_users = (await r("SELECT COUNT(*) FROM users WHERE status='expired'")).scalar()
    limited_users = (await r("SELECT COUNT(*) FROM users WHERE status='limited'")).scalar()
    total_nodes   = (await r("SELECT COUNT(*) FROM nodes")).scalar()
    online_nodes  = (await r("SELECT COUNT(*) FROM nodes WHERE status='online'")).scalar()
    total_traffic = (await r(
        "SELECT COALESCE(SUM(traffic_used_up + traffic_used_down), 0) FROM users"
    )).scalar()
    return {
        "total_users": total_users, "active_users": active_users,
        "expired_users": expired_users, "limited_users": limited_users,
        "total_nodes": total_nodes, "online_nodes": online_nodes,
        "total_traffic": total_traffic,
    }

# ─── Subscription ─────────────────────────────────────────────────────────────
@app.get("/sub/{token}/info")
async def sub_info(token: str, db: AsyncSession = Depends(get_db)):
    row = (await db.execute(
        text("SELECT * FROM users WHERE sub_token = :t"), {"t": token}
    )).mappings().fetchone()
    if not row:
        raise HTTPException(404, "Not found")
    sub_url = f"{SUB_BASE_URL}/sub/{token}"
    return {
        "username":          row["username"],
        "status":            row["status"],
        "traffic_limit":     row["traffic_limit"],
        "traffic_used":      row["traffic_used_up"] + row["traffic_used_down"],
        "traffic_remaining": max(0, row["traffic_limit"] - row["traffic_used_up"] - row["traffic_used_down"])
                             if row["traffic_limit"] > 0 else -1,
        "expires_at":        str(row["expires_at"]) if row["expires_at"] else None,
        "sub_links": {
            "json": f"{sub_url}?fmt=json",
            "uri":  f"{sub_url}?fmt=uri",
        },
    }

@app.get("/sub/{token}")
async def subscription(
    token: str,
    fmt:   str = "json",
    db: AsyncSession = Depends(get_db)
):
    user = (await db.execute(
        text("SELECT * FROM users WHERE sub_token = :t"), {"t": token}
    )).mappings().fetchone()
    if not user:
        raise HTTPException(404, "Not found")
    if user["status"] != "active":
        raise HTTPException(403, "Subscription expired or disabled")

    nodes = (await db.execute(text("""
        SELECT n.address, n.ghostnet_port, n.ghostnet_domain,
               n.ghostnet_secret, n.name, n.flag_emoji
        FROM nodes n
        JOIN user_nodes un ON un.node_id = n.id
        WHERE un.user_id = :uid AND un.is_enabled = TRUE AND n.is_enabled = TRUE
    """), {"uid": user["id"]})).mappings().all()

    configs = [{
        "protocol":      "ghostnet",
        "server_host":   n["address"],
        "server_port":   n["ghostnet_port"],
        "domain":        n["ghostnet_domain"],
        "shared_secret": n["ghostnet_secret"],
        "user_uuid":     user["uuid"],
        "remarks":       f"{n['flag_emoji']} {n['name']}",
    } for n in nodes]

    if fmt == "uri":
        import base64, json
        uris = [
            "ghostnet://" + base64.urlsafe_b64encode(
                json.dumps(c, separators=(",", ":")).encode()
            ).decode() + f"#{c['remarks']}"
            for c in configs
        ]
        import base64 as b64
        return __import__("fastapi").Response(
            content=b64.b64encode("\n".join(uris).encode()).decode(),
            media_type="text/plain"
        )

    return {"user": user["username"], "status": user["status"], "configs": configs}

# ─── Node Agent API ───────────────────────────────────────────────────────────
@app.post("/api/node/heartbeat")
async def node_heartbeat(data: dict, db: AsyncSession = Depends(get_db)):
    nid = data.get("node_id")
    if not nid:
        raise HTTPException(400, "node_id required")
    await db.execute(text("""
        UPDATE nodes
        SET status = 'online',
            load_avg     = :la,
            memory_usage = :mu,
            online_users = :ou,
            last_seen    = NOW()
        WHERE id = :id
    """), {
        "la": data.get("load_avg", 0),
        "mu": data.get("memory_usage", 0),
        "ou": data.get("online_users", 0),
        "id": nid,
    })
    rows = (await db.execute(text("""
        SELECT u.uuid FROM users u
        JOIN user_nodes un ON un.user_id = u.id
        WHERE un.node_id = :nid AND un.is_enabled = TRUE AND u.status = 'active'
    """), {"nid": nid})).fetchall()
    return {"ok": True, "active_users": [r[0] for r in rows]}

@app.post("/api/node/traffic")
async def node_traffic(data: dict, db: AsyncSession = Depends(get_db)):
    for entry in data.get("traffic", []):
        await db.execute(text("""
            UPDATE users
            SET traffic_used_up   = traffic_used_up   + :up,
                traffic_used_down = traffic_used_down + :dn,
                last_online       = NOW()
            WHERE uuid = :uuid
        """), {
            "up":   entry.get("up_bytes", 0),
            "dn":   entry.get("down_bytes", 0),
            "uuid": entry.get("user_uuid", ""),
        })
        # Обновляем трафик на конкретной ноде
        await db.execute(text("""
            UPDATE user_nodes un
            SET traffic_up   = traffic_up   + :up,
                traffic_down = traffic_down + :dn,
                last_connected = NOW()
            FROM users u
            WHERE un.user_id = u.id
              AND u.uuid = :uuid
              AND un.node_id = :nid
        """), {
            "up":   entry.get("up_bytes", 0),
            "dn":   entry.get("down_bytes", 0),
            "uuid": entry.get("user_uuid", ""),
            "nid":  data.get("node_id", 0),
        })
    return {"ok": True, "processed": len(data.get("traffic", []))}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=3000)
