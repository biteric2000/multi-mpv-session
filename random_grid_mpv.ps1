# random_grid_mpv.ps1
# 功能：
# 1. 从 config.json 中读取目录、网格、随机起始比例等设置
# 2. 只扫描配置目录本身，不递归
# 3. 随机挑选不重复视频文件
# 4. 使用 ffprobe 读取视频时长、宽高，不再依赖 mpv IPC
# 5. 用 mpv 打开多个无边框暂停窗口，并通过 --start 跳转到随机位置
# 6. 按视频比例计算窗口尺寸，在单显示器物理屏幕中按网格居中摆放
# 7. 低于最小时长的视频排除；坏视频跳过并抽替补
# 8. 控制台显示已开启视频信息，按任意键后脚本退出，mpv 窗口保留

[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Win32 API
# -----------------------------

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win32Api
{
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}

public struct RECT
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}
"@

$SW_RESTORE = 9
$SWP_NOZORDER = 0x0004
$SWP_SHOWWINDOW = 0x0040

function Get-PrimaryPhysicalScreenSize {
    return [PSCustomObject]@{
        Width  = [Win32Api]::GetSystemMetrics(0)
        Height = [Win32Api]::GetSystemMetrics(1)
    }
}

function Get-WindowRect {
    param([IntPtr]$Handle)

    $rect = New-Object RECT
    $ok = [Win32Api]::GetWindowRect($Handle, [ref]$rect)

    if (-not $ok) {
        throw "获取窗口矩形失败"
    }

    return [PSCustomObject]@{
        Left   = $rect.Left
        Top    = $rect.Top
        Right  = $rect.Right
        Bottom = $rect.Bottom
        Width  = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

# -----------------------------
# 配置与基础工具函数
# -----------------------------

function Resolve-ConfigPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path -Path (Get-Location) -ChildPath $Path)
}

function Load-Config {
    param([string]$Path)

    $realPath = Resolve-ConfigPath -Path $Path

    if (-not (Test-Path -LiteralPath $realPath)) {
        throw "配置文件不存在：$realPath"
    }

    $json = Get-Content -LiteralPath $realPath -Raw -Encoding UTF8
    return ($json | ConvertFrom-Json)
}

function Get-ScriptDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Find-MpvExe {
    param($Config)

    $scriptDir = Get-ScriptDirectory

    if ($Config.mpvPath -and -not [string]::IsNullOrWhiteSpace([string]$Config.mpvPath)) {
        if (Test-Path -LiteralPath $Config.mpvPath) {
            return (Resolve-Path -LiteralPath $Config.mpvPath).Path
        }

        throw "配置中的 mpvPath 不存在：$($Config.mpvPath)"
    }

    $localMpv = Join-Path $scriptDir "mpv.exe"

    if (Test-Path -LiteralPath $localMpv) {
        return $localMpv
    }

    $cmd = Get-Command "mpv.exe" -ErrorAction SilentlyContinue

    if ($cmd) {
        return $cmd.Source
    }

    $commonPaths = @(
        "$env:ProgramFiles\mpv\mpv.exe",
        "${env:ProgramFiles(x86)}\mpv\mpv.exe",
        "$env:LOCALAPPDATA\mpv\mpv.exe"
    )

    foreach ($p in $commonPaths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return $p
        }
    }

    throw "找不到 mpv.exe。请把 mpv.exe 放到脚本同目录、加入 PATH，或在 config.json 中设置 mpvPath。"
}

