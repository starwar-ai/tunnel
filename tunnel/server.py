"""内网穿透服务端：部署在具有公网 IP 的机器上。

工作模型（单端口复用）：
1. 客户端连接 control 端口，发送 auth 消息注册其隧道列表；
2. 服务端为每条隧道监听一个公网端口；
3. 有访问者连入公网端口时，服务端通过控制通道通知客户端建立数据通道；
4. 客户端回连并携带 session id，服务端将其与访问者连接配对并双向转发。

另带 Web 管理控制台（--admin-port，默认 7500）：实时状态、隧道列表、在线配置。
"""
import asyncio
import itertools
import json
import os
import secrets
import argparse
import time

from .common import (send_msg, read_msg, make_token_proof, bidirectional,
                     set_nodelay, PING_INTERVAL, PROTO_VERSION, log)
from .admin_page import ADMIN_HTML

CONFIG_PATH = os.environ.get("TUNNEL_SERVER_CONFIG", "server_config.json")


class TunnelSession:
    __slots__ = ("visitor_reader", "visitor_writer", "event")

    def __init__(self, reader, writer):
        self.visitor_reader = reader
        self.visitor_writer = writer
        self.event = asyncio.Event()


class ClientAgent:
    """一个已注册客户端及其隧道。"""

    def __init__(self, server, reader, writer, tunnels, peer):
        self.server = server
        self.reader = reader
        self.writer = writer
        self.peer = peer
        self.tunnels = tunnels          # name -> {remote_port, local_host, local_port}
        self.sessions = {}              # session_id -> TunnelSession
        self._counter = itertools.count(1)
        self.listeners = []
        self.alive = True

    async def start(self):
        for name, t in self.tunnels.items():
            port = int(t["remote_port"])
            try:
                srv = await asyncio.start_server(
                    lambda r, w, n=name: self.on_visitor(n, r, w), "0.0.0.0", port)
            except OSError as e:
                log("SERVER", f"隧道 {name} 端口 {port} 监听失败: {e}")
                await send_msg(self.writer, {"type": "error",
                                             "msg": f"tunnel {name}: port {port} unavailable"})
                continue
            self.listeners.append(srv)
            log("SERVER", f"隧道 {name} 已上线: 0.0.0.0:{port} -> {t['local_host']}:{t['local_port']}")
            await send_msg(self.writer, {"type": "tunnel_ok", "name": name, "remote_port": port})
        asyncio.create_task(self.heartbeat())
        try:
            while True:
                msg = await read_msg(self.reader)
                if msg is None:
                    break
                if msg.get("type") == "pong":
                    pass
        finally:
            await self.close()

    async def on_visitor(self, name, reader, writer):
        set_nodelay(writer)
        sid = f"{next(self._counter)}-{secrets.token_hex(4)}"
        sess = TunnelSession(reader, writer)
        self.sessions[sid] = sess
        try:
            await send_msg(self.writer, {"type": "new_conn", "tunnel": name, "session": sid})
            await asyncio.wait_for(sess.event.wait(), timeout=15)
        except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError):
            log("SERVER", f"隧道 {name} 会话 {sid} 等待数据通道超时")
            writer.close()
            self.sessions.pop(sid, None)

    async def attach_data(self, sid, reader, writer) -> bool:
        sess = self.sessions.pop(sid, None)
        if not sess:
            return False
        sess.event.set()
        asyncio.create_task(bidirectional(sess.visitor_reader, sess.visitor_writer,
                                          reader, writer, on_data=self.server.add_bytes))
        return True

    async def heartbeat(self):
        while self.alive:
            await asyncio.sleep(PING_INTERVAL)
            try:
                await send_msg(self.writer, {"type": "ping"})
            except Exception:
                break

    async def close(self):
        self.alive = False
        for srv in self.listeners:
            srv.close()
        for name in self.tunnels:
            log("SERVER", f"隧道 {name} 已下线")
        try:
            self.writer.close()
        except Exception:
            pass


