#Requires -Version 5.1
<#
================================================================================
 MiDrop-Menu.ps1  ——  一键安装主程序（管理员方式由「一键安装.cmd」调用）
================================================================================
 由同目录下的「一键安装.cmd」双击启动；也可在管理员 PowerShell 里直接运行。

 功能
   1) 路线 B 安装  —— 签名 .msix，不改任何系统全局开关      [推荐]
   2) 路线 A 安装  —— 免 SDK 免证书，但会开启「开发人员模式」
   3) 体验一下      —— 注册后立即测试，回车确认后自动注销还原
   4) 彻底删除      —— 注销包 + 还原开关 + 移除证书 + 卸载本脚本
                      自动装的 Windows SDK + 删除全部生成文件
   5) 查看当前状态
   0) 退出
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'MiDrop Win11 右键菜单 - 一键安装'

# ------------------------------------------------------------------ 常量
$AppName     = 'MiDropWin11Menu'
$PackageName = 'MiDropWin11MenuShim'
$CertSubject = 'CN=MiDropWin11MenuShim'
$StageRoot   = Join-Path $env:ProgramData 'MiDropWin11Menu'
$StageSparse = Join-Path $StageRoot 'sparse'
$BackupRoot  = Join-Path $StageRoot 'backup'
$StateFile   = Join-Path $StageRoot 'install-state.json'
$MsixPath    = Join-Path $StageRoot 'MiDropWin11MenuShim.msix'
$RegKey      = 'HKLM:\SOFTWARE\Classes'
$Clsid       = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'
$VerbFile    = 'HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu'
$VerbDir     = 'HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu'
$UnlockKey   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
# 小米组件根目录：用 ProgramFiles 环境变量，避免系统盘不是 C: 时找不到
$MiRoot      = Join-Path ${env:ProgramFiles} 'MI\HyperConnect'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($PSCommandPath) { $ScriptDir = Split-Path -Parent $PSCommandPath }

# 本会话内是否由脚本自动安装过 Windows SDK（写入状态文件，卸载时据此决定是否移除）
$script:SdkInstalledByUs = $false

# ------------------------------------------------------------------ 工具函数
function Write-Line { Write-Host ('=' * 62) -ForegroundColor DarkGray }
function Info($m) { Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!!] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[XX] $m" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Err '未获得管理员权限，无法继续。'
        Err '请在弹出的 UAC 窗口点「是」，或右键「一键安装.cmd」选「以管理员身份运行」。'
        return $false
    }
    return $true
}

function Assert-Win11 {
    $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    if ($b -lt 22000) {
        Err "当前系统内部版本 $b，不是 Windows 11，没有新版右键菜单。"
        return $false
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Err '当前系统不是 64 位，本方案不适用。'
        return $false
    }
    return $true
}

# 定位小米组件目录（自动挑最高版本）
function Get-MiDropDir {
    if (-not (Test-Path -LiteralPath $MiRoot)) { return $null }
    # @() 包裹：只有单个版本时管道会返回标量，下标/Count 行为不一致
    $hit = @(Get-ChildItem -LiteralPath $MiRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dll = Join-Path $_.FullName 'resources\native-interconnect\win32\MiDropShellExt.dll'
        $exe = Join-Path $_.FullName 'resources\native-interconnect\win32\MiPcContinuity.exe'
        if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $exe)) {
            $v = [version]'0.0.0.0'
            try { $v = [version]$_.Name } catch { }
            [pscustomobject]@{ Version = $v; Win32 = Split-Path $dll -Parent; Dll = $dll; DirName = $_.Name }
        }
    } | Sort-Object Version -Descending)
    if ($hit.Count -eq 0) { return $null }
    return $hit[0]
}