function Find-FfprobeExe {
    param($Config)

    $scriptDir = Get-ScriptDirectory

    if ($Config.ffprobePath -and -not [string]::IsNullOrWhiteSpace([string]$Config.ffprobePath)) {
        if (Test-Path -LiteralPath $Config.ffprobePath) {
            return (Resolve-Path -LiteralPath $Config.ffprobePath).Path
        }

        throw "配置中的 ffprobePath 不存在：$($Config.ffprobePath)"
    }

    $localFfprobe = Join-Path $scriptDir "ffprobe.exe"

    if (Test-Path -LiteralPath $localFfprobe) {
        return $localFfprobe
    }

    $cmd = Get-Command "ffprobe.exe" -ErrorAction SilentlyContinue

    if ($cmd) {
        return $cmd.Source
    }

    $commonPaths = @(
        "$env:ProgramFiles\ffmpeg\bin\ffprobe.exe",
        "${env:ProgramFiles(x86)}\ffmpeg\bin\ffprobe.exe",
        "$env:LOCALAPPDATA\ffmpeg\bin\ffprobe.exe",
        "C:\ffmpeg\bin\ffprobe.exe",
        "C:\ProgramData\chocolatey\bin\ffprobe.exe"
    )

    foreach ($p in $commonPaths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return $p
        }
    }

    throw "找不到 ffprobe.exe。请安装 ffmpeg，或把 ffprobe.exe 放到脚本同目录，或在 config.json 中设置 ffprobePath。"
}

function Normalize-Extensions {
    param($Extensions)

    $result = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    foreach ($ext in $Extensions) {
        $e = [string]$ext

        if ([string]::IsNullOrWhiteSpace($e)) {
            continue
        }

        if (-not $e.StartsWith(".")) {
            $e = "." + $e
        }

        [void]$result.Add($e.ToLowerInvariant())
    }

    return $result
}

function Get-VideoFilesFromDirectories {
    param($Directories, $AllowedExtensions)

    $files = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    foreach ($dir in $Directories) {
        $dirText = [string]$dir

        if ([string]::IsNullOrWhiteSpace($dirText)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $dirText -PathType Container)) {
            Write-Warning "目录不存在，已跳过：$dirText"
            continue
        }

        Get-ChildItem -LiteralPath $dirText -File | ForEach-Object {
            if ($AllowedExtensions.Contains($_.Extension.ToLowerInvariant())) {
                $full = $_.FullName

                if ($seen.Add($full)) {
                    [void]$files.Add($full)
                }
            }
        }
    }

    return $files
}

function Shuffle-Array {
    param([object[]]$Items)

    $arr = @($Items)

    for ($i = $arr.Count - 1; $i -gt 0; $i--) {
        $j = Get-Random -Minimum 0 -Maximum ($i + 1)

        $tmp = $arr[$i]
        $arr[$i] = $arr[$j]
        $arr[$j] = $tmp
    }

    return $arr
}

function Quote-ProcessArgument {
    param([string]$Text)

    if ($null -eq $Text) {
        return '""'
    }

    # Windows 命令行参数转义：
    # 1. 双引号需要转义成反斜杠双引号
    # 2. 整个参数用双引号包起来，避免路径空格问题
    $escaped = $Text.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-VideoInfoByFfprobe {
    param(
        [string]$FfprobeExe,
        [string]$FilePath,
        [int]$TimeoutMs = 15000
    )

    # 注意：
    # Windows PowerShell 5.1 的 ProcessStartInfo 没有 ArgumentList 属性，
    # 所以这里使用 Arguments 字符串方式，兼容性更好。
    $argList = @(
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "format=duration:stream=width,height",
        "-of",
        "json",
        "--",
        $FilePath
    )

    $escapedArgs = foreach ($a in $argList) {
        Quote-ProcessArgument -Text ([string]$a)
    }

    $arguments = $escapedArgs -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfprobeExe
    $psi.Arguments = $arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    try {
        [void]$p.Start()

        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit($TimeoutMs)) {
            try {
                $p.Kill()
            } catch {}

            throw "ffprobe 读取超时：$FilePath"
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if ($p.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($stderr)) {
                throw "ffprobe 读取失败，退出码：$($p.ExitCode)"
            } else {
                throw "ffprobe 读取失败：$stderr"
            }
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw "ffprobe 没有返回数据。"
        }

        $json = $stdout | ConvertFrom-Json

        if (-not $json.streams -or $json.streams.Count -le 0) {
            throw "ffprobe 未找到视频流。"
        }

        $stream = $json.streams[0]

        $width = [double]$stream.width
        $height = [double]$stream.height

        if (-not $width -or -not $height -or $width -le 0 -or $height -le 0) {
            throw "ffprobe 无法读取视频宽高。"
        }

        $duration = $null

        if ($json.format -and $json.format.duration) {
            $duration = [double]$json.format.duration
        }

        if (-not $duration -or $duration -le 0) {
            throw "ffprobe 无法读取视频时长。"
        }

        return [PSCustomObject]@{
            Duration = [double]$duration
            Width    = [double]$width
            Height   = [double]$height
        }
    }
    finally {
        if ($p) {
            $p.Dispose()
        }
    }
}

