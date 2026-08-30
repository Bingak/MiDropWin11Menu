# MiDropWin11Menu

把小米互联服务的「使用小米互传发送」提升到 **Windows 11 新版右键菜单第一层**。

不改系统全局行为，不回退右键菜单为 Win10 旧版，不破坏「显示更多选项」里的原入口。

## 原理

小米的右键处理器 `MiDropShellExt.dll` **已经实现了 `IExplorerCommand`**（Win11 新菜单的必要条件之一）。它只在旧菜单出现的唯一原因是：**缺少 package identity（包标识）** —— 小米互联服务是纯 Win32 安装，没有 MSIX。

本方案注册一个**稀疏包**（只含 `AppxManifest.xml` 的 MSIX，不含任何二进制），用 `-ExternalLocation` 指向小米原装目录，把包标识授予同一个 CLSID，**复用原厂 DLL，不写任何代码，不修改原厂注册表**。

```
MiDropShellExt.dll  ──有 IExplorerCommand、无包标识──▶ 旧菜单（显示更多选项）
                    ──补上稀疏包（包标识）──────────▶ 新菜单第一层
```

深入分析与实测证据见 [TECHNICAL-NOTES.md](TECHNICAL-NOTES.md)。

## 环境要求

- Windows 11（内部版本 ≥ 22000），64 位
- 已安装小米互联服务

## 使用方法

### 小白方式：双击「一键安装.cmd」

不想敲命令的话，下载整个仓库后**双击 `一键安装.cmd`** 即可。它会自动请求管理员权限，然后给一个菜单：

```
   [1] 路线 B 安装   推荐。签名安装，不改任何系统全局开关。
                    需 Windows SDK（没有的话会提示自动装）。

   [2] 路线 A 安装   免 SDK 免证书，但会开启系统「开发人员模式」。

   [3] 体验一下      临时启用，重启电脑后自动失效，不留痕迹。
                    想先看看效果选这个。

   [4] 彻底删除      注销包 + 还原开关 + 删掉全部生成的文件。

   [5] 查看当前状态
   [0] 退出
```

几点说明：

- **选 [3] 体验**最保险 —— 它只做临时注册，重启电脑后一切自动还原，适合先看看效果。
- 选 [1] 时若检测到没装 Windows SDK，脚本会问你要不要自动装（推荐装，只装签名工具，体积很小）。
- `[4] 彻底删除` 会移除包、把「开发人员模式」还原回关闭、删掉自签名证书，并删除 `C:\ProgramData\MiDropWin11Menu`（含之前做的注册表备份）。它**不会**动小米互联服务本身。

以下两节是命令行方式，效果与菜单里的 [1] [2] 完全一致。

### 路线 B（推荐）：签名安装

签名 `.msix` 走 Windows 默认已启用的旁加载，**不需要开启开发人员模式**，唯一改动是导入一张自签名证书公钥（卸载时会移除）。

先安装 Windows SDK 的签名工具（体积很小，向导里只勾选 **Signing Tools for Desktop Apps**）：

```powershell
winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements
```

然后以**管理员**身份运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RouteB-SignedMsix.ps1
```

### 路线 A（快速）：免 SDK 免证书

代价是需要开启系统「开发人员模式」（这是唯一的全局开关改动，卸载脚本会自动还原）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1 -EnableDeveloperMode
```

### 验证

安装脚本会自动重启 `explorer.exe`。右键任意文件，新菜单第一层应出现「使用小米互传发送」。

> **先右键单个文件测试。** 若互传窗口弹出但文件列表为空，说明原组件的共享内存在 COM 代理宿主中不成立，本方案不可用 —— 请直接回滚。

若未出现，注销重登一次（包标识的 AppExtension 目录有时需要重新登录才刷新）。

