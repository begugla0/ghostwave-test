"""
GhostWave Telegram Bot (aiogram 3.x)
Функции:
  - Выдача subscription URL пользователю
  - Просмотр баланса трафика
  - Для администраторов: создание/управление пользователями
"""
from __future__ import annotations
import asyncio
import logging
from datetime import datetime, timezone, timedelta

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
)
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.redis import RedisStorage
from sqlalchemy.ext.asyncio import AsyncSession

from panel.api.core.config import get_settings
from panel.api.core.database import AsyncSessionLocal
from panel.api.models import User, UserStatus
from panel.api.schemas import UserCreate
from panel.api.services.services import UserService, NodeService

log      = logging.getLogger("ghostwave.bot")
settings = get_settings()


# ─────────────────────────────────────────────
# FSM СОСТОЯНИЯ
# ─────────────────────────────────────────────

class AdminCreateUser(StatesGroup):
    waiting_username      = State()
    waiting_traffic_limit = State()
    waiting_expires_days  = State()


# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────

def is_admin(user_id: int) -> bool:
    return user_id in settings.TELEGRAM_ADMIN_IDS


def fmt_bytes(b: int) -> str:
    if b < 0:
        return "∞ (безлимит)"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def sub_url(user: User) -> str:
    return f"{settings.SUB_BASE_URL}{settings.SUB_PATH}/{user.sub_token}"


async def get_db() -> AsyncSession:
    async with AsyncSessionLocal() as session:
        yield session


# ─────────────────────────────────────────────
# КЛАВИАТУРЫ
# ─────────────────────────────────────────────

def kb_main_user() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📊 Мой статус",        callback_data="my_status")],
        [InlineKeyboardButton(text="🔗 Subscription URL",  callback_data="my_sub")],
        [InlineKeyboardButton(text="📱 Форматы конфигов",  callback_data="my_formats")],
        [InlineKeyboardButton(text="❓ Помощь",            callback_data="help")],
    ])


def kb_main_admin() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="👤 Создать пользователя", callback_data="admin_create_user")],
        [InlineKeyboardButton(text="📋 Список пользователей", callback_data="admin_list_users")],
        [InlineKeyboardButton(text="🖥️ Статус нод",           callback_data="admin_nodes")],
        [InlineKeyboardButton(text="📈 Статистика",           callback_data="admin_stats")],
        [InlineKeyboardButton(text="━━━━ Мой аккаунт ━━━━",  callback_data="noop")],
        [InlineKeyboardButton(text="📊 Мой статус",           callback_data="my_status")],
        [InlineKeyboardButton(text="🔗 Subscription URL",     callback_data="my_sub")],
    ])


def kb_sub_formats(token: str) -> InlineKeyboardMarkup:
    base = f"{settings.SUB_BASE_URL}{settings.SUB_PATH}/{token}"
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📄 URI (v2rayN/NekoBox)",   url=f"{base}?fmt=uri")],
        [InlineKeyboardButton(text="⚡ Clash/Mihomo YAML",      url=f"{base}?fmt=clash")],
        [InlineKeyboardButton(text="🎵 sing-box JSON",           url=f"{base}?fmt=singbox")],
        [InlineKeyboardButton(text="⬅️ Назад",                  callback_data="back_main")],
    ])


def kb_back() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_main")]
    ])


def kb_confirm_create(username: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="✅ Создать",  callback_data=f"confirm_create:{username}"),
            InlineKeyboardButton(text="❌ Отмена",   callback_data="cancel_create"),
        ]
    ])


# ─────────────────────────────────────────────
# РОУТЕР
# ─────────────────────────────────────────────

router = Router()


async def _user_card(user: User) -> str:
    """Красивое отображение информации о пользователе."""
    status_emoji = {
        UserStatus.ACTIVE:   "✅",
        UserStatus.DISABLED: "🚫",
        UserStatus.EXPIRED:  "⌛",
        UserStatus.LIMITED:  "⚡",
    }.get(user.status, "❓")

    lines = [
        f"👤 <b>{user.username}</b>  {status_emoji} {user.status.upper()}",
        "",
        "📊 <b>Трафик:</b>",
        f"  Использовано: <b>{fmt_bytes(user.traffic_used)}</b>",
        f"  Лимит:        <b>{fmt_bytes(user.traffic_limit)}</b>",
        f"  Осталось:     <b>{fmt_bytes(user.traffic_remaining)}</b>",
        "",
    ]
    if user.expires_at:
        now = datetime.now(timezone.utc)
        diff = user.expires_at - now
        days_left = diff.days
        if days_left > 0:
            lines.append(f"📅 Действует ещё: <b>{days_left} дн.</b>")
        elif days_left == 0:
            lines.append("⚠️ Истекает <b>сегодня</b>!")
        else:
            lines.append(f"❌ Истёк <b>{abs(days_left)} дн. назад</b>")
    else:
        lines.append("📅 Срок: <b>бессрочно</b>")

    return "\n".join(lines)