# -----------------------------
# 窗口处理
# -----------------------------

function Wait-ForMainWindowHandle {
    param(
        [int]$ProcessId,
        [int]$TimeoutMs = 10000
    )

    $start = Get-Date

    while (((Get-Date) - $start).TotalMilliseconds -lt $TimeoutMs) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue

        if ($p -and $p.MainWindowHandle -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            return $p.MainWindowHandle
        }

        Start-Sleep -Milliseconds 100
    }

    throw "等待 mpv 窗口句柄超时，PID=$ProcessId"
}

function Get-WindowRectForCell {
    param(
        [int]$Index,
        [int]$Columns,
        [int]$Rows,
        [int]$ScreenWidth,
        [int]$ScreenHeight,
        [double]$VideoWidth,
        [double]$VideoHeight
    )

    $col = $Index % $Columns
    $row = [math]::Floor($Index / $Columns)

    $cellW = [double]$ScreenWidth / [double]$Columns
    $cellH = [double]$ScreenHeight / [double]$Rows

    $scale = [math]::Min($cellW / $VideoWidth, $cellH / $VideoHeight)

    $winW = [math]::Max(1, [int][math]::Floor($VideoWidth * $scale))
    $winH = [math]::Max(1, [int][math]::Floor($VideoHeight * $scale))

    $cellX = [int][math]::Round($col * $cellW)
    $cellY = [int][math]::Round($row * $cellH)

    $x = [int][math]::Round($cellX + (($cellW - $winW) / 2.0))
    $y = [int][math]::Round($cellY + (($cellH - $winH) / 2.0))

    return [PSCustomObject]@{
        Row        = $row + 1
        Column     = $col + 1
        CellX      = $cellX
        CellY      = $cellY
        CellWidth  = [int][math]::Floor($cellW)
        CellHeight = [int][math]::Floor($cellH)
        X          = $x
        Y          = $y
        Width      = $winW
        Height     = $winH
    }
}

