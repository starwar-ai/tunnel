#requires -Version 5.1
<#
.SYNOPSIS
  Intranet Tunnel 客户端 Windows 一键安装程序
.DESCRIPTION
  用户级安装（无需管理员）：复制程序到 %LOCALAPPDATA%\intranet-tunnel，
  注册"计划任务"实现登录自启 + 崩溃自动拉起。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-client.ps1
  powershell -ExecutionPolicy Bypass -File install-client.ps1 -Uninstall
  # 非交互：
  powershell -ExecutionPolicy Bypass -File install-client.ps1 -Server 1.2.3.4:7000 -Token xxx -Tunnels "web:8080:127.0.0.1:80","ssh:6000:127.0.0.1:22"
#>
param(
  [string]$Server,
  [string]$Token,
  [string[]]$Tunnels,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$AppName  = "intranet-tunnel"
$TaskName = "IntranetTunnelClient"
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[✓] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[✗] $m" -ForegroundColor Red; exit 1 }

# ---------- 卸载 ----------
if ($Uninstall) {
  Info "卸载 $AppName…"
  Stop-Process -Name "pythonw","python" -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -like "*$InstallDir*" } 
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
  Ok "已卸载"
  exit 0
}

# ---------- 检测 Python ----------
function Find-Python {
  foreach ($cmd in @("python.exe","pythonw.exe","py.exe")) {
    $p = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
  }
  return $null
}
$python = Find-Python
if (-not $python) {
  Info "未检测到 Python，尝试通过 winget 安装 Python 3.12…"
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    $python = Find-Python
  }
  if (-not $python) { Fail "请先从 https://www.python.org/downloads/ 安装 Python 3.9+（勾选 Add to PATH）后重试" }
}
Ok "Python 环境: $python"

# ---------- 交互式参数 ----------
if (-not $Server) { $Server = Read-Host "服务端地址 (host:port，例如 1.2.3.4:7000)" }
if (-not $Server -or $Server -notmatch ":\d+$") { Fail "服务端地址格式不正确" }
if (-not $Token)  { $Token  = Read-Host "访问令牌" }
if (-not $Token)  { Fail "令牌不能为空" }
if (-not $Tunnels) {
  $line = Read-Host "隧道（格式 name:公网端口:内网地址:内网端口，多条用空格分隔）"
  if (-not $line) { $line = "web:8080:127.0.0.1:80" }
  $Tunnels = $line -split "\s+"
}

# ---------- 安装文件 ----------
Info "安装文件到 $InstallDir …"
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item -Recurse -Force (Join-Path $SrcDir "tunnel") $InstallDir

# ---------- 计划任务（登录自启 + 自动拉起） ----------
$argList = @("-m","tunnel.client","--server",$Server,"--token",$Token)
foreach ($t in $Tunnels) { $argList += @("--tunnel", $t) }
$action = New-ScheduledTaskAction -Execute $python -Argument ($argList -join " ") -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
              -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description "Intranet Tunnel Client" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Ok "客户端已安装并启动"
Write-Host ""
Write-Host "  服务端:     $Server"
Write-Host "  隧道:       $($Tunnels -join ', ')"
Write-Host "  查看状态:   任务计划程序 -> $TaskName"
Write-Host "  手动控制:   Stop-ScheduledTask / Start-ScheduledTask -TaskName $TaskName"
Write-Host "  卸载:       powershell -ExecutionPolicy Bypass -File install-client.ps1 -Uninstall"
