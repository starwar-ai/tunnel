"""MSI 安装后的客户端启动入口：加载同目录 client.json 并启动隧道客户端。"""
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

from tunnel.client import main  # noqa: E402

sys.argv = [sys.argv[0], "--config", os.path.join(BASE, "client.json")]
main()
