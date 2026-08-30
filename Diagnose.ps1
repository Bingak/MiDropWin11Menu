<#
================================================================================
 Diagnose.ps1  —— 只读体检，不修改任何东西
================================================================================
 输出：系统版本 / 组件目录 / CLSID 与 DLL / 接口实现方式 / verb 注册位置 /
       稀疏包状态 / 开发人员模式 / SDK 工具可用性
 安装前后各跑一次，便于对比。
   powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1
================================================================================
#>
$ErrorActionPreference = 'Continue'
$TargetClsid = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'
$PackageName = 'MiDropWin11MenuShim'

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
Get-ChildItem 'C:\Program Files\MI\HyperConnect' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
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

H "COM 注册 CLSID $TargetClsid"
foreach ($hive in @('HKLM:\SOFTWARE\Classes', 'HKLM:\SOFTWARE\Classes\WOW6432Node', 'HKCU:\SOFTWARE\Classes')) {
    $p = "$hive\CLSID\$TargetClsid"
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
$pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($pkg) {
    KV 'PackageFullName' $pkg.PackageFullName
    KV 'InstallLocation' $pkg.InstallLocation
    KV 'SignatureKind' $pkg.SignatureKind
    KV 'Status' $pkg.Status
    Write-Host '  → 已具备包标识，新版右键菜单第一层应能显示。' -ForegroundColor Green
}
else {
    KV $PackageName '未安装'
    Write-Host '  → 无包标识，条目只会出现在「显示更多选项」旧菜单里。' -ForegroundColor Yellow
}

H '环境开关与工具'
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$dev = if (Test-Path $unlock) { (Get-ItemProperty $unlock).AllowDevelopmentWithoutDevLicense } else { $null }
KV '开发人员模式' $(if ($dev -eq 1) { '开启（路线 A 可用）' } else { '关闭（路线 A 需先开启）' })
$classic = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
KV '全局回退旧菜单开关' $(if (Test-Path -LiteralPath $classic) { '存在 —— 整个右键菜单已回退为 Win10 旧版' } else { '不存在（新菜单正常，符合预期）' })
$mk = $null
foreach ($root in @('C:\Program Files (x86)\Windows Kits\10\bin', 'C:\Program Files\Windows Kits\10\bin')) {
    if (Test-Path $root) { $mk = Get-ChildItem $root -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if ($mk) { break }
}
KV 'MakeAppx.exe' $(if ($mk) { $mk } else { '未安装（路线 B 需要 Windows SDK）' })

Write-Host ''
