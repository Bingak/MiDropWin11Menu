#Requires -Version 5.1
<#
================================================================================
 Uninstall.ps1  ——  完整回滚（瘦包装器）
================================================================================
 注销稀疏包 → 还原开发人员模式 → 移除自签名证书 → 卸载自动装的 SDK →
 搜索并按需清理注册表 MiDropExtMenu 残留 → 清理暂存目录 → 重启 explorer。

 关于注册表（重要）：本脚本【只清理非原厂来源的 MiDropExtMenu 键】。
   - 小米原厂入口（ExplorerCommandHandler = {504d69c0-...}）一律【保留不删】，
     因此「显示更多选项」里的「使用小米互传发送」始终不受影响；
   - 只有 Handler 不等于该 CLSID 的键才被当作残留，默认询问、加 -PurgeRegistryVerbs 直接清理；
   - 清理前会先导出 .reg 备份，删过之后还会强制保留备份目录以便回滚。
 另：本方案的稀疏包只含 AppxManifest.xml，从不往注册表写 MiDropExtMenu，
     所以正常安装后再卸载，通常【根本不存在】非原厂残留需要清理。
 真实逻辑见 MiDrop-Menu.ps1（点源载入）。

 用法（管理员 PowerShell）：
   powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1
 可选开关：
   -KeepBackup         保留 C:\ProgramData\MiDropWin11Menu\backup 下的注册表备份（默认会删除）
   -KeepDeveloperMode  不动「开发人员模式」开关
   -KeepSdk            保留 Windows SDK（即使它由本工具自动安装）
   -NoRestartExplorer  不重启 explorer.exe
   -PurgeRegistryVerbs 确认清理非原厂残留键（不再询问；原厂入口仍保留不删）
   -KeepRegistryVerbs  跳过注册表搜索与清理（既不搜索也不删除）

 说明：regedit 里 HKCR 与 HKLM\SOFTWARE\Classes 下看到的 MiDropExtMenu 往往是
 【同一个物理键的两个视图】，并不是两份残留。搜索只在真实物理位置进行，不会重复计数：
   HKLM\SOFTWARE\Classes 、 HKCU\Software\Classes 、 HKLM\SOFTWARE\WOW6432Node\Classes
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$KeepBackup,
    [switch]$KeepDeveloperMode,
    [switch]$KeepSdk,
    [switch]$NoRestartExplorer,
    [switch]$PurgeRegistryVerbs,
    [switch]$KeepRegistryVerbs
)

$ErrorActionPreference = 'Continue'
$main = Join-Path $PSScriptRoot 'MiDrop-Menu.ps1'
if (-not (Test-Path -LiteralPath $main)) { Write-Host '[ X ] 找不到 MiDrop-Menu.ps1（应与本文件同目录）' -ForegroundColor Red; exit 1 }
. $main   # 点源：载入全部函数（被点源时主脚本不会弹菜单）

Invoke-Uninstall -KeepBackup:$KeepBackup -KeepDeveloperMode:$KeepDeveloperMode -KeepSdk:$KeepSdk -NoRestartExplorer:$NoRestartExplorer -PurgeRegistryVerbs:$PurgeRegistryVerbs -KeepRegistryVerbs:$KeepRegistryVerbs
