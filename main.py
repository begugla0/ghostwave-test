"""
GhostWave Panel — главное приложение FastAPI
"""
import asyncio
import logging
from contextlib import asynccontextmanager

import bcrypt
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from panel.api.core.config import get_settings
from panel.api.core.database import init_db, AsyncSessionLocal
from panel.api.models import Admin
from panel.api.routers import (
    router_auth, router_users, router_nodes,
    router_stats, router_node_agent,
)
from panel.api.routers.subscription import router_sub

log      = logging.getLogger("ghostwave.panel")
settings = get_settings()


# ─────────────────────────────────────────────
# ФОНОВЫЕ ЗАДАЧИ
# ─────────────────────────────────────────────

async def _scheduler():
    """Периодические задачи: sync статусов, mark offline нод."""
    from panel.api.services.services import UserService, NodeService
    while True:
        await asyncio.sleep(30)
        try:
            async with AsyncSessionLocal() as db:
                expired = await UserService.sync_status(db)
                await NodeService.mark_offline(db)
                await db.commit()
                if expired:
                    log.info(f"Помечено expired: {expired} пользователей")
        except Exception as e:
            log.error(f"Scheduler error: {e}")


async def _ensure_admin():
    """Создаём admin-аккаунт при первом запуске."""
    async with AsyncSessionLocal() as db:
        existing = await db.scalar(select(Admin).where(Admin.username == settings.ADMIN_USERNAME))
        if not existing:
            hashed = bcrypt.hashpw(
                settings.ADMIN_PASSWORD.encode(), bcrypt.gensalt()
            ).decode()
            db.add(Admin(username=settings.ADMIN_USERNAME, hashed_password=hashed))
            await db.commit()
            log.info(f"Admin '{settings.ADMIN_USERNAME}' создан")


# ─────────────────────────────────────────────
# LIFESPAN
# ─────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.basicConfig(
        level=logging.DEBUG if settings.DEBUG else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )
    log.info(f"GhostWave Panel v{settings.VERSION} starting…")

    await init_db()
    await _ensure_admin()

    scheduler_task = asyncio.create_task(_scheduler())

    # Telegram bot (если токен задан)
    bot_task = None
    if settings.TELEGRAM_BOT_TOKEN:
        from panel.api.services.telegram_bot import start_bot
        bot_task = asyncio.create_task(start_bot())

    log.info("Panel ready.")
    yield

    scheduler_task.cancel()
    if bot_task:
        bot_task.cancel()
    log.info("Panel shutdown.")


# ─────────────────────────────────────────────
# APP
# ─────────────────────────────────────────────

def create_app() -> FastAPI:
    app = FastAPI(
        title="GhostWave Panel",
        version=settings.VERSION,
        docs_url="/api/docs",
        redoc_url="/api/redoc",
        openapi_url="/api/openapi.json",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # API роутеры
    for r in (router_auth, router_users, router_nodes,
              router_stats, router_node_agent, router_sub):
        app.include_router(r)

    @app.get("/health")
    async def health():
        return {"status": "ok", "version": settings.VERSION}

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=3000, reload=settings.DEBUG)
