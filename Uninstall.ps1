#Requires -Version 5.1
<#
================================================================================
 Uninstall.ps1  ——  完整回滚（瘦包装器）
================================================================================
 注销稀疏包 → 还原开发人员模式 → 移除自签名证书 → 卸载自动装的 SDK →
 校验原厂注册 → 清理暂存目录 → 重启 explorer。
 本脚本不会触碰 HKLM\SOFTWARE\Classes 下任何原厂键值。
 真实逻辑见 MiDrop-Menu.ps1（点源载入）。

 用法（管理员 PowerShell）：
   powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1
 可选开关：
   -KeepBackup         保留 C:\ProgramData\MiDropWin11Menu\backup 下的注册表备份（默认会删除）
   -KeepDeveloperMode  不动「开发人员模式」开关
   -KeepSdk            保留 Windows SDK（即使它由本工具自动安装）
   -NoRestartExplorer  不重启 explorer.exe
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$KeepBackup,
    [switch]$KeepDeveloperMode,
    [switch]$KeepSdk,
    [switch]$NoRestartExplorer
)

$ErrorActionPreference = 'Continue'
$main = Join-Path $PSScriptRoot 'MiDrop-Menu.ps1'
if (-not (Test-Path -LiteralPath $main)) { Write-Host '[ X ] 找不到 MiDrop-Menu.ps1（应与本文件同目录）' -ForegroundColor Red; exit 1 }
. $main   # 点源：载入全部函数（被点源时主脚本不会弹菜单）

Invoke-Uninstall -KeepBackup:$KeepBackup -KeepDeveloperMode:$KeepDeveloperMode -KeepSdk:$KeepSdk -NoRestartExplorer:$NoRestartExplorer
