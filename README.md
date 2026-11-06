# MiDropWin11Menu

把小米互联服务的「使用小米互传发送」提升到 **Windows 11 新版右键菜单第一层**。

> **核心约束（本项目绝不违反）**
> - ✅ 把右键项从「显示更多选项」里提升到 Win11 原生新菜单第一层；
> - ❌ **不**整体回退为 Windows 10 旧版菜单（不动 `{86ca1aa0-...}` 全局开关）；
> - ❌ **不**改变系统全局行为；
> - ❌ **不**修改小米互联服务的任何原厂注册表键值（只读）。卸载时的注册表清理
>   **只针对非原厂来源**的 `MiDropExtMenu` 键，**原厂入口一律保留不删** —— 详见下文。
>
> 安装过程中会**临时关闭 Windows 安全中心实时防护**以便顺利完成注册/签名/证书导入，
> 安装结束（成功或失败都会）**自动精确恢复**，详见下文「安装时临时关闭安全中心」。

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
- 已安装「小米互联服务」（组件目录形如 `C:\Program Files\MI\HyperConnect\<版本>\resources\native-interconnect\win32`）

## 项目结构

`MiDrop-Menu.ps1` 是**自包含单文件**：菜单界面 + 全部核心逻辑（常量、公共函数、两条安装路线、
卸载、诊断、以及安全中心临时关闭/恢复）都在其中，直接运行即弹菜单。
其余 `.ps1` 是等价的**瘦命令行版**，自身不含逻辑，只是在启动时**点源（`.`）** `MiDrop-Menu.ps1`
载入全部函数，再透传参数调用对应入口——因此改一处逻辑全局生效、无重复代码：

| 文件 | 作用 |
|---|---|
| `MiDrop-Menu.ps1` | **自包含主脚本**：全部逻辑 + 菜单 UI。直接运行弹菜单；被其它脚本点源时只定义函数、不弹菜单 |
| `Install-RouteA-DevMode.ps1` | 路线 A 命令行版（点源主脚本 → 调 `Invoke-InstallRouteA`） |
| `Install-RouteB-SignedMsix.ps1` | 路线 B 命令行版（点源主脚本 → 调 `Invoke-InstallRouteB`） |
| `Uninstall.ps1` | 完整回滚（点源主脚本 → 调 `Invoke-Uninstall`） |
| `Diagnose.ps1` | 只读体检（点源主脚本 → 调 `Show-Diagnostics`） |
| `sparse/AppxManifest.xml` | 稀疏包清单，已填好原厂 CLSID `{504d69c0-cb52-48df-b5b5-7161829fabc8}` |
| `reg/Restore-MiDrop-Original.reg` | 原厂注册状态还原（应急修复用） |
| `一键安装.cmd` | **双击即用**，自动提权，菜单式选择路线 |
| `TECHNICAL-NOTES.md` | 实测证据、接口判定、共享内存机制、手工命令 |

> 日常使用双击「一键安装.cmd」即可；其余 `.ps1` 是等价的命令行版本，留给想自动化或排查的人。
> 注意：命令行版必须和 `MiDrop-Menu.ps1` 放在同一目录（靠 `PSScriptRoot` 点源加载）。

## 使用方法

### 小白方式：双击「一键安装.cmd」

下载整个仓库后**双击 `一键安装.cmd`** 即可。它会自动请求管理员权限，然后给一个菜单：

```
   [1] 路线 B 安装   签名安装，不改任何系统全局开关。
                    需 Windows SDK（没有的话会提示自动装，占用4G左右）。
   [2] 路线 A 安装   推荐，免 SDK 免证书，但会开启系统「开发人员模式」。
   [3] 体验一下      注册后立即测试，回车确认后自动注销还原。想先看看效果选这个。
   [4] 彻底删除      注销包 + 还原开关 + 卸载自动装的 SDK + 删掉生成的文件。
   [5] 查看当前状态
   [0] 退出
```

几点说明：

- **选 [3] 体验**最保险 —— 它注册后让你实际右键测试，回车确认后自动注销、还原开发人员模式开关、清理暂存文件。注意：体验注册不会因重启电脑自动消失，请务必回到窗口按回车完成还原。
- 选 [1] 时若检测到没装 Windows SDK，脚本会问你要不要自动装（推荐装，只装签名工具，体积约 3G）。
- `[4] 彻底删除` 会移除包、把「开发人员模式」还原回关闭、删掉自签名证书、**卸载脚本自动安装的 Windows SDK 10.0.26100**，并删除 `C:\ProgramData\MiDropWin11Menu`（含之前做的注册表备份）。它**不会**动小米互联服务本身。

### 命令行方式（与菜单 [1][2] 完全一致）

**路线 B（推荐）：签名安装** —— 走 Windows 默认已启用的旁加载，不需要开发人员模式，唯一改动是导入一张自签名证书公钥（卸载时移除）。

```powershell
# 先装 Windows SDK 的签名工具（只需 Signing Tools 组件）
winget install --id Microsoft.WindowsSDK.10.0.26100 --accept-package-agreements

# 以管理员身份运行
powershell -ExecutionPolicy Bypass -File .\Install-RouteB-SignedMsix.ps1
```

