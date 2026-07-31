# restore_state.ps1
# 功能：读取最新的 mpv_state_*.json，批量恢复 mpv 播放窗口
# 使用方式：双击运行
#
# 重要改动：
#   1. 不再使用 mpv --geometry 恢复窗口
#   2. 启动 mpv 后，通过 Win32 SetWindowPos 精确恢复外层窗口位置和大小
#   3. 因此窗口大小、位置不会再被 mpv 的 geometry 语义、视频比例、标题栏边框干扰
#   4. 新增：跳过的视频文件会在最后统一汇总显示（含跳过原因）

# ─────────────────────────────────────────────────────────────
# 编码设置
# ─────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─────────────────────────────────────────────────────────────
# DPI Awareness
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MpvRestoreDpiAwareness {
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int awareness);

    public static void Enable() {
        // Windows 10 1703+：PER_MONITOR_AWARE_V2 = -4
        try {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                return;
            }
        } catch {}

        // Windows 8.1+：PROCESS_PER_MONITOR_DPI_AWARE = 2
        try {
            SetProcessDpiAwareness(2);
        } catch {}
    }
}
"@

[MpvRestoreDpiAwareness]::Enable()

# ─────────────────────────────────────────────────────────────
# Win32：查找 mpv 窗口并精确移动/缩放
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MpvRestoreWindowApi {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags
    );

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static IntPtr FindMainWindowByPid(uint pid) {
        IntPtr found = IntPtr.Zero;

        EnumWindows((hWnd, lParam) => {
            if (found != IntPtr.Zero) {
                return true;
            }

            if (!IsWindowVisible(hWnd)) {
                return true;
            }

            if (GetWindowTextLength(hWnd) == 0) {
                return true;
            }

            uint windowPid;
            GetWindowThreadProcessId(hWnd, out windowPid);

            if (windowPid == pid) {
                found = hWnd;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    public static bool MoveWindowExact(IntPtr hWnd, int x, int y, int width, int height) {
        // SWP_NOZORDER   = 0x0004
        // SWP_NOACTIVATE = 0x0010
        // SWP_SHOWWINDOW = 0x0040
        uint flags = 0x0004 | 0x0010 | 0x0040;

        return SetWindowPos(
            hWnd,
            IntPtr.Zero,
            x,
            y,
            width,
            height,
            flags
        );
    }

    public static void RestoreWindow(IntPtr hWnd) {
        // SW_RESTORE = 9
        ShowWindow(hWnd, 9);
    }

    public static void MaximizeWindow(IntPtr hWnd) {
        // SW_MAXIMIZE = 3
        ShowWindow(hWnd, 3);
    }
}
"@

# ─────────────────────────────────────────────────────────────
# 辅助函数：格式化 mpv --start 参数
# 直接使用秒数，避免 HH:MM:SS 在部分场景下的兼容问题
# ─────────────────────────────────────────────────────────────
function Format-TimePos {
    param(
        [double]$Seconds
    )

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    return $Seconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
}

# ─────────────────────────────────────────────────────────────
# 辅助函数：查找 mpv.exe
# ─────────────────────────────────────────────────────────────
function Find-MpvExecutable {
    param(
        [string]$ScriptDir
    )

    $candidates = @()

    # 1. 脚本同目录
    $candidates += Join-Path $ScriptDir "mpv.exe"

    # 2. PATH
    $cmd = Get-Command "mpv.exe" -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        $candidates += $cmd.Source
    }

    # 3. 常见安装路径
    if ($env:ProgramFiles) {
        $candidates += "$env:ProgramFiles\mpv\mpv.exe"
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates += "${env:ProgramFiles(x86)}\mpv\mpv.exe"
    }

    if ($env:LOCALAPPDATA) {
        $candidates += "$env:LOCALAPPDATA\mpv\mpv.exe"
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

# ─────────────────────────────────────────────────────────────
# 辅助函数：简单命令行参数转义
# 用于 Start-Process -ArgumentList
# ─────────────────────────────────────────────────────────────
function Quote-CommandLineArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  mpv 播放状态恢复工具" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Step 1：查找最新 JSON
Write-Host "[1/4] 扫描状态文件..." -ForegroundColor White

$latestFile = Get-ChildItem -Path $scriptDir -Filter "mpv_state_*.json" -File |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $latestFile) {
    Write-Host ""
    Write-Host "  ！在脚本目录下未找到任何 mpv_state_*.json 文件。" -ForegroundColor Red
    Write-Host "  请先运行 save_state.ps1 保存一次状态。" -ForegroundColor Red
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  使用文件：$($latestFile.Name)" -ForegroundColor Green

# Step 2：读取 JSON
Write-Host "[2/4] 读取状态数据..." -ForegroundColor White

try {
    $jsonRaw = [System.IO.File]::ReadAllText(
        $latestFile.FullName,
        [System.Text.Encoding]::UTF8
    )

    $stateList = $jsonRaw | ConvertFrom-Json
}
catch {
    Write-Host ""
    Write-Host "  ！JSON 文件解析失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# 兼容单对象 JSON
if ($stateList -isnot [System.Array]) {
    $stateList = @($stateList)
}

$total = $stateList.Count

if ($total -le 0) {
    Write-Host ""
    Write-Host "  ！JSON 中没有任何记录。" -ForegroundColor Red
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  共读取到 $total 条记录" -ForegroundColor Green

# Step 3：查找 mpv.exe
Write-Host "[3/4] 定位 mpv 程序..." -ForegroundColor White

$mpvPath = Find-MpvExecutable -ScriptDir $scriptDir

if ($null -eq $mpvPath) {
    Write-Host ""
    Write-Host "  ！找不到 mpv.exe。" -ForegroundColor Red
    Write-Host "  请确认 mpv 已安装并加入 PATH，" -ForegroundColor Red
    Write-Host "  或将 mpv.exe 与本脚本放在同一目录。" -ForegroundColor Red
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  mpv 路径：$mpvPath" -ForegroundColor Green

# Step 4：逐条恢复
Write-Host "[4/4] 开始恢复..." -ForegroundColor White
Write-Host ""

$successCount = 0
$skipCount = 0
$index = 0

# 新增：记录被跳过的文件（路径 + 原因），用于最后统一汇总显示
$skippedItems = @()

foreach ($entry in $stateList) {
    $index++

    $filePath = [string]$entry.file_path
    $displayPath = if ([string]::IsNullOrWhiteSpace($filePath)) { "(路径为空 - 第 $index 条)" } else { $filePath }

    Write-Host "  [$index/$total] $filePath" -ForegroundColor White

    if ([string]::IsNullOrWhiteSpace($filePath)) {
        Write-Host "    ！文件路径为空，已跳过" -ForegroundColor Yellow
        $skipCount++
        $skippedItems += [PSCustomObject]@{ Path = $displayPath; Reason = "文件路径为空" }
        continue
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Host "    ！文件不存在，已跳过" -ForegroundColor Yellow
        $skipCount++
        $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "文件不存在" }
        continue
    }

    $timePos = 0.0

    try {
        $timePos = [double]$entry.time_pos
    }
    catch {
        $timePos = 0.0
    }

    $timeStr = Format-TimePos -Seconds $timePos

    # 读取窗口矩形
    try {
        $geoX = [int][Math]::Round([double]$entry.window_x)
        $geoY = [int][Math]::Round([double]$entry.window_y)
        $geoW = [int][Math]::Round([double]$entry.window_width)
        $geoH = [int][Math]::Round([double]$entry.window_height)
    }
    catch {
        Write-Host "    ！窗口数据异常，已跳过" -ForegroundColor Yellow
        $skipCount++
        $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "窗口数据异常" }
        continue
    }

    if ($geoW -le 0 -or $geoH -le 0) {
        Write-Host "    ！窗口尺寸异常，已跳过" -ForegroundColor Yellow
        $skipCount++
        $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "窗口尺寸异常" }
        continue
    }

    # 注意：
    # 这里不再使用 --geometry
    # 窗口位置和大小会在 mpv 窗口创建后通过 SetWindowPos 恢复
    $mpvArgs = @(
        "--start=$timeStr",
        "--pause=yes",
        "--force-window=yes",
        "--no-terminal",
        "--"
    )

    $mpvArgs += $filePath

    $argumentString = ($mpvArgs | ForEach-Object { Quote-CommandLineArgument -Argument $_ }) -join " "

    try {
        $proc = Start-Process -FilePath $mpvPath -ArgumentList $argumentString -PassThru

        if ($null -eq $proc) {
            Write-Host "    ！启动失败：未能获取进程对象" -ForegroundColor Red
            $skipCount++
            $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "启动失败：未能获取进程对象" }
            continue
        }

        # 等待 mpv 主窗口出现，最长约 10 秒
        $hwnd = [IntPtr]::Zero

        for ($i = 0; $i -lt 100; $i++) {
            Start-Sleep -Milliseconds 100

            try {
                if ($proc.HasExited) {
                    break
                }
            }
            catch {}

            $hwnd = [MpvRestoreWindowApi]::FindMainWindowByPid([uint32]$proc.Id)

            if ($hwnd -ne [IntPtr]::Zero) {
                break
            }
        }

        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Host "    ！已启动 mpv，但未找到窗口句柄，无法恢复位置" -ForegroundColor Yellow
            $skipCount++
            $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "未找到窗口句柄" }
            continue
        }

        # 先恢复为普通窗口，避免最大化状态干扰 SetWindowPos
        [MpvRestoreWindowApi]::RestoreWindow($hwnd)
        Start-Sleep -Milliseconds 50

        # 第一次移动/缩放
        $moveOk = [MpvRestoreWindowApi]::MoveWindowExact(
            $hwnd,
            $geoX,
            $geoY,
            $geoW,
            $geoH
        )

        Start-Sleep -Milliseconds 100

        # 再执行一次，防止 mpv 初始化期间自己调整窗口尺寸
        $moveOk2 = [MpvRestoreWindowApi]::MoveWindowExact(
            $hwnd,
            $geoX,
            $geoY,
            $geoW,
            $geoH
        )

        # 如果原始状态是最大化，则先移动到对应屏幕，再最大化
        if ($entry.is_maximized -eq $true) {
            Start-Sleep -Milliseconds 50
            [MpvRestoreWindowApi]::MaximizeWindow($hwnd)
        }

        if ($moveOk -or $moveOk2) {
            Write-Host "    ✓ 已启动  进度=${timeStr}s  窗口=${geoW}x${geoH}+${geoX}+${geoY}  最大化=$($entry.is_maximized)" -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "    ！SetWindowPos 失败" -ForegroundColor Yellow
            $skipCount++
            $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "SetWindowPos 失败" }
        }
    }
    catch {
        Write-Host "    ！启动失败：$($_.Exception.Message)" -ForegroundColor Red
        $skipCount++
        $skippedItems += [PSCustomObject]@{ Path = $filePath; Reason = "启动失败：$($_.Exception.Message)" }
    }

    Start-Sleep -Milliseconds 80
}

# 汇总
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  恢复完成" -ForegroundColor Cyan
Write-Host "  成功：$successCount  跳过：$skipCount  共计：$total" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 新增：跳过明细汇总显示
if ($skippedItems.Count -gt 0) {
    Write-Host ""
    Write-Host "以下文件被跳过：" -ForegroundColor Yellow
    Write-Host "----------------------------------------" -ForegroundColor Yellow

    $i = 0
    foreach ($item in $skippedItems) {
        $i++
        Write-Host "  [$i] $($item.Path)" -ForegroundColor Yellow
        Write-Host "      原因：$($item.Reason)" -ForegroundColor DarkYellow
    }

    Write-Host "----------------------------------------" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "窗口将在 3 秒后自动关闭..." -ForegroundColor Gray
Start-Sleep -Seconds 2