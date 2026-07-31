# save_state.ps1
# 功能：扫描所有正在运行的 mpv IPC 管道，保存播放状态、窗口位置和大小到 JSON
# 使用方式：双击运行
#
# 依赖：
#   1. mpv 正在运行
#   2. 每个 mpv 实例需要创建类似 \\.\pipe\mpv_ipc_进程ID 的 IPC 管道
#   3. 通常需要 auto_ipc.lua 放在 %APPDATA%\mpv\scripts\ 下

# ─────────────────────────────────────────────────────────────
# 编码设置
# ─────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─────────────────────────────────────────────────────────────
# DPI Awareness：避免 Windows 缩放导致坐标/尺寸虚拟化
# 即使你设置为 100% DPI，保留这段也更稳
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MpvStateDpiAwareness {
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

[MpvStateDpiAwareness]::Enable()

# ─────────────────────────────────────────────────────────────
# Win32：通过 PID 获取窗口矩形
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MpvStateWindowApi {
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
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    private static extern bool IsZoomed(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public struct WindowInfo {
        public IntPtr Handle;
        public int X;
        public int Y;
        public int Width;
        public int Height;
        public bool IsMaximized;
    }

    public static WindowInfo GetWindowInfoByPid(uint pid) {
        WindowInfo result = new WindowInfo();
        result.Handle = IntPtr.Zero;

        EnumWindows((hWnd, lParam) => {
            if (result.Handle != IntPtr.Zero) {
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
                RECT rect;
                if (GetWindowRect(hWnd, out rect)) {
                    result.Handle = hWnd;
                    result.X = rect.Left;
                    result.Y = rect.Top;
                    result.Width = rect.Right - rect.Left;
                    result.Height = rect.Bottom - rect.Top;
                    result.IsMaximized = IsZoomed(hWnd);
                }
            }

            return true;
        }, IntPtr.Zero);

        return result;
    }
}
"@

# ─────────────────────────────────────────────────────────────
# 辅助函数：调用 mpv IPC
# ─────────────────────────────────────────────────────────────
function Invoke-MpvIpc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PipePath,

        [Parameter(Mandatory = $true)]
        [string]$JsonRequest
    )

    $pipeNameOnly = $PipePath

    if ($PipePath -match '^\\\\\.\\pipe\\(.+)$') {
        $pipeNameOnly = $Matches[1]
    }

    $pipe = $null
    $writer = $null
    $reader = $null

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
            ".",
            $pipeNameOnly,
            [System.IO.Pipes.PipeDirection]::InOut,
            [System.IO.Pipes.PipeOptions]::None
        )

        # 连接超时 1500ms
        $pipe.Connect(1500)

        # 很关键：UTF-8 无 BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $writer = New-Object System.IO.StreamWriter($pipe, $utf8NoBom)
        $writer.AutoFlush = $true

        $reader = New-Object System.IO.StreamReader($pipe, $utf8NoBom)

        # 向 mpv IPC 写入一行 JSON
        $writer.WriteLine($JsonRequest)
        $writer.Flush()

        # 读取响应，加超时，避免无限卡死
        $responseTask = $reader.ReadLineAsync()

        if (-not $responseTask.Wait(1500)) {
            Write-Host "    IPC 读取超时：$PipePath" -ForegroundColor Yellow
            return $null
        }

        return $responseTask.Result
    }
    catch {
        Write-Host "    IPC 调用异常：$($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        if ($reader -ne $null) {
            try { $reader.Dispose() } catch {}
        }

        if ($writer -ne $null) {
            try { $writer.Dispose() } catch {}
        }

        if ($pipe -ne $null) {
            try { $pipe.Dispose() } catch {}
        }
    }
}

# ─────────────────────────────────────────────────────────────
# 辅助函数：读取 mpv 属性
# ─────────────────────────────────────────────────────────────
function Get-MpvProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PipePath,

        [Parameter(Mandatory = $true)]
        [string]$Property,

        [Parameter(Mandatory = $true)]
        [int]$RequestId
    )

    $request = @{
        command = @("get_property", $Property)
        request_id = $RequestId
    } | ConvertTo-Json -Compress

    $raw = Invoke-MpvIpc -PipePath $PipePath -JsonRequest $request

    if ($null -eq $raw) {
        return $null
    }

    try {
        $obj = $raw | ConvertFrom-Json

        if ($obj.error -eq "success") {
            return $obj.data
        }
    }
    catch {
        return $null
    }

    return $null
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  mpv 播放状态保存工具" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1：扫描 mpv IPC 管道
Write-Host "[1/4] 扫描 mpv IPC 管道..." -ForegroundColor White

$mpvPipes = @()