# 纯 .NET 的 .reg 导出（回退用）：
# 某些安全策略会禁用 reg.exe，导致原备份逻辑静默失败。
# 用 Registry API 手工生成 regedit 可导入的 "Version 5.00" 格式（UTF-16LE + CRLF）。
# 注意：OpenSubKey 把键名当字面量处理，路径里的 * 不会被当通配符，正好符合需要。
function Export-RegKeyPS {
    param([string]$RootKey, [string]$DestFile)
    $hiveMap    = @{ 'HKLM' = [Microsoft.Win32.Registry]::LocalMachine; 'HKCU' = [Microsoft.Win32.Registry]::CurrentUser }
    $hiveNameMap = @{ 'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKCU' = 'HKEY_CURRENT_USER' }
    $parts = $RootKey -split '\\', 2
    if ($parts.Count -lt 2 -or -not $hiveMap.ContainsKey($parts[0])) { return $false }
    $root = $hiveMap[$parts[0]].OpenSubKey($parts[1])
    if (-not $root) { return $false }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Windows Registry Editor Version 5.00')
    function Escape-RegText([string]$s) { (($s -replace '\\', '\\') -replace '"', '\"') }
    function Walk($key, [string]$pathText) {
        $lines.Add('')
        $lines.Add("[$pathText]")
        foreach ($vn in $key.GetValueNames()) {
            $kind = $key.GetValueKind($vn)
            $val  = $key.GetValue($vn, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $name = if ($vn -eq '') { '@' } else { '"' + (Escape-RegText $vn) + '"' }
            switch ("$kind") {
                'String'       { $lines.Add($name + '="' + (Escape-RegText ([string]$val)) + '"') }
                'ExpandString' { $lines.Add($name + '=hex(2):' + (([Text.Encoding]::Unicode.GetBytes("$val" + [char]0) | ForEach-Object { $_.ToString('x2') }) -join ',')) }
                'DWord'        { $lines.Add($name + ('=dword:{0:x8}' -f [uint32]$val)) }
                'QWord'        { $lines.Add($name + '=hex(b):' + (([BitConverter]::GetBytes([uint64]$val) | ForEach-Object { $_.ToString('x2') }) -join ',')) }
                'Binary'       { $lines.Add($name + '=hex:' + ((@($val) | ForEach-Object { $_.ToString('x2') }) -join ',')) }
                default        { $lines.Add($name + '="' + (Escape-RegText ([string]$val)) + '"') }
            }
        }
        foreach ($sk in $key.GetSubKeyNames()) {
            $sub = $null
            try { $sub = $key.OpenSubKey($sk) } catch { }
            if ($sub) { Walk $sub "$pathText\$sk" }
        }
    }
    Walk $root ("{0}\{1}" -f $hiveNameMap[$parts[0]], $parts[1])
    try {
        [IO.File]::WriteAllLines($DestFile, $lines, [Text.Encoding]::Unicode)
        return $true
    }
    catch { return $false }
}

function Backup-Registry {
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targets = @{
        "CLSID-$ts.reg"    = "HKLM\SOFTWARE\Classes\CLSID\$Clsid"
        "VerbStar-$ts.reg" = $VerbFile
        "VerbDir-$ts.reg"  = $VerbDir
    }
    $ok = $true
    foreach ($k in $targets.Keys) {
        $dest = Join-Path $BackupRoot $k
        & "$env:WINDIR\System32\reg.exe" export $targets[$k] $dest /y 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $dest)) {
            # reg.exe 被安全策略禁用 / 导出失败 → 纯 .NET 回退
            $null = Export-RegKeyPS -RootKey $targets[$k] -DestFile $dest
        }
        if (-not (Test-Path -LiteralPath $dest)) { $ok = $false }
    }
    return $ok
}

# 准备稀疏包目录：从脚本同级的 sparse\ 复制清单，从组件目录复制图标
function Install-Stage([string]$Win32Dir) {
    $src = Join-Path $ScriptDir 'sparse\AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $src)) {
        Err "找不到 $src"
        Err '请确保 sparse 文件夹与「一键安装.cmd」在同一目录。'
        return $false
    }
    if (Test-Path -LiteralPath $StageSparse) {
        Remove-Item -LiteralPath $StageSparse -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path (Join-Path $StageSparse 'Assets') -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $StageSparse 'AppxManifest.xml') -Force

    $assets = Join-Path $Win32Dir 'Assets'
    $map = @{
        'StoreLogo.png'                   = @('StoreLogo.png')
        'Square150x150Logo.scale-200.png' = @('Square150x150Logo.scale-200.png', 'Square150x150Logo.png')
        'Square44x44Logo.scale-200.png'   = @('Square44x44Logo.scale-200.png', 'Square44x44Logo.png')
    }
    foreach ($k in $map.Keys) {
        $s = Join-Path $assets $k
        if (Test-Path -LiteralPath $s) {
            foreach ($n in $map[$k]) { Copy-Item -LiteralPath $s -Destination (Join-Path $StageSparse "Assets\$n") -Force }
        }
    }
    return $true
}

