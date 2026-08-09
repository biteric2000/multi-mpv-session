# -*- coding: utf-8 -*-
r"""
mpv_state_gui.py

功能：
    1. 扫描正在运行的 mpv IPC 管道：\\.\pipe\mpv_ipc_<PID>
    2. 保存 mpv 当前播放文件、播放进度、窗口位置、窗口大小、最大化状态
    3. 从 JSON 恢复多个 mpv 播放窗口
    4. tkinter GUI，四个按钮：
        - 保存最新状态
        - 另存为状态
        - 读取最新状态
        - 载入其他状态

依赖：
    pip install pywin32

说明：
    IPC 部分使用 pywin32 读写命名管道。
    窗口枚举 / 操作部分改用 ctypes 直接调用 user32.dll，
    避免 pywin32 的 EnumWindows 在新版 Python 下的兼容性问题。

注意：
    需要 mpv 已通过 auto_ipc.lua 自动创建管道：
        \\.\pipe\mpv_ipc_<PID>
"""

import os
import re
import sys
import json
import time
import glob
import queue
import ctypes
import shutil
import threading
import subprocess
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from datetime import datetime
from ctypes import wintypes

import win32con
import win32file
import win32pipe


# ─────────────────────────────────────────────────────────────
# DPI Awareness
# ─────────────────────────────────────────────────────────────

def enable_dpi_awareness():
    """
    尽量启用 Per-Monitor DPI Awareness，避免窗口坐标/大小被 Windows 虚拟化。
    """
    try:
        shcore = ctypes.windll.shcore
        # PROCESS_PER_MONITOR_DPI_AWARE = 2
        shcore.SetProcessDpiAwareness(2)
        return
    except Exception:
        pass

    try:
        user32 = ctypes.windll.user32
        user32.SetProcessDPIAware()
    except Exception:
        pass


enable_dpi_awareness()


# ─────────────────────────────────────────────────────────────
# ctypes: user32.dll 绑定
# ─────────────────────────────────────────────────────────────

user32 = ctypes.windll.user32

# 回调函数签名，必须用 WINFUNCTYPE（stdcall），CFUNCTYPE 在这里会导致行为异常
EnumWindowsProc = ctypes.WINFUNCTYPE(
    wintypes.BOOL,
    wintypes.HWND,
    wintypes.LPARAM
)

