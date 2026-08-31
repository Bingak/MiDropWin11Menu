<#
================================================================================
 Install-RouteB-SignedMsix.ps1
 把「使用小米互传发送」提升到 Windows 11 新版右键菜单第一层
 —— 路线 B：构建并安装「已签名的稀疏 .msix」，不需要开启开发人员模式
================================================================================
 与路线 A 的区别
 ---------------
   路线 A：注册未签名松散文件  → 必须开「开发人员模式」（全局开关）
   路线 B：安装已签名 .msix    → 走 Windows 默认已启用的「旁加载」，
                                 不改任何全局开关，只需把自签名证书
                                 导入 LocalMachine\TrustedPeople（作用域很窄）

 前置依赖
 --------
   Windows SDK 里的 MakeAppx.exe 与 SignTool.exe。本机检测到未安装，可任选其一：
     winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements
   或从 https://developer.microsoft.com/windows/downloads/windows-sdk/ 安装
   （安装时只勾选「Windows SDK Signing Tools for Desktop Apps」即可，体积很小）

 用法
 ----
   以管理员身份打开 PowerShell：
     powershell -ExecutionPolicy Bypass -File .\Install-RouteB-SignedMsix.ps1
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$NoRestartExplorer,
    # 手动指定 SDK bin 目录（含 makeappx.exe / signtool.exe）
    [string]$SdkBin
)

$ErrorActionPreference = 'Stop'
$PackageName  = 'MiDropWin11MenuShim'
$CertSubject  = 'CN=MiDropWin11MenuShim'   # 必须与 AppxManifest.xml 的 Publisher 完全一致
$StageRoot    = 'C:\ProgramData\MiDropWin11Menu'
$StageSparse  = Join-Path $StageRoot 'sparse'
$BackupDir    = Join-Path $StageRoot 'backup'
$OutMsix      = Join-Path $StageRoot 'MiDropWin11MenuShim.msix'
$MarkerFile   = Join-Path $StageRoot 'install-state.json'
$TargetClsid  = '{504d69c0-cb52-48df-b5b5-7161829fabc8}'

function Info($m) { Write-Host "[ * ] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[ ! ] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[ X ] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 0. 前置检查
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die '需要管理员权限。'
}
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($build -lt 22000) { Die "内部版本 $build 不是 Windows 11。" }

# 找 MakeAppx / SignTool
function Find-SdkTool([string]$name) {
    if ($SdkBin) {
        $p = Join-Path $SdkBin $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    foreach ($root in @('C:\Program Files (x86)\Windows Kits\10\bin', 'C:\Program Files\Windows Kits\10\bin')) {
        if (-not (Test-Path $root)) { continue }
        # 按真实版本号降序（目录名字符串排序会把 10.0.9900 错排到 10.0.26100 前面）
        $dirs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
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
$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'
if (-not $makeappx -or -not $signtool) {
    Warn '未找到 MakeAppx.exe / SignTool.exe。'
    Warn '请先安装 Windows SDK（只需 Signing Tools 组件）：'
    Warn '  winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements'
    Warn '安装后重跑本脚本，或用 -SdkBin "<...\bin\10.0.26100.0\x64>" 手动指定。'
    Die  '已中止，未做任何修改。'
}
Ok "MakeAppx: $makeappx"
Ok "SignTool: $signtool"

# ------------------------------------------------- 1. 定位小米互联服务安装目录
$candidates = Get-ChildItem 'C:\Program Files\MI\HyperConnect' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $dll = Join-Path $_.FullName 'resources\native-interconnect\win32\MiDropShellExt.dll'
        if (Test-Path -LiteralPath $dll) {
            $ver = [version]'0.0.0.0'
            try { $ver = [version]$_.Name } catch { }
            [pscustomobject]@{ Version = $ver; Win32 = Split-Path $dll -Parent; Dll = $dll }
        }
    } | Sort-Object Version -Descending
if (-not $candidates) { Die '未找到 MiDropShellExt.dll。' }
$mi = $candidates[0]
Ok "外部位置（-ExternalLocation）：$($mi.Win32)"

if (-not (Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$TargetClsid\InprocServer32")) {
    Die "原厂 CLSID 未注册：$TargetClsid"
}
Ok '原厂 CLSID 注册完好。'

# ------------------------------------------------------------ 2. 注册表备份
# 纯 .NET 的 .reg 导出（回退用）：某些安全策略禁用 reg.exe 会导致备份静默失败。
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

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupTargets = @{
    "CLSID-$stamp.reg"    = "HKLM\SOFTWARE\Classes\CLSID\$TargetClsid"
    "VerbStar-$stamp.reg" = 'HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu'
    "VerbDir-$stamp.reg"  = 'HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu'
}
foreach ($kv in $backupTargets.GetEnumerator()) {
    $dest = Join-Path $BackupDir $kv.Key
    & "$env:WINDIR\System32\reg.exe" export $kv.Value $dest /y | Out-Null
    if (-not (Test-Path -LiteralPath $dest)) {
        # reg.exe 被安全策略禁用 / 导出失败 → 纯 .NET 回退
        $null = Export-RegKeyPS -RootKey $kv.Value -DestFile $dest
    }
    if (Test-Path -LiteralPath $dest) { Ok "已备份 $($kv.Value)" } else { Warn "备份失败：$($kv.Value)" }
}
Ok "注册表已备份到 $BackupDir"

# ------------------------------------------------ 3. 铺设稀疏包源目录 + 资源
$srcManifest = Join-Path $PSScriptRoot 'sparse\AppxManifest.xml'
if (-not (Test-Path -LiteralPath $srcManifest)) { Die '缺少 sparse\AppxManifest.xml。' }
Remove-Item -LiteralPath $StageSparse -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $StageSparse 'Assets') | Out-Null
Copy-Item -LiteralPath $srcManifest -Destination (Join-Path $StageSparse 'AppxManifest.xml') -Force

$assetSrc = Join-Path $mi.Win32 'Assets'
@{
    'StoreLogo.png'                   = @('StoreLogo.png')
    'Square150x150Logo.scale-200.png' = @('Square150x150Logo.scale-200.png', 'Square150x150Logo.png')
    'Square44x44Logo.scale-200.png'   = @('Square44x44Logo.scale-200.png', 'Square44x44Logo.png')
}.GetEnumerator() | ForEach-Object {
    $s = Join-Path $assetSrc $_.Key
    if (Test-Path -LiteralPath $s) {
        foreach ($n in $_.Value) { Copy-Item -LiteralPath $s -Destination (Join-Path $StageSparse "Assets\$n") -Force }
    }
}
Ok "稀疏包源目录：$StageSparse"

# --------------------------------------------------------- 4. 自签名证书
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $CertSubject } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    Info "创建自签名代码签名证书 $CertSubject …"
    $cert = New-SelfSignedCertificate `
        -Type Custom -Subject $CertSubject `
        -KeyUsage DigitalSignature -FriendlyName 'MiDrop Win11 Menu Shim' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Ok "证书已创建，指纹 $($cert.Thumbprint)"
}
else { Ok "复用已有证书，指纹 $($cert.Thumbprint)" }

