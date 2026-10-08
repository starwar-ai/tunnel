# intranet-tunnel — 轻量级内网穿透工具

纯 Python 标准库实现（asyncio），零依赖，支持多隧道 TCP 转发、令牌认证、心跳保活与断线自动重连。适用于将内网的 Web、SSH、RDP、数据库等任意 TCP 服务安全地暴露到公网服务器。

## 架构

```
访问者 ──► 公网服务器 (tunnel-server) ◄── 控制/数据通道 ── 内网客户端 (tunnel-client) ──► 内网服务
```

- 单端口复用：控制信令与数据通道共用服务端一个端口（默认 7000），只需在防火墙放行一个端口。
- 反向连接：客户端主动外连服务器，NAT/防火墙后的机器无需入站规则。
- 按需建链：每个访问者连接触发一条独立数据通道，支持高并发。
- 认证：基于 `sha256(token:nonce)` 的挑战-响应校验，令牌不以明文形式作为唯一凭证反复传输。

## 快速开始

### 1. 公网服务器

```bash
python3 -m tunnel.server --port 7000 --token 'your-strong-token'
```

### 2. 内网客户端

方式一：命令行快捷隧道

```bash
python3 -m tunnel.client --server your-server-ip:7000 --token 'your-strong-token' \
    --tunnel web:8080:127.0.0.1:80 \
    --tunnel ssh:6000:127.0.0.1:22
```

方式二：配置文件（参考 `client.example.json`）

```bash
python3 -m tunnel.client --server your-server-ip:7000 --token 'your-strong-token' \
    --config client.json
```

之后访问 `your-server-ip:8080` 即等同访问内网的 `127.0.0.1:80`。

## Web 管理控制台

服务端启动后访问 `http://服务器IP:7500/`（可用 `--admin-port` 修改）：

- **实时仪表盘**：运行时长、在线客户端、活跃隧道、进行中会话、总转发流量（5s 自动刷新）
- **隧道列表**：每条隧道的公网端口、内网目标、来源客户端与在线状态
- **在线配置**：控制端口、管理端口、访问令牌、单客户端最大并发会话数；保存后写入 `server_config.json`（令牌与会话数即时生效，端口重启生效）

## 一键安装（Ubuntu 22.04 LTS 推荐）

Ubuntu 22.04 自带 Python 3.10 与 systemd，直接执行：

```bash
# 1. 上传源码到服务器
scp -r intranet_tunnel root@<服务器IP>:/root/

# 2. 安装（选择 server，回车确认端口，令牌可自动生成）
cd intranet_tunnel
sudo bash install.sh

# 3. 验证
systemctl status tunnel-server
journalctl -u tunnel-server -f   # 实时日志
```

安装程序针对 Ubuntu 22.04 自动处理：
- 检测/补装 Python 3（`apt-get install python3`）
- 检测到 **ufw** 启用时，交互式放行控制端口与管理端口（隧道公网端口按需 `sudo ufw allow 8080/tcp`）
- 创建 `tunnel-server.service`（`After=network-online.target`），开机自启、崩溃 3 秒自动重启

> 云服务器（阿里云/腾讯云/AWS 等）还需在**控制台安全组**放行：控制端口（默认 7000）、管理端口（默认 7500）、各隧道公网端口。

### Windows 客户端（MSI 安装包）

MSI 工程位于 `msi/` 目录，在任意 Windows 机器上一条命令构建：

```powershell
powershell -ExecutionPolicy Bypass -File msi\build-msi.ps1
# 产物: msi\IntranetTunnelClient.msi
```

构建脚本自动完成：安装 .NET SDK 与 WiX 6 工具链 → 下载嵌入式 Python 3.12 运行时（**目标机器无需安装 Python**）→ 打包 → 编译。

生成的 MSI 特性：

- 安装到 `C:\Program Files\IntranetTunnel`，自带 Python 运行时，开箱即用
- 安装时自动生成 `client.json` 并注册**登录自启计划任务**，装完立即启动
- 卸载时自动停止并删除计划任务
- 支持**静默批量部署**（域控 GPO / SCCM / Intune 推送）：

```cmd
msiexec /i IntranetTunnelClient.msi /qn SERVER=1.2.3.4:7000 TOKEN=xxx TUNNELS="web:8080:127.0.0.1:80 rdp:6389:127.0.0.1:3389"
```

> 未传参安装时，装完编辑 `C:\Program Files\IntranetTunnel\app\client.json`，
> 然后 `schtasks /run /tn IntranetTunnelClient` 即可。

### Windows 客户端（免安装脚本）

无需管理员权限，PowerShell 执行：

```powershell
# 交互式安装（自动检测 Python，缺失时尝试 winget 安装）
powershell -ExecutionPolicy Bypass -File install-client.ps1

# 非交互
powershell -ExecutionPolicy Bypass -File install-client.ps1 `
    -Server 1.2.3.4:7000 -Token mytoken -Tunnels "web:8080:127.0.0.1:80","rdp:6389:127.0.0.1:3389"

