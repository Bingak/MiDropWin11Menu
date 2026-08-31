#Requires -Version 5.1
<#
================================================================================
 MiDrop-Menu.ps1  ——  小米互传 → Windows 11 新版右键菜单（自包含单文件）
================================================================================
 把「使用小米互传发送」从旧版「显示更多选项」菜单，提升到 Windows 11 原生
 新右键菜单第一层。不整体回退为 Win10 旧菜单、不改系统全局右键行为。

 本文件=菜单 UI + 全部核心逻辑（原 MiDrop-Menu.Core.psm1 已合并进来，
 不再有单独的模块文件）。可作为两种角色被使用：
   (1) 直接运行 → 显示交互菜单（由「一键安装.cmd」双击启动，或在管理员
       PowerShell 里直接运行）。
   (2) 被其它脚本「点源」(. .\MiDrop-Menu.ps1) → 只定义函数、不弹菜单，
       供 Install-RouteA-DevMode.ps1 / Install-RouteB-SignedMsix.ps1 /
       Uninstall.ps1 / Diagnose.ps1 调用。

 菜单选项
   [1] 路线 B 安装  —— 签名 .msix，不改任何系统全局开关     
   [2] 路线 A 安装  —— 推荐。免 SDK 免证书，但会开启「开发人员模式」
   [3] 体验一下      —— 注册后立即测试，回车确认后自动注销还原
   [4] 彻底删除      —— 注销包 + 还原开关 + 移除证书 + 卸载 SDK + 清理注册表残留 + 删生成文件
   [5] 查看当前状态
   [0] 退出

 设计原则
   - 对 HKLM\SOFTWARE\Classes 下的原厂键值只读，绝不修改 → 旧菜单入口永不受影响。
     卸载时的注册表清理【只针对非原厂来源】的 MiDropExtMenu 键（Handler ≠ 小米 CLSID）；
     原厂入口（Handler = {504d69c0-...}）一律保留不删。清理前必定先导出 .reg 备份，
     删后强制保留备份目录以便回滚。
   - 任何会改变系统状态的动作都尽量带容错；安全中心改动必走 try/finally 还原。
   - 组件目录自动挑选最高版本，系统盘不是 C: 时也能通过环境变量定位。
================================================================================
#>
[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'MiDrop Win11 右键菜单 - 一键安装'

# ------------------------------------------------------------------ 模块常量
$script:AppName         = 'MiDropWin11Menu'
$script:PackageName     = 'MiDropWin11MenuShim'
$script:CertSubject     = 'CN=MiDropWin11MenuShim'
$script:Clsid           = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'
# 小米互联服务根目录：用 ProgramFiles 环境变量，避免系统盘不是 C: 时找不到
$script:MiRoot          = Join-Path ${env:ProgramFiles} 'MI\HyperConnect'
$script:StageRoot       = Join-Path ${env:ProgramData} 'MiDropWin11Menu'
$script:StageSparse     = Join-Path $script:StageRoot 'sparse'
$script:BackupRoot      = Join-Path $script:StageRoot 'backup'
$script:StateFile       = Join-Path $script:StageRoot 'install-state.json'
$script:MsixPath        = Join-Path $script:StageRoot 'MiDropWin11MenuShim.msix'
$script:RegKey          = 'HKLM:\SOFTWARE\Classes'
$script:UnlockKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
# 脚本所在目录即项目根目录，sparse/ 与 reg/ 都在此目录
$script:ProjectRoot     = $PSScriptRoot
# 本会话内是否由脚本自动安装过 Windows SDK（写入状态文件，卸载时据此决定是否移除）
$script:SdkInstalledByUs = $false
# 安全中心本次究竟改动了哪些项，用于精确还原（null 表示未改动）
$script:_securitySnapshot = $null

# ------------------------------------------------------------------ 日志输出
function Write-Line { Write-Host ('=' * 62) -ForegroundColor DarkGray }
function Info($m) { Write-Host '[..] ' + $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host '[OK] ' + $m -ForegroundColor Green }
function Warn($m) { Write-Host '[!!] ' + $m -ForegroundColor Yellow }
function Err($m)  { Write-Host '[XX] ' + $m -ForegroundColor Red }

function Write-SectionHeader($title) {
    Write-Line
    Write-Host ('  ' + $title) -ForegroundColor Cyan
    Write-Line
}

# ------------------------------------------------------------------ 运行环境检查
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

# ------------------------------------------------------------------ 组件定位
# 定位小米互联服务目录：扫描 MiRoot 下每个版本子目录，
# 要求同时含 MiDropShellExt.dll 与 MiPcContinuity.exe，自动挑版本号最高者。
function Get-MiDropDir {
    if (-not (Test-Path -LiteralPath $script:MiRoot)) { return $null }
    # @() 包裹：只有单个版本时管道会返回标量，下标/Count 行为不一致
    $hit = @(Get-ChildItem -LiteralPath $script:MiRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dll = Join-Path $_.FullName 'resources\native-interconnect\win32\MiDropShellExt.dll'
        $exe = Join-Path $_.FullName 'resources\native-interconnect\win32\MiPcContinuity.exe'
        if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $exe)) {
            $v = [version]'0.0.0.0'
            try { $v = [version]$_.Name } catch { }
            [pscustomobject]@{
                Version  = $v
                Win32    = Split-Path $dll -Parent          # ...\win32
                Dll      = $dll
                DirName  = $_.Name                          # 版本号目录名
            }
        }
    } | Sort-Object Version -Descending)
    if ($hit.Count -eq 0) { return $null }
    return $hit[0]
}

