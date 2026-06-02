#!/usr/bin/env python3
"""
GhostWave Client v1.0
Кроссплатформенный GUI клиент для Windows / Linux / macOS

Зависимости:
    pip install cryptography httpx

Запуск (Linux/macOS - нужен sudo для TUN):
    sudo python3 ghostwave-client.py

Запуск (Windows - от Администратора):
    python ghostwave-client.py
"""

import os
import sys
import json
import time
import hmac
import struct
import hashlib
import base64
import secrets
import asyncio
import logging
import platform
import threading
import ipaddress
import subprocess
from datetime  import datetime, timezone
from pathlib   import Path
from typing    import Optional

# ── GUI ──────────────────────────────────────────────────────────────────────
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext

# ── Network ──────────────────────────────────────────────────────────────────
try:
    import httpx
except ImportError:
    print("Установите зависимости: pip install httpx cryptography")
    sys.exit(1)

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey
    )
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes, serialization
except ImportError:
    print("Установите зависимости: pip install cryptography")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS & CONFIG
# ─────────────────────────────────────────────────────────────────────────────

APP_NAME    = "GhostWave"
APP_VERSION = "1.0.0"
CONFIG_FILE = Path.home() / ".ghostwave" / "config.json"
LOG_FILE    = Path.home() / ".ghostwave" / "client.log"

OS = platform.system()  # "Windows", "Linux", "Darwin"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
    ]
)
log = logging.getLogger("ghostwave.client")

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG MANAGER
# ─────────────────────────────────────────────────────────────────────────────

class Config:
    def __init__(self):
        self.sub_url:       str  = ""
        self.selected_node: int  = 0   # индекс в списке nodes
        self.nodes:         list = []  # [{name, server_host, server_port, domain, shared_secret, user_uuid}]
        self.auto_connect:  bool = False
        self.split_tunnel:  bool = False
        self.dns_servers:   list = ["1.1.1.1", "8.8.8.8"]

    def load(self):
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        if CONFIG_FILE.exists():
            try:
                d = json.loads(CONFIG_FILE.read_text())
                self.sub_url       = d.get("sub_url", "")
                self.selected_node = d.get("selected_node", 0)
                self.nodes         = d.get("nodes", [])
                self.auto_connect  = d.get("auto_connect", False)
                self.split_tunnel  = d.get("split_tunnel", False)
                self.dns_servers   = d.get("dns_servers", ["1.1.1.1", "8.8.8.8"])
            except Exception as e:
                log.warning(f"Config load error: {e}")

    def save(self):
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(json.dumps({
            "sub_url":       self.sub_url,
            "selected_node": self.selected_node,
            "nodes":         self.nodes,
            "auto_connect":  self.auto_connect,
            "split_tunnel":  self.split_tunnel,
            "dns_servers":   self.dns_servers,
        }, indent=2, ensure_ascii=False))

# ─────────────────────────────────────────────────────────────────────────────
# SUBSCRIPTION FETCHER
# ─────────────────────────────────────────────────────────────────────────────

class SubscriptionFetcher:
    @staticmethod
    async def fetch(url: str) -> list[dict]:
        """
        Загружает subscription и возвращает список конфигов нод.
        Поддерживает ?fmt=json (наш формат) и base64 URI-список.
        """
        json_url = url if "fmt=" in url else url + ("&" if "?" in url else "?") + "fmt=json"

        async with httpx.AsyncClient(timeout=15, verify=False) as client:
            resp = await client.get(json_url)

        if resp.status_code == 403:
            raise PermissionError("Подписка истекла или заблокирована")
        if resp.status_code == 404:
            raise FileNotFoundError("Subscription URL не найден")
        resp.raise_for_status()

        data = resp.json()
        configs = data.get("configs", [])

        # Конвертируем в единый формат клиента
        nodes = []
        for c in configs:
            if c.get("protocol") != "ghostnet":
                continue
            nodes.append({
                "name":          c.get("remarks", "Unknown"),
                "server_host":   c["server_host"],
                "server_port":   c.get("server_port", 443),
                "domain":        c.get("domain", c["server_host"]),
                "shared_secret": c["shared_secret"],
                "user_uuid":     c.get("user_uuid", ""),
            })

        return nodes

    @staticmethod
    async def fetch_info(url: str) -> dict:
        """Загружает публичную информацию о подписке."""
        info_url = url.split("?")[0].rstrip("/") + "/info"
        async with httpx.AsyncClient(timeout=10, verify=False) as client:
            resp = await client.get(info_url)
        if resp.status_code == 200:
            return resp.json()
        return {}

# ─────────────────────────────────────────────────────────────────────────────
# GHOSTNET PROTOCOL IMPLEMENTATION
# ─────────────────────────────────────────────────────────────────────────────

FRAME_DATA      = 0x01
FRAME_KEEPALIVE = 0x02
FRAME_PADDING   = 0x03


def compute_sni(shared_secret: str, domain: str) -> str:
    """Temporal HMAC SNI токен для текущего временного окна."""
    slot = int(time.time()) // 30
    data = f"{slot}:{domain}".encode()
    digest = hmac.new(shared_secret.encode(), data, hashlib.sha256).digest()
    value = int.from_bytes(digest[:6], 'big')
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = []
    v = value
    while v:
        result.append(chars[v % 36])
        v //= 36
    token = ''.join(reversed(result)).zfill(10)
    return f"{token}.{domain}"