# 卸载
powershell -ExecutionPolicy Bypass -File install-client.ps1 -Uninstall
```

安装到 `%LOCALAPPDATA%\intranet-tunnel`，通过**计划任务**（`IntranetTunnelClient`）实现登录自启，进程退出后 1 分钟自动拉起。

### macOS 客户端（.pkg 安装包 · 菜单栏应用）

仓库根目录已提供构建好的 **`IntranetTunnelClient.pkg`**，双击安装（需管理员权限，macOS 13+）。安装后从「应用程序」打开 **IntranetTunnel**，顶部状态栏出现隧道图标：

- **状态栏图标**：⇅ 实心 = 已连接；⇅ 空心 = 连接中/断线重连；⏸ = 已关闭
- **一键开关**：菜单里「开启隧道 / 关闭隧道」，客户端进程随 app 托管、崩溃自动拉起
- **配置窗口**：菜单「配置…」图形化编辑服务器地址、令牌、隧道规则，保存后自动生效（无需改 JSON、无需 sudo）
- **运行日志**：菜单「查看日志…」实时查看连接与转发日志
- **开机自启**：菜单勾选即可（SMAppService 登录项）

配置文件位于 `~/Library/Application Support/intranet-tunnel/client.json`（无需管理员权限）。隧道由 app 以子进程方式运行系统自带 python3（已兼容 3.9+），不再注册后台 LaunchDaemon。

- 从旧版（LaunchDaemon 版）升级：安装新版 pkg 时自动停用并清理旧守护进程，旧 `client.json` 自动迁移到用户目录
- 卸载：退出 app 后 `sudo rm -rf /Applications/IntranetTunnel.app && rm -rf ~/Library/Application\ Support/intranet-tunnel`

在 Mac 上重建（需要 Xcode 命令行工具提供 swiftc，可带开发者签名）：

```bash
bash build-pkg.sh                                            # 未签名（ad-hoc）
SIGN_ID="Developer ID Installer: Your Name (TEAMID)" bash build-pkg.sh   # 签名
```

> 默认构建 arm64（Apple Silicon）；如需 Intel 支持请用完整 Xcode 工具链构建 universal。
> 企业分发（MDM/Apple Business Manager 推送）建议先签名并公证（notarytool）。

### macOS 客户端（免安装脚本）

无需 sudo：

```bash
# 交互式安装（无 Python 时尝试 Homebrew 安装）
bash install-client-mac.sh

# 非交互
SERVER=1.2.3.4:7000 TOKEN=mytoken TUNNELS="web:8080:127.0.0.1:80" bash install-client-mac.sh

# 卸载
bash install-client-mac.sh uninstall
```

安装到 `~/Library/Application Support/intranet-tunnel`，通过 **launchd LaunchAgent** 登录自启、`KeepAlive` 崩溃自动拉起，日志在 `~/Library/Logs/intranet-tunnel/`。

### Linux 客户端 / 其他方式

```bash
# 非交互安装
MODE=server TOKEN=mytoken sudo -E bash install.sh
MODE=client SERVER=1.2.3.4:7000 TOKEN=mytoken TUNNELS="web:8080:127.0.0.1:80" sudo -E bash install.sh

# 卸载
sudo bash install.sh uninstall
```

安装后程序位于 `/opt/intranet-tunnel`，服务端配置在 `/opt/intranet-tunnel/server_config.json`。

## 功能特性

| 特性 | 说明 |
|---|---|
| 多隧道 | 单客户端可同时注册任意多条隧道 |
| 令牌认证 | 服务端逐条校验，认证失败立即断开 |
| 心跳保活 | 25s 心跳，防止 NAT 会话老化断链 |
| 自动重连 | 客户端断线后 3s 重连，隧道自动重新上线 |
| 并发转发 | 每访问连接独立数据通道，asyncio 单进程高并发 |
| 端口冲突处理 | 公网端口被占用时仅该隧道下线并通知客户端，不影响其余隧道 |

## 生产部署建议

1. **使用强令牌**（32 位以上随机字符串），并定期更换。
2. 当前版本为明文 TCP 协议，建议外层套 **TLS 终结**（如 stunnel、Nginx stream ssl）或跑在 WireGuard/SSH 隧道之上；如需原生 TLS，可在 `asyncio.start_server` / `open_connection` 中传入 `ssl=` 上下文，代码已为此预留结构。
3. 用 systemd 托管：

```ini
# /etc/systemd/system/tunnel-server.service
[Service]
ExecStart=/usr/bin/python3 -m tunnel.server --port 7000 --token 'xxx'
WorkingDirectory=/opt/intranet_tunnel
Restart=always
```

4. 在服务端安全组中只放行控制端口与需要暴露的隧道端口。

## 文件结构

```
intranet_tunnel/
├── tunnel/
│   ├── common.py      # 协议与转发公共模块
│   ├── server.py      # 服务端（含 Web 管理控制台）
│   ├── client.py      # 客户端
│   └── admin_page.py  # 管理控制台页面
├── IntranetTunnelClient.pkg  # macOS 安装包（已构建，可直接分发）
├── build-pkg.sh              # macOS 原生重建 pkg（编译菜单栏 app + 打包）
├── macos-app/main.swift      # macOS 菜单栏应用源码（SwiftUI）
├── pkg_scripts/postinstall   # pkg 安装后脚本（旧版清理与配置迁移）
├── msi/                  # Windows MSI 安装包工程（WiX 6）
│   ├── build-msi.ps1     #   一键构建脚本（在 Windows 上运行）
│   ├── Package.wxs       #   WiX 包定义
│   ├── run_client.py     #   MSI 启动入口
│   └── write_config.py   #   安装时生成 client.json
├── install.sh            # 服务端一键安装（Ubuntu/Debian/CentOS，systemd）
├── install-client.ps1    # Windows 客户端一键安装（计划任务）
├── install-client-mac.sh # macOS 客户端一键安装（launchd）
├── client.example.json
└── README.md
```

## 已验证

- ✅ 本地端到端转发（HTTP 经隧道访问返回 200）
- ✅ 错误令牌被拒绝，隧道不建立
- ✅ 断线重连与多端隧道注册
# tunnel