function Move-Window {
    param(
        [IntPtr]$Handle,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    # 先恢复窗口，若最小化
    [void][Win32Api]::ShowWindow($Handle, $SW_RESTORE)

    $ok = [Win32Api]::SetWindowPos(
        $Handle,
        [IntPtr]::Zero,
        $X,
        $Y,
        $Width,
        $Height,
        $SWP_NOZORDER -bor $SWP_SHOWWINDOW
    )

    return $ok
}

function Ensure-WindowPosition {
    param(
        [IntPtr]$Handle,
        [int]$ExpectedX,
        [int]$ExpectedY,
        [int]$ExpectedWidth,
        [int]$ExpectedHeight,
        [int]$Retries = 3,
        [int]$DelayMs = 200
    )

    for ($i = 0; $i -lt $Retries; $i++) {
        # 尝试移动窗口
        $ok = Move-Window `
            -Handle $Handle `
            -X $ExpectedX `
            -Y $ExpectedY `
            -Width $ExpectedWidth `
            -Height $ExpectedHeight

        if (-not $ok) {
            Write-Warning "SetWindowPos 返回失败，重试 $($i + 1)/$Retries"
        }

        # 等待窗口更新
        Start-Sleep -Milliseconds $DelayMs

        # 读取当前窗口位置
        $rect = Get-WindowRect -Handle $Handle
        $tolerance = 2

        if ([math]::Abs($rect.Left - $ExpectedX) -le $tolerance -and
            [math]::Abs($rect.Top - $ExpectedY) -le $tolerance -and
            [math]::Abs($rect.Width - $ExpectedWidth) -le $tolerance -and
            [math]::Abs($rect.Height - $ExpectedHeight) -le $tolerance) {
            # 位置正确。
            # 注意：这里不要 return $true，否则会污染上层函数返回值。
            return
        }

        Write-Warning "窗口位置不符，期望 ($ExpectedX,$ExpectedY,$ExpectedWidth,$ExpectedHeight)，实际 ($($rect.Left),$($rect.Top),$($rect.Width),$($rect.Height))，重试 $($i + 1)/$Retries"
    }

    throw "经过 $Retries 次尝试，窗口位置仍不正确。"
}

# -----------------------------
# mpv 启动
# -----------------------------

function Start-MpvPaused {
    param(
        [string]$MpvExe,
        [string]$FilePath,
        [double]$StartSeconds,
        $Config
    )

    $mpvArgs = New-Object System.Collections.Generic.List[string]

    [void]$mpvArgs.Add("--pause=yes")
    [void]$mpvArgs.Add("--start=$StartSeconds")
    [void]$mpvArgs.Add("--force-window=yes")
    [void]$mpvArgs.Add("--idle=no")
    [void]$mpvArgs.Add("--keep-open=yes")
    [void]$mpvArgs.Add("--border=no")
    [void]$mpvArgs.Add("--keepaspect=yes")
    [void]$mpvArgs.Add("--no-terminal")
    [void]$mpvArgs.Add("--input-default-bindings=yes")
    [void]$mpvArgs.Add("--input-vo-keyboard=yes")

    if ($Config.mute -eq $true) {
        [void]$mpvArgs.Add("--mute=yes")
    }

    if ($Config.volume -ne $null) {
        [void]$mpvArgs.Add("--volume=$($Config.volume)")
    }

    if ($Config.extraMpvArgs -ne $null) {
        foreach ($a in $Config.extraMpvArgs) {
            if (-not [string]::IsNullOrWhiteSpace([string]$a)) {
                [void]$mpvArgs.Add([string]$a)
            }
        }
    }

    [void]$mpvArgs.Add("--")
    [void]$mpvArgs.Add($FilePath)

    # 使用 ProcessStartInfo 启动，避免 -ArgumentList 与 List<string> 的兼容性问题
    $escapedArgs = foreach ($a in $mpvArgs) {
        Quote-ProcessArgument -Text $a
    }

    $arguments = $escapedArgs -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MpvExe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)

    return $p
}

function Open-And-PrepareVideo {
    param(
        [string]$MpvExe,
        [string]$FfprobeExe,
        [string]$FilePath,
        [int]$Index,
        [int]$Columns,
        [int]$Rows,
        [int]$ScreenWidth,
        [int]$ScreenHeight,
        [double]$RandomStartMinRatio,
        [double]$RandomStartMaxRatio,
        [double]$MinDurationSeconds,
        $Config
    )

    $process = $null

    try {
        $videoInfo = Get-VideoInfoByFfprobe `
            -FfprobeExe $FfprobeExe `
            -FilePath $FilePath

        $duration = [double]$videoInfo.Duration

        if ($duration -lt $MinDurationSeconds) {
            throw "视频时长低于最小时长：$([math]::Round($duration, 2)) 秒 < $MinDurationSeconds 秒"
        }

        $dim = [PSCustomObject]@{
            Width  = [double]$videoInfo.Width
            Height = [double]$videoInfo.Height
        }

        $minRatio = [math]::Max(0.0, [double]$RandomStartMinRatio)
        $maxRatio = [math]::Min(1.0, [double]$RandomStartMaxRatio)

        if ($maxRatio -lt $minRatio) {
            throw "随机起始比例配置错误：randomStartMinRatio > randomStartMaxRatio"
        }

        $randomRatio = Get-Random -Minimum $minRatio -Maximum $maxRatio

        $startSeconds = [math]::Max(
            0.0,
            [math]::Min($duration - 0.1, $duration * $randomRatio)
        )

        $startSecondsForMpv = [math]::Round($startSeconds, 3)

        $rect = Get-WindowRectForCell `
            -Index $Index `
            -Columns $Columns `
            -Rows $Rows `
            -ScreenWidth $ScreenWidth `
            -ScreenHeight $ScreenHeight `
            -VideoWidth $dim.Width `
            -VideoHeight $dim.Height

        $process = Start-MpvPaused `
            -MpvExe $MpvExe `
            -FilePath $FilePath `
            -StartSeconds $startSecondsForMpv `
            -Config $Config

        $hwnd = Wait-ForMainWindowHandle `
            -ProcessId $process.Id `
            -TimeoutMs 10000

        # 等待一下窗口稳定
        Start-Sleep -Milliseconds 150

        # 重要：抑制 Ensure-WindowPosition 的输出，避免污染本函数返回值
        [void](Ensure-WindowPosition `
            -Handle $hwnd `
            -ExpectedX $rect.X `
            -ExpectedY $rect.Y `
            -ExpectedWidth $rect.Width `
            -ExpectedHeight $rect.Height)

        $result = [PSCustomObject]@{
            Index           = $Index + 1
            Row             = $rect.Row
            Column          = $rect.Column
            FilePath        = $FilePath
            FileName        = [System.IO.Path]::GetFileName($FilePath)
            Pid             = $process.Id
            DurationSeconds = [math]::Round($duration, 3)
            StartRatio      = [math]::Round($randomRatio, 5)
            StartSeconds    = [math]::Round($startSeconds, 3)
            VideoWidth      = [int]$dim.Width
            VideoHeight     = [int]$dim.Height
            WindowX         = $rect.X
            WindowY         = $rect.Y
            WindowWidth     = $rect.Width
            WindowHeight    = $rect.Height
            Process         = $process
        }

        return $result
    }
    catch {
        if ($process -and -not $process.HasExited) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {}
        }

        throw
    }
}

# -----------------------------
# 主流程
# -----------------------------

try {
    Write-Host "`n===== mpv 随机网格播放器 =====" -ForegroundColor Cyan

    $config = Load-Config -Path $ConfigPath
    $mpvExe = Find-MpvExe -Config $config
    $ffprobeExe = Find-FfprobeExe -Config $config

    if (-not $config.directories -or $config.directories.Count -eq 0) {
        throw "config.json 中必须设置 directories。"
    }

    $columns = [int]$config.grid.columns
    $rows = [int]$config.grid.rows

    if ($columns -le 0 -or $rows -le 0) {
        throw "grid.columns 和 grid.rows 必须大于 0。"
    }

    $requiredCount = $columns * $rows

    $defaultExts = @(
        ".mp4",
        ".mkv",
        ".avi",
        ".mpg",
        ".mpeg",
        ".mov",
        ".wmv",
        ".flv",
        ".webm",
        ".m4v",
        ".ts",
        ".m2ts"
    )

    $extensions = if ($config.videoExtensions -and $config.videoExtensions.Count -gt 0) {
        $config.videoExtensions
    } else {
        $defaultExts
    }

    $allowedExtensions = Normalize-Extensions -Extensions $extensions

    $randomStartMinRatio = if ($null -ne $config.randomStart.minRatio) {
        [double]$config.randomStart.minRatio
    } else {
        0.0
    }

    $randomStartMaxRatio = if ($null -ne $config.randomStart.maxRatio) {
        [double]$config.randomStart.maxRatio
    } else {
        0.8
    }

    if (
        $randomStartMinRatio -lt 0 -or
        $randomStartMaxRatio -gt 1 -or
        $randomStartMinRatio -gt $randomStartMaxRatio
    ) {
        throw "randomStart.minRatio / maxRatio 必须满足：0 <= minRatio <= maxRatio <= 1。"
    }

    $minDurationSeconds = if ($null -ne $config.minDurationSeconds) {
        [double]$config.minDurationSeconds
    } else {
        10.0
    }

    $screen = Get-PrimaryPhysicalScreenSize

    Write-Host "`nmpv 路径：$mpvExe"
    Write-Host "ffprobe 路径：$ffprobeExe"
    Write-Host "屏幕尺寸：$($screen.Width) x $($screen.Height)"
    Write-Host "网格布局：$columns x $rows，共需 $requiredCount 个视频窗口"
    Write-Host "随机起始比例：$randomStartMinRatio ~ $randomStartMaxRatio"
    Write-Host "最小时长：$minDurationSeconds 秒"

    Write-Host "`n正在扫描视频文件..." -ForegroundColor Cyan

    $allFiles = Get-VideoFilesFromDirectories `
        -Directories $config.directories `
        -AllowedExtensions $allowedExtensions

    if ($allFiles.Count -lt $requiredCount) {
        throw "视频文件数量不足。找到 $($allFiles.Count) 个，需要 $requiredCount 个。"
    }

    Write-Host "找到候选视频文件：$($allFiles.Count) 个`n"

    $shuffled = @(Shuffle-Array -Items $allFiles)

    $opened = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $used = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    $candidateIndex = 0

    while ($opened.Count -lt $requiredCount -and $candidateIndex -lt $shuffled.Count) {
        $file = [string]$shuffled[$candidateIndex]
        $candidateIndex++

        if (-not $used.Add($file)) {
            continue
        }

        $slotIndex = $opened.Count

        Write-Host (
            "[{0}/{1}] 正在打开：{2}" -f
            ($slotIndex + 1),
            $requiredCount,
            $file
        ) -ForegroundColor Yellow

        try {
            $info = Open-And-PrepareVideo `
                -MpvExe $mpvExe `
                -FfprobeExe $ffprobeExe `
                -FilePath $file `
                -Index $slotIndex `
                -Columns $columns `
                -Rows $rows `
                -ScreenWidth $screen.Width `
                -ScreenHeight $screen.Height `
                -RandomStartMinRatio $randomStartMinRatio `
                -RandomStartMaxRatio $randomStartMaxRatio `
                -MinDurationSeconds $minDurationSeconds `
                -Config $config

            # 防御检查：如果函数内部有未抑制输出，可能导致这里拿到数组。
            if ($info -is [array]) {
                throw "Open-And-PrepareVideo 返回了数组，疑似函数内部存在未抑制的输出。"
            }

            if (-not ($info.PSObject.Properties.Name -contains "Pid")) {
                throw "Open-And-PrepareVideo 返回对象缺少 Pid 属性。"
            }

            Write-Host (
                "    成功：PID={0}, 时长={1}s, 起点={2}s, 窗口={3}x{4}+{5}+{6}" -f
                $info.Pid,
                $info.DurationSeconds,
                $info.StartSeconds,
                $info.WindowWidth,
                $info.WindowHeight,
                $info.WindowX,
                $info.WindowY
            ) -ForegroundColor Green

            [void]$opened.Add($info)
        }
        catch {
            $reason = $_.Exception.Message

            [void]$failed.Add([PSCustomObject]@{
                FilePath = $file
                Reason   = $reason
            })

            Write-Warning "    跳过：$reason"
        }
    }

    if ($opened.Count -lt $requiredCount) {
        throw "有效视频数量不足。成功打开 $($opened.Count) 个，需要 $requiredCount 个。坏文件/过短文件/无法读取文件已跳过。"
    }

    Write-Host "`n===== 已开启视频列表 =====" -ForegroundColor Cyan

    $opened |
        Select-Object `
            Index,
            Row,
            Column,
            Pid,
            FileName,
            DurationSeconds,
            StartSeconds,
            StartRatio,
            VideoWidth,
            VideoHeight,
            WindowX,
            WindowY,
            WindowWidth,
            WindowHeight |
        Format-Table -AutoSize

    Write-Host "`n===== 完整路径 =====" -ForegroundColor Cyan

    foreach ($item in $opened) {
        Write-Host (
            "[{0}] 行{1} 列{2} | {3}" -f
            $item.Index,
            $item.Row,
            $item.Column,
            $item.FilePath
        )
    }

    if ($failed.Count -gt 0) {
        Write-Host "`n===== 已跳过文件 =====" -ForegroundColor DarkYellow
        $failed | Format-Table -AutoSize
    }

    Write-Host "`n所有窗口已打开并暂停。按任意键退出此控制台脚本；mpv 窗口会继续保留。" -ForegroundColor Green
    [void][System.Console]::ReadKey($true)
}
catch {
    Write-Host "`n发生错误：" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    Write-Host "`n按任意键退出..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)

    exit 1
}
