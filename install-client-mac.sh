#!/usr/bin/env bash
# Intranet Tunnel 客户端 macOS 一键安装程序
# 用户级安装（无需 sudo）：launchd LaunchAgent 实现登录自启 + 崩溃自动拉起
#
# 用法:
#   bash install-client-mac.sh             # 交互式安装
#   bash install-client-mac.sh uninstall   # 卸载
# 非交互:
#   SERVER=1.2.3.4:7000 TOKEN=xxx TUNNELS="web:8080:127.0.0.1:80" bash install-client-mac.sh
set -euo pipefail

APP_NAME="intranet-tunnel"
LABEL="com.intranet-tunnel.client"
INSTALL_DIR="$HOME/Library/Application Support/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[✓]\033[0m $*"; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*"; exit 1; }

if [[ "${1:-}" == "uninstall" ]]; then
  info "卸载 $APP_NAME…"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
    launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR" "$LOG_DIR"
  ok "已卸载"
  exit 0
fi

# ---------- 检测 Python ----------
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  if command -v brew >/dev/null; then
    info "未检测到 python3，正在通过 Homebrew 安装…"
    brew install python@3.12
    PYTHON="$(command -v python3)"
  else
    fail "未找到 python3。请先安装 Xcode 命令行工具（xcode-select --install）或 Homebrew 后重试"
  fi
fi
ok "Python 环境: $($PYTHON --version)"

# ---------- 交互式参数 ----------
prompt() {
  local var="$1" text="$2" def="${3:-}"
  if [[ -z "${!var:-}" ]]; then
    read -rp "$text${def:+ [$def]}: " "$var"
    [[ -z "${!var}" ]] && printf -v "$var" '%s' "$def"
  fi
}

prompt SERVER "服务端地址 (host:port，例如 1.2.3.4:7000)" ""
[[ "$SERVER" =~ :[0-9]+$ ]] || fail "服务端地址格式不正确"
prompt TOKEN "访问令牌" ""
[[ -n "$TOKEN" ]] || fail "令牌不能为空"
prompt TUNNELS "隧道（格式 name:公网端口:内网地址:内网端口，多条用空格分隔）" "web:8080:127.0.0.1:80"

# ---------- 安装文件 ----------
info "安装文件到 $INSTALL_DIR …"
mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$INSTALL_DIR/tunnel"
cp -R "$SRC_DIR/tunnel" "$INSTALL_DIR/"

# ---------- launchd LaunchAgent ----------
{
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>$LABEL</string>
  <key>WorkingDirectory</key>  <string>$INSTALL_DIR</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>-m</string>
    <string>tunnel.client</string>
    <string>--server</string>
    <string>$SERVER</string>
    <string>--token</string>
    <string>$TOKEN</string>
EOF
for t in $TUNNELS; do
  printf '    <string>--tunnel</string>\n    <string>%s</string>\n' "$t"
done
cat <<EOF
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>ThrottleInterval</key>  <integer>3</integer>
  <key>StandardOutPath</key>   <string>$LOG_DIR/client.log</string>
  <key>StandardErrorPath</key> <string>$LOG_DIR/client.err</string>
</dict>
</plist>
EOF
} > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  :
else
  launchctl load "$PLIST"   # macOS 旧版本兼容
fi

ok "客户端已安装并启动"
echo
echo "  服务端:   $SERVER"
echo "  隧道:     $TUNNELS"
echo "  日志:     $LOG_DIR/client.log"
echo "  控制:     launchctl kickstart -k gui/$(id -u)/$LABEL   # 重启"
echo "  卸载:     bash $SRC_DIR/install-client-mac.sh uninstall"
