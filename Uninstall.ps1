<#
================================================================================
 Uninstall.ps1  —— 完整回滚
================================================================================
 依次执行：
   1. 注销稀疏包（Remove-AppxPackage）—— 新版菜单里的条目立即消失
   2. 若安装脚本曾自动打开「开发人员模式」，还原为关闭
   3. 从 LocalMachine\TrustedPeople 移除自签名证书（路线 B）
   4. 校验原厂注册表键值是否完好；若被破坏，提示导入 reg\Restore-MiDrop-Original.reg
   5. 清理 C:\ProgramData\MiDropWin11Menu（-KeepBackup 可保留备份）
   6. 重启 explorer.exe

 本脚本不会触碰 HKLM\SOFTWARE\Classes 下任何原厂键值 →
 「显示更多选项」里的「使用小米互传发送」始终保持可用。

 用法：管理员 PowerShell
   powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$KeepBackup,
    [switch]$KeepDeveloperMode,
    [switch]$NoRestartExplorer
)

$ErrorActionPreference = 'Continue'
$PackageName = 'MiDropWin11MenuShim'
$CertSubject = 'CN=MiDropWin11MenuShim'
$StageRoot   = 'C:\ProgramData\MiDropWin11Menu'
$MarkerFile  = Join-Path $StageRoot 'install-state.json'
$TargetClsid = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'

function Info($m) { Write-Host "[ * ] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[ ! ] $m" -ForegroundColor Yellow }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[ X ] 需要管理员权限。' -ForegroundColor Red; exit 1
}

$state = $null
if (Test-Path -LiteralPath $MarkerFile) {
    try { $state = Get-Content -LiteralPath $MarkerFile -Raw | ConvertFrom-Json } catch { }
}

# ---------------------------------------------------------- 1. 注销稀疏包
$pkgs = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($pkgs) {
    foreach ($p in $pkgs) {
        Info "移除 $($p.PackageFullName)"
        Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Continue
    }
    if (Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue) {
        Warn '包仍存在，可能被占用。请注销重登后再次运行本脚本。'
    } else { Ok '稀疏包已注销。' }
}
else { Ok "未发现已注册的 $PackageName（可能已卸载）。" }

# ------------------------------------------------- 2. 还原开发人员模式开关
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
if (-not $KeepDeveloperMode -and $state -and $state.DevModeChangedByUs -eq $true) {
    if (Test-Path $unlock) {
        Set-ItemProperty -Path $unlock -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
        Ok '「开发人员模式」已还原为关闭（原本就是关闭状态）。'
    }
}
elseif ($state -and $state.DevModeChangedByUs -eq $true) {
    Warn '按要求保留「开发人员模式」为开启状态。'
}

# ------------------------------------------------------- 3. 移除自签名证书
$found = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
         Where-Object { $_.Subject -eq $CertSubject }
foreach ($c in $found) {
    Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Continue
    Ok "已从 LocalMachine\TrustedPeople 移除证书 $($c.Thumbprint)"
}
$mine = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $CertSubject }
foreach ($c in $mine) {
    Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Continue
    Ok "已从 CurrentUser\My 移除私钥证书 $($c.Thumbprint)"
}

# ------------------------------------------- 4. 校验原厂注册表是否完好无损
$checks = @(
    @{ Path = "HKLM:\SOFTWARE\Classes\CLSID\$TargetClsid\InprocServer32"; Name = '(default)' },
    @{ Path = 'HKLM:\SOFTWARE\Classes\*\shell\MiDropExtMenu';             Name = 'ExplorerCommandHandler' },
    @{ Path = 'HKLM:\SOFTWARE\Classes\Directory\shell\MiDropExtMenu';     Name = 'ExplorerCommandHandler' }
)
$broken = @()
foreach ($c in $checks) {
    # 注意 * 是合法键名，必须用 -LiteralPath
    if (-not (Test-Path -LiteralPath $c.Path)) { $broken += $c.Path; continue }
    $v = (Get-ItemProperty -LiteralPath $c.Path -ErrorAction SilentlyContinue)
    if ($null -eq $v) { $broken += $c.Path }
}
if ($broken.Count -eq 0) {
    Ok '原厂注册完好：「显示更多选项」里的「使用小米互传发送」不受影响。'
}
else {
    Warn '以下原厂键缺失：'
    $broken | ForEach-Object { Warn "    $_" }
    Warn '请用 64 位 regedit 导入修复：'
    Warn "    %WINDIR%\regedit.exe /s `"$PSScriptRoot\reg\Restore-MiDrop-Original.reg`""
    if ($state -and $state.BackupDir -and (Test-Path $state.BackupDir)) {
        Warn "也可使用安装时的原始备份：$($state.BackupDir)"
    }
}

# ----------------------------------------------------------- 5. 清理暂存目录
if (Test-Path -LiteralPath $StageRoot) {
    if ($KeepBackup) {
        Get-ChildItem -LiteralPath $StageRoot -Exclude 'backup' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Ok "已清理暂存文件，保留备份目录 $StageRoot\backup"
    }
    else {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $StageRoot) { Warn "未能完全删除 $StageRoot，请稍后手动删除。" }
        else { Ok "已删除 $StageRoot" }
    }
}

# --------------------------------------------------------- 6. 重启 explorer
if ($NoRestartExplorer) { Warn '已跳过重启 explorer.exe。' }
else {
    Info '重启 explorer.exe …'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Ok 'explorer.exe 已重启。'
}

Write-Host ''
Ok '回滚完成，系统已恢复到安装前状态。'
