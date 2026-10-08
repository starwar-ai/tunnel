"""内网穿透客户端：部署在内网机器上，断线自动重连。"""
import asyncio
import argparse
import json
import secrets

from .common import (send_msg, read_msg, make_token_proof, bidirectional,
                     set_nodelay, PROTO_VERSION, log)


class TunnelClient:
    def __init__(self, server_host, server_port, token, tunnels, reconnect_delay=3):
        self.server_host = server_host
        self.server_port = server_port
        self.token = token
        self.tunnels = tunnels          # {name: {remote_port, local_host, local_port}}
        self.reconnect_delay = reconnect_delay

    def _auth_msg(self, nonce):
        return {
            "type": "auth",
            "version": PROTO_VERSION,
            "nonce": nonce,
            "proof": make_token_proof(self.token, nonce),
            "tunnels": [{"name": n, **t} for n, t in self.tunnels.items()],
        }

    async def open_data_channel(self, tunnel_name, session_id):
        t = self.tunnels[tunnel_name]
        nonce = secrets.token_hex(16)
        try:
            s_reader, s_writer = await asyncio.open_connection(self.server_host, self.server_port)
            await send_msg(s_writer, {
                "type": "data", "version": PROTO_VERSION, "nonce": nonce,
                "proof": make_token_proof(self.token, nonce), "session": session_id,
            })
            l_reader, l_writer = await asyncio.open_connection(t["local_host"], int(t["local_port"]))
            set_nodelay(s_writer)
            set_nodelay(l_writer)
        except OSError as e:
            log("CLIENT", f"隧道 {tunnel_name} 建立数据通道失败: {e}")
            return
        log("CLIENT", f"隧道 {tunnel_name} 新连接 (session {session_id})")
        await bidirectional(s_reader, s_writer, l_reader, l_writer)

    async def session(self):
        nonce = secrets.token_hex(16)
        reader, writer = await asyncio.open_connection(self.server_host, self.server_port)
        set_nodelay(writer)
        await send_msg(writer, self._auth_msg(nonce))
        while True:
            msg = await read_msg(reader)
            if msg is None:
                break
            mtype = msg.get("type")
            if mtype == "auth_ok":
                log("CLIENT", f"已连接服务器 {self.server_host}:{self.server_port}")
            elif mtype == "tunnel_ok":
                log("CLIENT", f"隧道 {msg['name']} 就绪: 公网端口 {msg['remote_port']}")
            elif mtype == "error":
                log("CLIENT", f"服务端错误: {msg.get('msg')}")
            elif mtype == "ping":
                await send_msg(writer, {"type": "pong"})
            elif mtype == "new_conn":
                asyncio.create_task(self.open_data_channel(msg["tunnel"], msg["session"]))
        try:
            writer.close()
        except Exception:
            pass

    async def run(self):
        while True:
            try:
                await self.session()
            except (OSError, asyncio.TimeoutError, ValueError) as e:
                log("CLIENT", f"连接失败: {e}")
            log("CLIENT", f"{self.reconnect_delay} 秒后重连…")
            await asyncio.sleep(self.reconnect_delay)


def main():
    p = argparse.ArgumentParser(prog="tunnel-client", description="内网穿透客户端")
    p.add_argument("--server", help="服务器地址 host:port（也可写入配置文件）")
    p.add_argument("--token", help="访问令牌（也可写入配置文件）")
    p.add_argument("--config", help="JSON 配置文件（可定义 server/token/tunnels）")
    p.add_argument("--tunnel", action="append", default=[],
                   help="快捷隧道: name:remote_port:local_host:local_port，可重复")
    args = p.parse_args()

    tunnels = {}
    cfg = {}
    if args.config:
        with open(args.config, encoding="utf-8") as f:
            cfg = json.load(f)
        tunnels.update(cfg.get("tunnels", {}))
    server = args.server or cfg.get("server")
    token = args.token or cfg.get("token")
    if not server or not token:
        p.error("必须通过 --server/--token 或配置文件提供服务器地址与令牌")
    for item in args.tunnel:
        name, rport, lhost, lport = item.split(":")
        tunnels[name] = {"remote_port": int(rport), "local_host": lhost, "local_port": int(lport)}
    if not tunnels:
        p.error("至少定义一条隧道（--config 或 --tunnel）")

    host, _, port = server.rpartition(":")
    try:
        asyncio.run(TunnelClient(host, int(port), token, tunnels).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