class TunnelServer:
    def __init__(self, host, port, token, admin_port=7500, max_sessions_per_client=256):
        self.host, self.port, self.token = host, port, token
        self.admin_port = admin_port
        self.max_sessions = max_sessions_per_client
        self.clients = []               # 活跃的 ClientAgent
        self.bytes_total = 0
        self.started_at = time.time()

    # ---------- 统计 ----------
    def add_bytes(self, n):
        self.bytes_total += n

    def status(self):
        tunnels, sessions = [], 0
        for agent in self.clients:
            sessions += len(agent.sessions)
            online_ports = {srv.sockets[0].getsockname()[1] for srv in agent.listeners if srv.sockets}
            for name, t in agent.tunnels.items():
                tunnels.append({
                    "name": name, "remote_port": int(t["remote_port"]),
                    "local_host": t["local_host"], "local_port": int(t["local_port"]),
                    "client": str(agent.peer[0]) if agent.peer else "-",
                    "online": int(t["remote_port"]) in online_ports,
                })
        return {"uptime": int(time.time() - self.started_at), "clients": len(self.clients),
                "tunnels": tunnels, "sessions": sessions, "bytes_total": self.bytes_total}

    # ---------- 配置持久化 ----------
    def config(self):
        return {"port": self.port, "admin_port": self.admin_port,
                "token": self.token, "max_sessions": self.max_sessions}

    def save_config(self, cfg):
        self.token = str(cfg["token"])
        self.max_sessions = int(cfg["max_sessions"])
        # 端口修改需重启生效，仅持久化
        self.port = int(cfg["port"])
        self.admin_port = int(cfg["admin_port"])
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(self.config(), f, ensure_ascii=False, indent=2)
        log("SERVER", "配置已更新并写入 server_config.json")

    # ---------- 隧道协议 ----------
    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        set_nodelay(writer)
        try:
            msg = await asyncio.wait_for(read_msg(reader), timeout=10)
            if not msg or msg.get("version", 1) > PROTO_VERSION:
                writer.close()
                return
            mtype = msg.get("type")
            proof = make_token_proof(self.token, msg.get("nonce", ""))
            if msg.get("proof") != proof:
                log("SERVER", f"{peer} 认证失败，已断开")
                writer.close()
                return
            if mtype == "auth":
                await self.handle_client(reader, writer, msg, peer)
            elif mtype == "data":
                await self.handle_data(reader, writer, msg, peer)
        except (asyncio.TimeoutError, ValueError):
            writer.close()

    async def handle_client(self, reader, writer, msg, peer):
        tunnels = {t["name"]: t for t in msg.get("tunnels", [])}
        if not tunnels:
            await send_msg(writer, {"type": "error", "msg": "no tunnels declared"})
            writer.close()
            return
        log("SERVER", f"客户端 {peer} 已认证，注册 {len(tunnels)} 条隧道")
        agent = ClientAgent(self, reader, writer, tunnels, peer)
        self.clients.append(agent)
        try:
            await send_msg(writer, {"type": "auth_ok"})
            await agent.start()
        finally:
            if agent in self.clients:
                self.clients.remove(agent)
            log("SERVER", f"客户端 {peer} 已断开")

    async def handle_data(self, reader, writer, msg, peer):
        sid = msg.get("session", "")
        for agent in self.clients:
            if sid in agent.sessions:
                if len(agent.sessions) > self.max_sessions:
                    writer.close()
                    return
                if await agent.attach_data(sid, reader, writer):
                    return
        writer.close()

    # ---------- Web 管理控制台 ----------
    async def handle_admin(self, reader, writer):
        try:
            request = await asyncio.wait_for(reader.read(65536), timeout=10)
            head, _, body = request.partition(b"\r\n\r\n")
            line = head.split(b"\r\n", 1)[0].decode(errors="replace")
            method, _, rest = line.partition(" ")
            path = rest.split(" ")[0]
            status, ctype, payload = self.route(method, path, body)
        except Exception:
            status, ctype, payload = "400 Bad Request", "text/plain", b"bad request"
        resp = (f"HTTP/1.1 {status}\r\nContent-Type: {ctype}; charset=utf-8\r\n"
                f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n").encode() + payload
        writer.write(resp)
        await writer.drain()
        writer.close()

    def route(self, method, path, body):
        if path in ("/", "/index.html"):
            return "200 OK", "text/html", ADMIN_HTML.encode()
        if path == "/api/status":
            return "200 OK", "application/json", json.dumps(self.status()).encode()
        if path == "/api/config":
            if method == "GET":
                return "200 OK", "application/json", json.dumps(self.config()).encode()
            if method == "POST":
                try:
                    cfg = json.loads(body.decode())
                    assert cfg["token"] and int(cfg["port"]) > 0
                except (ValueError, KeyError, AssertionError):
                    return "400 Bad Request", "application/json", b'{"error":"invalid config"}'
                self.save_config(cfg)
                return "200 OK", "application/json", b'{"ok":true}'
        return "404 Not Found", "text/plain", b"not found"

    async def run(self):
        srv = await asyncio.start_server(self.handle, self.host, self.port)
        admin = await asyncio.start_server(self.handle_admin, self.host, self.admin_port)
        log("SERVER", f"控制端口监听于 {self.host}:{self.port}")
        log("SERVER", f"管理控制台: http://{self.host}:{self.admin_port}/")
        async with srv, admin:
            await asyncio.gather(srv.serve_forever(), admin.serve_forever())


def main():
    p = argparse.ArgumentParser(prog="tunnel-server", description="内网穿透服务端")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, default=None, help="控制/数据复用端口（默认 7000）")
    p.add_argument("--token", default=None, help="预共享令牌")
    p.add_argument("--admin-port", type=int, default=None, help="管理控制台端口（默认 7500）")
    args = p.parse_args()

    cfg = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg = json.load(f)
    port = args.port or cfg.get("port", 7000)
    token = args.token or cfg.get("token")
    admin_port = args.admin_port or cfg.get("admin_port", 7500)
    if not token:
        p.error("必须通过 --token 或 server_config.json 提供令牌")

    try:
        asyncio.run(TunnelServer(args.bind, port, token, admin_port,
                                 cfg.get("max_sessions", 256)).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
