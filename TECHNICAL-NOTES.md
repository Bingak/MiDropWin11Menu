# 技术说明：为什么它只在旧菜单，以及本方案的原理

> 实测环境：Windows 11 25H2，内部版本 **26200.9168**，x64
> 组件版本：`C:\Program Files\MI\HyperConnect\2.0.1.452`
> 深入分析和实测证据记录在此文件；只想使用请看 [README.md](README.md)。

---

## 1. 实现方式判定

### 1.1 它注册在哪里

在 `HKCR\*\shellex\ContextMenuHandlers`、`AllFilesystemObjects\shellex\...`、`Directory\shellex\...` 中 **没有** 任何小米相关项。真正的注册位置是 **静态 verb + `ExplorerCommandHandler`**：

| 注册路径 | 值 |
|---|---|
| `HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu` | `ExplorerCommandHandler = {504d69c0-cb52-48df-b5b5-7161829fabc8}` |
| `HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu` | `ExplorerCommandHandler = {504d69c0-cb52-48df-b5b5-7161829fabc8}` |

注意两个细节：**没有 `command` 子键**，**不是 `shellex\ContextMenuHandlers`**。这两点排除了「传统静态 verb」和「传统 IContextMenu 处理器」两种可能。

### 1.2 CLSID 与 DLL

```
HKLM\SOFTWARE\Classes\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}
    @                = "CMiDropContextMenuExt class"
    InprocServer32\@ = C:\Program Files\MI\HyperConnect\2.0.1.452\resources\
                       native-interconnect\win32\MiDropShellExt.dll
    InprocServer32\ThreadingModel = Apartment
    TypeLib\@        = {6fe24b7c-1fc3-4280-933c-f56b788dc058}   (MiDropShellExtLib)
    Version\@        = 1.0
Interface\{775BEDBE-8339-48F5-99D3-6429C4A67D19} = ICMiDropContextMenuExt
```

`WOW6432Node` 下**没有**镜像注册项 —— 因为 DLL 是纯 x64。

### 1.3 接口判定（决定性证据）

对 `MiDropShellExt.dll`（73,304 字节，ATL 编写，DigiCert 签名）做 PE 头与 IID 二进制扫描：

| 项目 | 结果 |
|---|---|
| PE Machine | `0x8664` → **x64**，与 64 位 `explorer.exe` 匹配 |
| `IID_IExplorerCommand` `{A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9}` | **存在** |
| `IID_IContextMenu` `{000214E4-...}` | 不存在 |
| `IID_IShellExtInit` `{000214E8-...}` | 不存在 |
| `IID_IEnumExplorerCommand` | 不存在（单条命令，无级联子菜单） |

### 1.4 结论

> **它不是传统 IContextMenu 处理器，而是已经实现了 `IExplorerCommand` 的现代处理器。**

进新菜单的两个必要条件：

| 条件 | 状态 |
|---|---|
| ① 实现 `IExplorerCommand` | ✅ 已满足 |
| ② 拥有 **package identity（包标识）** | ❌ **缺失** —— 这才是唯一卡点 |

`Get-AppxPackage` 全量 129 个包中没有任何小米相关条目，小米互联服务是纯 Win32 安装（Electron + ATL DLL），没有 MSIX，也没有稀疏包。微软官方文档明确要求二者同时满足，否则「your app's context menu extension will appear in the older context menu available via the **Show more options** item」——这就是你看到的现象。

附带发现：小米其实已经把 MSIX 需要的图标资源打包进去了（`win32\Assets\` 下有 `Square44x44Logo.scale-200.png`、`Square150x150Logo.scale-200.png`、`StoreLogo.png` 等），只是没有真的做包。本方案直接复用这些资源。

---

## 2. 方案

### 2.1 为什么纯 `.reg` 做不到

Win11 新版菜单不是从 `HKCR` 枚举命令的。它读取的是 **部署栈维护的 AppExtension 目录**：包安装时，`windows.comServer` 与 `windows.fileExplorerContextMenus` 声明被写入
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PackagedCom\...`（Package / ClassIndex）以及 `AppExtension` 相关目录。这些键：