function Remove-Package {
    $pkgs = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
    if ($pkgs.Count -eq 0) { return $true }
    foreach ($p in $pkgs) { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    # 若包被注册到「所有用户」，当前用户的 Remove-AppxPackage 会失败，补一次 -AllUsers
    $left = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        foreach ($p in $left) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    return (@(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue).Count -eq 0)
}

function Find-SdkTool([string]$name) {
    # 1) 优先用 SDK 自己导出的环境变量（最准确，也免去全盘扫描）
    #    WindowsSdkVerBinPath 形如 ...\Windows Kits\10\bin\10.0.26100.0\x64\
    if ($env:WindowsSdkVerBinPath) {
        $p = Join-Path $env:WindowsSdkVerBinPath $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $binRoots = @()
    if ($env:WindowsSdkBinPath) { $binRoots += $env:WindowsSdkBinPath }
    $binRoots += @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")

    foreach ($root in $binRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        # 按真实版本号降序（目录名字符串排序会把 10.0.9900 错排到 10.0.26100 前面）
        $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $v = $null
            try { $v = [version]$_.Name } catch { }
            if ($v) { [pscustomobject]@{ Ver = $v; Dir = $_.FullName } }
        } | Sort-Object Ver -Descending
        foreach ($d in $dirs) {
            $p = Join-Path $d.Dir "x64\$name"
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

# 是否装了 Windows SDK 10.0.26100（以 ARP 卸载项为准，与补丁版本号 .7705 等无关）
# 注意：SDK 主包是 32 位 MSI，ARP 条目注册在 WOW6432Node 视图，必须两个都查
function Test-Sdk26100Installed {
    $e = @(Get-ItemProperty @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -like 'Windows Software Development Kit - Windows 10.0.26100*' })
    return (@($e).Count -gt 0)
}

# 卸载 Windows SDK 10.0.26100：优先 winget，失败则查 ARP ProductCode 走 msiexec
function Remove-Sdk26100 {
    if (-not (Test-Sdk26100Installed)) { Ok '未检测到 Windows SDK 10.0.26100，无需移除。'; return }

    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wg) {
        Info '正在通过 winget 卸载 Windows SDK 10.0.26100（可能需要几分钟）...'
        & winget uninstall --id Microsoft.WindowsSDK.10.0.26100 --silent --disable-interactivity 2>&1 | Out-Null
    }
    if (Test-Sdk26100Installed) {
        # winget 没找到该条目（常见于 SDK 由 MSI 向导手动安装）→ 用 ProductCode 兜底
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
        Warn '  winget uninstall --id Microsoft.WindowsSDK.10.0.26100'
    }
    else { Ok 'Windows SDK 10.0.26100 已移除。' }
}

function Restart-ExplorerNow {
    Info '正在重启资源管理器，右键菜单即将刷新 ...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    # 轮询等系统自动拉起（AutoRestartShell），最多 15 秒。
    # 原先固定 sleep 2 秒再判断：系统拉起稍慢就会重复启动一个 explorer，
    # 或在尚未拉起时就误判为「已存在」而什么都不做。
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe | Out-Null
    }
    Ok '资源管理器已重启。'
}

# 校验原厂注册（即「显示更多选项」里的入口）是否完好。
# 本方案对 HKLM\SOFTWARE\Classes 只读，这里用于安装后自检与卸载后复核。
# 返回异常项路径数组；正常时为空数组。
function Test-FactoryRegistration {
    $bad = @()
    $must = @(
        @{ Path = "$RegKey\CLSID\$Clsid\InprocServer32"; Name = '(default)';              Expect = 'MiDropShellExt.dll' },
        @{ Path = "$RegKey\*\shell\MiDropExtMenu";        Name = 'ExplorerCommandHandler'; Expect = $Clsid },
        @{ Path = "$RegKey\Directory\shell\MiDropExtMenu"; Name = 'ExplorerCommandHandler'; Expect = $Clsid }
    )
    foreach ($m in $must) {
        if (-not (Test-Path -LiteralPath $m.Path)) { $bad += $m.Path; continue }
        $v = Get-ItemProperty -LiteralPath $m.Path -ErrorAction SilentlyContinue
        $val = if ($null -eq $v) { '' } elseif ($m.Name -eq '(default)') { $v.'(default)' } else { $v.($m.Name) }
        if ([string]::IsNullOrWhiteSpace([string]$val) -or ($val -notlike "*$($m.Expect)*")) { $bad += $m.Path }
    }
    return ,$bad
}

# 安装前的公共准备：定位组件 → 校验原厂注册 → 备份 → 铺设稀疏包目录。
# 任一步失败返回 $null（已打印原因），成功返回组件信息对象。
function Get-InstallContext {
    $mi = Get-MiDropDir
    if (-not $mi) { Err '未找到小米互联服务的组件目录，请先安装小米互联服务。'; return $null }
    Ok "组件目录：$($mi.Win32)（版本 $($mi.DirName)）"

    if (-not (Test-Path -LiteralPath "$RegKey\CLSID\$Clsid\InprocServer32")) {
        Err '原厂右键注册不存在，请先修复或重装小米互联服务。'
        return $null
    }

    Info '备份原厂注册表 ...'
    if (Backup-Registry) { Ok "备份已保存到 $BackupRoot" } else { Warn '部分备份未成功（不影响安装）。' }

    if (-not (Install-Stage $mi.Win32)) { return $null }
    return $mi
}

# 确保 makeappx / signtool 可用（路线 B 前置）。
# 返回 @{ MakeAppx=..; SignTool=.. }，或 @{ FallbackToA=$true }（用户改选路线 A），
# 或 $null（用户取消 / 安装失败）。
function Ensure-SdkTools {
    $makeappx = Find-SdkTool 'makeappx.exe'
    $signtool = Find-SdkTool 'signtool.exe'
    if ($makeappx -and $signtool) { return @{ MakeAppx = $makeappx; SignTool = $signtool } }

    Warn '未检测到 Windows SDK 的签名工具（MakeAppx.exe / SignTool.exe）。'
    Warn '路线 B 需要它。你可以：'
    Write-Host '   a) 现在自动安装（约需几分钟,大约占用3G空间）'
    Write-Host '   b) 改用路线 A（免 SDK，但要开「开发人员模式」）'
    Write-Host '   c) 返回主菜单'
    $c = (Read-Host '   请选择 a/b/c').Trim().ToLower()
    if ($c -eq 'b') { return @{ FallbackToA = $true } }
    if ($c -ne 'a') { return $null }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Err '未检测到 winget，无法自动安装。请手动安装 Windows SDK 或改用路线 A。'
        return $null
    }
    Info '正在通过 winget 安装 Windows SDK，请稍候 ...'
    winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Err "winget 安装失败，退出码 $LASTEXITCODE。可稍后重试或改用路线 A。"
        return $null
    }
    $script:SdkInstalledByUs = $true
    $makeappx = Find-SdkTool 'makeappx.exe'
    $signtool = Find-SdkTool 'signtool.exe'
    if (-not $makeappx -or -not $signtool) {
        Err '安装后仍未找到工具。请重新打开本窗口再试，或改用路线 A。'
        return $null
    }
    Ok 'SDK 已就绪（卸载本工具时会提示是否一并移除它）。'
    return @{ MakeAppx = $makeappx; SignTool = $signtool }
}

