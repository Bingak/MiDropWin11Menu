#Requires -Version 5.1
<#
================================================================================
 Install-RouteB-SignedMsix.ps1  ——  路线 B 命令行版（瘦包装器）
================================================================================
 构建并安装「已签名的稀疏 .msix」，不需要开启开发人员模式。
 走 Windows 默认已启用的旁加载，唯一改动是导入一张自签名证书公钥（卸载时移除）。
 真实逻辑见 MiDrop-Menu.ps1（点源载入）。

 前置依赖：Windows SDK 的 MakeAppx.exe 与 SignTool.exe
   winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements

 用法（管理员 PowerShell）：
   powershell -ExecutionPolicy Bypass -File .\Install-RouteB-SignedMsix.ps1
   powershell -ExecutionPolicy Bypass -File .\Install-RouteB-SignedMsix.ps1 -SdkBin "C:\...\10.0.26100.0\x64"
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$NoRestartExplorer,
    # 手动指定 SDK bin 目录（含 makeappx.exe / signtool.exe）
    [string]$SdkBin
)

$ErrorActionPreference = 'Continue'
$main = Join-Path $PSScriptRoot 'MiDrop-Menu.ps1'
if (-not (Test-Path -LiteralPath $main)) { Write-Host '[ X ] 找不到 MiDrop-Menu.ps1（应与本文件同目录）' -ForegroundColor Red; exit 1 }
. $main   # 点源：载入全部函数（被点源时主脚本不会弹菜单）

Invoke-InstallRouteB -NoRestartExplorer:$NoRestartExplorer -SdkBin $SdkBin