# ─── START ───

@router.message(CommandStart())
async def cmd_start(message: Message):
    async with AsyncSessionLocal() as db:
        user = await UserService.get_by_telegram(db, message.from_user.id)

    greeting = f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"

    if user:
        greeting += (
            f"Ваш аккаунт: <b>{user.username}</b>\n"
            "Используйте кнопки ниже для управления подпиской."
        )
    else:
        greeting += (
            "Вы ещё не зарегистрированы.\n"
            "Обратитесь к администратору для получения доступа."
        )

    kb = kb_main_admin() if is_admin(message.from_user.id) else kb_main_user()
    await message.answer(greeting, parse_mode="HTML", reply_markup=kb)


# ─── МОЙ СТАТУС ───

@router.callback_query(F.data == "my_status")
async def cb_my_status(call: CallbackQuery):
    async with AsyncSessionLocal() as db:
        user = await UserService.get_by_telegram(db, call.from_user.id)

    if not user:
        await call.answer("❌ Аккаунт не найден. Обратитесь к администратору.", show_alert=True)
        return

    text = await _user_card(user)
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=kb_back())
    await call.answer()


# ─── SUBSCRIPTION URL ───

@router.callback_query(F.data == "my_sub")
async def cb_my_sub(call: CallbackQuery):
    async with AsyncSessionLocal() as db:
        user = await UserService.get_by_telegram(db, call.from_user.id)

    if not user:
        await call.answer("❌ Аккаунт не найден.", show_alert=True)
        return

    url = sub_url(user)
    text = (
        "🔗 <b>Ваш Subscription URL:</b>\n\n"
        f"<code>{url}</code>\n\n"
        "Скопируйте и вставьте в приложение (v2rayN, NekoBox, Clash, sing-box).\n\n"
        "⚠️ <i>Не передавайте этот URL другим — он даёт полный доступ к вашей подписке.</i>"
    )
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=kb_back())
    await call.answer()


# ─── ФОРМАТЫ ───

@router.callback_query(F.data == "my_formats")
async def cb_my_formats(call: CallbackQuery):
    async with AsyncSessionLocal() as db:
        user = await UserService.get_by_telegram(db, call.from_user.id)

    if not user:
        await call.answer("❌ Аккаунт не найден.", show_alert=True)
        return

    text = (
        "📱 <b>Выберите формат конфигурации:</b>\n\n"
        "• <b>URI</b> — для v2rayN, NekoBox\n"
        "• <b>Clash</b> — для Clash Meta, Mihomo\n"
        "• <b>sing-box</b> — для sing-box, NekoBox (Android/iOS)"
    )
    await call.message.edit_text(
        text, parse_mode="HTML",
        reply_markup=kb_sub_formats(user.sub_token)
    )
    await call.answer()


# ─── НАЗАД ───

@router.callback_query(F.data == "back_main")
async def cb_back(call: CallbackQuery):
    kb = kb_main_admin() if is_admin(call.from_user.id) else kb_main_user()
    await call.message.edit_text(
        "Главное меню:",
        reply_markup=kb
    )
    await call.answer()


@router.callback_query(F.data == "noop")
async def cb_noop(call: CallbackQuery):
    await call.answer()


# ─── ПОМОЩЬ ───

@router.callback_query(F.data == "help")
async def cb_help(call: CallbackQuery):
    text = (
        "❓ <b>Помощь по GhostWave VPN</b>\n\n"
        "GhostWave — VPN-сервис с собственным протоколом, "
        "который невозможно заблокировать стандартными методами.\n\n"
        "<b>Как подключиться:</b>\n"
        "1️⃣ Установите одно из приложений:\n"
        "   • <a href='https://github.com/2dust/v2rayN'>v2rayN</a> (Windows)\n"
        "   • <a href='https://github.com/MatsuriDayo/NekoBoxForAndroid'>NekoBox</a> (Android)\n"
        "   • <a href='https://github.com/SagerNet/sing-box'>sing-box</a> (iOS/Android)\n\n"
        "2️⃣ Нажмите «🔗 Subscription URL» и скопируйте ссылку\n"
        "3️⃣ Добавьте ссылку в приложение как подписку\n"
        "4️⃣ Подключайтесь!\n\n"
        "По вопросам обращайтесь к администратору."
    )
    await call.message.edit_text(text, parse_mode="HTML",
                                  disable_web_page_preview=True,
                                  reply_markup=kb_back())
    await call.answer()