# 安装收尾：提示先测单文件，并自检原厂注册未被影响
function Write-PostInstallAdvice {
    Write-Host ''
    Warn '请务必先右键【单个文件】测试：互传窗口弹出且能看到该文件才算成功。'
    Warn '若窗口弹出但列表为空，说明本方案在你的环境不可用，请按 [4] 彻底删除。'
    $bad = Test-FactoryRegistration
    if ($bad.Count -eq 0) {
        Ok '自检通过：原厂注册完好，「显示更多选项」里的入口不受影响。'
    }
    else {
        Warn '自检发现原厂注册异常（本方案不修改这些键，请检查小米互联服务是否正常）：'
        $bad | ForEach-Object { Warn "    $_" }
    }
}

function Save-State([hashtable]$data) {
    $data.InstalledAt = (Get-Date).ToString('o')
    $data | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
}

# ------------------------------------------------------------------ 安装动作
function Invoke-RegisterPackage([string]$Win32Dir, [string]$Route, [bool]$DevModeChanged, [string]$Thumb, [bool]$SdkInstalled) {
    Info '正在注册稀疏包 ...'
    try {
        if ($Route -eq 'A') {
            Add-AppxPackage -Path (Join-Path $StageSparse 'AppxManifest.xml') -Register -ExternalLocation $Win32Dir -ErrorAction Stop
        }
        else {
            Add-AppxPackage -Path $MsixPath -ExternalLocation $Win32Dir -ErrorAction Stop
        }
    }
    catch {
        Err "注册失败：$($_.Exception.Message)"
        Warn '排查方法：在 PowerShell 里运行  Get-AppxLog -All  查看详细原因。'
        return $false
    }
    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Err '命令返回成功但查不到包，请运行 Get-AppxLog -All 排查。'
        return $false
    }
    Ok "已注册：$($pkg.PackageFullName)"
    Save-State @{
        Route              = $Route
        PackageFullName    = $pkg.PackageFullName
        ExternalLocation   = $Win32Dir
        DevModeChangedByUs = $DevModeChanged
        CertThumbprint     = $Thumb
        SdkInstalledByUs   = $SdkInstalled
        BackupDir          = $BackupRoot
    }
    return $true
}

