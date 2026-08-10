import csv
import json
import os
import random
import subprocess
import threading
import time
import tkinter as tk
from dataclasses import dataclass, asdict
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import win32api
import win32con
import win32gui
import win32process


APP_TITLE = "随机网格 MPV 播放器"
DEFAULT_CONFIG_NAME = "config.json"

DEFAULT_EXTENSIONS = [
    ".mp4", ".mkv", ".avi", ".mpg", ".mpeg",
    ".mov", ".wmv", ".flv", ".webm", ".m4v",
    ".ts", ".m2ts"
]


@dataclass
class VideoResult:
    index: int
    row: int
    column: int
    file_path: str
    file_name: str
    pid: int
    duration_seconds: float
    start_ratio: float
    start_seconds: float
    video_width: int
    video_height: int
    window_x: int
    window_y: int
    window_width: int
    window_height: int


class RandomGridMpvGUI:
    def __init__(self, root):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("1050x780")
        self.root.minsize(900, 650)

        self.stop_event = threading.Event()
        self.task_thread = None
        self.processes = []
        self.results = []
        self.failed_files = []

        self.config_path = Path(__file__).with_name(DEFAULT_CONFIG_NAME)

        self._create_variables()
        self._create_widgets()
        self._load_config_silently()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---------------------------------------------------------
    # GUI
    # ---------------------------------------------------------

    def _create_variables(self):
        self.mpv_path_var = tk.StringVar()
        self.ffprobe_path_var = tk.StringVar()
        self.directories_var = tk.StringVar()
        self.columns_var = tk.StringVar(value="7")
        self.rows_var = tk.StringVar(value="8")
        self.min_ratio_var = tk.StringVar(value="0.0")
        self.max_ratio_var = tk.StringVar(value="0.8")
        self.min_duration_var = tk.StringVar(value="10")
        self.extensions_var = tk.StringVar(value=",".join(DEFAULT_EXTENSIONS))
        self.mute_var = tk.BooleanVar(value=True)
        self.volume_var = tk.StringVar(value="50")
        self.extra_args_var = tk.StringVar()
        self.recursive_var = tk.BooleanVar(value=False)
        self.status_var = tk.StringVar(value="就绪")

    def _create_widgets(self):
        main = ttk.Frame(self.root, padding=10)
        main.pack(fill=tk.BOTH, expand=True)

        config_frame = ttk.LabelFrame(main, text="配置")
        config_frame.pack(fill=tk.X, pady=(0, 8))

        row = 0

        ttk.Label(config_frame, text="mpv 路径：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )
        ttk.Entry(config_frame, textvariable=self.mpv_path_var).grid(
            row=row, column=1, sticky=tk.EW, padx=5, pady=5
        )
        ttk.Button(
            config_frame,
            text="选择",
            command=lambda: self.choose_file(self.mpv_path_var)
        ).grid(row=row, column=2, padx=5, pady=5)

        row += 1

        ttk.Label(config_frame, text="ffprobe 路径：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )
        ttk.Entry(config_frame, textvariable=self.ffprobe_path_var).grid(
            row=row, column=1, sticky=tk.EW, padx=5, pady=5
        )
        ttk.Button(
            config_frame,
            text="选择",
            command=lambda: self.choose_file(self.ffprobe_path_var)
        ).grid(row=row, column=2, padx=5, pady=5)

        row += 1

        ttk.Label(config_frame, text="目录：").grid(
            row=row, column=0, sticky=tk.NW, padx=5, pady=5
        )

        directory_box = ttk.Frame(config_frame)
        directory_box.grid(row=row, column=1, columnspan=2, sticky=tk.EW)

        self.directory_list = tk.Listbox(
            directory_box,
            height=4,
            selectmode=tk.EXTENDED
        )
        self.directory_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        directory_scroll = ttk.Scrollbar(
            directory_box,
            orient=tk.VERTICAL,
            command=self.directory_list.yview
        )
        directory_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.directory_list.config(yscrollcommand=directory_scroll.set)

        directory_buttons = ttk.Frame(config_frame)
        directory_buttons.grid(row=row, column=3, sticky=tk.N, padx=5)

        ttk.Button(
            directory_buttons,
            text="添加目录",
            command=self.add_directory
        ).pack(fill=tk.X, pady=2)

        ttk.Button(
            directory_buttons,
            text="删除目录",
            command=self.remove_directory
        ).pack(fill=tk.X, pady=2)

        ttk.Checkbutton(
            directory_buttons,
            text="递归扫描",
            variable=self.recursive_var
        ).pack(anchor=tk.W, pady=5)

        row += 1

        grid_frame = ttk.LabelFrame(config_frame, text="网格与随机起点")
        grid_frame.grid(
            row=row,
            column=0,
            columnspan=4,
            sticky=tk.EW,
            padx=5,
            pady=5
        )

        ttk.Label(grid_frame, text="列数：").grid(
            row=0, column=0, padx=5, pady=5, sticky=tk.W
        )
        ttk.Entry(
            grid_frame,
            width=8,
            textvariable=self.columns_var
        ).grid(row=0, column=1, padx=5, pady=5)

        ttk.Label(grid_frame, text="行数：").grid(
            row=0, column=2, padx=5, pady=5, sticky=tk.W
        )
        ttk.Entry(
            grid_frame,
            width=8,
            textvariable=self.rows_var
        ).grid(row=0, column=3, padx=5, pady=5)

        ttk.Label(grid_frame, text="最小比例：").grid(
            row=0, column=4, padx=5, pady=5, sticky=tk.W
        )
        ttk.Entry(
            grid_frame,
            width=8,
            textvariable=self.min_ratio_var
        ).grid(row=0, column=5, padx=5, pady=5)

        ttk.Label(grid_frame, text="最大比例：").grid(
            row=0, column=6, padx=5, pady=5, sticky=tk.W
        )
        ttk.Entry(
            grid_frame,
            width=8,
            textvariable=self.max_ratio_var
        ).grid(row=0, column=7, padx=5, pady=5)

        row += 1

        ttk.Label(config_frame, text="最小时长：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )
        ttk.Entry(
            config_frame,
            width=12,
            textvariable=self.min_duration_var
        ).grid(row=row, column=1, sticky=tk.W, padx=5, pady=5)

        ttk.Label(config_frame, text="秒").grid(
            row=row, column=2, sticky=tk.W, padx=5, pady=5
        )

        row += 1

        ttk.Label(config_frame, text="视频扩展名：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )
        ttk.Entry(
            config_frame,
            textvariable=self.extensions_var
        ).grid(row=row, column=1, columnspan=3, sticky=tk.EW, padx=5, pady=5)

        row += 1

        ttk.Label(config_frame, text="音频：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )

        audio_frame = ttk.Frame(config_frame)
        audio_frame.grid(row=row, column=1, columnspan=3, sticky=tk.W)

        ttk.Checkbutton(
            audio_frame,
            text="静音",
            variable=self.mute_var
        ).pack(side=tk.LEFT, padx=(0, 15))

        ttk.Label(audio_frame, text="音量：").pack(side=tk.LEFT)
        ttk.Entry(
            audio_frame,
            width=8,
            textvariable=self.volume_var
        ).pack(side=tk.LEFT, padx=5)

        row += 1

        ttk.Label(config_frame, text="额外 MPV 参数：").grid(
            row=row, column=0, sticky=tk.W, padx=5, pady=5
        )
        ttk.Entry(
            config_frame,
            textvariable=self.extra_args_var
        ).grid(row=row, column=1, columnspan=3, sticky=tk.EW, padx=5, pady=5)

        config_frame.columnconfigure(1, weight=1)

        # 操作区
        button_frame = ttk.Frame(main)
        button_frame.pack(fill=tk.X, pady=(0, 8))

        self.start_button = ttk.Button(
            button_frame,
            text="开始任务",
            command=self.start_task
        )
        self.start_button.pack(side=tk.LEFT, padx=(0, 6))

        self.stop_button = ttk.Button(
            button_frame,
            text="停止当前任务",
            command=self.stop_task,
            state=tk.DISABLED
        )
        self.stop_button.pack(side=tk.LEFT, padx=(0, 6))

        ttk.Button(
            button_frame,
            text="保存配置",
            command=self.save_config
        ).pack(side=tk.LEFT, padx=(0, 6))

        ttk.Button(
            button_frame,
            text="加载配置",
            command=self.load_config
        ).pack(side=tk.LEFT, padx=(0, 6))

        ttk.Button(
            button_frame,
            text="导出本次结果",
            command=self.export_results
        ).pack(side=tk.LEFT, padx=(0, 6))

        ttk.Label(
            button_frame,
            textvariable=self.status_var
        ).pack(side=tk.RIGHT)

        # 日志区
        log_frame = ttk.LabelFrame(main, text="运行日志")
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(
            log_frame,
            wrap=tk.NONE,
            state=tk.DISABLED
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        log_scroll_y = ttk.Scrollbar(
            log_frame,
            orient=tk.VERTICAL,
            command=self.log_text.yview
        )
        log_scroll_y.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.config(yscrollcommand=log_scroll_y.set)

    def choose_file(self, variable):
        path = filedialog.askopenfilename(
            title="选择程序文件",
            filetypes=[
                ("可执行文件", "*.exe"),
                ("所有文件", "*.*")
            ]
        )
        if path:
            variable.set(path)

    def add_directory(self):
        path = filedialog.askdirectory(title="选择视频目录")
        if path:
            current = list(self.directory_list.get(0, tk.END))
            if path not in current:
                self.directory_list.insert(tk.END, path)

    def remove_directory(self):
        selected = list(self.directory_list.curselection())
        for index in reversed(selected):
            self.directory_list.delete(index)

    def log(self, text):
        def update():
            self.log_text.config(state=tk.NORMAL)
            self.log_text.insert(tk.END, text + "\n")
            self.log_text.see(tk.END)
            self.log_text.config(state=tk.DISABLED)

        self.root.after(0, update)

    # ---------------------------------------------------------
    # 配置读写
    # ---------------------------------------------------------

    def _load_config_silently(self):
        if self.config_path.exists():
            try:
                self._apply_config(self.config_path)
            except Exception:
                pass

    def _get_config_from_gui(self):
        columns = int(self.columns_var.get())
        rows = int(self.rows_var.get())
        min_ratio = float(self.min_ratio_var.get())
        max_ratio = float(self.max_ratio_var.get())
        min_duration = float(self.min_duration_var.get())
        volume = int(self.volume_var.get())

        if columns <= 0 or rows <= 0:
            raise ValueError("网格行数和列数必须大于 0。")

        if not 0 <= min_ratio <= max_ratio <= 1:
            raise ValueError("随机起始比例必须满足 0 <= 最小比例 <= 最大比例 <= 1。")

        if min_duration < 0:
            raise ValueError("最小时长不能小于 0。")

        if not 0 <= volume <= 100:
            raise ValueError("音量必须在 0 到 100 之间。")

        directories = list(self.directory_list.get(0, tk.END))
        extensions = [
            x.strip().lower()
            for x in self.extensions_var.get().split(",")
            if x.strip()
        ]

        normalized_extensions = []
        for ext in extensions:
            if not ext.startswith("."):
                ext = "." + ext
            if ext not in normalized_extensions:
                normalized_extensions.append(ext)

        extra_args = [
            x.strip()
            for x in self.extra_args_var.get().split()
            if x.strip()
        ]

        return {
            "mpvPath": self.mpv_path_var.get().strip(),
            "ffprobePath": self.ffprobe_path_var.get().strip(),
            "directories": directories,
            "recursive": self.recursive_var.get(),
            "grid": {
                "columns": columns,
                "rows": rows
            },
            "randomStart": {
                "minRatio": min_ratio,
                "maxRatio": max_ratio
            },
            "minDurationSeconds": min_duration,
            "videoExtensions": normalized_extensions,
            "mute": self.mute_var.get(),
            "volume": volume,
            "extraMpvArgs": extra_args
        }

    def _apply_config(self, path):
        with path.open("r", encoding="utf-8") as f:
            config = json.load(f)

        self.mpv_path_var.set(config.get("mpvPath", ""))
        self.ffprobe_path_var.set(config.get("ffprobePath", ""))

        self.directory_list.delete(0, tk.END)
        for directory in config.get("directories", []):
            self.directory_list.insert(tk.END, directory)

        grid = config.get("grid", {})
        random_start = config.get("randomStart", {})

        self.columns_var.set(str(grid.get("columns", 7)))
        self.rows_var.set(str(grid.get("rows", 8)))
        self.min_ratio_var.set(str(random_start.get("minRatio", 0.0)))
        self.max_ratio_var.set(str(random_start.get("maxRatio", 0.8)))
        self.min_duration_var.set(str(config.get("minDurationSeconds", 10)))

        extensions = config.get("videoExtensions", DEFAULT_EXTENSIONS)
        self.extensions_var.set(",".join(extensions))

        self.mute_var.set(bool(config.get("mute", True)))
        self.volume_var.set(str(config.get("volume", 50)))

        extra_args = config.get("extraMpvArgs", [])
        self.extra_args_var.set(" ".join(extra_args))

        # 默认不递归
        self.recursive_var.set(bool(config.get("recursive", False)))

        self.log(f"已加载配置：{path}")

    def load_config(self):
        path = filedialog.askopenfilename(
            title="加载配置文件",
            filetypes=[
                ("JSON 配置文件", "*.json"),
                ("所有文件", "*.*")
            ]
        )
        if not path:
            return

        try:
            self.config_path = Path(path)
            self._apply_config(self.config_path)
        except Exception as e:
            messagebox.showerror("加载失败", str(e))

    def save_config(self):
        try:
            config = self._get_config_from_gui()

            path = filedialog.asksaveasfilename(
                title="保存配置文件",
                initialfile="config.json",
                defaultextension=".json",
                filetypes=[
                    ("JSON 配置文件", "*.json"),
                    ("所有文件", "*.*")
                ]
            )
            if not path:
                return

            with open(path, "w", encoding="utf-8") as f:
                json.dump(config, f, ensure_ascii=False, indent=2)

            self.config_path = Path(path)
            self.log(f"配置已保存：{path}")
            messagebox.showinfo("保存成功", "配置文件已保存。")

        except Exception as e:
            messagebox.showerror("保存失败", str(e))

    # ---------------------------------------------------------
    # 文件扫描与 ffprobe
    # ---------------------------------------------------------

    def scan_files(self, directories, extensions, recursive):
        result = []
        seen = set()

        for directory in directories:
            if self.stop_event.is_set():
                break

            directory = os.path.abspath(directory)

            if not os.path.isdir(directory):
                self.log(f"跳过不存在目录：{directory}")
                continue

            if recursive:
                iterator = (
                    os.path.join(root, filename)
                    for root, _, files in os.walk(directory)
                    for filename in files
                )
            else:
                iterator = (
                    os.path.join(directory, filename)
                    for filename in os.listdir(directory)
                    if os.path.isfile(os.path.join(directory, filename))
                )

            for file_path in iterator:
                if self.stop_event.is_set():
                    break

                suffix = Path(file_path).suffix.lower()
                normalized = os.path.normcase(os.path.abspath(file_path))

                if suffix in extensions and normalized not in seen:
                    seen.add(normalized)
                    result.append(os.path.abspath(file_path))

        return result

    def run_ffprobe(self, ffprobe_path, file_path):
        command = [
            ffprobe_path,
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries",
            "format=duration:stream=width,height",
            "-of", "json",
            "--",
            file_path
        ]

        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW
        )

        if completed.returncode != 0:
            raise RuntimeError(
                completed.stderr.strip() or
                f"ffprobe 退出码：{completed.returncode}"
            )

        data = json.loads(completed.stdout)

        streams = data.get("streams") or []
        if not streams:
            raise RuntimeError("未找到视频流。")

        stream = streams[0]
        width = int(stream.get("width") or 0)
        height = int(stream.get("height") or 0)

        duration = float(
            (data.get("format") or {}).get("duration") or 0
        )

        if width <= 0 or height <= 0:
            raise RuntimeError("无法读取视频宽高。")

        if duration <= 0:
            raise RuntimeError("无法读取视频时长。")

        return duration, width, height

    # ---------------------------------------------------------
    # Windows 窗口处理
    # ---------------------------------------------------------

    @staticmethod
    def get_primary_screen_size():
        # SM_CXSCREEN = 0，SM_CYSCREEN = 1
        width = win32api.GetSystemMetrics(0)
        height = win32api.GetSystemMetrics(1)
        return width, height

    @staticmethod
    def find_main_window(pid, timeout=10):
        end_time = time.time() + timeout
        found = []

        def callback(hwnd, _):
            if not win32gui.IsWindowVisible(hwnd):
                return True

            try:
                _, window_pid = win32process.GetWindowThreadProcessId(hwnd)
            except Exception:
                return True

            if window_pid == pid:
                title = win32gui.GetWindowText(hwnd)
                if title or win32gui.GetClassName(hwnd):
                    found.append(hwnd)

            return True

        while time.time() < end_time:
            found.clear()
            win32gui.EnumWindows(callback, None)

            if found:
                return found[0]

            time.sleep(0.1)

        raise RuntimeError(f"等待 mpv 窗口超时，PID={pid}")

    @staticmethod
    def calculate_window(
        index,
        columns,
        rows,
        screen_width,
        screen_height,
        video_width,
        video_height
    ):
        col = index % columns
        row = index // columns

        cell_width = screen_width / columns
        cell_height = screen_height / rows

        scale = min(
            cell_width / video_width,
            cell_height / video_height
        )

        window_width = max(1, int(video_width * scale))
        window_height = max(1, int(video_height * scale))

        cell_x = int(round(col * cell_width))
        cell_y = int(round(row * cell_height))

        x = int(round(
            cell_x + (cell_width - window_width) / 2
        ))
        y = int(round(
            cell_y + (cell_height - window_height) / 2
        ))

        return {
            "row": row + 1,
            "column": col + 1,
            "x": x,
            "y": y,
            "width": window_width,
            "height": window_height
        }

    @staticmethod
    def move_window(hwnd, x, y, width, height):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
        win32gui.SetWindowPos(
            hwnd,
            win32con.HWND_TOP,
            x,
            y,
            width,
            height,
            win32con.SWP_SHOWWINDOW
        )

    # ---------------------------------------------------------
    # MPV 启动和任务
    # ---------------------------------------------------------

    def start_mpv(
        self,
        mpv_path,
        file_path,
        start_seconds,
        config
    ):
        args = [
            mpv_path,
            "--pause=yes",
            f"--start={start_seconds:.3f}",
            "--force-window=yes",
            "--idle=no",
            "--keep-open=yes",
            "--border=no",
            "--keepaspect=yes",
            "--no-terminal",
            "--input-default-bindings=yes",
            "--input-vo-keyboard=yes"
        ]

        if config["mute"]:
            args.append("--mute=yes")

        args.append(f"--volume={config['volume']}")

        args.extend(config["extraMpvArgs"])
        args.extend(["--", file_path])

        process = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW
        )

        self.processes.append(process)
        return process

    def validate_program(self, path, name):
        if not path:
            raise ValueError(f"未设置 {name} 路径。")

        if not os.path.isfile(path):
            raise FileNotFoundError(f"{name} 不存在：{path}")

    def start_task(self):
        if self.task_thread and self.task_thread.is_alive():
            messagebox.showwarning("任务进行中", "当前已有任务正在运行。")
            return

        try:
            config = self._get_config_from_gui()

            self.validate_program(config["mpvPath"], "mpv")
            self.validate_program(config["ffprobePath"], "ffprobe")

            if not config["directories"]:
                raise ValueError("至少需要配置一个视频目录。")

            self.stop_event.clear()
            self.results.clear()
            self.failed_files.clear()
            self.processes.clear()

            self.start_button.config(state=tk.DISABLED)
            self.stop_button.config(state=tk.NORMAL)
            self.status_var.set("任务运行中")

            self.log_text.config(state=tk.NORMAL)
            self.log_text.delete("1.0", tk.END)
            self.log_text.config(state=tk.DISABLED)

            self.task_thread = threading.Thread(
                target=self.task_worker,
                args=(config,),
                daemon=True
            )
            self.task_thread.start()

        except Exception as e:
            messagebox.showerror("参数错误", str(e))

    def task_worker(self, config):
        try:
            columns = config["grid"]["columns"]
            rows = config["grid"]["rows"]
            required_count = columns * rows

            min_ratio = config["randomStart"]["minRatio"]
            max_ratio = config["randomStart"]["maxRatio"]
            min_duration = config["minDurationSeconds"]

            extensions = set(config["videoExtensions"])
            screen_width, screen_height = self.get_primary_screen_size()

            self.log(
                f"主显示器：{screen_width} x {screen_height}"
            )
            self.log(
                f"网格：{columns} 列 x {rows} 行，共需要 "
                f"{required_count} 个窗口"
            )
            self.log(
                "目录扫描方式：" +
                ("递归" if config["recursive"] else "仅当前目录")
            )

            self.log("正在扫描视频文件……")

            files = self.scan_files(
                config["directories"],
                extensions,
                config["recursive"]
            )

            if self.stop_event.is_set():
                return

            self.log(f"找到候选视频：{len(files)} 个")

            if len(files) < required_count:
                raise RuntimeError(
                    f"候选视频不足：找到 {len(files)} 个，需要 "
                    f"{required_count} 个。"
                )

            random.shuffle(files)
            used = set()
            candidate_index = 0

            while (
                len(self.results) < required_count
                and candidate_index < len(files)
            ):
                if self.stop_event.is_set():
                    return

                file_path = files[candidate_index]
                candidate_index += 1

                file_key = os.path.normcase(os.path.abspath(file_path))
                if file_key in used:
                    continue

                used.add(file_key)
                slot_index = len(self.results)

                self.log(
                    f"[{slot_index + 1}/{required_count}] "
                    f"正在检查：{file_path}"
                )

                try:
                    duration, video_width, video_height = self.run_ffprobe(
                        config["ffprobePath"],
                        file_path
                    )

                    if duration < min_duration:
                        raise RuntimeError(
                            f"时长过短：{duration:.2f} 秒"
                        )

                    random_ratio = random.uniform(
                        min_ratio,
                        max_ratio
                    )

                    start_seconds = max(
                        0.0,
                        min(duration - 0.1, duration * random_ratio)
                    )

                    rect = self.calculate_window(
                        slot_index,
                        columns,
                        rows,
                        screen_width,
                        screen_height,
                        video_width,
                        video_height
                    )

                    process = self.start_mpv(
                        config["mpvPath"],
                        file_path,
                        start_seconds,
                        config
                    )

                    hwnd = self.find_main_window(process.pid)

                    time.sleep(0.15)

                    self.move_window(
                        hwnd,
                        rect["x"],
                        rect["y"],
                        rect["width"],
                        rect["height"]
                    )

                    item = VideoResult(
                        index=slot_index + 1,
                        row=rect["row"],
                        column=rect["column"],
                        file_path=file_path,
                        file_name=os.path.basename(file_path),
                        pid=process.pid,
                        duration_seconds=round(duration, 3),
                        start_ratio=round(random_ratio, 5),
                        start_seconds=round(start_seconds, 3),
                        video_width=video_width,
                        video_height=video_height,
                        window_x=rect["x"],
                        window_y=rect["y"],
                        window_width=rect["width"],
                        window_height=rect["height"]
                    )

                    self.results.append(item)

                    self.log(
                        f"成功：PID={process.pid}，"
                        f"起始={start_seconds:.2f}s，"
                        f"窗口={rect['width']}x{rect['height']} "
                        f"+{rect['x']}+{rect['y']}"
                    )

                except Exception as e:
                    self.failed_files.append({
                        "file_path": file_path,
                        "reason": str(e)
                    })
                    self.log(f"跳过：{e}")

            if self.stop_event.is_set():
                return

            if len(self.results) < required_count:
                raise RuntimeError(
                    f"有效视频不足：成功打开 {len(self.results)} 个，"
                    f"需要 {required_count} 个。"
                )

            self.log(
                f"任务完成，成功打开 {len(self.results)} 个视频。"
            )

            self.root.after(
                0,
                lambda: messagebox.showinfo(
                    "任务完成",
                    f"已成功打开 {len(self.results)} 个视频。\n"
                    f"可以点击“导出本次结果”保存 CSV。"
                )
            )

        except Exception as e:
            if not self.stop_event.is_set():
                self.log(f"发生错误：{e}")
                self.root.after(
                    0,
                    lambda message=str(e): messagebox.showerror(
                        "任务失败",
                        message
                    )
                )

        finally:
            self.root.after(0, self.task_finished)

    def task_finished(self):
        self.start_button.config(state=tk.NORMAL)
        self.stop_button.config(state=tk.DISABLED)

        if self.stop_event.is_set():
            self.status_var.set("任务已停止")
        else:
            self.status_var.set("就绪")

    def stop_task(self):
        if not self.task_thread or not self.task_thread.is_alive():
            return

        self.stop_event.set()
        self.status_var.set("正在停止……")
        self.log("正在停止当前任务并关闭本次启动的 mpv 窗口……")

        for process in list(self.processes):
            try:
                if process.poll() is None:
                    process.terminate()
            except Exception:
                pass

        self.stop_button.config(state=tk.DISABLED)

    # ---------------------------------------------------------
    # 结果导出
    # ---------------------------------------------------------

    def export_results(self):
        if not self.results:
            messagebox.showwarning(
                "没有结果",
                "当前没有可导出的随机打开结果。"
            )
            return

        path = filedialog.asksaveasfilename(
            title="导出本次随机打开结果",
            initialfile="random_mpv_results.csv",
            defaultextension=".csv",
            filetypes=[
                ("CSV 文件", "*.csv"),
                ("所有文件", "*.*")
            ]
        )

        if not path:
            return

        fieldnames = [
            "index",
            "row",
            "column",
            "file_path",
            "file_name",
            "pid",
            "duration_seconds",
            "start_ratio",
            "start_seconds",
            "video_width",
            "video_height",
            "window_x",
            "window_y",
            "window_width",
            "window_height"
        ]

        try:
            with open(
                path,
                "w",
                newline="",
                encoding="utf-8-sig"
            ) as f:
                writer = csv.DictWriter(
                    f,
                    fieldnames=fieldnames
                )
                writer.writeheader()

                for item in self.results:
                    writer.writerow(asdict(item))

            self.log(f"已导出结果：{path}")
            messagebox.showinfo("导出成功", "本次随机打开结果已导出。")

        except Exception as e:
            messagebox.showerror("导出失败", str(e))

    # ---------------------------------------------------------
    # 退出
    # ---------------------------------------------------------

    def on_close(self):
        if self.task_thread and self.task_thread.is_alive():
            self.stop_event.set()

        for process in list(self.processes):
            try:
                if process.poll() is None:
                    process.terminate()
            except Exception:
                pass

        self.root.destroy()


def main():
    root = tk.Tk()

    try:
        root.tk.call("tk", "scaling", 1.75)
    except Exception:
        pass

    app = RandomGridMpvGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()