- 由 **TrustedInstaller** 拥有，普通管理员没有写权限；
- 结构未公开文档化，且随系统更新变化；
- 会被部署栈在包状态变更 / 系统服务时重建，手工伪造的条目会被抹掉。

所以「手写 .reg 伪造包标识」既做不到也不该做。**唯一受支持的路径是注册一个稀疏包（sparse package）**：一个只含 `AppxManifest.xml` 的签名 MSIX，用 `-ExternalLocation` 指向已存在的安装目录，从而把包标识授予外部的 Win32 文件。Notepad++ 与 NanaZip 都是这么做的。

### 2.2 本方案（关键点：不需要写任何代码）

因为原 DLL 已经实现 `IExplorerCommand`，稀疏包清单里可以**直接引用原厂 CLSID 与原厂 DLL**：

```xml
<com:Extension Category="windows.comServer">
  <com:ComServer>
    <com:SurrogateServer DisplayName="MiDrop Context Menu Handler">
      <com:Class Id="504d69c0-cb52-48df-b5b5-7161829fabc8"
                 Path="MiDropShellExt.dll" ThreadingModel="STA" />
    </com:SurrogateServer>
  </com:ComServer>
</com:Extension>

<desktop4:Extension Category="windows.fileExplorerContextMenus">
  <desktop4:FileExplorerContextMenus>
    <desktop5:ItemType Type="*">
      <desktop5:Verb Id="MiDropSendFile"   Clsid="504d69c0-cb52-48df-b5b5-7161829fabc8" />
    </desktop5:ItemType>
    <desktop5:ItemType Type="Directory">
      <desktop5:Verb Id="MiDropSendFolder" Clsid="504d69c0-cb52-48df-b5b5-7161829fabc8" />
    </desktop5:ItemType>
  </desktop4:FileExplorerContextMenus>
</desktop4:Extension>
```

`Path` / `Executable` 都是**相对路径**，注册时由 `-ExternalLocation` 解析到
`C:\Program Files\MI\HyperConnect\<版本>\resources\native-interconnect\win32`。
包里不含任何二进制，不复制、不劫持、不改原厂注册表。

菜单文字与图标由 DLL 自己通过 `IExplorerCommand::GetTitle` / `GetIcon` 提供（DLL 内嵌字符串为 `使用小米互传发送` 与 `\Assets\midrop_logo.ico`），所以显示效果与旧菜单里完全一致。

### 2.3 关于「可直接调用的可执行文件与命令行参数」

从 `MiDropShellExt.dll` 提取的字符串揭示了它的转发机制：

```
Local\MiDropFileMappingObject     ← 命名共享内存（file mapping）
parent_dir:                       ← 共享内存里的字段前缀
\MiPcContinuity.exe               ← 被启动的可执行文件（相对 DLL 所在目录）
 --contextmenu_dropfile=1         ← 唯一的命令行开关
```

即：**`MiPcContinuity.exe --contextmenu_dropfile=1`**，而选中的文件列表**不通过 argv 传递**，而是由 DLL 写入命名共享内存 `Local\MiDropFileMappingObject`（含 `parent_dir:` 字段），再由 `MiPcContinuity.exe` 读取。

所以：

- ❌ 形如 `MiPcContinuity.exe --contextmenu_dropfile=1 "%1"` 或 `... "%V"` 的写法 **不成立** —— 进程会启动，但拿不到任何选中项，界面上是空的。
- ❌ `hyperConnect://` 协议（`HKCR\hyperConnect` → `hyperConnect.exe "%1"`）是主程序的通用协议入口，不是互传发送入口，也不接受文件列表。
- ✅ 多文件传参的正确方式就是原 DLL 已实现的共享内存协议。这也正是**必须复用原 DLL、而不是自己写 exe 包装器**的原因 —— 共享内存的结构未公开，逆向它既脆弱又会随版本失效。

如果哪天小米真把接口改成纯 `IContextMenu`，那时才需要写封装 DLL，思路是：实现 `IExplorerCommand`，在 `Invoke(IShellItemArray*)` 里把选中项转成 `HDROP`/`IDataObject`，`CoCreateInstance` 原 CLSID，`QueryInterface(IID_IContextMenu)` → `IShellExtInit::Initialize` → `InvokeCommand`。当前版本不需要。