# ─── ADMIN: СОЗДАТЬ ПОЛЬЗОВАТЕЛЯ ───

@router.callback_query(F.data == "admin_create_user")
async def cb_admin_create(call: CallbackQuery, state: FSMContext):
    if not is_admin(call.from_user.id):
        await call.answer("⛔ Доступ запрещён", show_alert=True)
        return
    await state.set_state(AdminCreateUser.waiting_username)
    await call.message.edit_text(
        "👤 <b>Создание пользователя</b>\n\nВведите <b>username</b> (латиница, цифры, _ - .):",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data="cancel_create")]
        ])
    )
    await call.answer()


@router.message(AdminCreateUser.waiting_username)
async def fsm_username(message: Message, state: FSMContext):
    if not is_admin(message.from_user.id):
        return
    username = message.text.strip()
    if not username.replace("_", "").replace("-", "").replace(".", "").isalnum():
        await message.reply("❌ Недопустимые символы. Используйте латиницу, цифры, _ - .")
        return
    await state.update_data(username=username)
    await state.set_state(AdminCreateUser.waiting_traffic_limit)
    await message.reply(
        f"📊 Лимит трафика для <b>{username}</b>?\n\n"
        "Введите число в ГБ или <code>0</code> для безлимита:",
        parse_mode="HTML"
    )


@router.message(AdminCreateUser.waiting_traffic_limit)
async def fsm_traffic(message: Message, state: FSMContext):
    if not is_admin(message.from_user.id):
        return
    try:
        gb = float(message.text.strip())
        if gb < 0:
            raise ValueError
    except ValueError:
        await message.reply("❌ Введите число ≥ 0")
        return

    limit_bytes = int(gb * 1024 ** 3)
    await state.update_data(traffic_limit=limit_bytes)
    await state.set_state(AdminCreateUser.waiting_expires_days)
    await message.reply(
        "📅 Срок действия в днях?\n\n"
        "Введите число или <code>0</code> для бессрочного доступа:",
        parse_mode="HTML"
    )


@router.message(AdminCreateUser.waiting_expires_days)
async def fsm_expires(message: Message, state: FSMContext):
    if not is_admin(message.from_user.id):
        return
    try:
        days = int(message.text.strip())
        if days < 0:
            raise ValueError
    except ValueError:
        await message.reply("❌ Введите целое число ≥ 0")
        return

    data = await state.get_data()
    expires_at = None
    if days > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(days=days)

    username = data["username"]
    traffic_limit = data["traffic_limit"]
    traffic_str = fmt_bytes(traffic_limit) if traffic_limit > 0 else "Безлимит"
    expires_str = f"{days} дн." if days > 0 else "Бессрочно"

    await state.update_data(expires_days=days, expires_at=expires_at)

    await message.reply(
        f"📋 <b>Проверьте данные:</b>\n\n"
        f"👤 Username:   <b>{username}</b>\n"
        f"📊 Трафик:     <b>{traffic_str}</b>\n"
        f"📅 Срок:       <b>{expires_str}</b>\n\n"
        "Создать пользователя?",
        parse_mode="HTML",
        reply_markup=kb_confirm_create(username)
    )


@router.callback_query(F.data.startswith("confirm_create:"))
async def cb_confirm_create(call: CallbackQuery, state: FSMContext):
    if not is_admin(call.from_user.id):
        await call.answer("⛔", show_alert=True)
        return

    data = await state.get_data()
    await state.clear()

    async with AsyncSessionLocal() as db:
        try:
            user = await UserService.create(db, UserCreate(
                username=data["username"],
                traffic_limit=data["traffic_limit"],
                expires_at=data.get("expires_at"),
            ))
            await db.commit()
        except ValueError as e:
            await call.message.edit_text(f"❌ Ошибка: {e}")
            await call.answer()
            return

    url = sub_url(user)
    text = (
        f"✅ <b>Пользователь создан!</b>\n\n"
        f"👤 Username: <b>{user.username}</b>\n"
        f"🔑 UUID: <code>{user.uuid}</code>\n\n"
        f"🔗 <b>Subscription URL:</b>\n"
        f"<code>{url}</code>\n\n"
        "Отправьте ссылку пользователю."
    )
    kb = kb_main_admin()
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=kb)
    await call.answer("✅ Создан!")