# ------------------------------------------------------------------ 注册表备份
# 纯 .NET 的 .reg 导出（回退用）：某些安全策略会禁用 reg.exe，导致原备份逻辑静默失败。
# 用 Registry API 手工生成 regedit 可导入的 "Version 5.00" 格式（UTF-16LE + CRLF）。
# 注意：OpenSubKey 把键名当字面量处理，路径里的 * 不会被当通配符，正好符合需要。
function Export-RegKeyPS {
    param([string]$RootKey, [string]$DestFile)
    $hiveMap     = @{ 'HKLM' = [Microsoft.Win32.Registry]::LocalMachine; 'HKCU' = [Microsoft.Win32.Registry]::CurrentUser }
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

# 备份三组原厂注册表键到 BackupRoot，优先用 reg.exe，失败则走纯 .NET 回退。
function Backup-Registry {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targets = @{
        "CLSID-$ts.reg"    = "HKLM\SOFTWARE\Classes\CLSID\$($script:Clsid)"
        "VerbStar-$ts.reg" = "HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu"
        "VerbDir-$ts.reg"  = "HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu"
    }
    $ok = $true
    foreach ($k in $targets.Keys) {
        $dest = Join-Path $script:BackupRoot $k
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
    $src = Join-Path $script:ProjectRoot 'sparse\AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $src)) {
        Err "找不到 $src"
        Err '请确保 sparse 文件夹与入口脚本在同一目录。'
        return $false
    }
    if (Test-Path -LiteralPath $script:StageSparse) {
        Remove-Item -LiteralPath $script:StageSparse -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path (Join-Path $script:StageSparse 'Assets') -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $script:StageSparse 'AppxManifest.xml') -Force

    $assets = Join-Path $Win32Dir 'Assets'
    $map = @{
        'StoreLogo.png'                   = @('StoreLogo.png')
        'Square150x150Logo.scale-200.png' = @('Square150x150Logo.scale-200.png', 'Square150x150Logo.png')
        'Square44x44Logo.scale-200.png'   = @('Square44x44Logo.scale-200.png', 'Square44x44Logo.png')
    }
    foreach ($k in $map.Keys) {
        $s = Join-Path $assets $k
        if (Test-Path -LiteralPath $s) {
            foreach ($n in $map[$k]) { Copy-Item -LiteralPath $s -Destination (Join-Path $script:StageSparse "Assets\$n") -Force }
        }
    }
    return $true
}

# ------------------------------------------------------------------ 包管理
function Get-InstalledPackage {
    return @(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue) | Select-Object -First 1
}

function Remove-Package {
    $pkgs = @(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue)
    if ($pkgs.Count -eq 0) { return $true }
    foreach ($p in $pkgs) { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    # 若包被注册到「所有用户」，当前用户的 Remove-AppxPackage 会失败，补一次 -AllUsers
    $left = @(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        foreach ($p in $left) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    return (@(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue).Count -eq 0)
}

# ------------------------------------------------------------------ Windows SDK 工具
# 查找 makeappx.exe / signtool.exe（路线 B 前置）。
# 1) -SdkBin 手动指定；2) SDK 自带环境变量（最准确）；3) 扫描 Kits\10\bin 按真实版本号降序、只认 x64。
function Find-SdkTool([string]$name, [string]$SdkBin) {
    if ($SdkBin) {
        $p = Join-Path $SdkBin $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
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

# 是否装了 Windows SDK 10.0.26100（以 ARP 卸载项为准，与补丁版本号 .7705 等无关）。
# 注意：SDK 主包是 32 位 MSI，ARP 条目注册在 WOW6432Node 视图，必须两个都查。
function Test-Sdk26100Installed {
    $e = @(Get-ItemProperty @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -like 'Windows Software Development Kit - Windows 10.0.26100*' })
    return (@($e).Count -gt 0)
}

# 卸载 Windows SDK 10.0.26100：优先 winget，失败则查 ARP ProductCode 走 msiexec。
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

# ------------------------------------------------------------------ explorer 重启
function Restart-ExplorerNow {
    [CmdletBinding()]
    param([switch]$NoRestart)
    if ($NoRestart) { Warn '已跳过重启 explorer.exe，请自行注销重登以使新菜单生效。'; return }
    Info '正在重启资源管理器，右键菜单即将刷新 ...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    # 轮询等系统自动拉起（AutoRestartShell），最多 15 秒。超时才手动启动，避免重复拉起。
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

# ------------------------------------------------------------------ 原厂注册校验
# 校验原厂注册（即「显示更多选项」里的入口）是否完好。本方案对 HKLM\SOFTWARE\Classes 只读。
# 返回异常项路径数组；正常时为空数组。
# 注意：返回空数组本身即可（调用方用 .Count -eq 0 与管道遍历），不要再包一层逗号。
function Test-FactoryRegistration {
    $bad = @()
    $must = @(
        @{ Path = "$($script:RegKey)\CLSID\$($script:Clsid)\InprocServer32"; Name = '(default)';               Expect = 'MiDropShellExt.dll' },
        @{ Path = "$($script:RegKey)\*\shell\MiDropExtMenu";                  Name = 'ExplorerCommandHandler';  Expect = $script:Clsid },
        @{ Path = "$($script:RegKey)\Directory\shell\MiDropExtMenu";         Name = 'ExplorerCommandHandler';  Expect = $script:Clsid }
    )
    foreach ($m in $must) {
        if (-not (Test-Path -LiteralPath $m.Path)) { $bad += $m.Path; continue }
        $v = Get-ItemProperty -LiteralPath $m.Path -ErrorAction SilentlyContinue
        $val = if ($null -eq $v) { '' } elseif ($m.Name -eq '(default)') { $v.'(default)' } else { $v.($m.Name) }
        if ([string]::IsNullOrWhiteSpace([string]$val) -or ($val -notlike "*$($m.Expect)*")) { $bad += $m.Path }
    }
    return $bad
}

# ------------------------------------------------------------------ 注册表残留搜索与清理
<#
 Find-MiDropRegVerbs
   全量搜索注册表里所有名为 MiDropExtMenu 的键（shell 动词挂载点）。

   重要：HKEY_CLASSES_ROOT(HKCR) 并不是独立的物理键，而是
   HKLM\SOFTWARE\Classes 与 HKCU\Software\Classes 的【合并视图】。
   所以 regedit 里 HKCR 与 HKLM 下看似 4 条，实际通常只有 2 个物理键。
   本函数只搜索真实物理位置，避免把同一份数据重复计数、重复删除：
     - HKLM\SOFTWARE\Classes            （64 位机器级，原厂通常注册在这里）
     - HKCU\Software\Classes            （用户级）
     - HKLM\SOFTWARE\WOW6432Node\Classes（32 位视图）

   返回对象数组，每项含：Hive / Path（展示用完整路径）/ Root+SubPath（删除用）/ Handler。
   Handler 为 ExplorerCommandHandler 的值，用于确认归属，避免误删同名但无关的键。
#>
function Find-MiDropRegVerbs {
    [CmdletBinding()]
    param([int]$MaxDepth = 6)

    $hives = @(
        [pscustomobject]@{ Root = [Microsoft.Win32.Registry]::LocalMachine; Base = 'SOFTWARE\Classes';             Display = 'HKLM:\SOFTWARE\Classes';             Prefix = 'HKLM' },
        [pscustomobject]@{ Root = [Microsoft.Win32.Registry]::CurrentUser;  Base = 'Software\Classes';              Display = 'HKCU:\Software\Classes';             Prefix = 'HKCU' },
        [pscustomobject]@{ Root = [Microsoft.Win32.Registry]::LocalMachine; Base = 'SOFTWARE\WOW6432Node\Classes';  Display = 'HKLM:\SOFTWARE\WOW6432Node\Classes'; Prefix = 'HKLM' }
    )
    $found = New-Object System.Collections.Generic.List[object]

    # 递归遍历。命中目标名后不再深入其内部（后续是整树删除，无需再枚举子键，也省时间）
    function Walk($root, [string]$sub, [string]$basePath, [string]$display, [string]$prefix, [int]$depth) {
        if ($depth -gt $MaxDepth) { return }
        $key = $null
        try { $key = $root.OpenSubKey($sub) } catch { return }
        if (-not $key) { return }
        foreach ($n in $key.GetSubKeyNames()) {
            $child = if ($sub) { "$sub\$n" } else { $n }
            if ($n -eq 'MiDropExtMenu') {
                $handler = ''
                try {
                    $vk = $root.OpenSubKey($child)
                    if ($vk) { $handler = [string]$vk.GetValue('ExplorerCommandHandler'); $vk.Dispose() }
                } catch { }
                $rel = if ($child.Length -gt $basePath.Length) { $child.Substring($basePath.Length).TrimStart('\') } else { $child }
                $found.Add([pscustomobject]@{
                    Hive       = $display
                    Root       = $root
                    SubPath    = $child
                    Path       = "$display\$rel"
                    RegPath    = "$prefix\$child"        # 供 Export-RegKeyPS 使用
                    Handler    = $handler
                    # 归属判定：Handler 严格等于小米 CLSID 才算原厂入口，其余一律视为非原厂
                    IsFactory  = ($handler -eq $script:Clsid)
                })
                continue
            }
            Walk $root $child $basePath $display $prefix ($depth + 1)
        }
        $key.Dispose()
    }

    foreach ($h in $hives) { Walk $h.Root $h.Base $h.Base $h.Display $h.Prefix 0 }
    return $found.ToArray()
}

<#
 Remove-MiDropRegVerbs
   删除 Find-MiDropRegVerbs 找到的注册表键（整树删除，含其下所有子键与值）。

   【原厂保护（默认行为）】
   只删除 IsFactory = $false 的键，即 ExplorerCommandHandler 不等于小米 CLSID 的键。
   原厂入口（Handler = {504d69c0-...}）默认一律跳过、绝不删除，
   保证「显示更多选项」里的「使用小米互传发送」始终不受影响。
   只有显式加 -IncludeFactory 才会连原厂键一起删（一般不需要，也不建议）。

   安全措施：
   - 删除前先用 Export-RegKeyPS 把每个键导出成 .reg 存到 backup 目录，可随时导入回滚；
   - 用 .NET 的 DeleteSubKeyTree 删除，而不是 Remove-Item —— 后者遇到路径里的「*」
     会触发通配符/视图问题（实测 PowerShell 对 HKCR:\*\shell\... 的 Test-Path 会假阴性）；
   - 逐项容错，单个失败不影响其余。

   返回 @{ Removed; BackupFiles; SkippedFactory }。
#>
function Remove-MiDropRegVerbs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Verbs,
        [switch]$BackupFirst,
        [switch]$IncludeFactory
    )

    # 默认只清理「非原厂」键；原厂入口受保护，除非显式加 -IncludeFactory
    $targets = @($Verbs | Where-Object { $IncludeFactory -or -not $_.IsFactory })
    if ($targets.Count -eq 0) {
        return @{ Removed = 0; BackupFiles = @(); SkippedFactory = @($Verbs | Where-Object { $_.IsFactory }).Count }
    }

    $removed   = 0
    $savedRegs = @()

    if ($BackupFirst) {
        if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
            New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
        }
    }

    foreach ($v in $targets) {
        # 1) 删除前导出备份
        if ($BackupFirst) {
            $safe = ($v.Path -replace '[\\:*?"<>|]', '_')
            $dest = Join-Path $script:BackupRoot ("PurgeVerbs-$safe-$(Get-Date -Format 'yyyyMMdd-HHmmss').reg")
            if (Export-RegKeyPS -RootKey $v.RegPath -DestFile $dest) {
                $savedRegs += $dest
            }
            else { Warn "导出备份失败，跳过删除以保证可回滚：$($v.Path)"; continue }
        }

        # 2) 用 .NET 删除：打开父键（可写）→ DeleteSubKeyTree
        try {
            $idx    = $v.SubPath.LastIndexOf('\')
            $parent = $v.SubPath.Substring(0, $idx)
            $leaf   = $v.SubPath.Substring($idx + 1)
            $pk = $v.Root.OpenSubKey($parent, $true)   # writable = true
            if (-not $pk) { Warn "无法打开父键（可能无权限）：$($v.Path)"; continue }
            try { $pk.DeleteSubKeyTree($leaf) } finally { $pk.Dispose() }
            $removed++
            Ok "已删除：$($v.Path)"
        }
        catch {
            Warn "删除失败：$($v.Path)"
            Warn "  原因：$($_.Exception.Message)"
        }
    }
    $skipped = if ($IncludeFactory) { 0 } else { @($Verbs | Where-Object { $_.IsFactory }).Count }
    return @{ Removed = $removed; BackupFiles = $savedRegs; SkippedFactory = $skipped }
}

# 安装前的公共准备：定位组件 → 校验原厂注册 → 备份 → 铺设稀疏包目录。
# 任一步失败返回 $null（已打印原因），成功返回组件信息对象。
function Get-InstallContext {
    $mi = Get-MiDropDir
    if (-not $mi) { Err '未找到小米互联服务的组件目录，请先安装小米互联服务。'; return $null }
    Ok "组件目录：$($mi.Win32)（版本 $($mi.DirName)）"

    if (-not (Test-Path -LiteralPath "$($script:RegKey)\CLSID\$($script:Clsid)\InprocServer32")) {
        Err '原厂右键注册不存在，请先修复或重装小米互联服务。'
        return $null
    }

    Info '备份原厂注册表 ...'
    if (Backup-Registry) { Ok "备份已保存到 $($script:BackupRoot)" } else { Warn '部分备份未成功（不影响安装）。' }

    if (-not (Install-Stage $mi.Win32)) { return $null }
    return $mi
}

# ------------------------------------------------------------------ Windows 安全中心（安装时临时关闭并自动恢复）
<#
 Suspend-WindowsSecurity
   安装过程中临时关闭 Windows 安全中心里可能干扰注册/签名/证书导入的实时防护。
   - 仅关闭 Defender 实时防护（DisableRealtimeMonitoring）与下载/附件扫描（DisableIOAVProtection）；
     不动「防篡改保护」、不停止安全中心服务、不动第三方杀软。
   - 若被「防篡改保护」或组策略阻止，记录并优雅跳过，绝不让安装因此失败。
   - 通过 $script:_securitySnapshot 记录本次究竟改了哪些项，供 Resume-WindowsSecurity 精确还原。
   返回值供调用方日志展示。
#>
function Suspend-WindowsSecurity {
    [CmdletBinding()]
    param()
    $result = [pscustomobject]@{ Suspended = $false; TamperBlocked = $false; Notes = @() }
    $script:_securitySnapshot = $null

    $mp = $null
    try { $mp = Get-MpPreference -ErrorAction Stop } catch { }
    if ($null -eq $mp) {
        $result.Notes += '未检测到 Windows Defender（可能由第三方杀软接管），跳过安全中心暂停。'
        return $result
    }

    $changed = @()
    try {
        if (-not $mp.DisableRealtimeMonitoring) {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
            $changed += 'RealtimeMonitoring'
            $result.Suspended = $true
        }
        if (-not $mp.DisableIOAVProtection) {
            Set-MpPreference -DisableIOAVProtection $true -ErrorAction Stop
            $changed += 'IOAVProtection'
            $result.Suspended = $true
        }
    }
    catch {
        $result.TamperBlocked = $true
        $result.Notes += "关闭实时防护失败（可能被「防篡改保护」或组策略阻止）：$($_.Exception.Message)"
    }

    $script:_securitySnapshot = $changed
    if ($result.Suspended) {
        Info '已临时关闭 Windows 安全中心实时防护（安装完成后自动恢复）。'
    }
    elseif (-not $result.TamperBlocked) {
        $result.Notes += '实时防护本就处于关闭状态，无需改动。'
    }
    return $result
}

<#
 Resume-WindowsSecurity
   把 Suspend-WindowsSecurity 关闭的项精确还原为开启。务必放在 try/finally 或结束处调用，
   确保安装无论成功/失败都会恢复安全中心。重复调用安全（snapshot 为空则直接返回）。
#>
function Resume-WindowsSecurity {
    [CmdletBinding()]
    param()
    $snap = $script:_securitySnapshot
    $script:_securitySnapshot = $null
    if ($null -eq $snap -or $snap.Count -eq 0) { return }

    $allOk = $true
    foreach ($item in $snap) {
        try {
            switch ($item) {
                'RealtimeMonitoring' { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop }
                'IOAVProtection'     { Set-MpPreference -DisableIOAVProtection $false -ErrorAction Stop }
            }
        }
        catch {
            $allOk = $false
            Warn "恢复 Windows 安全中心项 $item 失败：$($_.Exception.Message)"
        }
    }
    if ($allOk) { Ok 'Windows 安全中心实时防护已恢复。' }
}

# ------------------------------------------------------------------ 包注册 + 状态
function Invoke-RegisterPackage([string]$Win32Dir, [string]$Route, [bool]$DevModeChanged, [string]$Thumb, [bool]$SdkInstalled) {
    Info '正在注册稀疏包 ...'
    try {
        if ($Route -eq 'A') {
            Add-AppxPackage -Path (Join-Path $script:StageSparse 'AppxManifest.xml') -Register -ExternalLocation $Win32Dir -ErrorAction Stop
        }
        else {
            Add-AppxPackage -Path $script:MsixPath -ExternalLocation $Win32Dir -ErrorAction Stop
        }
    }
    catch {
        Err "注册失败：$($_.Exception.Message)"
        Warn '排查方法：在 PowerShell 里运行  Get-AppxLog -All  查看详细原因。'
        return $false
    }
    $pkg = Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue
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
        BackupDir          = $script:BackupRoot
    }
    return $true
}

function Save-State([hashtable]$data) {
    $data.InstalledAt = (Get-Date).ToString('o')
    $data | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -Force
}

# 安装收尾：提示先测单文件，并自检原厂注册未被影响
function Write-PostInstallAdvice {
    Write-Host ''
    Warn '请务必先右键【单个文件】测试：互传窗口弹出且能看到该文件才算成功。'
    Warn '若窗口弹出但列表为空，说明本方案在你的环境不可用，请按彻底删除回滚。'
    $bad = Test-FactoryRegistration
    if ($bad.Count -eq 0) {
        Ok '自检通过：原厂注册完好，「显示更多选项」里的入口不受影响。'
    }
    else {
        Warn '自检发现原厂注册异常（本方案不修改这些键，请检查小米互联服务是否正常）：'
        $bad | ForEach-Object { Warn "    $_" }
    }
}

# 确保 makeappx / signtool 可用（路线 B 前置）。
# 返回 @{ MakeAppx=..; SignTool=.. }，或 @{ FallbackToA=$true }（用户改选路线 A），或 $null（用户取消/安装失败）。
function Ensure-SdkTools([string]$SdkBin) {
    $makeappx = Find-SdkTool 'makeappx.exe' $SdkBin
    $signtool = Find-SdkTool 'signtool.exe' $SdkBin
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
    $makeappx = Find-SdkTool 'makeappx.exe' $SdkBin
    $signtool = Find-SdkTool 'signtool.exe' $SdkBin
    if (-not $makeappx -or -not $signtool) {
        Err '安装后仍未找到工具。请重新打开本窗口再试，或改用路线 A。'
        return $null
    }
    Ok 'SDK 已就绪（卸载本工具时会提示是否一并移除它）。'
    return @{ MakeAppx = $makeappx; SignTool = $signtool }
}

# ------------------------------------------------------------------ 路线 A
function Invoke-InstallRouteA {
    [CmdletBinding()]
    param([switch]$EnableDeveloperMode, [switch]$Trial, [switch]$NoRestartExplorer)
    Write-SectionHeader $(if ($Trial) { '体验模式（路线 A，回车确认后自动还原）' } else { '路线 A 安装' })

    if (-not $Trial) {
        Warn '此路线需要开启系统「开发人员模式」（一个全局开关）。'
        Warn '若不想改全局开关，请改用路线 B。'
        Write-Host ''
    }

    $mi = Get-InstallContext
    if (-not $mi) { return }

    # 开发人员模式
    $devOn = $false
    if (Test-Path $script:UnlockKey) { $devOn = ((Get-ItemProperty $script:UnlockKey).AllowDevelopmentWithoutDevLicense -eq 1) }
    $devChanged = $false
    if (-not $devOn) {
        if ($EnableDeveloperMode) {
            Info '正在开启「开发人员模式」...'
            New-Item -Path $script:UnlockKey -Force | Out-Null
            New-ItemProperty -Path $script:UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
            $devChanged = $true
            Ok '已开启（卸载时会自动还原）。'
        }
        else {
            Warn '系统「开发人员模式」未开启，-Register 注册未签名松散文件会失败。'
            Warn '  请加 -EnableDeveloperMode 重跑，或改用路线 B（Install-RouteB-SignedMsix.ps1）。'
            return
        }
    }
    else { Ok '「开发人员模式」已经是开启状态。' }

    Remove-Package | Out-Null

    # 安装期间临时关闭 Windows 安全中心，结束（含异常）后自动恢复
    $null = Suspend-WindowsSecurity
    try {
        if (-not (Invoke-RegisterPackage $mi.Win32 'A' $devChanged '' $false)) { return }
    }
    finally {
        Resume-WindowsSecurity
    }

    if ($Trial) {
        Restart-ExplorerNow -NoRestart:$NoRestartExplorer
        Write-Host ''
        Ok '体验模式已启用！现在右键任意文件，看看新版菜单第一层是否出现。'
        Warn '体验注册同样是持久的，不会因重启电脑自动消失；'
        Warn '请在测试完毕后回到本窗口按回车，脚本会自动注销并还原。'
        $null = Read-Host '  测试完毕后按回车，自动注销并还原'
        Info '正在注销体验注册 ...'
        Remove-Package | Out-Null
        if ($devChanged) {
            Set-ItemProperty -Path $script:UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Info '「开发人员模式」已还原为关闭。'
        }
        if (Test-Path -LiteralPath $script:StageRoot) {
            Remove-Item -LiteralPath $script:StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Restart-ExplorerNow -NoRestart:$NoRestartExplorer
        Ok '体验结束，已恢复原状，未留任何痕迹。'
        Warn '若本窗口意外关闭导致未还原，重新运行脚本选彻底删除即可。'
    }
    else {
        Restart-ExplorerNow -NoRestart:$NoRestartExplorer
        Write-Host ''
        Ok '安装完成！请右键任意文件或文件夹查看效果。'
        Warn '若未出现，请注销重登一次再试。'
        Write-PostInstallAdvice
    }
}

# ------------------------------------------------------------------ 路线 B
function Invoke-InstallRouteB {
    [CmdletBinding()]
    param([switch]$NoRestartExplorer, [string]$SdkBin)
    Write-SectionHeader '路线 B 安装（签名 .msix，不改系统全局开关）[推荐]'

    $sdk = Ensure-SdkTools -SdkBin $SdkBin
    if (-not $sdk) { return }
    if ($sdk.FallbackToA) { Invoke-InstallRouteA -EnableDeveloperMode; return }

    $mi = Get-InstallContext
    if (-not $mi) { return }

    # 安装期间临时关闭 Windows 安全中心（覆盖证书创建、打包、签名、注册全过程）
    $null = Suspend-WindowsSecurity
    try {
        # 自签名证书
        Info '准备签名证书 ...'
        $cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq $script:CertSubject } |
                Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) {
            try {
                $cert = New-SelfSignedCertificate -Type Custom -Subject $script:CertSubject `
                    -KeyUsage DigitalSignature -FriendlyName 'MiDrop Win11 Menu Shim' `
                    -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5) `
                    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -ErrorAction Stop
            }
            catch { Err "证书创建失败：$($_.Exception.Message)"; return }
        }
        Ok "证书指纹 $($cert.Thumbprint)"

        $pwdPlain = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
        $pwd  = ConvertTo-SecureString -String $pwdPlain -Force -AsPlainText
        $pfx  = Join-Path $script:StageRoot 'signing.pfx'
        $cer  = Join-Path $script:StageRoot 'signing.cer'
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd -Force | Out-Null
        Export-Certificate  -Cert $cert -FilePath $cer -Force | Out-Null
        Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
        Ok '公钥已加入系统信任列表（卸载时会移除）。'

        # 打包 + 签名
        Info '打包并签名 .msix ...'
        & $sdk.MakeAppx pack /o /d $script:StageSparse /nv /p $script:MsixPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Err "MakeAppx 打包失败，退出码 $LASTEXITCODE"; Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue; return }
        & $sdk.SignTool sign /fd SHA256 /f $pfx /p $pwdPlain $script:MsixPath 2>&1 | Out-Null
        Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { Err "SignTool 签名失败，退出码 $LASTEXITCODE"; return }
        Ok '签名完成，私钥文件已销毁。'

        Remove-Package | Out-Null
        if (-not (Invoke-RegisterPackage $mi.Win32 'B' $false $cert.Thumbprint $script:SdkInstalledByUs)) { return }
    }
    finally {
        Resume-WindowsSecurity
    }

    Restart-ExplorerNow -NoRestart:$NoRestartExplorer
    Write-Host ''
    Ok '安装完成！请右键任意文件或文件夹查看效果。'
    Warn '若未出现，请注销重登一次再试。'
    Write-PostInstallAdvice
}

# ------------------------------------------------------------------ 彻底删除
function Invoke-Uninstall {
    [CmdletBinding()]
    param(
        [switch]$KeepBackup,
        [switch]$KeepDeveloperMode,
        [switch]$KeepSdk,
        [switch]$NoRestartExplorer,
        [switch]$PurgeRegistryVerbs,
        [switch]$KeepRegistryVerbs
    )
    Write-SectionHeader '彻底删除（注销 + 还原开关 + 移除证书 + 卸载 SDK + 清理注册表残留 + 清理生成文件）'

    $state = $null
    if (Test-Path -LiteralPath $script:StateFile) {
        try { $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json } catch { }
    }

    Write-Host '  此操作会：' -ForegroundColor DarkGray
    Write-Host '    1. 注销右键菜单包（新菜单里的条目消失）'
    Write-Host '    2. 还原「开发人员模式」开关（若当初由本脚本开启）'
    Write-Host '    3. 移除自签名证书'
    Write-Host '    4. 卸载本脚本自动安装的 Windows SDK 10.0.26100（若有）'
    Write-Host '    5. 搜索注册表 MiDropExtMenu 残留，只清理【非原厂】来源的键'
    if ($PurgeRegistryVerbs) { Write-Host '       （-PurgeRegistryVerbs：确认清理非原厂残留，不再询问）' -ForegroundColor Yellow }
    elseif ($KeepRegistryVerbs) { Write-Host '       （-KeepRegistryVerbs：跳过，既不搜索也不删除）' -ForegroundColor DarkGray }
    else { Write-Host '       （默认：搜索后询问；原厂入口一律保留不删）' -ForegroundColor DarkGray }
    Write-Host '    6. 删除 C:\ProgramData\MiDropWin11Menu'
    if ($KeepBackup) { Write-Host '       （-KeepBackup：保留注册表备份子目录）' -ForegroundColor Yellow }
    else { Write-Host '       （含注册表备份；加 -KeepBackup 可保留）' -ForegroundColor DarkGray }
    Write-Host '  不会动小米互联服务的程序文件。'
    Write-Host ''
    Write-Host '  说明：注册表清理只针对【非原厂】来源的 MiDropExtMenu 键；' -ForegroundColor Green
    Write-Host '        小米原厂入口（Handler = {504d69c0-...}）一律保留不删，' -ForegroundColor Green
    Write-Host '        「显示更多选项」里的「使用小米互传发送」始终可用。' -ForegroundColor Green
    Write-Host ''
    $c = (Read-Host '  确认删除？输入 y 继续，其它取消').Trim().ToLower()
    if ($c -ne 'y') { Info '已取消。'; return }

    Write-Host ''
    Info '1/6 注销包 ...'
    if (Remove-Package) { Ok '已注销（或本就未安装）。' } else { Warn '包可能仍被占用，请注销重登后重试一次。' }

    Info '2/6 还原「开发人员模式」...'
    if ($state -and $state.DevModeChangedByUs -eq $true) {
        if (-not $KeepDeveloperMode -and (Test-Path $script:UnlockKey)) {
            Set-ItemProperty -Path $script:UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Ok '已还原为关闭。'
        }
        elseif ($KeepDeveloperMode) { Warn '按要求保留「开发人员模式」为开启状态。' }
    }
    else {
        $keep = (Read-Host '    未记录是否由本脚本开启过。要把「开发人员模式」关掉吗？(y/n)').Trim().ToLower()
        if ($keep -eq 'y' -and -not $KeepDeveloperMode -and (Test-Path $script:UnlockKey)) {
            Set-ItemProperty -Path $script:UnlockKey -Name 'AllowDevelopmentWithoutDevLicense' -Value 0 -Type DWord -Force
            Ok '已关闭。'
        }
        else { Info '保持原状。' }
    }

    Info '3/6 移除证书 ...'
    $n = 0
    foreach ($c2 in @(Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $script:CertSubject })) {
        Remove-Item -LiteralPath $c2.PSPath -Force -ErrorAction SilentlyContinue; $n++
    }
    foreach ($c2 in @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $script:CertSubject })) {
        Remove-Item -LiteralPath $c2.PSPath -Force -ErrorAction SilentlyContinue; $n++
    }
    Ok "已移除 $n 张证书。"

    Info '4/6 移除 Windows SDK（若由本脚本自动安装）...'
    if (-not $KeepSdk) {
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
    }
    else { Info '按要求保留 Windows SDK。' }

    Info '5/6 搜索并清理注册表里的 MiDropExtMenu 残留 ...'
    $purgeKeptBackup = $false
    if ($KeepRegistryVerbs) {
        Info '已指定 -KeepRegistryVerbs，跳过注册表搜索与清理。'
    }
    else {
        Info '正在全量搜索（HKLM\SOFTWARE\Classes / HKCU\Software\Classes / WOW6432Node\Classes）...'
        $verbs = @(Find-MiDropRegVerbs)
        if ($verbs.Count -eq 0) {
            Ok '未找到任何 MiDropExtMenu 注册表键，无需清理。'
        }
        else {
            # 分类：原厂入口（Handler 严格等于小米 CLSID） vs 其它来源（可能是残留）
            $factory = @($verbs | Where-Object { $_.IsFactory })
            $others  = @($verbs | Where-Object { -not $_.IsFactory })

            Write-Host "    共找到 $($verbs.Count) 个 MiDropExtMenu 键：" -ForegroundColor Yellow
            foreach ($v in $verbs) {
                Write-Host "      - $($v.Path)"
                Write-Host ("          Handler = {0}{1}" -f $v.Handler, $(if ($v.IsFactory) { '   ← 小米原厂入口（保留）' } else { '   ← 非原厂来源' }))
            }
            Write-Host ''

            # 原厂入口一律保护，绝不删除
            if ($factory.Count -gt 0) {
                Ok "其中 $($factory.Count) 个是小米原厂入口 —— 按策略【保留不删】，"
                Ok '「显示更多选项」里的「使用小米互传发送」不受影响。'
            }

            if ($others.Count -eq 0) {
                Ok '没有非原厂来源的残留键，无需清理；原厂入口保持原样。'
            }
            else {
                Write-Host "    另有 $($others.Count) 个【非原厂】来源的键：" -ForegroundColor Yellow
                foreach ($v in $others) { Write-Host "      - $($v.Path)" -ForegroundColor Yellow }
                $doPurge = $false
                if ($PurgeRegistryVerbs) { $doPurge = $true }
                else {
                    $ans = (Read-Host '    要清理这些非原厂残留键吗？(y/n，默认 n)').Trim().ToLower()
                    $doPurge = ($ans -eq 'y')
                }
                if ($doPurge) {
                    # 只传非原厂键，且不带 -IncludeFactory → 双保险，原厂键绝不会被删
                    $r = Remove-MiDropRegVerbs -Verbs $others -BackupFirst
                    if ($r.Removed -gt 0) {
                        Ok "已清理 $($r.Removed) 个非原厂残留键（原厂入口 $($factory.Count) 个已保留）。"
                        # 删过注册表后，.reg 是唯一回滚手段 → 强制保留 backup 目录
                        $purgeKeptBackup = $true
                        if ($r.BackupFiles.Count -gt 0) {
                            Write-Host '    回滚备份（务必保留）：' -ForegroundColor Yellow
                            foreach ($f in $r.BackupFiles) { Write-Host "      $f" -ForegroundColor Yellow }
                            Warn '如需恢复：用 64 位 regedit（%WINDIR%\regedit.exe）导入上述 .reg。'
                        }
                    }
                    else { Warn '没有删除任何注册表键（多半是无权限）。请以管理员身份重跑。' }
                }
                else { Info '已保留，未做删除。' }
            }
        }
    }

    Info '6/6 清理生成文件 ...'
    # 先显式处理注册表备份目录：默认删除；加 -KeepBackup、或本轮刚删过注册表键则保留。
    $backupDir = $script:BackupRoot
    if ($KeepBackup -or $purgeKeptBackup) {
        if ($purgeKeptBackup -and -not $KeepBackup) {
            Warn '本轮删除过注册表键，已强制保留备份目录（内含回滚用的 .reg）。'
        }
        elseif (Test-Path -LiteralPath $backupDir) { Info '已指定 -KeepBackup，注册表备份目录将保留。' }
        else { Info '已指定 -KeepBackup，但注册表备份目录不存在。' }
    }
    else {
        if (Test-Path -LiteralPath $backupDir) {
            Info "正在删除注册表备份目录：$backupDir ..."
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $backupDir) {
                Warn '注册表备份目录未能立即删除，将在清理暂存目录时再次尝试。'
            }
            else {
                Ok '已删除注册表备份目录。'
            }
        }
        else {
            Info '注册表备份目录不存在，无需删除。'
        }
    }

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
        if (Test-Path -LiteralPath $script:StageRoot) {
            Remove-Item -LiteralPath $script:StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $script:StageRoot)) { break }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $script:StageRoot) {
        Warn "未能完全删除：$($script:StageRoot)"
        Warn '通常是 DLL 仍被占用。请重启电脑后手动删除该文件夹。'
    }
    else { Ok "已删除 $($script:StageRoot)" }

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
        $regFile = Join-Path $script:ProjectRoot 'reg\Restore-MiDrop-Original.reg'
        Warn "可用 reg\Restore-MiDrop-Original.reg 修复（用 64 位 regedit 导入）。"
    }
    Write-Host ''
    Ok '清理完成，系统已恢复。'
}

# ------------------------------------------------------------------ 状态
function Show-InstallStatus {
    Write-Line
    Write-Host '  当前状态' -ForegroundColor Cyan
    Write-Line

    $state = $null
    if (Test-Path -LiteralPath $script:StateFile) {
        try { $state = Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $state = $null }
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

    $pkg = Get-InstalledPackage
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
    if (Test-Path $script:UnlockKey) { $dev = if ((Get-ItemProperty $script:UnlockKey).AllowDevelopmentWithoutDevLicense -eq 1) { '已开启' } else { '未开启' } }
    Write-Host '  开发人员模式       ' -NoNewline -ForegroundColor Gray
    Write-Host $dev -ForegroundColor $(if ($dev -eq '已开启') { 'Yellow' } else { 'Green' })

    $cls = Test-Path -LiteralPath "$($script:RegKey)\CLSID\$($script:Clsid)\InprocServer32"
    Write-Host '  原厂右键注册       ' -NoNewline -ForegroundColor Gray
    Write-Host $(if ($cls) { '完好' } else { '缺失' }) -ForegroundColor $(if ($cls) { 'Green' } else { 'Red' })

    $mk = Find-SdkTool 'makeappx.exe' $null
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
    Write-Host $(if (Test-Path -LiteralPath $script:StageRoot) { $script:StageRoot } else { '不存在' })
    Write-Line
}

# ------------------------------------------------------------------ 诊断（只读）
function Show-Diagnostics {
    function H($t) { Write-Host ''; Write-Host "── $t " -ForegroundColor Cyan -NoNewline; Write-Host ('─' * [Math]::Max(0, 60 - $t.Length)) -ForegroundColor DarkCyan }
    function KV($k, $v) { Write-Host ("  {0,-34}" -f $k) -NoNewline -ForegroundColor Gray; Write-Host $v }

    H '系统'
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    KV 'DisplayVersion' $cv.DisplayVersion
    KV 'Build' "$($cv.CurrentBuild).$($cv.UBR)"
    KV '是否支持新版右键菜单' $(if ([int]$cv.CurrentBuild -ge 22000) { '是 (>=22000)' } else { '否' })
    KV 'OS 架构' $env:PROCESSOR_ARCHITECTURE

    H '小米互联服务组件'
    $found = @()
    Get-ChildItem $script:MiRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dll = Join-Path $_.FullName 'resources\native-interconnect\win32\MiDropShellExt.dll'
        if (Test-Path -LiteralPath $dll) { $found += $dll }
    }
    if (-not $found) { KV 'MiDropShellExt.dll' '未找到（小米互联服务未安装？）' }
    foreach ($d in $found) {
        KV '处理器 DLL' $d
        $fi = Get-Item -LiteralPath $d
        KV '  大小 / 修改时间' "$($fi.Length) bytes / $($fi.LastWriteTime)"
        $fs = [IO.File]::OpenRead($d)
        try { $br = New-Object IO.BinaryReader($fs); $fs.Position = 0x3C; $pe = $br.ReadInt32(); $fs.Position = $pe + 4; $m = $br.ReadUInt16() } finally { $fs.Dispose() }
        KV '  PE 架构' $(switch ($m) { 0x8664 { 'x64 (与 explorer.exe 匹配)' } 0x14C { 'x86 (不匹配，无法加载)' } 0xAA64 { 'ARM64' } default { "0x$($m.ToString('X'))" } })
        # 二进制扫描 IID，判断实现的是哪个接口
        $bytes = [IO.File]::ReadAllBytes($d)
        function Has([string]$g) {
            $by = ([Guid]$g).ToByteArray()
            for ($i = 0; $i -lt $bytes.Length - 16; $i++) {
                if ($bytes[$i] -eq $by[0] -and $bytes[$i + 1] -eq $by[1] -and $bytes[$i + 2] -eq $by[2] -and $bytes[$i + 3] -eq $by[3]) {
                    $okm = $true; for ($j = 4; $j -lt 16; $j++) { if ($bytes[$i + $j] -ne $by[$j]) { $okm = $false; break } }
                    if ($okm) { return $true }
                }
            }
            return $false
        }
        KV '  含 IExplorerCommand IID' $(if (Has 'A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9') { '是 → 现代处理器，可进新菜单' } else { '否' })
        KV '  含 IContextMenu IID' $(if (Has '000214E4-0000-0000-C000-000000000046') { '是 → 传统处理器' } else { '否（不是传统处理器）' })
    }

    H "COM 注册 CLSID $($script:Clsid)"
    foreach ($hive in @('HKLM:\SOFTWARE\Classes', 'HKLM:\SOFTWARE\Classes\WOW6432Node', 'HKCU:\SOFTWARE\Classes')) {
        $p = "$hive\CLSID\$($script:Clsid)"
        if (Test-Path -LiteralPath $p) {
            KV $p ((Get-ItemProperty -LiteralPath $p).'(default)')
            $ip = "$p\InprocServer32"
            if (Test-Path -LiteralPath $ip) {
                $v = Get-ItemProperty -LiteralPath $ip
                KV '  InprocServer32' $v.'(default)'
                KV '  ThreadingModel' $v.ThreadingModel
            }
        }
        else { KV $p '不存在' }
    }

    H 'verb 注册位置（决定出现在哪个菜单）'
    foreach ($p in @('HKLM:\SOFTWARE\Classes\*\shell\MiDropExtMenu',
                     'HKLM:\SOFTWARE\Classes\Directory\shell\MiDropExtMenu',
                     'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\MiDropExtMenu')) {
        if (Test-Path -LiteralPath $p) {
            $v = Get-ItemProperty -LiteralPath $p
            $ech = $v.ExplorerCommandHandler
            KV $p $(if ($ech) { "ExplorerCommandHandler=$ech" } else { '(存在，但无 ExplorerCommandHandler)' })
        }
        else { KV $p '不存在' }
    }

    H '稀疏包（包标识）状态'
    $pkg = Get-InstalledPackage
    if ($pkg) {
        KV 'PackageFullName' $pkg.PackageFullName
        KV 'InstallLocation' $pkg.InstallLocation
        KV 'SignatureKind' $pkg.SignatureKind
        KV 'Status' $pkg.Status
        Write-Host '  → 已具备包标识，新版右键菜单第一层应能显示。' -ForegroundColor Green
    }
    else {
        KV $script:PackageName '未安装'
        Write-Host '  → 无包标识，条目只会出现在「显示更多选项」旧菜单里。' -ForegroundColor Yellow
    }

    H '安装状态文件'
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $st = Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            KV 'Route' $st.Route
            KV 'ExternalLocation' $st.ExternalLocation
            KV '  有效性' $(if ($st.ExternalLocation -and (Test-Path -LiteralPath $st.ExternalLocation)) { '有效' } else { '已失效（组件可能已升级，需重装）' })
            KV 'DevModeChangedByUs' $st.DevModeChangedByUs
            KV 'SdkInstalledByUs' $st.SdkInstalledByUs
            KV 'InstalledAt' $st.InstalledAt
        }
        catch { KV $script:StateFile '解析失败（文件已损坏）' }
    }
    else { KV $script:StateFile '不存在（尚未安装或已清理）' }

    H '环境开关与工具'
    $unlock = $script:UnlockKey
    $dev = if (Test-Path $unlock) { (Get-ItemProperty $unlock).AllowDevelopmentWithoutDevLicense } else { $null }
    KV '开发人员模式' $(if ($dev -eq 1) { '开启（路线 A 可用）' } else { '关闭（路线 A 需先开启）' })
    $classic = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    KV '全局回退旧菜单开关' $(if (Test-Path -LiteralPath $classic) { '存在 —— 整个右键菜单已回退为 Win10 旧版' } else { '不存在（新菜单正常，符合预期）' })
    $mk = Find-SdkTool 'makeappx.exe' $null
    KV 'MakeAppx.exe (x64)' $(if ($mk) { $mk } else { '未安装（路线 B 需要 Windows SDK）' })
    $sdk26100 = @(Get-ItemProperty @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Windows Software Development Kit - Windows 10.0.26100*' })
    KV 'Windows SDK 10.0.26100' $(if ($sdk26100.Count -gt 0) { "已安装（$($sdk26100[0].DisplayName)）" } else { '未安装' })

    Write-Host ''
}

# ------------------------------------------------------------------ 交互菜单
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
    Write-Host '签名安装，不改任何系统全局开关。' -ForegroundColor Gray
    Write-Host '                   需 Windows SDK（没有的话会提示自动装,占用4G左右）。'
    Write-Host ''
    Write-Host '   [2] 路线 A 安装  ' -NoNewline -ForegroundColor Cyan
    Write-Host '推荐。免 SDK 免证书，但会开启系统「开发人员模式」。' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [3] 体验一下      ' -NoNewline -ForegroundColor Cyan
    Write-Host '注册后立即测试，回车确认后自动注销还原。' -ForegroundColor Gray
    Write-Host '                   想先看看效果选这个。'
    Write-Host ''
    Write-Host '   [4] 彻底删除      ' -NoNewline -ForegroundColor Yellow
    Write-Host '注销包 + 还原开关 + 卸载 SDK + 清理注册表残留 + 删生成文件。' -ForegroundColor Gray
    Write-Host '                   只清非原厂残留键，小米原厂入口保留不动（删前自动 .reg 备份）。'
    Write-Host ''
    Write-Host '   [5] 查看当前状态' -ForegroundColor Gray
    Write-Host '   [0] 退出' -ForegroundColor Gray
    Write-Line

    if (Get-InstalledPackage) {
        Write-Host '   提示：当前已安装，重复安装会先自动卸载旧的。' -ForegroundColor Yellow
    }
    Write-Host ''
}

# ------------------------------------------------------------------ 入口守卫
# 直接运行本文件（powershell -File .\MiDrop-Menu.ps1 / 双击「一键安装.cmd」）才显示菜单；
# 被其它脚本点源（. .\MiDrop-Menu.ps1）时只定义上面的函数，不弹菜单、不 exit。
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host '正在检查运行环境 ...' -ForegroundColor DarkGray
    if (-not (Assert-Admin)) { if (-not $NoPause) { Read-Host '按回车退出' }; exit 1 }
    if (-not (Assert-Win11)) { if (-not $NoPause) { Read-Host '按回车退出' }; exit 1 }

    while ($true) {
        Show-Menu
        $sel = (Read-Host '   请输入序号后回车').Trim()
        switch ($sel) {
            '1' { Invoke-InstallRouteB;  Write-Host ''; Read-Host '按回车返回菜单' }
            '2' { Invoke-InstallRouteA -EnableDeveloperMode; Write-Host ''; Read-Host '按回车返回菜单' }
            '3' { Invoke-InstallRouteA -EnableDeveloperMode -Trial; Write-Host ''; Read-Host '按回车返回菜单' }
            '4' { Invoke-Uninstall;      Write-Host ''; Read-Host '按回车返回菜单' }
            '5' { Show-InstallStatus;    Write-Host ''; Read-Host '按回车返回菜单' }
            '0' { Write-Host '再见。'; exit 0 }
            default { Write-Host '   无效输入，请重试。' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}