user32.EnumWindows.argtypes = [EnumWindowsProc, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL

user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL

user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD

user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.restype = ctypes.c_int

user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int

user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetWindowRect.restype = wintypes.BOOL

user32.IsZoomed.argtypes = [wintypes.HWND]
user32.IsZoomed.restype = wintypes.BOOL

user32.IsIconic.argtypes = [wintypes.HWND]
user32.IsIconic.restype = wintypes.BOOL

user32.SetWindowPos.argtypes = [
    wintypes.HWND, wintypes.HWND,
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wintypes.UINT
]
user32.SetWindowPos.restype = wintypes.BOOL

user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindow.restype = wintypes.BOOL

SW_RESTORE = 9
SW_MAXIMIZE = 3

SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040


def get_window_text(hwnd):
    length = user32.GetWindowTextLengthW(hwnd)
    if length <= 0:
        return ""

    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def get_window_pid(hwnd):
    pid = wintypes.DWORD(0)
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def enum_windows_for_pid(target_pid):
    """
    枚举所有可见顶层窗口，返回属于 target_pid 的候选 hwnd 列表。

    过滤条件（对齐原 PS1 逻辑）：
        1. 必须可见 (IsWindowVisible)
        2. 必须标题非空 (GetWindowTextLength > 0)
           —— 这一步至关重要：mpv 在 gpu/d3d11 渲染后端下会创建一个
              无标题的隐藏设备上下文窗口，用于初始化 ANGLE/D3D 渲染，
              该窗口常被刻意放置在屏幕外 (-32000, -32000)。
              如果不过滤标题，会误选中这个占位窗口，
              导致保存/恢复的坐标全是 -32000。
        3. 跳过当前处于最小化状态的窗口 (IsIconic)，
           避免真正被最小化的窗口返回同样的 -32000 占位矩形。
        4. PID 必须匹配
    """
    matched = []

    def callback(hwnd, lparam):
        try:
            if not user32.IsWindowVisible(hwnd):
                return True

            # 关键修复：标题必须非空，排除隐藏的渲染上下文占位窗口
            title_length = user32.GetWindowTextLengthW(hwnd)
            if title_length <= 0:
                return True

            # 跳过真正处于最小化状态的窗口，避免拿到 -32000 占位矩形
            if user32.IsIconic(hwnd):
                return True

            pid = get_window_pid(hwnd)
            if pid != target_pid:
                return True

            matched.append(hwnd)
        except Exception:
            pass

        return True

    cb = EnumWindowsProc(callback)
    user32.EnumWindows(cb, 0)

    return matched




def find_main_window_by_pid(pid, log_func=None):
    """
    根据 PID 找到对应的顶层窗口句柄。

    策略（对齐原 PS1 逻辑）：
        在同 PID 下所有"可见 + 标题非空 + 非最小化"的候选窗口中，
        取 EnumWindows 返回顺序（即 Z-order，从前到后）的第一个，
        并校验其矩形数据有效（宽高 > 0）。
    """
    candidates = enum_windows_for_pid(pid)

    if not candidates:
        if log_func:
            log_func(f"    诊断：PID {pid} 下未枚举到任何“可见+有标题+非最小化”的窗口。")
        return None

    for hwnd in candidates:
        rect = wintypes.RECT()
        if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            continue

        width = rect.right - rect.left
        height = rect.bottom - rect.top

        if width <= 0 or height <= 0:
            continue

        # 额外保险：即使标题非空、非 IsIconic，
        # 如果矩形数值仍然落在经典的“最小化占位坐标”附近，也跳过
        if rect.left <= -30000 and rect.top <= -30000:
            if log_func:
                title = get_window_text(hwnd)
                log_func(f"    诊断：跳过疑似占位窗口（标题=\"{title}\"，坐标={rect.left},{rect.top}）")
            continue

        return hwnd

    if log_func:
        log_func(f"    诊断：PID {pid} 找到 {len(candidates)} 个候选窗口，但均矩形异常或疑似占位窗口。")

    return None
def get_window_info_by_pid(pid, log_func=None):
    """
    获取窗口位置、大小、最大化状态。
    返回 None 或 dict。
    """
    hwnd = find_main_window_by_pid(pid, log_func)
    if not hwnd:
        return None

    rect = wintypes.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None

    width = rect.right - rect.left
    height = rect.bottom - rect.top

    if width <= 0 or height <= 0:
        return None

    return {
        "hwnd": hwnd,
        "x": int(rect.left),
        "y": int(rect.top),
        "width": int(width),
        "height": int(height),
        "is_maximized": bool(user32.IsZoomed(hwnd))
    }


def restore_window(hwnd):
    try:
        user32.ShowWindow(hwnd, SW_RESTORE)
    except Exception:
        pass


def maximize_window(hwnd):
    try:
        user32.ShowWindow(hwnd, SW_MAXIMIZE)
    except Exception:
        pass


def move_window_exact(hwnd, x, y, width, height):
    """
    使用 SetWindowPos 精确移动/缩放外层窗口。
    """
    flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW

    try:
        ok = user32.SetWindowPos(
            hwnd, None,
            int(x), int(y), int(width), int(height),
            flags
        )
        return bool(ok)
    except Exception:
        return False


def wait_for_main_window(pid, timeout_seconds=10.0):
    """
    等待指定 PID 的主窗口出现。
    """
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        hwnd = find_main_window_by_pid(pid)
        if hwnd:
            return hwnd
        time.sleep(0.1)

    return None


# ─────────────────────────────────────────────────────────────
# 基础路径
# ─────────────────────────────────────────────────────────────

def get_app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


APP_DIR = get_app_dir()


# ─────────────────────────────────────────────────────────────
# mpv IPC（pywin32 部分，已验证工作正常）
# ─────────────────────────────────────────────────────────────

def list_mpv_ipc_pipes():
    """
    扫描 \\.\pipe\ 下所有 mpv_ipc_<PID> 管道。
    """
    result = []

    try:
        paths = glob.glob(r"\\.\pipe\mpv_ipc_*")
    except Exception:
        paths = []

    for path in paths:
        name = os.path.basename(path)
        m = re.match(r"^mpv_ipc_(\d+)$", name)
        if not m:
            continue

        try:
            pid = int(m.group(1))
        except Exception:
            continue

        result.append({
            "pid": pid,
            "pipe_path": path
        })

    result.sort(key=lambda x: x["pid"])
    return result


def invoke_mpv_ipc(pipe_path, request_obj, timeout_ms=1500):
    """
    向 mpv IPC 命名管道发送一条 JSON 命令，读取一行响应。
    """
    request_line = json.dumps(request_obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    data = request_line.encode("utf-8")

    handle = None

    try:
        start = time.time()

        while True:
            try:
                handle = win32file.CreateFile(
                    pipe_path,
                    win32con.GENERIC_READ | win32con.GENERIC_WRITE,
                    0,
                    None,
                    win32con.OPEN_EXISTING,
                    0,
                    None
                )
                break
            except Exception:
                if (time.time() - start) * 1000 >= timeout_ms:
                    raise
                time.sleep(0.03)

        try:
            win32pipe.SetNamedPipeHandleState(
                handle,
                win32pipe.PIPE_READMODE_BYTE,
                None,
                None
            )
        except Exception:
            pass

        win32file.WriteFile(handle, data)

        deadline = time.time() + timeout_ms / 1000.0
        chunks = []

        while time.time() < deadline:
            try:
                hr, chunk = win32file.ReadFile(handle, 4096)
                if chunk:
                    chunks.append(chunk)
                    if b"\n" in chunk:
                        break
            except Exception:
                time.sleep(0.03)

        if not chunks:
            return None

        raw = b"".join(chunks)
        first_line = raw.split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
        if not first_line:
            return None

        return json.loads(first_line)

    finally:
        if handle is not None:
            try:
                win32file.CloseHandle(handle)
            except Exception:
                pass


def get_mpv_property(pipe_path, prop_name, request_id):
    req = {
        "command": ["get_property", prop_name],
        "request_id": request_id
    }

    try:
        resp = invoke_mpv_ipc(pipe_path, req)
    except Exception:
        return None

    if not isinstance(resp, dict):
        return None

    if resp.get("error") == "success":
        return resp.get("data")

    return None


# ─────────────────────────────────────────────────────────────
# mpv 可执行文件定位
# ─────────────────────────────────────────────────────────────

def find_mpv_executable():
    candidates = []

    candidates.append(os.path.join(APP_DIR, "mpv.exe"))

    path_found = shutil.which("mpv.exe") or shutil.which("mpv")
    if path_found:
        candidates.append(path_found)

    envs = [
        os.environ.get("ProgramFiles"),
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("LOCALAPPDATA")
    ]

    for base in envs:
        if base:
            candidates.append(os.path.join(base, "mpv", "mpv.exe"))

    for path in candidates:
        if path and os.path.isfile(path):
            return path

    return None


# ─────────────────────────────────────────────────────────────
# 保存状态
# ─────────────────────────────────────────────────────────────

def collect_mpv_states(log_func):
    log_func("[1/3] 扫描 mpv IPC 管道...")

    pipes = list_mpv_ipc_pipes()

    if not pipes:
        log_func("未发现任何 mpv IPC 管道。", "warn")
        return []

    log_func(f"发现 {len(pipes)} 个 mpv IPC 管道。", "ok")

    log_func("[2/3] 查询播放状态和窗口信息...")

    states = []
    request_id = 1

    for item in pipes:
        pid = item["pid"]
        pipe_path = item["pipe_path"]

        log_func(f"处理 PID {pid} ...")

        file_path = get_mpv_property(pipe_path, "path", request_id)
        request_id += 1

        time_pos = get_mpv_property(pipe_path, "time-pos", request_id)
        request_id += 1

        if not file_path:
            log_func(f"跳过 PID {pid}：无法获取文件路径。", "warn")
            continue

        win_info = get_window_info_by_pid(pid, log_func)
        if not win_info:
            log_func(f"跳过 PID {pid}：找不到对应窗口或窗口尺寸异常。", "warn")
            continue

        try:
            time_pos_value = float(time_pos) if time_pos is not None else 0.0
        except Exception:
            time_pos_value = 0.0

        entry = {
            "pid": int(pid),
            "file_path": str(file_path),
            "time_pos": float(time_pos_value),
            "window_x": int(win_info["x"]),
            "window_y": int(win_info["y"]),
            "window_width": int(win_info["width"]),
            "window_height": int(win_info["height"]),
            "is_maximized": bool(win_info["is_maximized"])
        }

        states.append(entry)

        log_func(
            f"OK：{file_path}\n"
            f"    进度 {round(time_pos_value, 3)}s  "
            f"窗口 {entry['window_width']}x{entry['window_height']}+{entry['window_x']}+{entry['window_y']}  "
            f"最大化={entry['is_maximized']}",
            "ok"
        )

    return states


def save_states_to_file(states, output_file):
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(states, f, ensure_ascii=False, indent=4)


def make_latest_state_filename():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return os.path.join(APP_DIR, f"mpv_state_{timestamp}.json")


# ─────────────────────────────────────────────────────────────
# 恢复状态
# ─────────────────────────────────────────────────────────────

def find_latest_state_file():
    files = glob.glob(os.path.join(APP_DIR, "mpv_state_*.json"))
    if not files:
        return None

    files.sort(key=lambda p: os.path.basename(p), reverse=True)
    return files[0]


def load_state_file(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        data = json.load(f)

    if isinstance(data, dict):
        data = [data]

    if not isinstance(data, list):
        raise ValueError("JSON 根对象必须是数组或单个对象。")

    return data


def format_time_pos(seconds):
    try:
        value = float(seconds)
    except Exception:
        value = 0.0

    if value < 0:
        value = 0.0

    return f"{value:.3f}".rstrip("0").rstrip(".")


def normalize_bool(value):
    if isinstance(value, bool):
        return value

    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes", "y")

    return bool(value)


def restore_states_from_file(json_file, log_func):
    log_func(f"[1/4] 读取状态文件：{json_file}")

    try:
        state_list = load_state_file(json_file)
    except Exception as e:
        log_func(f"JSON 文件解析失败：{e}", "error")
        return

    if not state_list:
        log_func("JSON 中没有任何记录。", "warn")
        return

    log_func(f"共读取到 {len(state_list)} 条记录。", "ok")

    log_func("[2/4] 定位 mpv.exe ...")

    mpv_path = find_mpv_executable()

    if not mpv_path:
        log_func("找不到 mpv.exe。", "error")
        log_func("请将 mpv.exe 加入 PATH，或放到本程序同目录。", "error")
        return

    log_func(f"mpv 路径：{mpv_path}", "ok")

    log_func("[3/4] 开始逐条恢复...")

    success_count = 0
    skip_items = []

    total = len(state_list)

    for index, entry in enumerate(state_list, start=1):
        file_path = str(entry.get("file_path", "") or "")
        display_name = file_path if file_path else f"(路径为空 - 第 {index} 条)"

        log_func(f"[{index}/{total}] {display_name}")

        if not file_path:
            reason = "文件路径为空"
            log_func(f"跳过：{reason}", "warn")
            skip_items.append((display_name, reason))
            continue

        if not os.path.isfile(file_path):
            reason = "文件不存在"
            log_func(f"跳过：{reason}", "warn")
            skip_items.append((file_path, reason))
            continue

        try:
            time_pos = format_time_pos(entry.get("time_pos", 0.0))
            x = int(round(float(entry.get("window_x"))))
            y = int(round(float(entry.get("window_y"))))
            width = int(round(float(entry.get("window_width"))))
            height = int(round(float(entry.get("window_height"))))
            is_maximized = normalize_bool(entry.get("is_maximized", False))
        except Exception:
            reason = "窗口数据异常"
            log_func(f"跳过：{reason}", "warn")
            skip_items.append((file_path, reason))
            continue

        if width <= 0 or height <= 0:
            reason = "窗口尺寸异常"
            log_func(f"跳过：{reason}", "warn")
            skip_items.append((file_path, reason))
            continue

        args = [
            mpv_path,
            f"--start={time_pos}",
            "--pause=yes",
            "--force-window=yes",
            "--no-terminal",
            "--",
            file_path
        ]

        try:
            proc = subprocess.Popen(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP
            )
        except Exception as e:
            reason = f"启动失败：{e}"
            log_func(reason, "error")
            skip_items.append((file_path, reason))
            continue

        hwnd = wait_for_main_window(proc.pid, timeout_seconds=10.0)

        if not hwnd:
            reason = "已启动 mpv，但未找到窗口句柄"
            log_func(reason, "warn")
            skip_items.append((file_path, reason))
            continue

        restore_window(hwnd)
        time.sleep(0.05)

        ok1 = move_window_exact(hwnd, x, y, width, height)
        time.sleep(0.10)

        ok2 = move_window_exact(hwnd, x, y, width, height)

        if is_maximized:
            time.sleep(0.05)
            maximize_window(hwnd)

        if ok1 or ok2:
            success_count += 1
            log_func(
                f"✓ 已启动  进度={time_pos}s  "
                f"窗口={width}x{height}+{x}+{y}  最大化={is_maximized}",
                "ok"
            )
        else:
            reason = "SetWindowPos 失败"
            log_func(reason, "warn")
            skip_items.append((file_path, reason))

        time.sleep(0.08)

    log_func("[4/4] 恢复完成。", "ok")
    log_func(f"成功：{success_count}  跳过：{len(skip_items)}  共计：{total}", "ok")

    if skip_items:
        log_func("")
        log_func("以下文件被跳过：", "warn")
        for i, (path, reason) in enumerate(skip_items, start=1):
            log_func(f"[{i}] {path}", "warn")
            log_func(f"    原因：{reason}", "warn")


# ─────────────────────────────────────────────────────────────
# GUI
# ─────────────────────────────────────────────────────────────

class MpvStateGui(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title("mpv 播放状态保存 / 恢复工具")
        self.geometry("980x640")
        self.minsize(820, 520)

        self.log_queue = queue.Queue()
        self.worker_running = False

        self._build_ui()
        self._poll_log_queue()

    def _build_ui(self):
        main = ttk.Frame(self, padding=10)
        main.pack(fill=tk.BOTH, expand=True)

        title = ttk.Label(
            main,
            text="mpv 播放状态保存 / 恢复工具",
            font=("Microsoft YaHei UI", 16, "bold")
        )
        title.pack(anchor=tk.W)

        desc = ttk.Label(
            main,
            text=(
                r"依赖 auto_ipc.lua 创建的 IPC 管道：\\.\pipe\mpv_ipc_<PID>。"
                "本程序只负责保存与恢复，不管理 auto_ipc.lua。"
            ),
            foreground="#555555"
        )
        desc.pack(anchor=tk.W, pady=(4, 10))

        button_frame = ttk.Frame(main)
        button_frame.pack(fill=tk.X, pady=(0, 10))

        self.btn_save_latest = ttk.Button(
            button_frame,
            text="保存最新状态",
            command=self.on_save_latest
        )
        self.btn_save_latest.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_save_as = ttk.Button(
            button_frame,
            text="另存为状态",
            command=self.on_save_as
        )
        self.btn_save_as.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_restore_latest = ttk.Button(
            button_frame,
            text="读取最新状态",
            command=self.on_restore_latest
        )
        self.btn_restore_latest.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_restore_other = ttk.Button(
            button_frame,
            text="载入其他状态",
            command=self.on_restore_other
        )
        self.btn_restore_other.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_clear_log = ttk.Button(
            button_frame,
            text="清空日志",
            command=self.clear_log
        )
        self.btn_clear_log.pack(side=tk.RIGHT)

        info_frame = ttk.LabelFrame(main, text="状态")
        info_frame.pack(fill=tk.X, pady=(0, 10))

        self.status_var = tk.StringVar(value=f"程序目录：{APP_DIR}")
        status_label = ttk.Label(info_frame, textvariable=self.status_var)
        status_label.pack(anchor=tk.W, padx=8, pady=6)

        log_frame = ttk.LabelFrame(main, text="日志")
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(
            log_frame,
            wrap=tk.WORD,
            height=20,
            font=("Consolas", 10)
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.configure(yscrollcommand=scroll.set)

        self.log_text.tag_configure("normal", foreground="#222222")
        self.log_text.tag_configure("ok", foreground="#008000")
        self.log_text.tag_configure("warn", foreground="#b08000")
        self.log_text.tag_configure("error", foreground="#cc0000")

        self.log("就绪。")
        self.log("提示：如扫描不到 mpv，请确认 mpv 已运行，并且 auto_ipc.lua 已放入 %APPDATA%\\mpv\\scripts\\。")

    def set_buttons_enabled(self, enabled):
        state = tk.NORMAL if enabled else tk.DISABLED
        for btn in [
            self.btn_save_latest,
            self.btn_save_as,
            self.btn_restore_latest,
            self.btn_restore_other,
            self.btn_clear_log
        ]:
            btn.configure(state=state)

    def log(self, text="", level="normal"):
        self.log_queue.put((text, level))

    def _poll_log_queue(self):
        try:
            while True:
                text, level = self.log_queue.get_nowait()
                self._append_log(text, level)
        except queue.Empty:
            pass

        self.after(80, self._poll_log_queue)

    def _append_log(self, text, level="normal"):
        if level not in ("normal", "ok", "warn", "error"):
            level = "normal"

        self.log_text.insert(tk.END, str(text) + "\n", level)
        self.log_text.see(tk.END)

    def clear_log(self):
        self.log_text.delete("1.0", tk.END)

    def run_worker(self, title, func):
        if self.worker_running:
            messagebox.showwarning("正在执行", "当前已有任务正在执行，请等待完成。")
            return

        self.worker_running = True
        self.set_buttons_enabled(False)
        self.status_var.set(title)
        self.log("")
        self.log("────────────────────────────────────────")
        self.log(title)
        self.log("────────────────────────────────────────")

        def wrapper():
            try:
                func()
            except Exception as e:
                self.log(f"任务异常：{e}", "error")
            finally:
                self.worker_running = False
                self.after(0, lambda: self.set_buttons_enabled(True))
                self.after(0, lambda: self.status_var.set(f"就绪。程序目录：{APP_DIR}"))

        t = threading.Thread(target=wrapper, daemon=True)
        t.start()

    def on_save_latest(self):
        def task():
            output_file = make_latest_state_filename()
            self._save_to_file(output_file)

        self.run_worker("保存最新状态", task)

    def on_save_as(self):
        default_name = f"mpv_state_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"

        output_file = filedialog.asksaveasfilename(
            title="另存为状态",
            initialdir=APP_DIR,
            initialfile=default_name,
            defaultextension=".json",
            filetypes=[
                ("JSON 文件", "*.json"),
                ("所有文件", "*.*")
            ]
        )

        if not output_file:
            return

        def task():
            self._save_to_file(output_file)

        self.run_worker(f"另存为状态：{output_file}", task)

    def _save_to_file(self, output_file):
        states = collect_mpv_states(self.log)

        if not states:
            self.log("没有成功采集到任何 mpv 状态，文件未保存。", "error")
            return

        self.log("[3/3] 写入 JSON 文件...")

        try:
            save_states_to_file(states, output_file)
        except Exception as e:
            self.log(f"保存失败：{e}", "error")
            return

        self.log("保存完成！", "ok")
        self.log(f"文件：{output_file}", "ok")
        self.log(f"共保存 {len(states)} 个 mpv 窗口状态。", "ok")

    def on_restore_latest(self):
        latest = find_latest_state_file()

        if not latest:
            messagebox.showwarning(
                "未找到状态文件",
                "程序目录下未找到任何 mpv_state_*.json 文件。"
            )
            return

        def task():
            restore_states_from_file(latest, self.log)

        self.run_worker(f"读取最新状态：{latest}", task)

    def on_restore_other(self):
        json_file = filedialog.askopenfilename(
            title="载入其他状态",
            initialdir=APP_DIR,
            filetypes=[
                ("JSON 文件", "*.json"),
                ("所有文件", "*.*")
            ]
        )

        if not json_file:
            return

        def task():
            restore_states_from_file(json_file, self.log)

        self.run_worker(f"载入其他状态：{json_file}", task)


def main():
    app = MpvStateGui()
    app.mainloop()


if __name__ == "__main__":
    main()