---

## 3. 命令细节

### 路线 B 手工命令

```powershell
MakeAppx.exe pack /o /d "C:\ProgramData\MiDropWin11Menu\sparse" /nv `
             /p "C:\ProgramData\MiDropWin11Menu\MiDropWin11MenuShim.msix"

SignTool.exe sign /fd SHA256 /f signing.pfx /p <密码> `
             "C:\ProgramData\MiDropWin11Menu\MiDropWin11MenuShim.msix"

Add-AppxPackage -Path "C:\ProgramData\MiDropWin11Menu\MiDropWin11MenuShim.msix" `
                -ExternalLocation "C:\Program Files\MI\HyperConnect\2.0.1.452\resources\native-interconnect\win32"
```

> `/nv` 必须加：稀疏包清单引用了包外文件，不跳过校验会打包失败。
> `Publisher` 必须与证书 `Subject` 严格一致（`CN=MiDropWin11MenuShim`）。

### 路线 A 手工命令

```powershell
Add-AppxPackage -Path "C:\ProgramData\MiDropWin11Menu\sparse\AppxManifest.xml" -Register `
                -ExternalLocation "C:\Program Files\MI\HyperConnect\2.0.1.452\resources\native-interconnect\win32"
```

对应 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1`。

### 生效方式

按代价从低到高：

1. **重启 `explorer.exe`**（脚本已自动做）—— 多数情况足够
   ```powershell
   Stop-Process -Name explorer -Force   # 系统会自动拉起
   ```
2. **注销重登** —— 若第 1 步后新菜单仍未出现，用这个。包标识的 AppExtension 目录有时需要重新登录才刷新。
3. 重启 —— 一般不需要。

---

## 4. 备份与回滚细节

### 安装脚本自动做的备份

`C:\ProgramData\MiDropWin11Menu\backup\` 下按时间戳导出三个键：

```
CLSID-<时间戳>.reg      HKLM\SOFTWARE\Classes\CLSID\{504d69c0-...}
VerbStar-<时间戳>.reg   HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu
VerbDir-<时间戳>.reg    HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu
```

同时写入 `install-state.json` 记录包全名、外部位置、证书指纹、是否由脚本改过开发人员模式。

### 手工备份

```cmd
mkdir "%USERPROFILE%\Desktop\MiDropBackup"
reg export "HKLM\SOFTWARE\Classes\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}" "%USERPROFILE%\Desktop\MiDropBackup\clsid.reg" /y
reg export "HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu" "%USERPROFILE%\Desktop\MiDropBackup\verb_star.reg" /y
reg export "HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu" "%USERPROFILE%\Desktop\MiDropBackup\verb_dir.reg" /y
```

系统还原点：
```powershell
Checkpoint-Computer -Description "before MiDrop Win11 menu shim" -RestorePointType MODIFY_SETTINGS
```

### 关于 `.reg` 与 32/64 位

`reg\Restore-MiDrop-Original.reg` 是**还原 / 应急修复**用的，内容 100% 采集自本机真实状态。导入务必用 **64 位** regedit：

```cmd
%WINDIR%\regedit.exe /s "<路径>\reg\Restore-MiDrop-Original.reg"
```

若误用 `C:\Windows\SysWOW64\regedit.exe`（32 位），所有 `HKLM\SOFTWARE\Classes\...` 会被重定向到 `...\Classes\WOW6432Node\...`，64 位 `explorer.exe` 找不到该 CLSID，右键项会**彻底消失**。该文件只含新增/覆盖指令，不含任何 `-` 删除指令，导入是幂等安全的。写 HKLM 需要管理员权限。

---

## 5. 明确不采用的做法

```cmd
:: 全局回退 Win10 旧菜单 —— 违反「不改系统全局行为」的约束，本方案不使用
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve
```

这会让**整个**右键菜单变回 Win10 样式。`Diagnose.ps1` 会检查该键是否存在并报告。