# 导出 pfx（含私钥，仅用于签名）与 cer（仅公钥，用于建立信任）
$pfxPwdPlain = [Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Max 256 } | ForEach-Object { [byte]$_ }))
$pfxPwd = ConvertTo-SecureString -String $pfxPwdPlain -Force -AsPlainText
$pfxPath = Join-Path $StageRoot 'signing.pfx'
$cerPath = Join-Path $StageRoot 'signing.cer'
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPwd -Force | Out-Null
Export-Certificate  -Cert $cert -FilePath $cerPath -Force | Out-Null

# 只导入公钥到 TrustedPeople —— 这是让旁加载接受此包的最小信任面
$imported = Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
Ok "公钥已导入 LocalMachine\TrustedPeople（$($imported.Thumbprint)）"

# ------------------------------------------------------------- 5. 打包并签名
Info '打包 .msix（/nv 跳过外部文件路径校验，稀疏包必需）…'
& $makeappx pack /o /d $StageSparse /nv /p $OutMsix
if ($LASTEXITCODE -ne 0) { Die "MakeAppx 失败，退出码 $LASTEXITCODE" }
Ok "已生成 $OutMsix"

Info '签名 .msix …'
& $signtool sign /fd SHA256 /f $pfxPath /p $pfxPwdPlain $OutMsix
if ($LASTEXITCODE -ne 0) { Die "SignTool 失败，退出码 $LASTEXITCODE" }
Ok '签名完成。'
Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue   # 私钥文件用完即删

# --------------------------------------------------------------- 6. 安装包
$existing = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($existing) { Info "移除旧注册 $($existing.PackageFullName)"; Remove-AppxPackage -Package $existing.PackageFullName }

Info '安装稀疏包（-ExternalLocation 指向小米原装目录）…'
try {
    Add-AppxPackage -Path $OutMsix -ExternalLocation $mi.Win32
}
catch {
    Warn "安装失败：$($_.Exception.Message)"
    Warn '  0x800B0109 CERT_E_UNTRUSTEDROOT → 证书未被信任，确认已导入 LocalMachine\TrustedPeople'
    Warn '  0x80073CF3                      → Publisher 与证书 Subject 不一致'
    Warn '  详细日志：Get-AppxLog -All'
    Die  '已中止。原厂注册表未被修改。'
}
$pkg = Get-AppxPackage -Name $PackageName
if (-not $pkg) { Die '安装后查不到包，请运行 Get-AppxLog -All。' }
Ok "已安装：$($pkg.PackageFullName)"

@{
    InstalledAt        = (Get-Date).ToString('o')
    PackageFullName    = $pkg.PackageFullName
    ExternalLocation   = $mi.Win32
    Route              = 'B-SignedMsix'
    CertThumbprint     = $cert.Thumbprint
    DevModeChangedByUs = $false
    BackupDir          = $BackupDir
} | ConvertTo-Json | Set-Content -LiteralPath $MarkerFile -Encoding UTF8

# ----------------------------------------------------------- 7. 让 shell 重载
if ($NoRestartExplorer) { Warn '已跳过重启 explorer.exe，请自行注销重登。' }
else {
    Info '重启 explorer.exe …'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Ok 'explorer.exe 已重启。'
}

Write-Host ''
Ok '安装完成。右键任意文件 / 文件夹，检查新版菜单第一层。'
Write-Host '  回滚：运行 Uninstall.ps1' -ForegroundColor DarkGray
