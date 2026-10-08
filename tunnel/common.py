"""公共协议与工具模块：JSON 行协议 + 双向数据转发。"""
from __future__ import annotations   # 兼容 macOS 自带 Python 3.9（dict | None 标注）
import asyncio
import json
import hashlib
import socket
import time

PROTO_VERSION = 1
MAX_LINE = 64 * 1024
PING_INTERVAL = 25      # 心跳间隔（秒）
PING_TIMEOUT = 60       # 心跳超时（秒）


def set_nodelay(writer: asyncio.StreamWriter) -> None:
    """转发链路必须禁用 Nagle，否则小包与延迟 ACK 相互作用产生 40ms 级停顿。"""
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass


def make_token_proof(token: str, nonce: str) -> str:
    """HMAC 风格的令牌校验，避免明文令牌在握手后反复出现。"""
    return hashlib.sha256(f"{token}:{nonce}".encode()).hexdigest()


async def send_msg(writer: asyncio.StreamWriter, obj: dict) -> None:
    writer.write(json.dumps(obj, ensure_ascii=False).encode() + b"\n")
    await writer.drain()


async def read_msg(reader: asyncio.StreamReader) -> dict | None:
    line = await reader.readline()
    if not line:
        return None
    if len(line) > MAX_LINE:
        raise ValueError("message too large")
    return json.loads(line.decode())


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
               on_data=None) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            if on_data:
                on_data(len(data))
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def bidirectional(a_reader, a_writer, b_reader, b_writer, on_data=None) -> None:
    await asyncio.gather(
        pipe(a_reader, b_writer, on_data),
        pipe(b_reader, a_writer, on_data),
        return_exceptions=True,
    )


def ts() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(tag: str, msg: str) -> None:
    print(f"[{ts()}] [{tag}] {msg}", flush=True)