**路线 A（快速）：免 SDK 免证书** —— 代价是需要开启系统「开发人员模式」（唯一的全局开关改动，卸载时自动还原）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RouteA-DevMode.ps1 -EnableDeveloperMode
```

| 维度 | 路线 A | 路线 B（推荐） |
|---|---|---|
| 是否需要 Windows SDK | 否 | 是（MakeAppx / SignTool） |
| 是否需要开发人员模式 | 是（全局开关） | 否 |
| 是否签名 | 否（松散文件注册） | 是（自签名 .msix + 信任公钥） |
| 是否改系统全局行为 | 仅「开发人员模式」一项 | 仅导入一张证书公钥到 TrustedPeople |
| 安装后自动恢复项 | 开发人员模式 | 证书（卸载时移除） |

### 验证

安装脚本会自动重启 `explorer.exe`。右键任意文件，新菜单第一层应出现「使用小米互传发送」。

> **先右键单个文件测试。** 若互传窗口弹出但文件列表为空，说明原组件的共享内存在 COM 代理宿主中不成立，本方案不可用 —— 请按彻底删除回滚。

若未出现，注销重登一次（包标识的 AppExtension 目录有时需要重新登录才刷新）。

### 体检与卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1     # 只读体检，不改任何东西
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1    # 完整回滚
```

`Uninstall.ps1` 可选开关：

- `-KeepBackup`：保留 `C:\ProgramData\MiDropWin11Menu\backup\` 下的注册表备份（**默认会删除**）。
- `-KeepDeveloperMode`：不动「开发人员模式」开关。
- `-KeepSdk`：保留 Windows SDK。
- `-NoRestartExplorer`：不重启 explorer.exe。
- `-PurgeRegistryVerbs`：确认清理**非原厂**残留键（不再询问；**原厂入口仍保留不删**）。
- `-KeepRegistryVerbs`：跳过注册表搜索与清理（既不搜索也不删除）。

若 Windows SDK 10.0.26100 由脚本自动安装过，卸载时会一并移除；无法确认来源时会询问。SDK 移除顺序：先 `winget uninstall`，失败则按 ARP 里的 ProductCode 走 `msiexec /x /qn`。

## 安装时临时关闭 Windows 安全中心

安装过程中（证书创建、`.msix` 打包/签名、包注册等环节）可能被 Windows 安全中心的实时扫描拦截或拖慢，因此脚本会在**开始注册前临时关闭以下实时防护**：

- 实时病毒与威胁防护（`DisableRealtimeMonitoring`）
- 下载/附件扫描（`DisableIOAVProtection`）

并在**安装结束后（无论成功、失败还是用户取消）通过 `try/finally` 精确还原为开启**。

安全与可控性保障：

- **只动 Defender 实时防护**，不动「防篡改保护」、不停止安全中心服务、不动第三方杀软；
- 若系统开启了**防篡改保护（Tamper Protection）**或组策略禁止关闭，PowerShell 无法关闭实时防护，此时脚本会**跳过并提示、安装照常进行**，不会因此失败；
- 还原动作放在 `finally` 中，即使安装中途报错或被 Ctrl+C 中断也会尽量恢复；
- 还原仅针对本次脚本**实际改动过的项**，不会去动你原本就关闭的防护。

> 如果你不希望脚本触碰安全中心，可改用「路线 A」并**手动分步执行**（仅运行 `Install-RouteA-DevMode.ps1` 前先自行临时关闭安全中心），或在已加白名单的环境下安装。

## 备份与回滚

安装脚本会自动备份到 `C:\ProgramData\MiDropWin11Menu\backup\`：

- `HKLM\SOFTWARE\Classes\CLSID\{504d69c0-...}`
- `HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu`
- `HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu`

卸载时的备份处理：

- 默认情况下，`Uninstall.ps1` 会**显式删除** `C:\ProgramData\MiDropWin11Menu\backup\` 下的注册表备份，随后清理整个暂存目录。
- 若你希望保留备份用于人工比对或后续手动回滚，请运行 `powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -KeepBackup`。
- 备份目录就在暂存目录 `C:\ProgramData\MiDropWin11Menu\` 里面，所以「保留备份」时脚本只清理它的兄弟项，
  **不会**再把整个暂存目录连同 `backup\` 一起 `-Recurse` 删掉。

### 清理注册表里的 MiDropExtMenu 残留

卸载流程的**步骤 5/6** 会扫描注册表里的 `MiDropExtMenu` 键，但**只清理非原厂来源的键，
小米原厂入口一律保留不删**。

判定规则：键的 `ExplorerCommandHandler` **严格等于**小米 CLSID `{504d69c0-cb52-48df-b5b5-7161829fabc8}`
即认定为原厂入口 → 保留；否则视为非原厂残留 → 可清理。

**先厘清一个常见误解**：`HKEY_CLASSES_ROOT`（HKCR）**不是独立的物理键**，它只是
`HKLM\SOFTWARE\Classes` 与 `HKCU\Software\Classes` 的**合并视图**。所以在 regedit 里
看到下面 4 条路径，实际通常只有 **2 个物理键**：

| regedit 里看到的路径 | 性质 |
|---|---|
| `HKEY_CLASSES_ROOT\*\shell\MiDropExtMenu` | 视图，与下面第 3 条是**同一个键** |
| `HKEY_CLASSES_ROOT\Directory\shell\MiDropExtMenu` | 视图，与下面第 4 条是**同一个键** |
| `HKLM\SOFTWARE\Classes\*\shell\MiDropExtMenu` | 物理键（原厂通常注册在这里） |
| `HKLM\SOFTWARE\Classes\Directory\shell\MiDropExtMenu` | 物理键 |

因此脚本**只搜索真实物理位置**，不会把同一份数据重复计数、重复删除：

- `HKLM\SOFTWARE\Classes`（64 位机器级）
- `HKCU\Software\Classes`（用户级）
- `HKLM\SOFTWARE\WOW6432Node\Classes`（32 位视图）

**搜索方式**：只探测 shell 动词的**挂载父键**，不做全量递归遍历。原因是
`HKLM\SOFTWARE\Classes` 单机就有 20 万个子键左右，逐键递归在 PowerShell 里要跑
25 秒以上，期间没有任何输出，看起来就像卡死（旧版卸载停在「5/6」不动正是这个原因）。
而动词只可能注册在下面几类父键下，所以脚本不再逐键递归，只对约 5200 个一级 ProgID
各探测 3 个挂载父键（合计约 1.6 万次子键探测，绝大多数立刻返回「不存在」），
本机实测 **24.6 秒 → 0.9 秒**：

- `<ProgID>\shell\<verb>`（含 `*` / `Directory` / `Drive` 等特殊 ProgID）
- `<ProgID>\shellex\ContextMenuHandlers\<verb>`（旧式 `IContextMenu` 处理器）
- `Directory\Background\shell\<verb>`（文件夹空白处）
- `SystemFileAssociations\<ext>\shell\<verb>`、`Applications\<exe>\shell\<verb>`

**默认行为**：搜索 → 分类列出（标注原厂 / 非原厂）→ 原厂键直接跳过，非原厂键询问后才清理。

```powershell
# 搜索并询问（默认，推荐）
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

