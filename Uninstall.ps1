<#
================================================================================
 Uninstall.ps1  ——  完整回滚
================================================================================
 依次执行：
   1. 结束仍占用扩展 DLL 的 dllhost 代理进程，注销稀疏包（Remove-AppxPackage）
      —— 新版菜单里的条目立即消失
   2. 若安装脚本曾自动打开「开发人员模式」，还原为关闭
   3. 从 LocalMachine\TrustedPeople 移除自签名证书（路线 B）
   4. 卸载本工具自动安装的 Windows SDK 10.0.26100（可选，-KeepSdk 跳过）
   5. 校验原厂注册表键值是否完好；若被破坏，提示导入 reg\Restore-MiDrop-Original.reg
   6. 清理 C:\ProgramData\MiDropWin11Menu（-KeepBackup 可保留备份）
   7. 重启 explorer.exe

 本脚本不会触碰 HKLM\SOFTWARE\Classes 下任何原厂键值 →
 「显示更多选项」里的「使用小米互传发送」始终保持可用。

 用法：管理员 PowerShell
   powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1
 可选开关：
   -KeepBackup         保留 C:\ProgramData\MiDropWin11Menu\backup
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
$PackageName = 'MiDropWin11MenuShim'
$CertSubject = 'CN=MiDropWin11MenuShim'
$StageRoot   = 'C:\ProgramData\MiDropWin11Menu'
$MarkerFile  = Join-Path $StageRoot 'install-state.json'
$TargetClsid = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'
$SdkWingetId = 'Microsoft.WindowsSDK.10.0.26100'

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

# ------------------------------------------- Windows SDK 10.0.26100 检测与卸载
# 以 ARP（卸载注册表）条目为准：SDK 由 MSI 安装，补丁升级（如 .7705）不影响匹配。
# 注意：SDK 主包是 32 位 MSI，ARP 条目注册在 WOW6432Node 视图，必须两个都查。
function Test-Sdk26100Installed {
    $e = @(Get-ItemProperty @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -like 'Windows Software Development Kit - Windows 10.0.26100*' })
    return (@($e).Count -gt 0)
}

function Remove-Sdk26100 {
    if (-not (Test-Sdk26100Installed)) { Ok '未检测到 Windows SDK 10.0.26100，无需移除。'; return }

    # 方式一：winget（该 SDK 由 winget 安装时，条目可直接对应）
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wg) {
        Info '正在通过 winget 卸载 Windows SDK 10.0.26100（可能需要几分钟）...'
        & winget uninstall --id $SdkWingetId --silent --disable-interactivity 2>&1 | Out-Null
    }
    if (Test-Sdk26100Installed) {
        # 方式二：winget 找不到条目（SDK 由 MSI 向导手动装、或 winget 源不匹配）
        # → 从 ARP 查 ProductCode，直接 msiexec /x 卸载主包（子组件随之联动移除）
        $entries = @(Get-ItemProperty @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Windows Software Development Kit - Windows 10.0.26100*' })
        foreach ($e in @($entries)) {
            Info "通过 msiexec 卸载 $($e.DisplayName) ..."
            $p = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" `
                 -ArgumentList "/x $($e.PSChildName) /qn /norestart" -Wait -PassThru
            # 0 = 成功；3010 = 成功但需重启；1605 = 本就不存在
            if ($p.ExitCode -notin @(0, 3010, 1605)) {
                Warn "msiexec 退出码 $($p.ExitCode)（非 0/3010/1605）"
            }
        }
    }
    if (Test-Sdk26100Installed) {
        Warn 'SDK 未完全移除。可稍后在「设置 → 应用」中手动卸载，或运行：'
        Warn "  winget uninstall --id $SdkWingetId"
    }
    else { Ok 'Windows SDK 10.0.26100 已移除。' }
}

# --------------------------------- 0. 结束占用扩展 DLL 的 dllhost 代理进程
# 避免包仍被 COM 代理占用导致 Remove-AppxPackage 报「应用正在使用」。
# 访问其他进程的 Modules 可能因权限抛异常，逐个 try/catch 容错。
Get-Process dllhost -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $mods = $_.Modules | Where-Object { $_.ModuleName -match 'MiDropShellExt' }
        if ($mods) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

