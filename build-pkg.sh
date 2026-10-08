#!/usr/bin/env bash
# 构建 macOS 菜单栏版客户端安装包（安装 /Applications/IntranetTunnel.app）
# 可选签名:  SIGN_ID="Developer ID Installer: Your Name (TEAMID)" bash build-pkg.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
APP="$WORK/root/Applications/IntranetTunnel.app"
CONT="$APP/Contents"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$CONT/MacOS" "$CONT/Resources" "$WORK/scripts"

# 1) 编译菜单栏应用（优先通用二进制，失败则回退 arm64）
if ! swiftc -parse-as-library -O "$SRC_DIR/macos-app/main.swift" \
      -o "$CONT/MacOS/IntranetTunnel" -target universal-apple-macos13.0 2>/dev/null; then
  echo "（通用二进制编译失败，回退仅 arm64）"
  swiftc -parse-as-library -O "$SRC_DIR/macos-app/main.swift" \
    -o "$CONT/MacOS/IntranetTunnel" -target arm64-apple-macos13.0
fi

# 2) Python 隧道代码打进 app 资源目录
# -X: 不拷贝扩展属性，避免包里混入 ._* AppleDouble 文件
COPYFILE_DISABLE=1 cp -R -X "$SRC_DIR/tunnel" "$CONT/Resources/tunnel"
find "$CONT/Resources" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

cat > "$CONT/Resources/run_client.py" <<'EOF'
import os, sys
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
from tunnel.client import main
args = sys.argv[1:]
if "--config" not in args:
    args += ["--config", os.path.join(BASE, "client.json")]
sys.argv = [sys.argv[0]] + args
main()
EOF

cat > "$CONT/Resources/client.template.json" <<'EOF'
{
  "server": "SERVER_IP:7000",
  "token": "CHANGE_ME",
  "tunnels": {
    "web": { "remote_port": 8080, "local_host": "127.0.0.1", "local_port": 80 }
  }
}
EOF

# 2b) 应用图标（AppKit 绘制 iconset → icns）
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$SRC_DIR/macos-app/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONT/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 3) Info.plist（LSUIElement: 仅菜单栏，不占 Dock）
cat > "$CONT/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>IntranetTunnel</string>
  <key>CFBundleIdentifier</key><string>com.intranet-tunnel.clientapp</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>IntranetTunnel</string>
  <key>CFBundleDisplayName</key><string>内网穿透</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>1.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# 4) ad-hoc 签名（arm64 平台要求可执行文件至少具有 ad-hoc 签名）
codesign --force --sign - "$APP"

# 5) postinstall：清理旧版 LaunchDaemon 并迁移配置
cp "$SRC_DIR/pkg_scripts/postinstall" "$WORK/scripts/postinstall"
chmod +x "$WORK/scripts/postinstall"

# 6) 打包
ARGS=(--root "$WORK/root" --scripts "$WORK/scripts"
      --identifier com.intranet-tunnel.client.pkg --version 1.1.0
      --install-location /)
if [[ -n "${SIGN_ID:-}" ]]; then
  ARGS+=(--sign "$SIGN_ID")
fi
pkgbuild "${ARGS[@]}" "$SRC_DIR/IntranetTunnelClient.pkg"

echo "✓ 生成: $SRC_DIR/IntranetTunnelClient.pkg"
if [[ -n "${SIGN_ID:-}" ]]; then
  echo "已签名。公证: xcrun notarytool submit IntranetTunnelClient.pkg --apple-id ... --team-id ... --wait"
fi