# 确认清理非原厂残留，不再询问（原厂入口仍保留）
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -PurgeRegistryVerbs

# 完全跳过注册表搜索与清理
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -KeepRegistryVerbs
```

清理时的保护：

- **原厂入口绝不删除**（函数级双保险：只传非原厂键 + 默认不带 `-IncludeFactory`）；
- 清理前**先用 `Export-RegKeyPS` 把每个键导出成 `.reg`** 存到备份目录；
- 清理后**强制保留备份目录**（即使没加 `-KeepBackup`），因为此时 `.reg` 是唯一回滚手段；
- 用 .NET 的 `DeleteSubKeyTree` 删除，避开 `Remove-Item` 遇到路径里 `*` 时的通配符/视图问题。

> **正常安装后再卸载，通常什么都不用清**：本方案的稀疏包只含 `AppxManifest.xml`，
> 从不往注册表写 `MiDropExtMenu`。你机器上那 2 个键是小米原厂的旧菜单入口，
> 脚本会识别出来并**保留**，你会看到「没有非原厂来源的残留键，无需清理；原厂入口保持原样」。

**恢复方法**：若确有非原厂键被清理，用 **64 位** regedit（`%WINDIR%\regedit.exe`）
导入备份目录里的 `PurgeVerbs-*.reg`，然后重启 explorer。

回滚顺序：

1. 运行 `Uninstall.ps1`（默认会删除注册表备份；加 `-KeepBackup` 可保留）
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
5. **开发人员模式**（路线 A）—— 全局开关，会允许安装任意未签名松散文件包；卸载脚本自动还原。
6. **安装时会临时关闭安全中心实时防护** —— 如上节所述，仅安装期间、自动恢复，且受防篡改保护限制时会优雅跳过。
7. **仅供本机使用** —— 自签名包只在导入同一张证书的机器上可装，无法分发给他人。
8. **注册表清理只针对非原厂键，原厂入口不受影响** —— 判定依据是 `ExplorerCommandHandler`
   是否严格等于小米 CLSID `{504d69c0-...}`：等于即视为原厂入口并**保留**，不等才当作残留清理。
   清理前会自动导出 `.reg`，可用 **64 位** regedit 导入恢复。

## 参考

- [Add a File Explorer context menu command to a packaged desktop app](https://learn.microsoft.com/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)
- [Grant package identity by packaging with external location manually](https://learn.microsoft.com/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)

## 许可与声明

脚本、清单与文档以 [MIT](LICENSE) 授权。

本项目**不包含、不重新分发、不修改、不打补丁**于小米互联服务的任何二进制文件 —— 它只注册一个指向本机已有安装的稀疏包，让小米自己的 shell 扩展 DLL 获得包标识。小米的商标、二进制与版权均归小米公司及其关联方所有。本项目为非官方作品，与小米无关联，亦未获其背书或支持。