### 体检与卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1     # 只读体检，不改任何东西
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1    # 完整回滚
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `一键安装.cmd` | **双击即用**，自动提权，菜单式选择路线 A / B / 体验 / 彻底删除 |
| `MiDrop-Menu.ps1` | 一键安装的主程序，由上面的 `.cmd` 调起 |
| `sparse/AppxManifest.xml` | 稀疏包清单，已填好原厂 CLSID `{504d69c0-cb52-48df-b5b5-7161829fabc8}` |
| `Install-RouteB-SignedMsix.ps1` | 路线 B：签名安装（推荐，命令行版） |
| `Install-RouteA-DevMode.ps1` | 路线 A：免 SDK，需开发人员模式（命令行版） |
| `Uninstall.ps1` | 回滚：注销包、还原开关、移除证书、校验原厂注册完好 |
| `Diagnose.ps1` | 只读体检，输出 CLSID / DLL / verb / 包状态 / 开关状态 |
| `reg/Restore-MiDrop-Original.reg` | 原厂注册状态还原（应急修复用） |
| `TECHNICAL-NOTES.md` | 实测证据、接口判定、共享内存机制、手工命令 |

> 只要用「一键安装.cmd」，就不需要管下面那几个 `.ps1` —— 它们是完全等价的命令行版本，留着给想自动化或排查问题的人用。

## 备份与回滚

安装脚本会自动备份到 `C:\ProgramData\MiDropWin11Menu\backup\`：

- `HKLM\SOFTWARE\Classes\CLSID\{504d69c0-...}`
- `HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu`
- `HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu`

回滚顺序：

1. 运行 `Uninstall.ps1`
2. `Get-AppxPackage -Name MiDropWin11MenuShim` 应无输出
3. 若原厂注册被意外破坏，用 **64 位** regedit 导入 `reg/Restore-MiDrop-Original.reg`
4. 重启 explorer 或注销重登

> 导入 `.reg` 必须用 `%WINDIR%\regedit.exe`。用 `C:\Windows\SysWOW64\regedit.exe`（32 位）会被重定向到 `WOW6432Node`，导致 64 位 explorer 找不到该 CLSID，右键项彻底消失。

**核心安全性**：本方案对 `HKLM\SOFTWARE\Classes` 下的原厂键值是**只读**的。即使包注册完全失败，旧菜单入口也毫发无损。

## 适用范围

| 场景 | 生效 | 说明 |
|---|---|---|
| 单个文件 | ✅ | `ItemType Type="*"` |
| 多选文件 | ✅ | `Invoke` 收到 `IShellItemArray` |
| 文件夹（选中） | ✅ | `ItemType Type="Directory"` |
| 特定扩展名 | 不区分 | 由原 DLL 的 `GetState` 决定 |
| 文件夹空白处 | ❌ | 原厂未注册，本方案保持一致 |
| 驱动器、桌面、压缩包内 | ❌ | 非文件系统项 |

范围与原厂在旧菜单里的行为**完全一致**，不多不少。

## 已知风险

1. **小米升级后失效（最可能遇到）** —— `-ExternalLocation` 是含版本号的绝对路径，升级换新版本目录后新菜单条目会消失。**升级后重跑安装脚本即可**（脚本自动挑选最新版本目录）。旧菜单入口由小米安装器重新注册，不受影响。
2. **共享内存握手需实测** —— 新菜单的 `Invoke` 跑在带包标识的 COM 代理宿主中，原 DLL 依赖命名共享内存 `Local\MiDropFileMappingObject` 与 `MiPcContinuity.exe` 通信。清单已声明完全信任 + `unvirtualizedResources`，理论上可用，但**必须先测单文件**确认。
3. **旧菜单可能出现重复条目** —— 少数系统版本上打包注册的命令也会渲染进旧菜单，仅观感问题。
4. **自签名证书**（路线 B）—— 公钥进入 `LocalMachine\TrustedPeople`，卸载脚本会移除；私钥 `.pfx` 签名后立即删除。
5. **开发人员模式**（路线 A）—— 全局开关，会允许安装任意未签名松散文件包。
6. **仅供本机使用** —— 自签名包只在导入同一张证书的机器上可装，无法分发给他人。

## 参考

- [Add a File Explorer context menu command to a packaged desktop app](https://learn.microsoft.com/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)
- [Grant package identity by packaging with external location manually](https://learn.microsoft.com/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)

## 许可与声明

脚本、清单与文档以 [MIT](LICENSE) 授权。

本项目**不包含、不重新分发、不修改、不打补丁**于小米互联服务的任何二进制文件 —— 它只注册一个指向本机已有安装的稀疏包，让小米自己的 shell 扩展 DLL 获得包标识。小米的商标、二进制与版权均归小米公司及其关联方所有。本项目为非官方作品，与小米无关联，亦未获其背书或支持。
