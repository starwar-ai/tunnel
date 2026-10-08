#!/usr/bin/env bash
# Intranet Tunnel 一键安装程序
# 用法:
#   sudo bash install.sh            # 交互式安装
#   sudo bash install.sh uninstall  # 卸载
# 非交互模式（环境变量）:
#   MODE=server TOKEN=xxx sudo -E bash install.sh
#   MODE=client SERVER=1.2.3.4:7000 TOKEN=xxx TUNNELS="web:8080:127.0.0.1:80" sudo -E bash install.sh
set -euo pipefail

APP_NAME="intranet-tunnel"
INSTALL_DIR="/opt/${APP_NAME}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[✓]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[✗]\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || fail "请以 root 运行（sudo bash install.sh）"

uninstall() {
  info "卸载 ${APP_NAME}…"
  for u in tunnel-server tunnel-client; do
    systemctl disable --now "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/${u}.service"
  done
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  ok "已卸载（配置与程序均已移除）"
  exit 0
}
[[ "${1:-}" == "uninstall" ]] && uninstall

command -v systemctl >/dev/null || fail "本安装程序需要 systemd（Ubuntu 16.04+/Debian 8+/CentOS 7+）"

# Ubuntu/Debian 自动补装 Python 3（Ubuntu 22.04 默认自带 3.10，通常无需此步）
if ! command -v python3 >/dev/null; then
  if command -v apt-get >/dev/null; then
    info "未检测到 python3，正在通过 apt 安装…"
    apt-get update -qq && apt-get install -y -qq python3
  else
    fail "未找到 python3，请先安装 Python 3.9+"
  fi
fi
ok "Python 环境: $(python3 --version)"

# ---------- 交互式参数 ----------
prompt() {  # prompt VAR "提示" "默认值" [secret]
  local var="$1" text="$2" def="${3:-}"
  if [[ -z "${!var:-}" ]]; then
    read -rp "$text${def:+ [$def]}: " "$var"
    [[ -z "${!var}" ]] && printf -v "$var" '%s' "$def"
  fi
}

echo "==============================================="
echo "   Intranet Tunnel 安装程序"
echo "==============================================="
echo "  1) server  - 安装为服务端（公网服务器）"
echo "  2) client  - 安装为客户端（内网机器）"
prompt MODE "请选择安装模式 (server/client)" "server"

if [[ "$MODE" == "server" ]]; then
  prompt PORT "控制端口" "7000"
  prompt ADMIN_PORT "管理控制台端口" "7500"
  prompt TOKEN "访问令牌（留空自动生成）" ""
  if [[ -z "$TOKEN" ]]; then
    TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    info "已生成令牌: $TOKEN  （请妥善保存，客户端需要使用）"
  fi
else
  prompt SERVER "服务端地址 (host:port)" ""
  [[ -n "$SERVER" ]] || fail "服务端地址不能为空"
  prompt TOKEN "访问令牌" ""
  [[ -n "$TOKEN" ]] || fail "令牌不能为空"
  prompt TUNNELS "隧道（格式 name:公网端口:内网地址:内网端口，多条用空格分隔）" "web:8080:127.0.0.1:80"
fi

# ---------- 安装文件 ----------
info "安装文件到 $INSTALL_DIR …"
mkdir -p "$INSTALL_DIR"
cp -r "$SRC_DIR/tunnel" "$INSTALL_DIR/"
cp -f "$SRC_DIR/README.md" "$INSTALL_DIR/" 2>/dev/null || true

# ---------- 生成配置与 systemd 单元 ----------
if [[ "$MODE" == "server" ]]; then
  cat > "$INSTALL_DIR/server_config.json" <<EOF
{
  "port": $PORT,
  "admin_port": $ADMIN_PORT,
  "token": "$TOKEN",
  "max_sessions": 256
}
EOF
  cat > /etc/systemd/system/tunnel-server.service <<EOF
[Unit]
Description=Intranet Tunnel Server
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$INSTALL_DIR
Environment=TUNNEL_SERVER_CONFIG=$INSTALL_DIR/server_config.json
ExecStart=$(command -v python3) -m tunnel.server
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  # Ubuntu 默认防火墙 ufw：询问是否放行端口
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    read -rp "检测到 ufw 已启用，是否放行控制端口 $PORT 和管理端口 $ADMIN_PORT？(Y/n) " UFW_OK
    if [[ "${UFW_OK:-Y}" != [nN] ]]; then
      ufw allow "$PORT"/tcp && ufw allow "$ADMIN_PORT"/tcp
      ok "ufw 已放行 $PORT、$ADMIN_PORT（隧道公网端口请按需自行 ufw allow）"
    fi
  else
    info "提示：如启用了 ufw/云安全组，请放行端口 $PORT（控制）与 $ADMIN_PORT（管理台）"
  fi

  systemctl daemon-reload
  systemctl enable --now tunnel-server
  ok "服务端已启动"
  echo
  echo "  控制端口:     $PORT"
  echo "  管理控制台:   http://<本机IP>:$ADMIN_PORT/"
  echo "  令牌:         $TOKEN"
  echo "  查看日志:     journalctl -u tunnel-server -f"
else
  CLIENT_ARGS=()
  for t in $TUNNELS; do CLIENT_ARGS+=(--tunnel "$t"); done
  cat > /etc/systemd/system/tunnel-client.service <<EOF
[Unit]
Description=Intranet Tunnel Client
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$(command -v python3) -m tunnel.client --server $SERVER --token $TOKEN ${CLIENT_ARGS[*]}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tunnel-client
  ok "客户端已启动并注册隧道: $TUNNELS"
  echo "  查看日志: journalctl -u tunnel-client -f"
fi

echo
ok "安装完成。卸载: sudo bash $SRC_DIR/install.sh uninstall"
