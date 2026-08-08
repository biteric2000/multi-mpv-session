# mpv 工具集

本仓库包含两个独立的 PowerShell 小工具，用于扩展 mpv 播放器的使用体验：

1. **保存与恢复播放状态**（`save_state.ps1` / `restore_state.ps1`）  
   批量保存所有正在运行的 mpv 窗口的播放进度、窗口位置/大小/最大化状态，关机后一键恢复。

2. **随机网格播放器**（`random_grid_mpv.ps1`）  
   在屏幕网格中同时打开多个视频，每个从随机时间点开始并暂停，适合预览、视频墙等场景。

两个工具相互独立，可单独使用，也可配合使用。

---

## 目录

- [通用依赖与环境准备](#通用依赖与环境准备)
- [工具一：保存与恢复播放状态](#工具一保存与恢复播放状态)
  - [功能概览](#功能概览)
  - [工作原理](#工作原理)
  - [安装步骤](#安装步骤)
  - [全局命令行调用（推荐）](#全局命令行调用推荐)
  - [使用方法](#使用方法)
  - [JSON 状态文件格式](#json-状态文件格式)
- [工具二：随机网格播放器](#工具二随机网格播放器)
  - [功能特性](#功能特性)
  - [配置说明](#配置说明)
  - [使用方法](#使用方法-1)
  - [运行示例](#运行示例)
- [常见问题排查](#常见问题排查)
- [已知限制](#已知限制)
- [许可证](#许可证)

---

## 通用依赖与环境准备

两个工具均依赖以下环境：

| 依赖项 | 说明 |
|---|---|
| Windows 10 / 11 | 两个工具都使用 Win32 API 控制窗口，仅支持 Windows |
| PowerShell 5.1+ | Windows 自带版本即可，无需额外安装 |
| mpv 播放器 | 两个工具均需 `mpv.exe`，建议将其所在目录加入系统 `PATH` 或放在脚本同目录 |
| ffprobe（来自 FFmpeg） | **仅随机网格播放器需要**，用于读取视频宽高及时长信息 |

> 如果只使用保存/恢复工具，可以不需要 ffprobe；如果使用随机网格工具，则需要安装 FFmpeg 并将 `ffprobe.exe` 放入 PATH 或同目录。

---

# 工具一：保存与恢复播放状态

一套基于 PowerShell 编写的小工具，用于**保存**和**恢复** mpv 播放器的多窗口播放状态（包括播放进度、窗口位置、窗口大小、是否最大化）。

适合在关机 / 重启前批量保存所有正在播放的 mpv 窗口状态，下次开机后一键恢复到之前的样子。

## 功能概览

本项目包含两个脚本，分别负责"保存"和"恢复"：

### 1. `save_state.ps1`（保存）

- 自动扫描当前系统中所有正在运行的 mpv 实例（通过 IPC 命名管道）
- 通过 mpv IPC 协议读取每个实例的**当前播放文件路径**、**播放进度**
- 通过 Win32 API 精确获取每个 mpv 窗口的**位置、大小、是否最大化**
- 将以上信息汇总，生成一个带时间戳的 JSON 文件（如 `mpv_state_20260727_095500.json`）

### 2. `restore_state.ps1`（恢复）

- 自动查找脚本目录下**最新**的 `mpv_state_*.json` 文件
- 根据 JSON 中记录的文件路径，逐个启动 mpv 并跳转到对应播放进度
- 通过 Win32 `SetWindowPos` 精确恢复窗口的位置和大小（不依赖 mpv 自身的 `--geometry` 参数，避免受视频比例、标题栏边框等因素干扰）
- 若原窗口为最大化状态，会先恢复窗口再执行最大化
- **恢复完成后会在末尾统一汇总列出所有被跳过的视频**，并附带具体跳过原因，方便排查（例如文件已被移动/删除、窗口句柄获取失败等）

## 工作原理

mpv 支持通过 `--input-ipc-server` 参数开启一个命名管道，外部程序可以通过这个管道发送 JSON 格式的命令来查询或控制 mpv（官方文档：[JSON IPC](https://mpv.io/manual/master/#json-ipc)）。

本项目约定：**每个 mpv 实例的 IPC 管道名称为 `mpv_ipc_<进程PID>`**，例如：
\.\pipe\mpv_ipc_12345


为了让每个 mpv 实例自动创建以自身 PID 命名的管道，需要一个 mpv 脚本（`auto_ipc.lua`）在启动时自动设置该选项。

## 安装步骤

### 第一步：安装 mpv

确保 mpv 已安装，并且能通过以下任一方式被脚本找到：

- 与脚本放在同一目录
- 已加入系统 `PATH` 环境变量
- 安装在常见路径下，例如 `%ProgramFiles%\mpv\mpv.exe`、`%LOCALAPPDATA%\mpv\mpv.exe`

### 第二步：安装 `auto_ipc.lua`

在 mpv 配置目录下创建脚本文件：

%APPDATA%\mpv\scripts\auto_ipc.lua

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



说明：mpv 提供只读属性 pid，可获取当前进程 ID。该脚本会在 mpv 启动时自动把 IPC 管道设置为 mpv_ipc_<PID>，无需手动传参。

第三步：放置本项目脚本
将以下两个文件放在同一个目录下（建议单独建一个文件夹，例如 D:\mpv_state_tool\）：

save_state.ps1

restore_state.ps1

全局命令行调用（推荐）
默认情况下，需要打开脚本所在文件夹并双击 .ps1 文件才能运行，比较繁琐。

更推荐的做法是：编写两个 .bat 批处理文件，并把脚本所在目录加入系统 PATH 环境变量，之后就可以在任意目录下、任意 CMD / PowerShell 窗口中，直接输入命令即可保存或恢复状态，无需再打开文件管理器。

第一步：在脚本目录下创建两个 bat 文件
假设脚本存放目录为 D:\mpv_state_tool\，在该目录下新建以下两个文件：

restore.bat（用于恢复播放状态）：
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0restore_state.ps1"
pause

save.bat（用于保存播放状态）：
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0save_state.ps1"
pause

说明：

%~dp0 表示当前 bat 文件所在的目录，因此无论把这个文件夹放在哪个盘符下，都不需要修改脚本内容

-ExecutionPolicy Bypass 用于临时绕过 PowerShell 的脚本执行策略限制，仅对本次调用生效，不会更改系统全局策略

末尾的 pause 用于运行结束后暂停窗口，方便查看输出结果（包括跳过明细汇总）

此时目录结构应类似：
D:\mpv_state_tool\
├── save_state.ps1
├── restore_state.ps1
├── save.bat
└── restore.bat

第二步：把脚本目录加入系统 PATH
加入 PATH 后，Windows 会在任意目录下的命令行中自动搜索该目录内的可执行文件（包括 .bat），从而实现"全局命令"的效果。

以下提供两种配置方式，任选其一即可。

方式一：图形界面操作（推荐新手）
右键点击"此电脑" → 选择"属性"

点击"高级系统设置"

在弹出窗口中点击"环境变量"

在"系统变量"（或"用户变量"）中找到名为 Path 的条目，选中后点击"编辑"

点击"新建"，粘贴脚本所在目录路径，例如：D:\mpv_state_tool

一路点击"确定"保存所有窗口

重新打开一个新的 CMD / PowerShell 窗口（已打开的窗口不会自动生效）

方式二：命令行操作（推荐熟悉命令行的用户）
以管理员身份打开 PowerShell 或 CMD，执行以下命令即可将目录写入系统级 PATH（对所有用户生效）：

setx PATH "%PATH%;D:\mpv_state_tool" /M

如果只想对当前用户生效（无需管理员权限），去掉 /M 参数即可：
setx PATH "%PATH%;D:\mpv_state_tool"
setx 是 Windows 提供的官方命令行工具，用于永久写入环境变量（区别于 set，后者只在当前会话临时生效）。使用 /M 参数表示修改系统级环境变量，否则默认只修改当前用户的环境变量。

同样，配置完成后需要重新打开一个新的命令行窗口才能生效。

⚠️ 注意：setx 读取 %PATH% 时是从注册表中读取当前用户/系统变量，而不是当前会话展开后的完整 PATH，因此在某些情况下直接拼接可能导致长度超限或重复。如果追加多次，建议先通过图形界面检查 PATH 内容是否重复膨胀。

第三步：验证配置
打开一个新的 CMD 窗口，输入以下命令测试：

where save.bat
where restore.bat

如果能正确输出文件路径，说明 PATH 配置成功。

第四步：随时随地一键调用
配置完成后，无论当前处于哪个目录，直接在命令行中输入：

save

即可保存当前所有 mpv 窗口状态；输入：
restore


即可恢复最近一次保存的状态。

也可以进一步为这两个命令设置全局快捷键（例如通过 AutoHotkey 绑定快捷键调用 save.bat / restore.bat），实现"一键保存/恢复"的效果，本 README 不再展开。

使用方法
保存状态
正常使用 mpv 打开若干个视频，调整好每个窗口的位置、大小

双击运行 save_state.ps1，或在命令行中输入 save（需已完成 PATH 配置）

脚本会自动扫描所有 mpv 实例，采集状态后在同目录生成 mpv_state_<时间戳>.json

可以放心关闭 mpv 或关机

恢复状态
双击运行 restore_state.ps1，或在命令行中输入 restore（需已完成 PATH 配置）

脚本会自动查找最新的 mpv_state_*.json 文件

依次启动 mpv，跳转到记录的播放进度，并恢复窗口位置/大小/最大化状态

全部处理完成后，控制台会输出：

成功恢复的数量

跳过的数量

跳过明细列表（逐条列出文件路径 + 跳过原因）

示例输出：

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


JSON 状态文件格式
save_state.ps1 生成的 JSON 是一个数组，每个元素对应一个 mpv 窗口，字段说明如下：

字段	类型	说明
pid	int	mpv 进程 ID（仅保存时使用，恢复时不依赖）
file_path	string	正在播放的文件完整路径
time_pos	double	播放进度（单位：秒）
window_x	int	窗口左上角 X 坐标（屏幕坐标系）
window_y	int	窗口左上角 Y 坐标
window_width	int	窗口宽度（像素）
window_height	int	窗口高度（像素）
is_maximized	bool	该窗口是否处于最大化状态
示例：

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


工具二：随机网格播放器
一个基于 PowerShell 的小工具，用于在屏幕网格中随机播放多个视频片段。
它会自动扫描指定目录中的视频文件，随机挑选若干个，并在屏幕网格中并排显示，每个视频从随机时间点开始播放并暂停。

适合用于展示、预览、视频墙等场景。

功能特性
从配置文件中读取视频目录、网格行列数、随机起始比例等参数

自动扫描目录中的视频文件（支持常见格式），不递归子目录

随机挑选视频，确保不重复

使用 ffprobe 获取视频时长和宽高信息

根据视频原始比例计算窗口大小，在屏幕网格内居中显示

自动排除时长过短的视频，并补充替补视频

所有窗口默认暂停在随机时间点，方便逐一查看

支持自定义 mpv 额外参数（如静音、音量等）

控制台输出每个窗口的详细信息（PID、时长、起始时间等）

配置说明
在脚本同目录下创建 config.json，内容示例如下：

{
  "directories": [
    "D:\\Videos\\Movies",
    "E:\\Downloads\\Clips"
  ],
  "grid": {
    "columns": 3,
    "rows": 2
  },
  "randomStart": {
    "minRatio": 0.0,
    "maxRatio": 0.8
  },
  "minDurationSeconds": 10.0,
  "videoExtensions": [".mp4", ".mkv", ".avi", ".mov"],
  "mpvPath": "",
  "ffprobePath": "",
  "mute": false,
  "volume": 50,
  "extraMpvArgs": ["--no-osc", "--no-input-default-bindings"]
}

配置项说明：

字段	类型	说明
directories	字符串数组	要扫描的视频目录（不递归子目录）
grid.columns	整数	网格列数
grid.rows	整数	网格行数（总窗口数 = 列 × 行）
randomStart.minRatio	浮点数	随机起始位置的最小比例（0~1），默认 0.0
randomStart.maxRatio	浮点数	随机起始位置的最大比例（0~1），默认 0.8
minDurationSeconds	浮点数	排除时长小于此值的视频（单位：秒），默认 10.0
videoExtensions	字符串数组	允许的文件扩展名（不区分大小写），默认包含常见格式
mpvPath	字符串	mpv.exe 的完整路径（可选，留空则自动查找）
ffprobePath	字符串	ffprobe.exe 的完整路径（可选，留空则自动查找）
mute	布尔值	是否静音播放，默认 false
volume	整数	音量值（0~100），默认不设置
extraMpvArgs	字符串数组	传递给 mpv 的额外命令行参数
使用方法
编辑 config.json，设置好视频目录和网格参数

打开 PowerShell 或 CMD，进入脚本所在目录

执行脚本：
.\random_grid_mpv.ps1

或指定配置文件路径：
.\random_grid_mpv.ps1 -ConfigPath "D:\my_config.json"

脚本会：

扫描目录，随机打乱视频列表

逐个打开视频，跳过不符合条件的（时长不足、无法读取等）

当成功打开的视频数量达到所需数量（列 × 行）时停止

在控制台显示每个视频的详细信息

所有窗口将停留在随机时间点（暂停状态）

按任意键退出脚本，但所有 mpv 窗口会继续保持打开状态（不会关闭）。

运行示例
假设配置为 3 列 × 2 行，共需 6 个视频。脚本输出可能如下：

===== mpv 随机网格播放器 =====

mpv 路径：C:\tools\mpv\mpv.exe
ffprobe 路径：C:\tools\ffmpeg\bin\ffprobe.exe
屏幕尺寸：1920 x 1080
网格布局：3 x 2，共需 6 个视频窗口
随机起始比例：0.0 ~ 0.8
最小时长：10 秒

正在扫描视频文件...
找到候选视频文件：45 个

[1/6] 正在打开：D:\Videos\movie1.mp4
    成功：PID=1234, 时长=120.5s, 起点=45.2s, 窗口=640x360+100+200
[2/6] 正在打开：E:\clips\clip2.mkv
    成功：PID=1235, 时长=85.3s, 起点=22.1s, 窗口=640x360+740+200
...

===== 已开启视频列表 =====
Index Row Column Pid FileName DurationSeconds StartSeconds ...
----- --- ------ --- -------- --------------- ------------ ...
1     1   1      1234 movie1.mp4 120.500        45.200
...

===== 完整路径 =====
[1] 行1 列1 | D:\Videos\movie1.mp4
...

所有窗口已打开并暂停。按任意键退出此控制台脚本；mpv 窗口会继续保留。



已知限制
保存/恢复工具
仅支持 Windows 系统（依赖 Win32 API 和命名管道）

不会保存音量、字幕轨道、音轨等播放参数，仅保存文件路径 + 播放进度 + 窗口几何信息

恢复时会重新启动 mpv 进程，原进程 PID 不会保留

多显示器环境下，如果保存后又拔掉/更换了显示器，窗口坐标可能落在不存在的屏幕区域之外

随机网格播放器
仅支持 Windows 系统（依赖 Win32 API）

窗口位置基于主显示器，多显示器下窗口只出现在主屏幕

使用 ffprobe 解析视频信息，某些格式可能解析较慢或失败

不会对视频进行转码或缩放，视频窗口大小根据原始比例计算，可能在某些分辨率下显示不全

许可证
本项目脚本仅供个人学习和使用，可自由修改和分发。