try {
    $pipeItems = Get-ChildItem -LiteralPath "\\.\pipe\" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^mpv_ipc_\d+$' }

    foreach ($item in $pipeItems) {
        $mpvPipes += "\\.\pipe\$($item.Name)"
    }
}
catch {
    # 备用方案
    try {
        $allPipePaths = [System.IO.Directory]::GetFiles("\\.\pipe\")

        foreach ($pipePath in $allPipePaths) {
            if ($pipePath -match 'mpv_ipc_\d+$') {
                $mpvPipes += $pipePath
            }
        }
    }
    catch {}
}

$mpvPipes = @($mpvPipes | Sort-Object -Unique)

if ($mpvPipes.Count -eq 0) {
    Write-Host ""
    Write-Host "  ！未发现任何正在运行的 mpv 实例。" -ForegroundColor Yellow
    Write-Host "  请确认：" -ForegroundColor Yellow
    Write-Host "    1. mpv 正在运行" -ForegroundColor Yellow
    Write-Host "    2. auto_ipc.lua 已放入 %APPDATA%\mpv\scripts\" -ForegroundColor Yellow
    Write-Host "    3. mpv IPC 管道名称形如：mpv_ipc_进程ID" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  发现 $($mpvPipes.Count) 个 mpv IPC 管道" -ForegroundColor Green

# Step 2：读取播放状态
Write-Host "[2/4] 查询播放状态和窗口信息..." -ForegroundColor White

$stateList = @()
$requestId = 1

foreach ($pipePath in $mpvPipes) {
    if ($pipePath -match 'mpv_ipc_(\d+)$') {
        $mpvPid = [uint32]$Matches[1]
    }
    else {
        continue
    }

    Write-Host "  处理 PID $mpvPid ..." -ForegroundColor Gray

    $filePath = Get-MpvProperty -PipePath $pipePath -Property "path" -RequestId $requestId
    $requestId++

    $timePos = Get-MpvProperty -PipePath $pipePath -Property "time-pos" -RequestId $requestId
    $requestId++

    if ([string]::IsNullOrWhiteSpace([string]$filePath)) {
        Write-Host "    跳过：无法获取文件路径" -ForegroundColor Yellow
        continue
    }

    $winInfo = [MpvStateWindowApi]::GetWindowInfoByPid($mpvPid)

    if ($winInfo.Handle -eq [IntPtr]::Zero) {
        Write-Host "    跳过：找不到 PID $mpvPid 对应的窗口" -ForegroundColor Yellow
        continue
    }

    if ($winInfo.Width -le 0 -or $winInfo.Height -le 0) {
        Write-Host "    跳过：窗口尺寸异常" -ForegroundColor Yellow
        continue
    }

    $timePosValue = 0.0

    if ($null -ne $timePos) {
        try {
            $timePosValue = [double]$timePos
        }
        catch {
            $timePosValue = 0.0
        }
    }

    $entry = [PSCustomObject]@{
        pid              = [int]$mpvPid
        file_path        = [string]$filePath
        time_pos         = [double]$timePosValue
        window_x         = [int]$winInfo.X
        window_y         = [int]$winInfo.Y
        window_width     = [int]$winInfo.Width
        window_height    = [int]$winInfo.Height
        is_maximized     = [bool]$winInfo.IsMaximized
    }

    $stateList += $entry

    Write-Host "    OK：$filePath" -ForegroundColor Green
    Write-Host "        进度 $([Math]::Round($entry.time_pos, 3))s  窗口 $($entry.window_width)x$($entry.window_height)+$($entry.window_x)+$($entry.window_y)  最大化=$($entry.is_maximized)" -ForegroundColor Gray
}

if ($stateList.Count -eq 0) {
    Write-Host ""
    Write-Host "  ！没有成功采集到任何 mpv 状态，文件未保存。" -ForegroundColor Red
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Step 3：生成 JSON
Write-Host "[3/4] 生成 JSON 文件..." -ForegroundColor White

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "mpv_state_$timestamp.json"

$jsonContent = $stateList | ConvertTo-Json -Depth 8

# UTF-8 无 BOM
[System.IO.File]::WriteAllText(
    $outputFile,
    $jsonContent,
    [System.Text.UTF8Encoding]::new($false)
)

# Step 4：完成
Write-Host "[4/4] 保存完成！" -ForegroundColor Green
Write-Host ""
Write-Host "  文件：$outputFile" -ForegroundColor Cyan
Write-Host "  共保存 $($stateList.Count) 个 mpv 窗口状态" -ForegroundColor Cyan
Write-Host ""
Write-Host "窗口将在 5 秒后自动关闭..." -ForegroundColor Gray
Start-Sleep -Seconds 5
