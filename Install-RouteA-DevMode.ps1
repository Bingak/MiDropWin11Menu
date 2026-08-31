#Requires -Version 5.1
<#
================================================================================
 Install-RouteA-DevMode.ps1  ——  路线 A 命令行版（瘦包装器）
================================================================================
 把「使用小米互传发送」提升到 Windows 11 新版右键菜单第一层。
 注册未签名松散文件稀疏包，需要开启系统「开发人员模式」（唯一全局开关改动）。
 真实逻辑见 MiDrop-Menu.ps1（点源载入）。

 用法（管理员 PowerShell）：
   powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1
   powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1 -EnableDeveloperMode
   powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1 -NoRestartExplorer
================================================================================
#>
[CmdletBinding()]
param(
    # 自动写入 AllowDevelopmentWithoutDevLicense = 1（否则检测到未开启会中止并提示）
    [switch]$EnableDeveloperMode,
    # 跳过重启 explorer.exe（改为自行注销重登）
    [switch]$NoRestartExplorer
)

$ErrorActionPreference = 'Continue'
$main = Join-Path $PSScriptRoot 'MiDrop-Menu.ps1'
if (-not (Test-Path -LiteralPath $main)) { Write-Host '[ X ] 找不到 MiDrop-Menu.ps1（应与本文件同目录）' -ForegroundColor Red; exit 1 }
. $main   # 点源：载入全部函数（被点源时主脚本不会弹菜单）

Invoke-InstallRouteA -EnableDeveloperMode:$EnableDeveloperMode -NoRestartExplorer:$NoRestartExplorer
