<#
================================================================================
 Install-RouteA-DevMode.ps1
 把「使用小米互传发送」提升到 Windows 11 新版右键菜单第一层
 —— 路线 A：注册松散文件（loose files）稀疏包，无需 Windows SDK、无需证书
================================================================================
 原理
 ----
 小米互联服务的右键处理器 CLSID {504d69c0-cb52-48df-b5b5-7161829fabc8}
 已经是 IExplorerCommand 实现（MiDropShellExt.dll，x64）。
 它只出现在旧菜单的唯一原因是：缺少 package identity（包标识）。
 本脚本注册一个「只含清单、不含二进制」的稀疏包，
 用 -ExternalLocation 指向小米原装目录，把包标识授予同一个 CLSID。
 原厂注册表键值完全不动 → 「显示更多选项」里的入口保持原样。

 代价
 ----
 -Register 方式注册未签名松散文件，需要打开系统「开发人员模式」。
 这是本方案唯一的全局开关改动。若不接受，请改用 Install-RouteB-SignedMsix.ps1
 （签名 .msix，走默认已开启的旁加载，不需要开发人员模式）。

 用法
 ----
   以管理员身份打开 PowerShell，然后：
     Set-Location <本文件所在目录>
     powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1
   如需脚本自动打开开发人员模式，追加 -EnableDeveloperMode
================================================================================
#>
[CmdletBinding()]
param(
    # 自动写入 HKLM\...\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1
    [switch]$EnableDeveloperMode,
    # 跳过重启 explorer.exe（改为自行注销重登）
    [switch]$NoRestartExplorer
)

$ErrorActionPreference = 'Stop'
$PackageName = 'MiDropWin11MenuShim'
$StageRoot   = 'C:\ProgramData\MiDropWin11Menu'
$StageSparse = Join-Path $StageRoot 'sparse'
$BackupDir   = Join-Path $StageRoot 'backup'
$MarkerFile  = Join-Path $StageRoot 'install-state.json'
$TargetClsid = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'

function Info($m) { Write-Host "[ * ] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[ ! ] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[ X ] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 0. 前置检查
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die '需要管理员权限。请以管理员身份重新运行 PowerShell。'
}
if ([Environment]::Is64BitOperatingSystem -ne $true) { Die '本方案仅适用于 64 位 Windows。' }

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($build -lt 22000) { Die "当前系统内部版本 $build 不是 Windows 11，没有新版右键菜单。" }
Info "系统内部版本 $build，64 位，检查通过。"

# ------------------------------------------------- 1. 定位小米互联服务安装目录
$candidates = Get-ChildItem 'C:\Program Files\MI\HyperConnect' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $dll = Join-Path $_.FullName 'resources\native-interconnect\win32\MiDropShellExt.dll'
        if (Test-Path -LiteralPath $dll) {
            # 目录名不一定是合法版本号，单独解析，失败则降级为 0.0.0.0
            $ver = [version]'0.0.0.0'
            try { $ver = [version]$_.Name } catch { }
            [pscustomobject]@{
                Version = $ver
                Win32   = Split-Path $dll -Parent
                Dll     = $dll
            }
        }
    } | Sort-Object Version -Descending

if (-not $candidates) { Die '未找到 MiDropShellExt.dll，请确认小米互联服务已安装。' }
$mi = $candidates[0]
Ok "组件目录：$($mi.Win32)"
Ok "处理器 DLL：$($mi.Dll)"

# 校验 DLL 架构必须与 explorer.exe 一致（x64）
$fs = [IO.File]::OpenRead($mi.Dll)
try {
    $br = New-Object IO.BinaryReader($fs)
    $fs.Position = 0x3C; $pe = $br.ReadInt32(); $fs.Position = $pe + 4
    $machine = $br.ReadUInt16()
} finally { $fs.Dispose() }
if ($machine -ne 0x8664) { Die ("DLL 架构不是 x64（0x{0:X}），无法被 64 位 explorer.exe 加载。" -f $machine) }
Ok 'DLL 架构 x64，与 explorer.exe 匹配。'

# 校验原厂 CLSID 注册仍然完好（这是我们复用的对象）
$clsKey = "HKLM:\SOFTWARE\Classes\CLSID\$TargetClsid\InprocServer32"
if (-not (Test-Path $clsKey)) { Die "原厂 CLSID 未注册：$clsKey —— 请先修复/重装小米互联服务。" }
Ok "原厂 CLSID 注册完好：$TargetClsid"

# ------------------------------------------------------------ 2. 注册表备份
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$exports = @{
    "CLSID-$stamp.reg"     = "HKLM\SOFTWARE\Classes\CLSID\$TargetClsid"
    "VerbStar-$stamp.reg"  = 'HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu'
    "VerbDir-$stamp.reg"   = 'HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu'
}
foreach ($kv in $exports.GetEnumerator()) {
    $dest = Join-Path $BackupDir $kv.Key
    & "$env:WINDIR\System32\reg.exe" export $kv.Value $dest /y | Out-Null
    if (Test-Path -LiteralPath $dest) { Ok "已备份 $($kv.Value)" } else { Warn "备份失败：$($kv.Value)" }
}
Info "备份目录：$BackupDir"

