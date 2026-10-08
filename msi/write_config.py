"""MSI 安装时调用：根据传入的 server/token/tunnels 生成 client.json。

用法: write_config.py <server> <token> <tunnels>
  tunnels 为空格分隔的 name:remote_port:local_host:local_port
  server 为空（""）且 client.json 已存在时，保留原配置不覆盖。
"""
import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, "client.json")


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else ""
    token = sys.argv[2] if len(sys.argv) > 2 else ""
    tunnels_raw = sys.argv[3] if len(sys.argv) > 3 else ""

    if not server and os.path.exists(CFG_PATH):
        return 0  # 保留用户已有配置

    tunnels = {}
    for item in tunnels_raw.split():
        try:
            name, rport, lhost, lport = item.split(":")
            tunnels[name] = {"remote_port": int(rport), "local_host": lhost,
                             "local_port": int(lport)}
        except ValueError:
            pass
    if not tunnels:
        tunnels = {"web": {"remote_port": 8080, "local_host": "127.0.0.1", "local_port": 80}}

    cfg = {"server": server or "SERVER_IP:7000", "token": token or "CHANGE_ME",
           "tunnels": tunnels}
    with open(CFG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
