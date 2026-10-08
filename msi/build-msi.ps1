#requires -Version 5.1
<#
.SYNOPSIS
  一键构建 Intranet Tunnel 客户端 MSI 安装包（在 Windows 上运行）
.DESCRIPTION
  1. 检测/安装 .NET SDK 与 WiX 6 工具链
  2. 下载嵌入式 Python 3.12 运行时（随包分发，目标机器无需装 Python）
  3. 打包客户端代码
  4. 编译生成 IntranetTunnelClient.msi
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build-msi.ps1
#>
$ErrorActionPreference = "Stop"
$MsiDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $MsiDir
$WorkDir = Join-Path $MsiDir "build"
$PyVersion = "3.12.7"

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[✓] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[✗] $m" -ForegroundColor Red; exit 1 }

# ---------- 1. .NET SDK ----------
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
  Info "安装 .NET SDK 8…"
  winget install -e --id Microsoft.DotNet.SDK.8 --accept-source-agreements --accept-package-agreements
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("Path","User")
}
(Get-Command dotnet -ErrorAction SilentlyContinue) | Out-Null
if (-not $?) { Fail "未找到 dotnet，请手动安装 .NET SDK 8" }
Ok ".NET: $(dotnet --version)"

# ---------- 2. WiX 6 ----------
$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix -or -not (wix --version 2>$null | Select-String "^6\.")) {
  Info "安装 WiX 6.0.2…"
  dotnet tool install --global wix --version 6.0.2 2>$null
  if ($LASTEXITCODE -ne 0) { dotnet tool update --global wix --version 6.0.2 }
  $env:Path += ";$env:USERPROFILE\.dotnet\tools"
}
Push-Location $MsiDir
wix extension add WixToolset.Util.wixext/6.0.2 | Out-Null
Ok "WiX: $(wix --version)"

# ---------- 3. 嵌入式 Python ----------
$pyZip = Join-Path $WorkDir "pyembed.zip"
$pyDir = Join-Path $WorkDir "pyrt"
New-Item -ItemType Directory -Force $WorkDir | Out-Null
if (-not (Test-Path (Join-Path $pyDir "pythonw.exe"))) {
  Info "下载嵌入式 Python $PyVersion…"
  $urls = @(
    "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip",
    "https://mirrors.huaweicloud.com/python/$PyVersion/python-$PyVersion-embed-amd64.zip",
    "https://registry.npmmirror.com/-/binary/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
  )
  foreach ($u in $urls) {
    try { Invoke-WebRequest -Uri $u -OutFile $pyZip -UseBasicParsing -TimeoutSec 120; break }
    catch { Info "镜像失败，尝试下一个: $u" }
  }
  if (-not (Test-Path $pyZip)) { Fail "Python 运行时下载失败" }
  Expand-Archive -Force $pyZip $pyDir
}
Ok "Python 运行时就绪"

# ---------- 4. 打包客户端 ----------
$appDir = Join-Path $WorkDir "app"
if (Test-Path $appDir) { Remove-Item -Recurse -Force $appDir }
New-Item -ItemType Directory -Force $appDir | Out-Null
Copy-Item -Recurse (Join-Path $RootDir "tunnel") $appDir
Copy-Item (Join-Path $MsiDir "run_client.py") $appDir
Copy-Item (Join-Path $MsiDir "write_config.py") $appDir
Ok "客户端文件已打包"

# ---------- 5. 编译 MSI ----------
Info "编译 MSI…"
Push-Location $WorkDir
wix build (Join-Path $MsiDir "Package.wxs") -ext WixToolset.Util.wixext -arch x64 `
  -o (Join-Path $MsiDir "IntranetTunnelClient.msi")
Pop-Location
Pop-Location

$msi = Join-Path $MsiDir "IntranetTunnelClient.msi"
if (-not (Test-Path $msi)) { Fail "MSI 编译失败" }
Ok "生成成功: $msi"
Write-Host ""
Write-Host "安装（交互式）：双击 msi，装完编辑 C:\Program Files\IntranetTunnel\app\client.json"
Write-Host "安装（静默带参）："
Write-Host '  msiexec /i IntranetTunnelClient.msi /qn SERVER=1.2.3.4:7000 TOKEN=xxx TUNNELS="web:8080:127.0.0.1:80"'
Write-Host "卸载：msiexec /x IntranetTunnelClient.msi"