def make_frame(frame_type: int, payload: bytes, session_key: Optional[bytes] = None) -> bytes:
    stream_id = secrets.randbelow(2**32)
    if session_key and frame_type == FRAME_DATA:
        aead  = ChaCha20Poly1305(session_key)
        nonce = secrets.token_bytes(12)
        payload = nonce + aead.encrypt(nonce, payload, None)
    pad_size = secrets.randbelow(200)
    padding  = secrets.token_bytes(pad_size)
    header   = struct.pack("!BBIH", 0x01, frame_type, stream_id, len(payload))
    tail     = struct.pack("!H", pad_size) + padding
    return header + payload + tail


def parse_frame(data: bytes, session_key: Optional[bytes] = None):
    if len(data) < 8:
        return None, None
    _, frame_type, _, payload_len = struct.unpack_from("!BBIH", data, 0)
    raw = data[8: 8 + payload_len]
    if session_key and frame_type == FRAME_DATA and len(raw) >= 12:
        try:
            aead    = ChaCha20Poly1305(session_key)
            nonce   = raw[:12]
            payload = aead.decrypt(nonce, raw[12:], None)
        except Exception:
            return None, None
    else:
        payload = raw
    return frame_type, payload


# ─────────────────────────────────────────────────────────────────────────────
# TUN INTERFACE
# ─────────────────────────────────────────────────────────────────────────────

class TunInterface:
    """Создаёт и управляет TUN-интерфейсом для Layer 3 туннеля."""

    def __init__(self, name: str = "ghostwave0"):
        self.name    = name
        self.fd      = None
        self.ip      = "10.8.0.1"
        self.peer_ip = "10.8.0.2"
        self._orig_routes = []

    def open(self) -> bool:
        if OS == "Linux":
            return self._open_linux()
        elif OS == "Darwin":
            return self._open_macos()
        elif OS == "Windows":
            return self._open_windows()
        return False

    def _open_linux(self) -> bool:
        try:
            import fcntl
            TUNSETIFF = 0x400454CA
            IFF_TUN   = 0x0001
            IFF_NO_PI = 0x1000
            self.fd = open('/dev/net/tun', 'r+b', buffering=0)
            flags   = IFF_TUN | IFF_NO_PI
            ifr     = struct.pack('16sH', self.name.encode(), flags)
            fcntl.ioctl(self.fd, TUNSETIFF, ifr)

            # Настройка интерфейса
            subprocess.run(["ip", "link", "set", self.name, "up"],              check=True)
            subprocess.run(["ip", "addr", "add", f"{self.ip}/30", "dev", self.name], check=True)
            subprocess.run(["ip", "route", "add", "0.0.0.0/0", "dev", self.name,
                           "metric", "50"],                                     check=False)
            log.info(f"TUN {self.name} opened (Linux)")
            return True
        except Exception as e:
            log.error(f"TUN open failed: {e}")
            return False

    def _open_macos(self) -> bool:
        try:
            # На macOS используем utun
            import socket, struct as s
            self.fd = socket.socket(socket.AF_SYSTEM, socket.SOCK_DGRAM, 0x02)
            for unit in range(10):
                try:
                    ifr = s.pack("!16sI", f"utun{unit}".encode(), 0)
                    self.fd.setsockopt(0x00000200, 1, ifr)  # SYSPROTO_CONTROL
                    self.name = f"utun{unit}"
                    break
                except Exception:
                    continue
            subprocess.run(["ifconfig", self.name, self.ip, self.peer_ip, "up"],  check=True)
            subprocess.run(["route", "add", "default", "-interface", self.name], check=False)
            log.info(f"TUN {self.name} opened (macOS)")
            return True
        except Exception as e:
            log.error(f"TUN macOS failed: {e}")
            return False

    def _open_windows(self) -> bool:
        # На Windows используем WinTun (wintun.dll) или WireGuard's тунель
        # Для PoC — запускаем системный тунель через netsh
        log.warning("Windows TUN: используем системный адаптер (требует Wintun)")
        # В production здесь ctypes-вызовы к wintun.dll
        return False

    def read(self, size: int = 65535) -> Optional[bytes]:
        if not self.fd:
            return None
        try:
            if OS in ("Linux", "Darwin"):
                return self.fd.read(size)
        except Exception:
            return None

    def write(self, packet: bytes):
        if not self.fd:
            return
        try:
            if OS in ("Linux", "Darwin"):
                self.fd.write(packet)
        except Exception as e:
            log.error(f"TUN write: {e}")

    def configure_dns(self, dns_servers: list[str]):
        if OS == "Linux":
            try:
                with open("/etc/resolv.conf", "w") as f:
                    for dns in dns_servers:
                        f.write(f"nameserver {dns}\n")
            except Exception:
                pass

    def close(self):
        try:
            if OS == "Linux":
                subprocess.run(["ip", "route", "del", "0.0.0.0/0", "dev", self.name], check=False)
                subprocess.run(["ip", "link", "set", self.name, "down"],              check=False)
            elif OS == "Darwin":
                subprocess.run(["route", "delete", "default", "-interface", self.name], check=False)
            if self.fd:
                self.fd.close()
        except Exception:
            pass
        log.info("TUN closed")


