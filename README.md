# mpv 播放状态保存与恢复工具

一套基于 PowerShell 编写的小工具，用于**保存**和**恢复** mpv 播放器的多窗口播放状态（包括播放进度、窗口位置、窗口大小、是否最大化）。

适合在关机 / 重启前批量保存所有正在播放的 mpv 窗口状态，下次开机后一键恢复到之前的样子。

<br>

---

## 目录

- [功能概览](#功能概览)

- [工作原理](#工作原理)

- [环境依赖](#环境依赖)

- [安装步骤](#安装步骤)

- [全局命令行调用（推荐）](#全局命令行调用推荐)

- [使用方法](#使用方法)

- [JSON 状态文件格式](#json-状态文件格式)

- [常见问题排查](#常见问题排查)

- [已知限制](#已知限制)

<br>

---

## 功能概览

本项目包含两个脚本，分别负责"保存"和"恢复"：

<br>

### 1. `save_state.ps1`（保存）

- 自动扫描当前系统中所有正在运行的 mpv 实例（通过 IPC 命名管道）

- 通过 mpv IPC 协议读取每个实例的**当前播放文件路径**、**播放进度**

- 通过 Win32 API 精确获取每个 mpv 窗口的**位置、大小、是否最大化**

- 将以上信息汇总，生成一个带时间戳的 JSON 文件（如 `mpv_state_20260727_095500.json`）

<br>

### 2. `restore_state.ps1`（恢复）

- 自动查找脚本目录下**最新**的 `mpv_state_*.json` 文件

- 根据 JSON 中记录的文件路径，逐个启动 mpv 并跳转到对应播放进度

- 通过 Win32 `SetWindowPos` 精确恢复窗口的位置和大小（不依赖 mpv 自身的 `--geometry` 参数，避免受视频比例、标题栏边框等因素干扰）

- 若原窗口为最大化状态，会先恢复窗口再执行最大化

- **恢复完成后会在末尾统一汇总列出所有被跳过的视频**，并附带具体跳过原因，方便排查（例如文件已被移动/删除、窗口句柄获取失败等）

<br>

---

## 工作原理

mpv 支持通过 `--input-ipc-server` 参数开启一个命名管道，外部程序可以通过这个管道发送 JSON 格式的命令来查询或控制 mpv（官方文档：[JSON IPC](https://mpv.io/manual/master/#json-ipc)）。

本项目约定：**每个 mpv 实例的 IPC 管道名称为 `mpv_ipc_<进程PID>`**，例如：

```
\\.\pipe\mpv_ipc_12345
```

为了让每个 mpv 实例自动创建以自身 PID 命名的管道，需要一个 mpv 脚本（`auto_ipc.lua`）在启动时自动设置该选项。

<br>

---

## 环境依赖

| 依赖项 | 说明 |
|---|---|
| Windows 10 / 11 | 脚本使用了 Win32 API 和 PowerShell，仅支持 Windows |
| PowerShell 5.1+ | Windows 自带版本即可，无需额外安装 |
| mpv 播放器 | 建议使用较新版本，需支持 `--input-ipc-server` 及 `pid` 属性 |
| `auto_ipc.lua` | 用于让每个 mpv 实例自动创建专属 IPC 管道，见下方安装步骤 |

<br>

---

## 安装步骤

### 第一步：安装 mpv

确保 mpv 已安装，并且能通过以下任一方式被脚本找到：

- 与脚本放在同一目录

- 已加入系统 `PATH` 环境变量

- 安装在常见路径下，例如 `%ProgramFiles%\mpv\mpv.exe`、`%LOCALAPPDATA%\mpv\mpv.exe`

<br>

### 第二步：安装 `auto_ipc.lua`

在 mpv 配置目录下创建脚本文件：

```
%APPDATA%\mpv\scripts\auto_ipc.lua
```

文件内容示例：

```lua
-- auto_ipc.lua
-- 功能：让每个 mpv 实例根据自身 PID 自动创建专属 IPC 管道
-- 管道名称格式：mpv_ipc_<进程PID>

local pid = mp.get_property_number("pid")

if pid then
    local pipe_name = "\\\\.\\pipe\\mpv_ipc_" .. tostring(pid)
    mp.set_property("options/input-ipc-server", pipe_name)
end
```

> 说明：mpv 提供只读属性 `pid`，可获取当前进程 ID。该脚本会在 mpv 启动时自动把 IPC 管道设置为 `mpv_ipc_<PID>`，无需手动传参。

<br>

### 第三步：放置本项目脚本

将以下两个文件放在**同一个目录**下（建议单独建一个文件夹，例如 `D:\mpv_state_tool\`）：

- `save_state.ps1`

- `restore_state.ps1`

<br>

---

## 全局命令行调用（推荐）

默认情况下，需要打开脚本所在文件夹并双击 `.ps1` 文件才能运行，比较繁琐。

更推荐的做法是：**编写两个 `.bat` 批处理文件，并把脚本所在目录加入系统 `PATH` 环境变量**，之后就可以在任意目录下、任意 CMD / PowerShell 窗口中，直接输入命令即可保存或恢复状态，无需再打开文件管理器。

<br>

### 第一步：在脚本目录下创建两个 bat 文件

假设脚本存放目录为 `D:\mpv_state_tool\`，在该目录下新建以下两个文件：

<br>

**`restore.bat`**（用于恢复播放状态）：

```bat
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0restore_state.ps1"
pause
```

<br>

**`save.bat`**（用于保存播放状态）：

```bat
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0save_state.ps1"
pause
```

<br>

> 说明：
>
> - `%~dp0` 表示当前 bat 文件所在的目录，因此无论把这个文件夹放在哪个盘符下，都不需要修改脚本内容
>
> - `-ExecutionPolicy Bypass` 用于临时绕过 PowerShell 的脚本执行策略限制，仅对本次调用生效，不会更改系统全局策略
>
> - 末尾的 `pause` 用于运行结束后暂停窗口，方便查看输出结果（包括跳过明细汇总）

<br>

此时目录结构应类似：

```
D:\mpv_state_tool\
├── save_state.ps1
├── restore_state.ps1
├── save.bat
└── restore.bat
```

<br>

### 第二步：把脚本目录加入系统 PATH

加入 `PATH` 后，Windows 会在任意目录下的命令行中自动搜索该目录内的可执行文件（包括 `.bat`），从而实现"全局命令"的效果。

以下提供两种配置方式，任选其一即可。

<br>

#### 方式一：图形界面操作（推荐新手）

1. 右键点击"此电脑" → 选择"属性"

2. 点击"高级系统设置"

3. 在弹出窗口中点击"环境变量"

4. 在"系统变量"（或"用户变量"）中找到名为 `Path` 的条目，选中后点击"编辑"

5. 点击"新建"，粘贴脚本所在目录路径，例如：

   ```
   D:\mpv_state_tool
   ```

6. 一路点击"确定"保存所有窗口

7. **重新打开**一个新的 CMD / PowerShell 窗口（已打开的窗口不会自动生效）$CITE_4

<br>

#### 方式二：命令行操作（推荐熟悉命令行的用户）

以**管理员身份**打开 PowerShell 或 CMD，执行以下命令即可将目录写入**系统级** `PATH`（对所有用户生效）：

```powershell
setx PATH "%PATH%;D:\mpv_state_tool" /M
```

如果只想对当前用户生效（无需管理员权限），去掉 `/M` 参数即可：

```powershell
setx PATH "%PATH%;D:\mpv_state_tool"
```

> `setx` 是 Windows 提供的官方命令行工具，用于永久写入环境变量（区别于 `set`，后者只在当前会话临时生效）$CITE_2。使用 `/M` 参数表示修改系统级环境变量，否则默认只修改当前用户的环境变量$CITE_5。

同样，配置完成后需要**重新打开**一个新的命令行窗口才能生效$CITE_7。

<br>

> ⚠️ 注意：`setx` 读取 `%PATH%` 时是从**注册表**中读取当前用户/系统变量，而不是当前会话展开后的完整 PATH，因此在某些情况下直接拼接可能导致长度超限或重复。如果追加多次，建议先通过图形界面检查 PATH 内容是否重复膨胀。

<br>

### 第三步：验证配置

打开一个新的 CMD 窗口，输入以下命令测试：

```bat
where save.bat
where restore.bat
```

如果能正确输出文件路径，说明 PATH 配置成功。

<br>

### 第四步：随时随地一键调用

配置完成后，无论当前处于哪个目录，直接在命令行中输入：

```bat
save
```

即可保存当前所有 mpv 窗口状态；输入：

```bat
restore
```

即可恢复最近一次保存的状态。

<br>

也可以进一步为这两个命令设置**全局快捷键**（例如通过 AutoHotkey 绑定快捷键调用 `save.bat` / `restore.bat`），实现"一键保存/恢复"的效果，本 README 不再展开。

<br>

---

## 使用方法

### 保存状态

1. 正常使用 mpv 打开若干个视频，调整好每个窗口的位置、大小

2. 双击运行 `save_state.ps1`，或在命令行中输入 `save`（需已完成 PATH 配置）

3. 脚本会自动扫描所有 mpv 实例，采集状态后在同目录生成 `mpv_state_<时间戳>.json`

4. 可以放心关闭 mpv 或关机

<br>

### 恢复状态

1. 双击运行 `restore_state.ps1`，或在命令行中输入 `restore`（需已完成 PATH 配置）

2. 脚本会自动查找**最新**的 `mpv_state_*.json` 文件

3. 依次启动 mpv，跳转到记录的播放进度，并恢复窗口位置/大小/最大化状态

4. 全部处理完成后，控制台会输出：

   - 成功恢复的数量

   - 跳过的数量

   - **跳过明细列表**（逐条列出文件路径 + 跳过原因）

<br>

示例输出：

```
========================================
  恢复完成
  成功：3  跳过：2  共计：5
========================================

以下文件被跳过：
----------------------------------------
  [1] D:\Videos\old_clip.mp4
      原因：文件不存在
  [2] E:\Downloads\sample.mkv
      原因：窗口尺寸异常
----------------------------------------
```

<br>

---

## JSON 状态文件格式

`save_state.ps1` 生成的 JSON 是一个数组，每个元素对应一个 mpv 窗口，字段说明如下：

| 字段 | 类型 | 说明 |
|---|---|---|
| `pid` | int | mpv 进程 ID（仅保存时使用，恢复时不依赖） |
| `file_path` | string | 正在播放的文件完整路径 |
| `time_pos` | double | 播放进度（单位：秒） |
| `window_x` | int | 窗口左上角 X 坐标（屏幕坐标系） |
| `window_y` | int | 窗口左上角 Y 坐标 |
| `window_width` | int | 窗口宽度（像素） |
| `window_height` | int | 窗口高度（像素） |
| `is_maximized` | bool | 该窗口是否处于最大化状态 |

示例：

```json
[
  {
    "pid": 12345,
    "file_path": "D:\\Videos\\example.mkv",
    "time_pos": 128.456,
    "window_x": 100,
    "window_y": 80,
    "window_width": 1280,
    "window_height": 720,
    "is_maximized": false
  }
]
```

<br>

---

## 常见问题排查

### 保存时提示"未发现任何正在运行的 mpv 实例"

请检查：

1. mpv 是否确实在运行

2. `auto_ipc.lua` 是否已放入 `%APPDATA%\mpv\scripts\` 目录

3. 可以在 mpv 中按 `` ` `` 打开控制台，查看是否有脚本加载报错

4. 手动检查管道是否存在：在 PowerShell 中执行

   ```powershell
   Get-ChildItem \\.\pipe\ | Where-Object { $_.Name -match '^mpv_ipc_\d+$' }
   ```

<br>

### 恢复时提示"找不到 mpv.exe"

请将 `mpv.exe` 放在脚本同目录下，或将其所在目录加入系统 `PATH` 环境变量（推荐）。

<br>

### 恢复后窗口位置/大小不准确

- 请确认保存时和恢复时使用的是**同一套显示器布局**（分辨率、多屏排列一致）

- 如果 Windows 系统缩放比例发生变化，坐标可能出现偏差，建议保存和恢复时保持相同的 DPI 缩放设置

<br>

### 恢复时部分视频被跳过

查看控制台末尾的"跳过明细"列表，常见原因包括：

| 跳过原因 | 可能情况 |
|---|---|
| 文件路径为空 | JSON 记录本身缺少路径信息 |
| 文件不存在 | 视频文件已被移动、改名或删除 |
| 窗口数据异常 / 窗口尺寸异常 | JSON 中的窗口字段缺失或非法 |
| 未找到窗口句柄 | mpv 启动较慢，或窗口在 10 秒内未创建成功 |
| SetWindowPos 失败 | 系统级窗口操作被拒绝（较少见） |

<br>

### 配置 PATH 后命令仍无法识别

- 确认是否重新打开了新的命令行窗口（旧窗口不会自动刷新环境变量）$CITE_7

- 使用 `where save.bat` 检查系统是否真的能找到该文件

- 检查 PATH 中路径是否拼写正确、是否存在多余的空格或分号

<br>

---

## 已知限制

- 仅支持 Windows 系统（依赖 Win32 API 和命名管道）

- 不会保存音量、字幕轨道、音轨等播放参数，仅保存**文件路径 + 播放进度 + 窗口几何信息**

- 恢复时会重新启动 mpv 进程，原进程 PID 不会保留

- 多显示器环境下，如果保存后又拔掉/更换了显示器，窗口坐标可能落在不存在的屏幕区域之外

<br>

---

## License

本项目脚本仅供个人学习和使用，可自由修改和分发。
