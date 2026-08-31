#Requires -Version 5.1
<#
================================================================================
 Diagnose.ps1  ——  只读体检（瘦包装器）
================================================================================
 输出：系统版本 / 组件目录 / CLSID 与 DLL / 接口实现方式 / verb 注册位置 /
       稀疏包状态 / 开发人员模式 / SDK 工具可用性。不修改任何东西。
 安装前后各跑一次便于对比。真实逻辑见 MiDrop-Menu.ps1（点源载入）。

 用法：
   powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1
================================================================================
#>
$ErrorActionPreference = 'Continue'
$main = Join-Path $PSScriptRoot 'MiDrop-Menu.ps1'
if (-not (Test-Path -LiteralPath $main)) { Write-Host '[ X ] 找不到 MiDrop-Menu.ps1（应与本文件同目录）' -ForegroundColor Red; exit 1 }
. $main   # 点源：载入全部函数（被点源时主脚本不会弹菜单）

Show-Diagnostics