# ─────────────────────────────────────────────────────────────────────────────
# VPN CONNECTION
# ─────────────────────────────────────────────────────────────────────────────

class ConnectionStatus:
    DISCONNECTED = "disconnected"
    CONNECTING   = "connecting"
    CONNECTED    = "connected"
    ERROR        = "error"


class VPNConnection:
    """
    Управляет одним VPN-соединением с нодой.
    Запускается в фоновом потоке.
    """

    def __init__(self, node: dict, on_status: callable, on_stats: callable):
        self.node       = node
        self.on_status  = on_status   # callback(status, message)
        self.on_stats   = on_stats    # callback(rx_bytes, tx_bytes, duration)
        self._loop:     Optional[asyncio.AbstractEventLoop] = None
        self._task:     Optional[asyncio.Task]  = None
        self._stop      = asyncio.Event()
        self._session_key: Optional[bytes]      = None
        self._session_id:  Optional[bytes]      = None
        self._tun          = TunInterface()
        self._rx_bytes  = 0
        self._tx_bytes  = 0
        self._connected_at: Optional[float]    = None
        self.status     = ConnectionStatus.DISCONNECTED

    # ── PUBLIC ──────────────────────────────────────────────────────────────

    def connect(self):
        """Запускает подключение в отдельном потоке."""
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()

    def disconnect(self):
        """Останавливает соединение."""
        if self._loop and self._stop:
            self._loop.call_soon_threadsafe(self._stop.set)

    @property
    def uptime(self) -> str:
        if not self._connected_at:
            return "00:00:00"
        secs = int(time.time() - self._connected_at)
        h, r = divmod(secs, 3600)
        m, s = divmod(r, 60)
        return f"{h:02d}:{m:02d}:{s:02d}"

    # ── INTERNAL ────────────────────────────────────────────────────────────

    def _run_loop(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._main())
        finally:
            self._loop.close()

    async def _main(self):
        self._stop = asyncio.Event()
        self._set_status(ConnectionStatus.CONNECTING, "Подключение…")

        try:
            sni = compute_sni(self.node["shared_secret"], self.node["domain"])
            log.info(f"Connecting to {self.node['server_host']}:{self.node['server_port']}")
            log.info(f"SNI: {sni}")

            # TLS соединение
            ssl_ctx = self._make_ssl_ctx()
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(
                    self.node["server_host"],
                    self.node["server_port"],
                    ssl=ssl_ctx,
                    server_hostname=sni,
                ),
                timeout=15,
            )

            self._set_status(ConnectionStatus.CONNECTING, "TLS установлен. Handshake…")

            # ECDH session init
            ok = await self._handshake(reader, writer, sni)
            if not ok:
                self._set_status(ConnectionStatus.ERROR, "Handshake failed")
                return

            # TUN interface
            self._set_status(ConnectionStatus.CONNECTING, "Настройка сети…")
            if not self._tun.open():
                log.warning("TUN недоступен — работаем без системного маршрута (прокси-режим)")

            self._tun.configure_dns(["1.1.1.1", "8.8.8.8"])
            self._connected_at = time.time()
            self._set_status(ConnectionStatus.CONNECTED, "Подключено")

            # Main loops
            await asyncio.gather(
                self._upload_loop(writer),
                self._download_loop(reader, writer),
                self._keepalive_loop(writer),
                self._stats_loop(),
                self._stop.wait(),
            )

        except asyncio.TimeoutError:
            self._set_status(ConnectionStatus.ERROR, "Timeout подключения")
        except ConnectionRefusedError:
            self._set_status(ConnectionStatus.ERROR, "Сервер недоступен")
        except Exception as e:
            log.error(f"Connection error: {e}")
            self._set_status(ConnectionStatus.ERROR, f"Ошибка: {e}")
        finally:
            self._tun.close()
            if self.status == ConnectionStatus.CONNECTED:
                self._set_status(ConnectionStatus.DISCONNECTED, "Отключено")

    def _make_ssl_ctx(self):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version   = ssl.TLSVersion.TLSv1_2
        ctx.maximum_version   = ssl.TLSVersion.TLSv1_3
        ctx.check_hostname    = False
        ctx.verify_mode       = ssl.CERT_NONE
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        try:
            ctx.set_ciphers(
                "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:"
                "TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
                "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305"
            )
        except Exception:
            pass
        return ctx

    async def _handshake(self, reader, writer, sni: str) -> bool:
        try:
            priv    = X25519PrivateKey.generate()
            pub_b   = priv.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw
            )
            body    = json.dumps({"ephemeral_pubkey": pub_b.hex()}).encode()
            req     = (
                f"POST /api/v1/init HTTP/1.1\r\n"
                f"Host: {sni}\r\n"
                f"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                f"AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n"
                f"Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Accept: application/json\r\n"
                f"Connection: keep-alive\r\n\r\n"
            ).encode() + body
            writer.write(req)
            await writer.drain()

            header  = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
            clen    = 0
            for line in header.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    clen = int(line.split(b":")[1].strip())
            if clen == 0:
                return False

            resp_raw = await asyncio.wait_for(reader.readexactly(clen), timeout=10)
            # Убираем padding
            clean = resp_raw.split(b',"_pad"')[0]
            if not clean.endswith(b"}"):
                clean += b"}"
            resp = json.loads(clean)

            srv_pub_b = bytes.fromhex(resp["ephemeral_pubkey"])
            srv_pub   = X25519PublicKey.from_public_bytes(srv_pub_b)
            shared    = priv.exchange(srv_pub)

            hkdf = HKDF(algorithm=hashes.SHA256(), length=32,
                        salt=None, info=b"ghostnet-session-v1")
            self._session_key = hkdf.derive(shared)
            self._session_id  = bytes.fromhex(resp["session_id"])
            log.info(f"Session: {self._session_id.hex()[:8]}… IP: {resp.get('client_ip')}")
            return True
        except Exception as e:
            log.error(f"Handshake: {e}")
            return False

    async def _upload_loop(self, writer):
        """TUN → Server: читаем IP-пакеты и отправляем."""
        sni = compute_sni(self.node["shared_secret"], self.node["domain"])
        while not self._stop.is_set():
            packet = None
            if self._tun.fd:
                loop   = asyncio.get_event_loop()
                packet = await loop.run_in_executor(None, self._tun.read)

            if packet:
                frame   = make_frame(FRAME_DATA, packet, self._session_key)
                # Паддинг до минимального размера
                if len(frame) < 512:
                    frame += secrets.token_bytes(512 - len(frame))

                body    = frame
                req     = (
                    f"POST /api/v1/up HTTP/1.1\r\n"
                    f"Host: {sni}\r\n"
                    f"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    f"AppleWebKit/537.36 Chrome/120.0.0.0\r\n"
                    f"Content-Type: application/octet-stream\r\n"
                    f"Content-Length: {len(body)}\r\n"
                    f"X-Request-Id: {self._session_id.hex() if self._session_id else ''}\r\n"
                    f"Connection: keep-alive\r\n\r\n"
                ).encode() + body

                writer.write(req)
                await writer.drain()
                self._tx_bytes += len(packet)
            else:
                await asyncio.sleep(0.005)

    async def _download_loop(self, reader, writer):
        """Server → TUN: получаем пакеты и пишем в TUN."""
        sni = compute_sni(self.node["shared_secret"], self.node["domain"])
        while not self._stop.is_set():
            req = (
                f"GET /api/v1/down HTTP/1.1\r\n"
                f"Host: {sni}\r\n"
                f"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                f"AppleWebKit/537.36 Chrome/120.0.0.0\r\n"
                f"Accept: application/json\r\n"
                f"X-Request-Id: {self._session_id.hex() if self._session_id else ''}\r\n"
                f"Connection: keep-alive\r\n\r\n"
            ).encode()
            writer.write(req)
            await writer.drain()

            try:
                header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=5)
                clen   = 0
                for line in header.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        clen = int(line.split(b":")[1].strip())
                if clen > 0:
                    body = await asyncio.wait_for(reader.readexactly(clen), timeout=10)
                    try:
                        clean = body.split(b',"_pad"')[0]
                        if not clean.endswith(b"}"):
                            clean += b"}"
                        resp  = json.loads(clean)
                        for frame_hex in resp.get("frames", []):
                            frame_bytes = bytes.fromhex(frame_hex)
                            ftype, payload = parse_frame(frame_bytes, self._session_key)
                            if ftype == FRAME_DATA and payload and self._tun.fd:
                                self._tun.write(payload)
                                self._rx_bytes += len(payload)
                    except Exception:
                        pass
            except asyncio.TimeoutError:
                pass

            await asyncio.sleep(0.05)

    async def _keepalive_loop(self, writer):
        """Имитация браузерного поведения — периодические keepalive запросы."""
        sni   = compute_sni(self.node["shared_secret"], self.node["domain"])
        paths = ["/api/v1/ping", "/favicon.ico", "/api/health"]
        while not self._stop.is_set():
            delay = 10 + secrets.randbelow(20)
            await asyncio.sleep(delay)
            if self._stop.is_set():
                break
            path = secrets.choice(paths)
            req  = (
                f"GET {path} HTTP/1.1\r\nHost: {sni}\r\n"
                f"User-Agent: Mozilla/5.0\r\nConnection: keep-alive\r\n\r\n"
            ).encode()
            try:
                writer.write(req)
                await writer.drain()
            except Exception:
                break

    async def _stats_loop(self):
        while not self._stop.is_set():
            await asyncio.sleep(1)
            if self.on_stats:
                self.on_stats(self._rx_bytes, self._tx_bytes,
                              self._connected_at)

    def _set_status(self, status: str, message: str = ""):
        self.status = status
        log.info(f"Status: {status} — {message}")
        if self.on_status:
            self.on_status(status, message)