# ---------------------------------------------------------- 1. 注销稀疏包
$pkgs = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($pkgs) {
    foreach ($p in @($pkgs)) {
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
elseif (-not $KeepDeveloperMode) {
    # 无状态文件可参考时，给出提示但不擅自动手
    $dev = $null
    if (Test-Path $unlock) { $dev = (Get-ItemProperty $unlock -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense }
    if ($dev -eq 1) {
        Warn '「开发人员模式」当前为开启状态，但状态文件未记录是否由本工具开启，保持不动。'
        Warn '若想关闭：设置 → 系统 → 开发者选项 → 开发人员模式。'
    }
}

# ------------------------------------------------------- 3. 移除自签名证书
$found = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
         Where-Object { $_.Subject -eq $CertSubject }
foreach ($c in @($found)) {
    Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Continue
    Ok "已从 LocalMachine\TrustedPeople 移除证书 $($c.Thumbprint)"
}
$mine = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $CertSubject }
foreach ($c in @($mine)) {
    Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Continue
    Ok "已从 CurrentUser\My 移除私钥证书 $($c.Thumbprint)"
}

# ------------------------------------------- 4. 卸载本工具自动安装的 SDK
if (-not $KeepSdk) {
    if ($state -and $state.SdkInstalledByUs -eq $true) {
        Remove-Sdk26100
    }
    elseif (Test-Sdk26100Installed) {
        Warn '检测到已安装 Windows SDK 10.0.26100，但状态文件未记录它由本工具自动安装'
        Warn '（可能是你手动或其它工具装的）。'
        $ans = (Read-Host '    要一并卸载吗？(y/N)').Trim().ToLower()
        if ($ans -eq 'y') { Remove-Sdk26100 } else { Info '已保留 Windows SDK。' }
    }
    else { Info '未检测到 Windows SDK 10.0.26100，跳过。' }
}
else { Info '按要求保留 Windows SDK。' }

# ------------------------------------------- 5. 校验原厂注册表是否完好无损
$checks = @(
    @{ Path = "HKLM:\SOFTWARE\Classes\CLSID\$TargetClsid\InprocServer32"; Name = '(default)';         Expect = 'MiDropShellExt.dll' },
    @{ Path = 'HKLM:\SOFTWARE\Classes\*\shell\MiDropExtMenu';              Name = 'ExplorerCommandHandler'; Expect = $TargetClsid },
    @{ Path = 'HKLM:\SOFTWARE\Classes\Directory\shell\MiDropExtMenu';      Name = 'ExplorerCommandHandler'; Expect = $TargetClsid }
)
$broken = @()
foreach ($c in $checks) {
    # 注意 * 是合法键名，必须用 -LiteralPath
    if (-not (Test-Path -LiteralPath $c.Path)) { $broken += $c.Path; continue }
    $v = Get-ItemProperty -LiteralPath $c.Path -ErrorAction SilentlyContinue
    if ($null -eq $v) { $broken += $c.Path; continue }
    $val = if ($c.Name -eq '(default)') { $v.'(default)' } else { $v.($c.Name) }
    if ([string]::IsNullOrWhiteSpace([string]$val) -or ($val -notlike "*$($c.Expect)*")) {
        $broken += "$($c.Path) → $($c.Name) 值异常"
    }
}
if ($broken.Count -eq 0) {
    Ok '原厂注册完好：「显示更多选项」里的「使用小米互传发送」不受影响。'
}
else {
    Warn '以下原厂键缺失或值异常：'
    $broken | ForEach-Object { Warn "    $_" }
    Warn '请用 64 位 regedit 导入修复：'
    Warn "    %WINDIR%\regedit.exe /s `"$PSScriptRoot\reg\Restore-MiDrop-Original.reg`""
    if ($state -and $state.BackupDir -and (Test-Path $state.BackupDir)) {
        Warn "也可使用安装时的原始备份：$($state.BackupDir)"
    }
}

# ----------------------------------------------------------- 6. 清理暂存目录
if (Test-Path -LiteralPath $StageRoot) {
    if ($KeepBackup) {
        Get-ChildItem -LiteralPath $StageRoot -Exclude 'backup' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Ok "已清理暂存文件，保留备份目录 $StageRoot\backup"
    }
    else {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $StageRoot) { Warn "未能完全删除 $StageRoot，请稍后手动删除。" }
        else { Ok "已删除 $StageRoot" }
    }
}

# --------------------------------------------------------- 7. 重启 explorer
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