# ------------------------------------------------ 3. 铺设稀疏包暂存目录 + 资源
$srcManifest = Join-Path $PSScriptRoot 'sparse\AppxManifest.xml'
if (-not (Test-Path -LiteralPath $srcManifest)) { Die "缺少 sparse\AppxManifest.xml（应与本脚本同级）。" }

New-Item -ItemType Directory -Force -Path (Join-Path $StageSparse 'Assets') | Out-Null
Copy-Item -LiteralPath $srcManifest -Destination (Join-Path $StageSparse 'AppxManifest.xml') -Force

# 复制清单引用的图标：既保留 scale 限定名，也生成无限定名副本，彻底消除 MRM 解析歧义
$assetSrc = Join-Path $mi.Win32 'Assets'
$assetMap = @{
    'StoreLogo.png'                    = @('StoreLogo.png')
    'Square150x150Logo.scale-200.png'  = @('Square150x150Logo.scale-200.png', 'Square150x150Logo.png')
    'Square44x44Logo.scale-200.png'    = @('Square44x44Logo.scale-200.png', 'Square44x44Logo.png')
}
foreach ($kv in $assetMap.GetEnumerator()) {
    $s = Join-Path $assetSrc $kv.Key
    if (-not (Test-Path -LiteralPath $s)) { Warn "缺少图标 $($kv.Key)，跳过"; continue }
    foreach ($n in $kv.Value) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $StageSparse "Assets\$n") -Force
    }
}
Ok "稀疏包已铺设：$StageSparse"

# --------------------------------------------------------- 4. 开发人员模式检查
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devOn = $false
if (Test-Path $unlock) {
    $devOn = ((Get-ItemProperty $unlock).AllowDevelopmentWithoutDevLicense -eq 1)
}
$devModeChangedByUs = $false
if (-not $devOn) {
    if ($EnableDeveloperMode) {
        Warn '正在打开系统「开发人员模式」（这是一个全局开关）。'
        New-Item -Path $unlock -Force | Out-Null
        New-ItemProperty -Path $unlock -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
        $devModeChangedByUs = $true
        Ok '开发人员模式已开启（卸载脚本可自动还原）。'
    }
    else {
        Warn '系统「开发人员模式」未开启，-Register 注册未签名松散文件会失败。'
        Warn '两种选择：'
        Warn '  a) 手动开启：设置 → 系统 → 开发者选项 → 开发人员模式；或本脚本加 -EnableDeveloperMode 重跑'
        Warn '  b) 改用 Install-RouteB-SignedMsix.ps1（签名 .msix，不需要开发人员模式）'
        Die  '已中止，未做任何注册。'
    }
}
else { Ok '开发人员模式已处于开启状态。' }

# --------------------------------------------------------------- 5. 注册稀疏包
$existing = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($existing) {
    Info "检测到旧注册 $($existing.PackageFullName)，先移除。"
    Remove-AppxPackage -Package $existing.PackageFullName
}

Info '正在注册稀疏包 …'
try {
    Add-AppxPackage -Path (Join-Path $StageSparse 'AppxManifest.xml') -Register -ExternalLocation $mi.Win32
}
catch {
    Warn "注册失败：$($_.Exception.Message)"
    Warn '常见原因与对策：'
    Warn '  0x80073CFF / 未签名  → 开发人员模式未真正生效，注销重登后重试'
    Warn '  找不到 Executable    → 检查 -ExternalLocation 目录是否含 MiPcContinuity.exe'
    Warn '  清单校验失败         → 用 Get-AppxLog -All 查看详细原因'
    Die  '已中止。原厂注册表未被修改，旧菜单入口不受影响。'
}

$pkg = Get-AppxPackage -Name $PackageName
if (-not $pkg) { Die '注册命令返回成功但查不到包，请运行 Get-AppxLog -All 排查。' }
Ok "已注册：$($pkg.PackageFullName)"
Ok "外部位置：$($mi.Win32)"

# ------------------------------------------------------------- 6. 记录安装状态
@{
    InstalledAt        = (Get-Date).ToString('o')
    PackageFullName    = $pkg.PackageFullName
    ExternalLocation   = $mi.Win32
    Route              = 'A-DevModeRegister'
    DevModeChangedByUs = $devModeChangedByUs
    BackupDir          = $BackupDir
} | ConvertTo-Json | Set-Content -LiteralPath $MarkerFile -Encoding UTF8

# ----------------------------------------------------------- 7. 让 shell 重载
if ($NoRestartExplorer) {
    Warn '已跳过重启 explorer.exe，请自行注销重登以使新菜单生效。'
}
else {
    Info '重启 explorer.exe 以重载右键菜单注册 …'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Ok 'explorer.exe 已重启。'
}

Write-Host ''
Ok '安装完成。请右键任意文件 / 文件夹，检查新版菜单第一层是否出现「使用小米互传发送」。'
Write-Host '  若未出现：注销重登一次再看（包标识的 AppExtension 目录有时需要重新登录才刷新）。' -ForegroundColor DarkGray
Write-Host '  回滚：运行 Uninstall.ps1' -ForegroundColor DarkGray