# ─────────────────────────────────────────────────────────────────────────────
# GUI APPLICATION
# ─────────────────────────────────────────────────────────────────────────────

class GhostWaveApp(tk.Tk):

    # Цвета
    C_BG      = "#0d1117"
    C_SURFACE = "#161b22"
    C_BORDER  = "#21262d"
    C_TEXT    = "#e6edf3"
    C_MUTED   = "#8b949e"
    C_ACCENT  = "#2f81f7"
    C_GREEN   = "#3fb950"
    C_RED     = "#f85149"
    C_YELLOW  = "#d29922"

    def __init__(self):
        super().__init__()
        self.config_mgr = Config()
        self.config_mgr.load()

        self.conn: Optional[VPNConnection] = None
        self._status_var = tk.StringVar(value="Отключено")
        self._node_var   = tk.StringVar()

        self._setup_window()
        self._setup_styles()
        self._build_ui()
        self._refresh_node_list()

        if self.config_mgr.auto_connect and self.config_mgr.nodes:
            self.after(500, self._on_connect)

    # ── WINDOW SETUP ─────────────────────────────────────────────────────────

    def _setup_window(self):
        self.title(f"{APP_NAME} {APP_VERSION}")
        self.geometry("560x620")
        self.resizable(False, False)
        self.configure(bg=self.C_BG)
        # Иконка (встроенная, не требует файла)
        try:
            self.iconbitmap(default="")
        except Exception:
            pass

    def _setup_styles(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".",
            background=self.C_BG,
            foreground=self.C_TEXT,
            fieldbackground=self.C_SURFACE,
            font=("Consolas", 10) if OS == "Windows" else ("Menlo", 10),
        )
        style.configure("TNotebook",
            background=self.C_BG,
            borderwidth=0,
            tabmargins=[0, 0, 0, 0],
        )
        style.configure("TNotebook.Tab",
            background=self.C_SURFACE,
            foreground=self.C_MUTED,
            padding=[16, 8],
            borderwidth=0,
        )
        style.map("TNotebook.Tab",
            background=[("selected", self.C_BG)],
            foreground=[("selected", self.C_TEXT)],
        )
        style.configure("TCombobox",
            background=self.C_SURFACE,
            foreground=self.C_TEXT,
            fieldbackground=self.C_SURFACE,
            arrowcolor=self.C_MUTED,
            relief="flat",
            borderwidth=1,
        )
        style.configure("TEntry",
            background=self.C_SURFACE,
            foreground=self.C_TEXT,
            fieldbackground=self.C_SURFACE,
            relief="flat",
            borderwidth=1,
        )

    # ── UI BUILD ─────────────────────────────────────────────────────────────

    def _build_ui(self):
        # ── Header ──────────────────────────────────────────────────────────
        header = tk.Frame(self, bg=self.C_BG, pady=20)
        header.pack(fill="x", padx=24)

        tk.Label(header,
            text="GHOST",
            font=("Consolas", 22, "bold") if OS == "Windows" else ("Menlo", 22, "bold"),
            bg=self.C_BG, fg=self.C_ACCENT,
        ).pack(side="left")
        tk.Label(header,
            text="WAVE",
            font=("Consolas", 22, "bold") if OS == "Windows" else ("Menlo", 22, "bold"),
            bg=self.C_BG, fg=self.C_TEXT,
        ).pack(side="left")
        tk.Label(header,
            text=f"v{APP_VERSION}",
            font=("Consolas", 10) if OS == "Windows" else ("Menlo", 10),
            bg=self.C_BG, fg=self.C_MUTED,
        ).pack(side="left", padx=(8, 0), pady=(8, 0))

        # ── Status indicator ─────────────────────────────────────────────────
        self._status_frame = tk.Frame(self, bg=self.C_SURFACE, pady=16)
        self._status_frame.pack(fill="x", padx=24, pady=(0, 16))

        self._dot = tk.Label(self._status_frame,
            text="●", font=("Arial", 18),
            bg=self.C_SURFACE, fg=self.C_RED,
        )
        self._dot.pack(side="left", padx=(20, 10))

        status_info = tk.Frame(self._status_frame, bg=self.C_SURFACE)
        status_info.pack(side="left", fill="x", expand=True)

        self._status_label = tk.Label(status_info,
            textvariable=self._status_var,
            font=("Consolas", 12, "bold") if OS == "Windows" else ("Menlo", 12, "bold"),
            bg=self.C_SURFACE, fg=self.C_TEXT, anchor="w",
        )
        self._status_label.pack(anchor="w")

        self._msg_label = tk.Label(status_info,
            text="", bg=self.C_SURFACE, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
            anchor="w",
        )
        self._msg_label.pack(anchor="w")

        # Stats
        stats_frame = tk.Frame(self._status_frame, bg=self.C_SURFACE)
        stats_frame.pack(side="right", padx=20)

        self._rx_label = tk.Label(stats_frame,
            text="↓ 0 B", bg=self.C_SURFACE, fg=self.C_GREEN,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        )
        self._rx_label.pack(anchor="e")

        self._tx_label = tk.Label(stats_frame,
            text="↑ 0 B", bg=self.C_SURFACE, fg=self.C_ACCENT,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        )
        self._tx_label.pack(anchor="e")

        self._uptime_label = tk.Label(stats_frame,
            text="00:00:00", bg=self.C_SURFACE, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        )
        self._uptime_label.pack(anchor="e")

        # ── Notebook tabs ────────────────────────────────────────────────────
        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=24, pady=(0, 24))

        tab1 = tk.Frame(nb, bg=self.C_BG)
        tab2 = tk.Frame(nb, bg=self.C_BG)
        tab3 = tk.Frame(nb, bg=self.C_BG)

        nb.add(tab1, text="  Подключение  ")
        nb.add(tab2, text="  Подписка  ")
        nb.add(tab3, text="  Настройки  ")

        self._build_tab_connect(tab1)
        self._build_tab_sub(tab2)
        self._build_tab_settings(tab3)

    def _build_tab_connect(self, parent):
        """Вкладка подключения."""
        pad = dict(padx=16, pady=8)

        # Node selector
        tk.Label(parent,
            text="Сервер:", bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        ).pack(anchor="w", **pad)

        node_frame = tk.Frame(parent, bg=self.C_BG)
        node_frame.pack(fill="x", padx=16, pady=(0, 4))

        self._node_combo = ttk.Combobox(node_frame,
            textvariable=self._node_var,
            state="readonly", height=10,
        )
        self._node_combo.pack(side="left", fill="x", expand=True)
        self._node_combo.bind("<<ComboboxSelected>>", self._on_node_selected)

        tk.Button(node_frame,
            text="⟳", width=3,
            bg=self.C_SURFACE, fg=self.C_TEXT,
            relief="flat", bd=0,
            activebackground=self.C_BORDER,
            activeforeground=self.C_TEXT,
            command=self._on_refresh_sub,
        ).pack(side="left", padx=(6, 0))

        # Ping indicator
        self._ping_label = tk.Label(parent,
            text="", bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        )
        self._ping_label.pack(anchor="w", padx=16)

        # Connect button (big)
        self._conn_btn = tk.Button(parent,
            text="ПОДКЛЮЧИТЬ",
            font=("Consolas", 13, "bold") if OS == "Windows" else ("Menlo", 13, "bold"),
            bg=self.C_ACCENT, fg="white",
            relief="flat", bd=0, pady=14,
            activebackground="#1a6fd4",
            activeforeground="white",
            cursor="hand2",
            command=self._on_connect_toggle,
        )
        self._conn_btn.pack(fill="x", padx=16, pady=16)

        # Log area
        tk.Label(parent,
            text="Лог подключения:", bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        ).pack(anchor="w", padx=16)

        self._log_text = scrolledtext.ScrolledText(parent,
            bg=self.C_SURFACE, fg=self.C_MUTED,
            font=("Consolas", 8) if OS == "Windows" else ("Menlo", 8),
            relief="flat", bd=0, height=8,
            insertbackground=self.C_TEXT,
        )
        self._log_text.pack(fill="both", expand=True, padx=16, pady=(4, 16))

        # Route log to GUI
        gui_handler = self._GuiLogHandler(self._log_text)
        gui_handler.setLevel(logging.INFO)
        logging.getLogger("ghostwave").addHandler(gui_handler)

    def _build_tab_sub(self, parent):
        """Вкладка управления подпиской."""
        pad = dict(padx=16, pady=6)

        tk.Label(parent,
            text="Subscription URL:",
            bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        ).pack(anchor="w", **pad)

        self._sub_entry = tk.Entry(parent,
            bg=self.C_SURFACE, fg=self.C_TEXT,
            insertbackground=self.C_TEXT,
            relief="flat", bd=4,
            font=("Consolas", 10) if OS == "Windows" else ("Menlo", 10),
        )
        self._sub_entry.pack(fill="x", padx=16, pady=(0, 8))
        if self.config_mgr.sub_url:
            self._sub_entry.insert(0, self.config_mgr.sub_url)

        btn_row = tk.Frame(parent, bg=self.C_BG)
        btn_row.pack(fill="x", padx=16, pady=(0, 16))

        tk.Button(btn_row,
            text="Сохранить и обновить",
            bg=self.C_ACCENT, fg="white",
            relief="flat", bd=0, padx=16, pady=8,
            activebackground="#1a6fd4",
            activeforeground="white",
            cursor="hand2",
            command=self._on_save_sub,
        ).pack(side="left")

        # Sub info
        self._sub_info = tk.Text(parent,
            bg=self.C_SURFACE, fg=self.C_TEXT,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
            relief="flat", bd=0, height=12,
            state="disabled",
        )
        self._sub_info.pack(fill="both", expand=True, padx=16, pady=(0, 16))

        if self.config_mgr.sub_url:
            self._load_sub_info()

    def _build_tab_settings(self, parent):
        """Вкладка настроек."""
        pad = dict(padx=16, pady=6)

        # DNS
        tk.Label(parent, text="DNS серверы (через пробел):",
            bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 9) if OS == "Windows" else ("Menlo", 9),
        ).pack(anchor="w", **pad)

        self._dns_entry = tk.Entry(parent,
            bg=self.C_SURFACE, fg=self.C_TEXT,
            insertbackground=self.C_TEXT,
            relief="flat", bd=4,
        )
        self._dns_entry.pack(fill="x", padx=16, pady=(0, 8))
        self._dns_entry.insert(0, " ".join(self.config_mgr.dns_servers))

        # Auto-connect
        self._auto_var = tk.BooleanVar(value=self.config_mgr.auto_connect)
        tk.Checkbutton(parent,
            text="Подключаться автоматически при запуске",
            variable=self._auto_var,
            bg=self.C_BG, fg=self.C_TEXT,
            selectcolor=self.C_SURFACE,
            activebackground=self.C_BG,
            activeforeground=self.C_TEXT,
        ).pack(anchor="w", padx=16, pady=6)

        # Save settings
        tk.Button(parent,
            text="Сохранить настройки",
            bg=self.C_GREEN, fg="white",
            relief="flat", bd=0, padx=16, pady=8,
            activebackground="#2ea043",
            activeforeground="white",
            cursor="hand2",
            command=self._on_save_settings,
        ).pack(anchor="w", padx=16, pady=16)

        # System info
        tk.Label(parent,
            text=f"OS: {OS} | Python: {sys.version.split()[0]}",
            bg=self.C_BG, fg=self.C_MUTED,
            font=("Consolas", 8) if OS == "Windows" else ("Menlo", 8),
        ).pack(anchor="w", padx=16)

    # ── CALLBACKS ────────────────────────────────────────────────────────────

    def _on_connect_toggle(self):
        if self.conn and self.conn.status == ConnectionStatus.CONNECTED:
            self._on_disconnect()
        else:
            self._on_connect()

    def _on_connect(self):
        if not self.config_mgr.nodes:
            messagebox.showwarning("GhostWave",
                "Нет серверов.\nДобавьте Subscription URL на вкладке «Подписка».")
            return

        idx  = self.config_mgr.selected_node
        if idx >= len(self.config_mgr.nodes):
            idx = 0
        node = self.config_mgr.nodes[idx]

        self.conn = VPNConnection(
            node=node,
            on_status=self._on_status_update,
            on_stats=self._on_stats_update,
        )
        self.conn.connect()
        self._conn_btn.config(text="ОТКЛЮЧИТЬ", bg=self.C_RED, activebackground="#b91c1c")

    def _on_disconnect(self):
        if self.conn:
            self.conn.disconnect()
            self.conn = None
        self._conn_btn.config(text="ПОДКЛЮЧИТЬ", bg=self.C_ACCENT, activebackground="#1a6fd4")

    def _on_status_update(self, status: str, message: str):
        """Вызывается из фонового потока."""
        self.after(0, lambda: self._apply_status(status, message))

    def _apply_status(self, status: str, message: str):
        self._status_var.set({
            ConnectionStatus.CONNECTED:    "Подключено",
            ConnectionStatus.CONNECTING:   "Подключение…",
            ConnectionStatus.DISCONNECTED: "Отключено",
            ConnectionStatus.ERROR:        "Ошибка",
        }.get(status, status))

        color = {
            ConnectionStatus.CONNECTED:    self.C_GREEN,
            ConnectionStatus.CONNECTING:   self.C_YELLOW,
            ConnectionStatus.DISCONNECTED: self.C_RED,
            ConnectionStatus.ERROR:        self.C_RED,
        }.get(status, self.C_MUTED)

        self._dot.config(fg=color)
        self._msg_label.config(text=message)

        if status == ConnectionStatus.DISCONNECTED:
            self._conn_btn.config(text="ПОДКЛЮЧИТЬ", bg=self.C_ACCENT, activebackground="#1a6fd4")

    def _on_stats_update(self, rx: int, tx: int, connected_at: Optional[float]):
        self.after(0, lambda: self._apply_stats(rx, tx, connected_at))

    def _apply_stats(self, rx: int, tx: int, connected_at: Optional[float]):
        self._rx_label.config(text=f"↓ {self._fmt_bytes(rx)}")
        self._tx_label.config(text=f"↑ {self._fmt_bytes(tx)}")
        if connected_at:
            secs = int(time.time() - connected_at)
            h, r = divmod(secs, 3600)
            m, s = divmod(r, 60)
            self._uptime_label.config(text=f"{h:02d}:{m:02d}:{s:02d}")

    def _on_node_selected(self, _event=None):
        idx = self._node_combo.current()
        if idx >= 0:
            self.config_mgr.selected_node = idx
            self.config_mgr.save()
            # Ping (упрощённо)
            self._ping_label.config(text="")
            self.after(100, lambda: self._do_ping(idx))

    def _do_ping(self, idx: int):
        if idx >= len(self.config_mgr.nodes):
            return
        node = self.config_mgr.nodes[idx]
        start = time.time()
        try:
            result = subprocess.run(
                ["ping", "-c", "1", "-W", "2", node["server_host"]] if OS != "Windows"
                else ["ping", "-n", "1", "-w", "2000", node["server_host"]],
                capture_output=True, timeout=5,
            )
            ms = int((time.time() - start) * 1000)
            if result.returncode == 0:
                color = self.C_GREEN if ms < 100 else (self.C_YELLOW if ms < 200 else self.C_RED)
                self._ping_label.config(text=f"Пинг: {ms} мс", fg=color)
            else:
                self._ping_label.config(text="Недоступен", fg=self.C_RED)
        except Exception:
            self._ping_label.config(text="", fg=self.C_MUTED)

    def _on_refresh_sub(self):
        self._on_save_sub()

    def _on_save_sub(self):
        url = self._sub_entry.get().strip()
        if not url:
            messagebox.showwarning("GhostWave", "Введите Subscription URL")
            return
        self.config_mgr.sub_url = url
        self.config_mgr.save()
        self._log("Загрузка подписки…")
        threading.Thread(target=self._fetch_sub, daemon=True).start()

    def _fetch_sub(self):
        async def _do():
            return await SubscriptionFetcher.fetch(self.config_mgr.sub_url)

        try:
            loop  = asyncio.new_event_loop()
            nodes = loop.run_until_complete(_do())
            loop.close()
            self.config_mgr.nodes = nodes
            self.config_mgr.save()
            self.after(0, self._refresh_node_list)
            self.after(0, lambda: self._log(f"Загружено {len(nodes)} серверов"))
            self.after(0, self._load_sub_info)
        except Exception as e:
            self.after(0, lambda: self._log(f"Ошибка загрузки: {e}"))
            self.after(0, lambda: messagebox.showerror("GhostWave",
                f"Не удалось загрузить подписку:\n{e}"))

    def _load_sub_info(self):
        threading.Thread(target=self._fetch_sub_info, daemon=True).start()

    def _fetch_sub_info(self):
        async def _do():
            return await SubscriptionFetcher.fetch_info(self.config_mgr.sub_url)
        try:
            loop = asyncio.new_event_loop()
            info = loop.run_until_complete(_do())
            loop.close()
            self.after(0, lambda: self._show_sub_info(info))
        except Exception:
            pass

    def _show_sub_info(self, info: dict):
        if not info:
            return
        lines = [
            f"Пользователь:  {info.get('username', '—')}",
            f"Статус:        {info.get('status', '—').upper()}",
            "",
            f"Трафик использовано: {self._fmt_bytes(info.get('traffic_used', 0))}",
            f"Лимит:               {self._fmt_bytes(info.get('traffic_limit', 0))}",
            f"Осталось:            {self._fmt_bytes(info.get('traffic_remaining', -1))}",
            "",
        ]
        if info.get("expires_at"):
            lines.append(f"Действует до: {info['expires_at'][:10]}")

        lines += ["", "Серверы:"]
        for n in info.get("nodes", []):
            lines.append(f"  {n.get('flag', '🌐')} {n.get('name', '?')} ({n.get('country', '?')})")

        self._sub_info.config(state="normal")
        self._sub_info.delete("1.0", "end")
        self._sub_info.insert("1.0", "\n".join(lines))
        self._sub_info.config(state="disabled")

    def _on_save_settings(self):
        dns_raw = self._dns_entry.get().strip()
        self.config_mgr.dns_servers  = dns_raw.split() if dns_raw else ["1.1.1.1"]
        self.config_mgr.auto_connect = self._auto_var.get()
        self.config_mgr.save()
        messagebox.showinfo("GhostWave", "Настройки сохранены")

    # ── HELPERS ──────────────────────────────────────────────────────────────

    def _refresh_node_list(self):
        names = [n.get("name", f"Node {i}") for i, n in enumerate(self.config_mgr.nodes)]
        self._node_combo["values"] = names
        if names:
            idx = min(self.config_mgr.selected_node, len(names) - 1)
            self._node_combo.current(idx)

    def _log(self, message: str):
        ts  = datetime.now().strftime("%H:%M:%S")
        msg = f"[{ts}] {message}\n"
        self._log_text.insert("end", msg)
        self._log_text.see("end")

    @staticmethod
    def _fmt_bytes(b: int) -> str:
        if b < 0:
            return "∞"
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if b < 1024:
                return f"{b:.1f} {unit}"
            b /= 1024
        return f"{b:.1f} PB"

    # ── LOG HANDLER ──────────────────────────────────────────────────────────

    class _GuiLogHandler(logging.Handler):
        def __init__(self, widget):
            super().__init__()
            self.widget = widget

        def emit(self, record):
            msg = self.format(record)
            try:
                self.widget.after(0, lambda: self._append(msg))
            except Exception:
                pass

        def _append(self, msg):
            self.widget.insert("end", msg + "\n")
            self.widget.see("end")


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def check_privileges():
    """Проверяем права для TUN-интерфейса."""
    if OS == "Windows":
        try:
            import ctypes
            return ctypes.windll.shell32.IsUserAnAdmin()
        except Exception:
            return False
    else:
        return os.geteuid() == 0


def main():
    if not check_privileges():
        print("="*60)
        print("ПРЕДУПРЕЖДЕНИЕ: Клиент запущен без прав администратора.")
        print("TUN-интерфейс не будет создан.")
        print("Для полноценной работы:")
        if OS == "Windows":
            print("  Запустите от имени Администратора")
        else:
            print("  sudo python3 ghostwave-client.py")
        print("="*60)
        print()

    app = GhostWaveApp()
    app.mainloop()


if __name__ == "__main__":
    main()