@router.callback_query(F.data == "cancel_create")
async def cb_cancel_create(call: CallbackQuery, state: FSMContext):
    await state.clear()
    await call.message.edit_text("❌ Отменено.", reply_markup=kb_main_admin())
    await call.answer()


# ─── ADMIN: СПИСОК ПОЛЬЗОВАТЕЛЕЙ ───

@router.callback_query(F.data == "admin_list_users")
async def cb_admin_list(call: CallbackQuery):
    if not is_admin(call.from_user.id):
        await call.answer("⛔", show_alert=True)
        return

    async with AsyncSessionLocal() as db:
        total, users = await UserService.list_all(db, offset=0, limit=20)

    if not users:
        await call.message.edit_text("📋 Пользователей нет.", reply_markup=kb_back())
        await call.answer()
        return

    lines = [f"📋 <b>Пользователи</b> (показано {len(users)} из {total}):\n"]
    for u in users:
        emoji = {"active": "✅", "disabled": "🚫", "expired": "⌛", "limited": "⚡"}.get(u.status, "❓")
        lines.append(f"{emoji} <b>{u.username}</b> — {fmt_bytes(u.traffic_used)}")

    await call.message.edit_text(
        "\n".join(lines),
        parse_mode="HTML",
        reply_markup=kb_back()
    )
    await call.answer()


# ─── ADMIN: НОДЫ ───

@router.callback_query(F.data == "admin_nodes")
async def cb_admin_nodes(call: CallbackQuery):
    if not is_admin(call.from_user.id):
        await call.answer("⛔", show_alert=True)
        return

    async with AsyncSessionLocal() as db:
        nodes = await NodeService.list_all(db)

    if not nodes:
        await call.message.edit_text("🖥️ Нод нет.", reply_markup=kb_back())
        await call.answer()
        return

    lines = ["🖥️ <b>Статус нод:</b>\n"]
    for n in nodes:
        emoji = "🟢" if n.is_online else "🔴"
        last = ""
        if n.last_seen:
            diff = datetime.now(timezone.utc) - n.last_seen
            last = f" ({int(diff.total_seconds())}с назад)"
        lines.append(
            f"{emoji} {n.flag_emoji} <b>{n.name}</b>{last}\n"
            f"   👥 {n.online_users} онлайн | CPU {n.load_avg:.1f}% | RAM {n.memory_usage:.0f}%"
        )

    await call.message.edit_text("\n".join(lines), parse_mode="HTML", reply_markup=kb_back())
    await call.answer()


# ─── ADMIN: СТАТИСТИКА ───

@router.callback_query(F.data == "admin_stats")
async def cb_admin_stats(call: CallbackQuery):
    if not is_admin(call.from_user.id):
        await call.answer("⛔", show_alert=True)
        return

    async with AsyncSessionLocal() as db:
        from sqlalchemy import select, func
        from panel.api.models import User as UserModel
        total   = await db.scalar(select(func.count(UserModel.id)))
        active  = await db.scalar(select(func.count(UserModel.id)).where(UserModel.status == "active"))
        traffic = await db.scalar(
            select(func.sum(UserModel.traffic_used_up + UserModel.traffic_used_down))
        )
        node_stats = await NodeService.get_stats(db)

    text = (
        "📈 <b>Статистика системы</b>\n\n"
        f"👥 Пользователей: <b>{total}</b> (активных: <b>{active}</b>)\n"
        f"🖥️ Нод: <b>{node_stats['total']}</b> (онлайн: <b>{node_stats['online']}</b>)\n"
        f"📦 Суммарный трафик: <b>{fmt_bytes(traffic or 0)}</b>"
    )
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=kb_back())
    await call.answer()


# ─────────────────────────────────────────────
# ЗАПУСК БОТА
# ─────────────────────────────────────────────

async def start_bot():
    if not settings.TELEGRAM_BOT_TOKEN:
        log.warning("TELEGRAM_BOT_TOKEN не задан, бот не запущен")
        return

    storage = RedisStorage.from_url(settings.REDIS_URL)
    bot = Bot(token=settings.TELEGRAM_BOT_TOKEN, parse_mode="HTML")
    dp  = Dispatcher(storage=storage)
    dp.include_router(router)

    log.info("Telegram бот запускается…")
    await dp.start_polling(bot, allowed_updates=["message", "callback_query"])