function Install-RouteA([bool]$Trial) {
    Write-Line
    Write-Host ('  ' + $(if ($Trial) { '体验模式（路线 A，回车确认后自动还原）' } else { '路线 A 安装' })) -ForegroundColor Cyan
    Write-Line

    if (-not $Trial) {
        Warn '此路线需要开启系统「开发人员模式」（一个全局开关）。'
        Warn '若不想改全局开关，请改用路线 B。'
        Write-Host ''
    }

    $mi = Get-InstallContext
    if (-not $mi) { return }

    # 开发人员模式
    $devOn = $false
    if (Test-Path $UnlockKey) { $devOn = ((Get-ItemProperty $UnlockKey).AllowDevelopmentWithoutDevLicense -eq 1) }
    $changed = $false
    if (-not $devOn) {
        Info '正在开启「开发人员模式」...'
        New-Item -Path $UnlockKey -Force | Out-Null
        New-ItemProperty -Path $UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
        $changed = $true
        Ok '已开启（卸载时会自动还原）。'
    } else {
        Ok '「开发人员模式」已经是开启状态。'
    }

    Remove-Package | Out-Null

    if (-not (Invoke-RegisterPackage $mi.Win32 'A' $changed '' $false)) { return }

    if ($Trial) {
        Restart-ExplorerNow
        Write-Host ''
        Ok '体验模式已启用！现在右键任意文件，看看新版菜单第一层是否出现。'
        Warn '体验注册同样是持久的，不会因重启电脑自动消失；'
        Warn '请在测试完毕后回到本窗口按回车，脚本会自动注销并还原。'
        $null = Read-Host '  测试完毕后按回车，自动注销并还原'
        Info '正在注销体验注册 ...'
        Remove-Package | Out-Null
        if ($changed) {
            Set-ItemProperty -Path $UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Info '「开发人员模式」已还原为关闭。'
        }
        if (Test-Path -LiteralPath $StageRoot) {
            Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Restart-ExplorerNow
        Ok '体验结束，已恢复原状，未留任何痕迹。'
        Warn '若本窗口意外关闭导致未还原，重新运行脚本选 [4] 彻底删除即可。'
    }
    else {
        Restart-ExplorerNow
        Write-Host ''
        Ok '安装完成！请右键任意文件或文件夹查看效果。'
        Warn '若未出现，请注销重登一次再试。'
        Write-PostInstallAdvice
    }
}

function Install-RouteB {
    Write-Line
    Write-Host '  路线 B 安装（签名 .msix，不改系统全局开关）[推荐]' -ForegroundColor Cyan
    Write-Line

    $sdk = Ensure-SdkTools
    if (-not $sdk) { return }
    if ($sdk.FallbackToA) { Install-RouteA $false; return }

    $mi = Get-InstallContext
    if (-not $mi) { return }

    # 自签名证书
    Info '准备签名证书 ...'
    $cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq $CertSubject } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        try {
            $cert = New-SelfSignedCertificate -Type Custom -Subject $CertSubject `
                -KeyUsage DigitalSignature -FriendlyName 'MiDrop Win11 Menu Shim' `
                -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5) `
                -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -ErrorAction Stop
        }
        catch { Err "证书创建失败：$($_.Exception.Message)"; return }
    }
    Ok "证书指纹 $($cert.Thumbprint)"

    $pwdPlain = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    $pwd  = ConvertTo-SecureString -String $pwdPlain -Force -AsPlainText
    $pfx  = Join-Path $StageRoot 'signing.pfx'
    $cer  = Join-Path $StageRoot 'signing.cer'
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd -Force | Out-Null
    Export-Certificate  -Cert $cert -FilePath $cer -Force | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
    Ok '公钥已加入系统信任列表（卸载时会移除）。'

    # 打包 + 签名
    Info '打包并签名 .msix ...'
    & $sdk.MakeAppx pack /o /d $StageSparse /nv /p $MsixPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Err "MakeAppx 打包失败，退出码 $LASTEXITCODE"; Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue; return }
    & $sdk.SignTool sign /fd SHA256 /f $pfx /p $pwdPlain $MsixPath 2>&1 | Out-Null
    Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { Err "SignTool 签名失败，退出码 $LASTEXITCODE"; return }
    Ok '签名完成，私钥文件已销毁。'

    Remove-Package | Out-Null
    if (-not (Invoke-RegisterPackage $mi.Win32 'B' $false $cert.Thumbprint $script:SdkInstalledByUs)) { return }

    Restart-ExplorerNow
    Write-Host ''
    Ok '安装完成！请右键任意文件或文件夹查看效果。'
    Warn '若未出现，请注销重登一次再试。'
    Write-PostInstallAdvice
}

# ------------------------------------------------------------------ 彻底删除
function Invoke-FullRemoval {
    Write-Line
    Write-Host '  彻底删除（注销 + 还原开关 + 移除证书 + 卸载自动装的 SDK + 清理生成文件）' -ForegroundColor Cyan
    Write-Line

    $state = $null
    if (Test-Path -LiteralPath $StateFile) {
        try { $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { }
    }

    Write-Host '  此操作会：' -ForegroundColor DarkGray
    Write-Host '    1. 注销右键菜单包（新菜单里的条目消失）'
    Write-Host '    2. 还原「开发人员模式」开关（若当初由本脚本开启）'
    Write-Host '    3. 移除自签名证书'
    Write-Host '    4. 卸载本脚本自动安装的 Windows SDK 10.0.26100（若有）'
    Write-Host '    5. 删除 C:\ProgramData\MiDropWin11Menu（含注册表备份）'
    Write-Host '  不会动小米互联服务本身及其原厂右键注册。'
    Write-Host ''
    $c = (Read-Host '  确认删除？输入 y 继续，其它取消').Trim().ToLower()
    if ($c -ne 'y') { Info '已取消。'; return }

    Write-Host ''
    Info '1/5 注销包 ...'
    if (Remove-Package) { Ok '已注销（或本就未安装）。' } else { Warn '包可能仍被占用，请注销重登后重试一次。' }

    Info '2/5 还原「开发人员模式」...'
    if ($state -and $state.DevModeChangedByUs -eq $true) {
        if (Test-Path $UnlockKey) {
            Set-ItemProperty -Path $UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Ok '已还原为关闭。'
        }
    }
    else {
        $keep = (Read-Host '    未记录是否由本脚本开启过。要把「开发人员模式」关掉吗？(y/n)').Trim().ToLower()
        if ($keep -eq 'y' -and (Test-Path $UnlockKey)) {
            Set-ItemProperty -Path $UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Ok '已关闭。'
        }
        else { Info '保持原状。' }
    }

    Info '3/5 移除证书 ...'
    $n = 0
    foreach ($c2 in @(Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $CertSubject })) {
        Remove-Item -LiteralPath $c2.PSPath -Force -ErrorAction SilentlyContinue; $n++
    }
    foreach ($c2 in @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $CertSubject })) {
        Remove-Item -LiteralPath $c2.PSPath -Force -ErrorAction SilentlyContinue; $n++
    }
    Ok "已移除 $n 张证书。"

    Info '4/5 移除 Windows SDK（若由本脚本自动安装）...'
    if ($state -and $state.SdkInstalledByUs -eq $true) {
        Remove-Sdk26100
    }
    elseif (Test-Sdk26100Installed) {
        Warn '检测到已安装 Windows SDK 10.0.26100，但状态文件未记录它由本脚本安装'
        Warn '（可能是你之前用其它方式装的）。'
        $c3 = (Read-Host '    要一并卸载它吗？(y/n)').Trim().ToLower()
        if ($c3 -eq 'y') { Remove-Sdk26100 } else { Info '保留 Windows SDK。' }
    }
    else { Info '未检测到 Windows SDK 10.0.26100，跳过。' }

    Info '5/5 删除生成文件 ...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    # 结束仍加载扩展 DLL 的 dllhost 代理进程（访问 Modules 可能因权限抛异常，逐个容错）
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Get-Process dllhost -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $mods = $_.Modules | Where-Object { $_.ModuleName -match 'MiDropShellExt' }
                if ($mods) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
            }
            catch { }
        }
        if (Test-Path -LiteralPath $StageRoot) {
            Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $StageRoot)) { break }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $StageRoot) {
        Warn "未能完全删除：$StageRoot"
        Warn '通常是 DLL 仍被占用。请重启电脑后手动删除该文件夹。'
    }
    else { Ok "已删除 $StageRoot" }

    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe | Out-Null }

    Write-Host ''
    Info '检查原厂右键注册是否完好 ...'
    $bad = Test-FactoryRegistration   # 值级校验（含 DLL 路径与 CLSID 比对）
    if ($bad.Count -eq 0) {
        Ok '原厂注册完好：「显示更多选项」里的入口不受影响。'
    }
    else {
        Warn '以下原厂注册缺失或值异常（本方案不会删除它们，可能是其他原因）：'
        $bad | ForEach-Object { Warn "    $_" }
        Warn '可用同目录下 reg\Restore-MiDrop-Original.reg 修复（用 64 位 regedit 导入）。'
    }
    Write-Host ''
    Ok '清理完成，系统已恢复。'
}

# ------------------------------------------------------------------ 状态
function Show-Status {
    Write-Line
    Write-Host '  当前状态' -ForegroundColor Cyan
    Write-Line

    # 状态文件：解析失败不能影响后续展示，置为 $null 即可
    $state = $null
    if (Test-Path -LiteralPath $StateFile) {
        try { $state = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $state = $null }
    }

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { '64 位' } else { $env:PROCESSOR_ARCHITECTURE }
    Write-Host '  系统               ' -NoNewline -ForegroundColor Gray
    Write-Host "Windows 内部版本 $($cv.CurrentBuild).$($cv.UBR) / $arch"

    $mi = Get-MiDropDir
    if ($mi) {
        Write-Host '  小米组件           ' -NoNewline -ForegroundColor Gray; Write-Host "$($mi.Win32)"
        Write-Host '  组件版本           ' -NoNewline -ForegroundColor Gray; Write-Host $mi.DirName
    }
    else {
        Write-Host '  小米组件           ' -NoNewline -ForegroundColor Gray; Write-Host '未找到' -ForegroundColor Red
    }

    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-Host '  右键菜单包         ' -NoNewline -ForegroundColor Gray; Write-Host '已安装' -ForegroundColor Green
        Write-Host '  注册方式           ' -NoNewline -ForegroundColor Gray; Write-Host "$($pkg.SignatureKind) / $($pkg.PackageFullName)"
        Write-Host '  外部位置           ' -NoNewline -ForegroundColor Gray
        if ($state) {
            $ext = $state.ExternalLocation
            if ($ext -and (Test-Path -LiteralPath $ext)) { Write-Host "$ext （有效）" -ForegroundColor Green }
            else { Write-Host "$ext （已失效，组件可能已升级，请重新安装）" -ForegroundColor Red }
        }
        else { Write-Host '状态文件缺失或已损坏' -ForegroundColor Yellow }
    }
    else {
        Write-Host '  右键菜单包         ' -NoNewline -ForegroundColor Gray; Write-Host '未安装' -ForegroundColor Yellow
    }

    $dev = '未开启'
    if (Test-Path $UnlockKey) { $dev = if ((Get-ItemProperty $UnlockKey).AllowDevelopmentWithoutDevLicense -eq 1) { '已开启' } else { '未开启' } }
    Write-Host '  开发人员模式       ' -NoNewline -ForegroundColor Gray
    Write-Host $dev -ForegroundColor $(if ($dev -eq '已开启') { 'Yellow' } else { 'Green' })

    $cls = Test-Path -LiteralPath "$RegKey\CLSID\$Clsid\InprocServer32"
    Write-Host '  原厂右键注册       ' -NoNewline -ForegroundColor Gray
    Write-Host $(if ($cls) { '完好' } else { '缺失' }) -ForegroundColor $(if ($cls) { 'Green' } else { 'Red' })

    $mk = Find-SdkTool 'makeappx.exe'
    Write-Host '  Windows SDK 工具   ' -NoNewline -ForegroundColor Gray
    Write-Host $(if ($mk) { '已安装' } else { '未安装（路线 B 需要）' }) -ForegroundColor $(if ($mk) { 'Green' } else { 'Yellow' })

    $sdkInstalled = Test-Sdk26100Installed
    Write-Host '  Windows SDK 包     ' -NoNewline -ForegroundColor Gray
    $sdkNote = if (-not $sdkInstalled) { '未安装' }
               elseif ($state -and $state.SdkInstalledByUs -eq $true) { '已安装（由本脚本安装，卸载时会移除）' }
               else { '已安装（非本脚本安装，卸载时会询问）' }
    Write-Host $sdkNote -ForegroundColor $(if ($sdkInstalled) { 'Green' } else { 'Gray' })

    $old = Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    Write-Host '  旧菜单全局回退     ' -NoNewline -ForegroundColor Gray
    Write-Host $(if ($old) { '已开启（整个右键菜单已回退 Win10 样式）' } else { '未开启（正常）' }) -ForegroundColor $(if ($old) { 'Yellow' } else { 'Green' })

    Write-Host '  暂存目录           ' -NoNewline -ForegroundColor Gray
    Write-Host $(if (Test-Path -LiteralPath $StageRoot) { $StageRoot } else { '不存在' })
    Write-Line
}

# ------------------------------------------------------------------ 菜单
function Show-Menu {
    Clear-Host
    Write-Line
    Write-Host '   小米互传 -> Windows 11 新版右键菜单' -ForegroundColor White
    Write-Host '   MiDrop Win11 Context Menu  |  项目: github.com/Bingak/MiDropWin11Menu'
    Write-Line
    Write-Host '   想把「使用小米互传发送」放到 Win11 新右键菜单的第一层，' -ForegroundColor DarkGray
    Write-Host '   不用每次点「显示更多选项」。以下三选一：' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   [1] 路线 B 安装  ' -NoNewline -ForegroundColor Green
    Write-Host '推荐。签名安装，不改任何系统全局开关。' -ForegroundColor Gray
    Write-Host '                   需 Windows SDK（没有的话会提示自动装）。'
    Write-Host ''
    Write-Host '   [2] 路线 A 安装  ' -NoNewline -ForegroundColor Cyan
    Write-Host '免 SDK 免证书，但会开启系统「开发人员模式」。' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [3] 体验一下      ' -NoNewline -ForegroundColor Cyan
    Write-Host '注册后立即测试，回车确认后自动注销还原。' -ForegroundColor Gray
    Write-Host '                   想先看看效果选这个。'
    Write-Host ''
    Write-Host '   [4] 彻底删除      ' -NoNewline -ForegroundColor Yellow
    Write-Host '注销包 + 还原开关 + 卸载自动装的 SDK + 删掉生成的文件。' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [5] 查看当前状态' -ForegroundColor Gray
    Write-Host '   [0] 退出' -ForegroundColor Gray
    Write-Line

    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-Host '   提示：当前已安装，重复安装会先自动卸载旧的。' -ForegroundColor Yellow
    }
    Write-Host ''
}

# ------------------------------------------------------------------ 主流程
Write-Host '正在检查运行环境 ...' -ForegroundColor DarkGray
if (-not (Assert-Admin)) { if (-not $NoPause) { Read-Host '按回车退出' }; exit 1 }
if (-not (Assert-Win11)) { if (-not $NoPause) { Read-Host '按回车退出' }; exit 1 }

while ($true) {
    Show-Menu
    $sel = (Read-Host '   请输入序号后回车').Trim()
    switch ($sel) {
        '1' { Install-RouteB;  Write-Host ''; Read-Host '按回车返回菜单' }
        '2' { Install-RouteA $false; Write-Host ''; Read-Host '按回车返回菜单' }
        '3' { Install-RouteA $true;  Write-Host ''; Read-Host '按回车返回菜单' }
        '4' { Invoke-FullRemoval;    Write-Host ''; Read-Host '按回车返回菜单' }
        '5' { Show-Status;           Write-Host ''; Read-Host '按回车返回菜单' }
        '0' { Write-Host '再见。'; exit 0 }
        default { Write-Host '   无效输入，请重试。' -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
