import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import yt_dlp
import sys
import threading
import queue
import os
import subprocess
import urllib.request
from urllib.parse import urlparse, parse_qs, urlunparse
import webbrowser
from pathlib import Path

from ytdp import (
    DownloadArtifactTracker,
    DownloadRequest,
    ToolchainError,
    format_bytes,
    reserve_output_stem,
)
from ytdp.downloader import (
    make_analysis_options as build_analysis_options,
    make_download_options as build_download_options,
)
from ytdp.localization import (
    LANG_DATA as SHARED_LANG_DATA,
    clean_download_error as map_download_error,
)
from ytdp.settings import load_settings, save_settings, valid_output_directory
from ytdp.updater import (
    is_newer_version as compare_versions,
    make_update_ssl_context as build_update_ssl_context,
    parse_update_manifest as parse_manifest,
)

VERSION = "1.8.7"
APP_NAME = "YT Downloader Pro"
DEFAULT_UPDATE_MANIFEST_URL = "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/contents/version.txt?ref=main"
DEFAULT_UPDATE_DOWNLOAD_URL = "https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest"
PUBLIC_UPDATE_MANIFEST_URL = os.environ.get("YTDP_UPDATE_MANIFEST_URL", DEFAULT_UPDATE_MANIFEST_URL).strip()
UPDATE_DOWNLOAD_URL = os.environ.get("YTDP_UPDATE_DOWNLOAD_URL", DEFAULT_UPDATE_DOWNLOAD_URL).strip()
COOKIES_BROWSER = os.environ.get("YTDP_COOKIES_BROWSER", "").strip()
DEFAULT_DOWNLOAD_PATH = os.path.join(os.path.expanduser("~"), "Downloads")


# Shared localization is used by both macOS and Windows entry points.
LANG_DATA = SHARED_LANG_DATA

class YTDownloaderApp:
    """Shared Tkinter application driven by a platform adapter."""

    def __init__(self, root, platform_adapter):
        self.root = root
        self.platform = platform_adapter
        self.lang = self.platform.language()
        self.text = LANG_DATA[self.lang]
        
        # 狀態控制變數
        self.is_paused = False
        self.is_cancelled = False
        self.download_phase = "idle"
        self.pause_event = threading.Event()
        self.pause_event.set()
        
        self.root.title(f"{self.text['title']} v{VERSION}")
        self.root.geometry("600x720")
        self.settings_path = self.get_settings_path()
        self.settings = self.load_settings()
        self.download_path = self.get_saved_download_path()
        self.video_format_list = []
        self.audio_format_list = []
        self.current_video_title = ""
        self.analyzed_url = ""
        self.pending_analysis_url = ""
        self.analysis_request_id = 0
        self.current_artifacts = None
        self.browser_cookies = (COOKIES_BROWSER,) if COOKIES_BROWSER else None
        self.toolchain_error = None
        self.ui_queue = queue.Queue()

        # 選單列
        menubar = tk.Menu(root)
        help_menu = tk.Menu(menubar, tearoff=0)
        help_menu.add_command(label=self.text['update_check'], command=lambda: self.check_update(silent=False))
        help_menu.add_separator()
        help_menu.add_command(label=self.text['about'], command=self.show_about)
        menubar.add_cascade(label="Menu", menu=help_menu)
        root.config(menu=menubar)

        # UI 佈局
        tk.Label(root, text=self.text['title'], font=("Arial", 18, "bold")).pack(pady=10)
        self.lbl_video_title = tk.Label(root, text="", font=("Arial", 10, "bold"), wraplength=500, fg="black")
        self.lbl_video_title.pack(pady=5)
        
        url_frame = tk.Frame(root)
        url_frame.pack(pady=5, fill="x", padx=30)
        self.url_entry = tk.Entry(url_frame)
        self.url_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        self.url_entry.bind('<Return>', lambda e: self.start_analyze())
        self.url_entry.bind('<KeyRelease>', self.handle_url_change)
        self.root.bind_all('<<Paste>>', lambda e: self.force_paste())
        self.url_entry.bind('<Button-3>', self.show_context_menu)

        self.btn_analyze = tk.Button(url_frame, text=self.text['analyze'], command=self.start_analyze)
        self.btn_analyze.pack(side="right")

        tk.Label(root, text=self.text['quality']).pack(pady=(5, 0))
        self.combo_quality = ttk.Combobox(root, state="readonly", width=45)
        self.combo_quality.pack(pady=5)

        tk.Label(root, text=self.text['audio_track']).pack(pady=(5, 0))
        self.combo_audio = ttk.Combobox(root, state="readonly", width=45)
        self.combo_audio.pack(pady=5)

        self.audio_only_var = tk.BooleanVar()
        tk.Checkbutton(
            root,
            text=self.text['audio_only'],
            variable=self.audio_only_var,
            command=self.refresh_download_button,
        ).pack(pady=5)

        tk.Button(root, text=self.text['change_path'], command=self.change_path).pack(pady=5)
        self.lbl_path = tk.Label(root, text=f"{self.text['save_to']} {self.download_path}", fg="gray", wraplength=480)
        self.lbl_path.pack()

        # 進度與數據
        self.progress_bar = ttk.Progressbar(root, orient="horizontal", length=400, mode="determinate")
        self.progress_bar.pack(pady=15)
        self.lbl_percent = tk.Label(root, text="0%", font=("Arial", 12, "bold"))
        self.lbl_percent.pack()
        self.lbl_speed = tk.Label(root, text=f"{self.text['speed']} --", fg="#2196F3")
        self.lbl_speed.pack()
        self.lbl_size = tk.Label(root, text=f"{self.text['size']} -- / --", fg="#666")
        self.lbl_size.pack()

        # 控制區
        ctrl_frame = tk.Frame(root)
        ctrl_frame.pack(pady=15)
        self.btn_download = tk.Button(ctrl_frame, text=self.text['start_download'], command=self.start_download, bg="#4CAF50", height=2, width=15, state="disabled")
        self.btn_download.pack(side="left", padx=5)
        self.btn_pause = tk.Button(ctrl_frame, text=self.text['pause'], command=self.toggle_pause, state="disabled")
        self.btn_pause.pack(side="left", padx=5)
        self.btn_cancel = tk.Button(ctrl_frame, text=self.text['cancel'], command=self.cancel_download, state="disabled", fg="red")
        self.btn_cancel.pack(side="left", padx=5)

        self.check_update(silent=True)
        self.root.after(50, self.process_ui_queue)
        self.root.after(250, self.check_toolchain_on_startup)

    def post_to_ui(self, callback, *args):
        self.ui_queue.put((callback, args))

    def process_ui_queue(self):
        try:
            while True:
                callback, args = self.ui_queue.get_nowait()
                try:
                    callback(*args)
                except Exception as error:
                    self.root.report_callback_exception(type(error), error, error.__traceback__)
        except queue.Empty:
            pass
        try:
            self.root.after(50, self.process_ui_queue)
        except tk.TclError:
            pass

    def show_context_menu(self, event):
        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label="Paste", command=self.force_paste)
        menu.post(event.x_root, event.y_root)

    def force_paste(self):
        try:
            content = self.root.clipboard_get()
            self.url_entry.delete(0, tk.END)
            self.url_entry.insert(0, content)
            self.handle_url_change()
            return "break"
        except: pass

    def cleanup_current_artifacts(self):
        if self.current_artifacts:
            return self.current_artifacts.cleanup()
        return []

    def track_download_artifacts(self, data):
        if not self.current_artifacts or not isinstance(data, dict):
            return
        for key in ("filename", "tmpfilename", "filepath"):
            self.current_artifacts.track(data.get(key))
        info = data.get("info_dict")
        if isinstance(info, dict):
            for key in ("filename", "tmpfilename", "filepath"):
                self.current_artifacts.track(info.get(key))

    def get_settings_path(self):
        return str(self.platform.settings_dir() / "settings.json")

    def load_settings(self):
        return load_settings(self.settings_path)

    def save_settings(self):
        save_settings(self.settings_path, self.settings)

    def get_saved_download_path(self):
        saved_path = self.settings.get("download_path")
        fallback = (
            self.platform.default_download_dir()
            if hasattr(self, "platform")
            else Path(DEFAULT_DOWNLOAD_PATH)
        )
        return str(valid_output_directory(saved_path, fallback))

    def get_safe_filename(self, directory, title, ext):
        platform_adapter = getattr(self, "platform", None)
        platform_name = (
            platform_adapter.filename_platform()
            if platform_adapter is not None
            else "macos"
        )
        stem = reserve_output_stem(directory, title, f".{ext}", platform_name)
        return f"{stem}.{ext}"

    def make_analysis_options(self, js_runtime_path=None):
        return build_analysis_options(
            self.get_js_runtime_name(), js_runtime_path, self.browser_cookies
        )

    def make_download_options(self, request, ffmpeg_dir, js_runtime_path=None):
        ext = 'mp3' if request.audio_only else 'mp4'
        safe_name = self.get_safe_filename(request.output_directory, request.title, ext)
        self.current_artifacts = DownloadArtifactTracker(request.output_directory, safe_name)
        options = build_download_options(
            request,
            Path(safe_name).stem,
            ffmpeg_dir,
            self.get_js_runtime_name(),
            js_runtime_path,
            self.progress_hook,
            self.browser_cookies,
            artifact_hook=self.track_download_artifacts,
        )
        return options

    def download_video(self, request):
        try:
            ffmpeg_dir = self.get_ffmpeg_path()
            js_runtime_path = self.get_js_runtime_path()
        except ToolchainError as e:
            message = str(e)
            self.toolchain_error = message
            self.post_to_ui(self.show_download_error, message, self.text['tool_unavailable_title'])
            self.post_to_ui(self.reset_ui)
            return
        ydl_opts = self.make_download_options(request, ffmpeg_dir, js_runtime_path)
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl: ydl.download([request.url])
            self.post_to_ui(self.show_download_success)
        except Exception as e:
            if self.is_cancelled:
                removed_paths = self.cleanup_current_artifacts()
                self.post_to_ui(self.show_cancelled, removed_paths)
            else:
                message = self.clean_download_error(e)
                self.post_to_ui(self.show_download_error, message)
        finally: self.post_to_ui(self.reset_ui)

    def analyze_video(self, request_id, url):
        try:
            js_runtime_path = self.get_js_runtime_path()
        except ToolchainError as e:
            self.post_to_ui(self.apply_analysis_error, request_id, str(e))
            return
        ydl_opts = self.make_analysis_options(js_runtime_path)
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                title = info.get('title', 'Unknown Title')
                formats = info.get('formats', [])
                video_data, audio_data = [], []
                for f in formats:
                    if self.is_video_merge_format(f):
                        video_data.append(self.make_video_option(f))
                    if self.is_audio_merge_format(f):
                        audio_data.append(self.make_audio_option(f))
                video_data.sort(key=lambda x: x['priority'], reverse=True)
                audio_data.sort(key=lambda x: x['priority'], reverse=True)
                self.post_to_ui(
                    self.apply_analysis_result,
                    request_id,
                    url,
                    title,
                    video_data,
                    audio_data,
                )
        except Exception as e:
            message = self.clean_download_error(e)
            self.post_to_ui(self.apply_analysis_error, request_id, message)

    def show_download_success(self):
        messagebox.showinfo("OK", self.text['success'])

    def show_download_error(self, message, title="Error"):
        messagebox.showerror(title, message)

    def show_cancelled(self, _removed_paths):
        messagebox.showwarning("!", self.text['cancelled'])

    def show_about(self):
        messagebox.showinfo(self.text['about'], f"YT Downloader Pro v{VERSION}\nDeveloped by catstayathome")

    def is_video_merge_format(self, fmt):
        protocol = fmt.get('protocol')
        return (
            bool(fmt.get('height')) and
            fmt.get('vcodec') not in (None, 'none') and
            fmt.get('acodec') == 'none' and
            protocol in ('http', 'https')
        )

    def is_audio_merge_format(self, fmt):
        return fmt.get('acodec') not in (None, 'none') and fmt.get('vcodec') == 'none'

    def make_video_option(self, fmt):
        height = fmt.get('height') or 0
        ext = fmt.get('ext') or 'unknown'
        note = fmt.get('format_note')
        codec = fmt.get('vcodec') or ''
        priority = height * 10
        if ext == 'mp4':
            priority += 5
        if codec.startswith('avc1'):
            priority += 2
        label = f"{height}p - {ext}" + (f" ({note})" if note else "")
        return {'label': label, 'id': fmt.get('format_id'), 'priority': priority}

    def make_audio_option(self, fmt):
        note = (fmt.get('format_note') or '').lower()
        abr = fmt.get('abr') or fmt.get('tbr') or 0
        ext_bonus = 3 if fmt.get('ext') == 'm4a' else 0
        if 'high' in note:
            priority = 300
        elif 'medium' in note:
            priority = 200
        elif 'low' in note:
            priority = 100
        else:
            priority = 150
        priority += abr + ext_bonus
        if 'default' in note:
            priority += 1
        label = f"Audio: {fmt.get('language') or 'original'} ({fmt.get('format_note')}) - {fmt.get('ext')}"
        return {'label': label, 'id': fmt.get('format_id'), 'priority': priority}

    def check_update(self, silent=True):
        if not PUBLIC_UPDATE_MANIFEST_URL:
            if not silent:
                messagebox.showinfo("Update", self.text['manual_update'].format(version=VERSION))
            return

        def _check():
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(PUBLIC_UPDATE_MANIFEST_URL),
                    timeout=5,
                    context=self.make_update_ssl_context(),
                ) as resp:
                    latest = self.parse_update_manifest(resp.read().decode('utf-8'))
                if not latest:
                    raise ValueError("missing latest version")
                if self.is_newer_version(latest, VERSION): self.post_to_ui(self.show_update_dialog, latest)
                elif not silent: self.post_to_ui(messagebox.showinfo, "Update", self.text['is_latest'])
            except Exception as e:
                if not silent:
                    message = self.text['update_failed'].format(error=e)
                    self.post_to_ui(self.show_download_error, message, "Update")
        threading.Thread(target=_check, daemon=True).start()

    def make_update_ssl_context(self):
        return build_update_ssl_context()

    def parse_update_manifest(self, content):
        return parse_manifest(content)

    def is_newer_version(self, latest, current):
        return compare_versions(latest, current)

    def show_update_dialog(self, latest):
        if messagebox.askyesno("Update", self.text['update_available'].format(latest=latest)):
            webbrowser.open(UPDATE_DOWNLOAD_URL)

    def get_tool_dir(self):
        return str(self.platform.helper_dir())

    def get_tool_path(self, tool):
        helper_name = self.platform.helper_name(tool)
        path = os.path.realpath(os.path.join(self.get_tool_dir(), helper_name))
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=helper_name,
                path=path,
                detail=self.text['tool_missing'].format(tool=helper_name)
            ))
        try:
            self.platform.validate_architecture(path)
        except ToolchainError as error:
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=helper_name,
                path=path,
                detail=str(error),
            )) from error
        return path

    def get_ffmpeg_path(self):
        self.validate_tool("ffmpeg")
        self.validate_tool("ffprobe")
        return self.get_tool_dir()

    def get_js_runtime_name(self):
        platform_adapter = getattr(self, "platform", None)
        if platform_adapter is None:
            return "quickjs"
        return platform_adapter.js_runtime_name()

    def get_js_runtime_path(self):
        platform_adapter = getattr(self, "platform", None)
        runtime_tool = (
            platform_adapter.js_runtime_tool()
            if platform_adapter is not None
            else "qjs"
        )
        runtime_args = (
            platform_adapter.js_runtime_check_args()
            if platform_adapter is not None
            else ("--help",)
        )
        runtime_marker = (
            platform_adapter.js_runtime_output_marker()
            if platform_adapter is not None
            else "QuickJS version"
        )
        path = self.get_tool_path(runtime_tool)
        try:
            result = subprocess.run(
                [path, *runtime_args],
                capture_output=True,
                text=True,
                timeout=8,
                **self.platform.subprocess_kwargs(),
            )
        except Exception as e:
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=runtime_tool,
                path=path,
                detail=str(e),
            )) from e
        output = f"{result.stdout}\n{result.stderr}"
        if result.returncode not in (0, 1) or runtime_marker not in output:
            detail = output.strip() or f"exit code {result.returncode}"
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=runtime_tool,
                path=path,
                detail=detail,
            ))
        return path

    def get_qjs_path(self):
        """Retain the legacy macOS helper name for external callers."""
        return self.get_js_runtime_path()

    def validate_tool(self, tool):
        path = self.get_tool_path(tool)
        try:
            result = subprocess.run(
                [path, "-version"],
                capture_output=True,
                text=True,
                timeout=8,
                **self.platform.subprocess_kwargs(),
            )
        except Exception as e:
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=tool,
                path=path,
                detail=str(e)
            )) from e
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or f"exit code {result.returncode}").strip()
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=tool,
                path=path,
                detail=detail
            ))
        return path

    def check_toolchain_on_startup(self):
        try:
            self.get_ffmpeg_path()
            self.get_js_runtime_path()
            self.toolchain_error = None
        except ToolchainError as e:
            self.toolchain_error = str(e)
            messagebox.showerror(self.text['tool_unavailable_title'], str(e))

    def clean_download_error(self, error):
        language = getattr(self, "lang", None)
        if language not in LANG_DATA:
            language = next(
                (
                    code for code, catalog in LANG_DATA.items()
                    if catalog is getattr(self, "text", None)
                ),
                "en",
            )
        platform_adapter = getattr(self, "platform", None)
        log_path = (
            platform_adapter.log_dir() / "download-errors.log"
            if platform_adapter is not None
            else None
        )
        return map_download_error(error, language, log_path)

    def progress_hook(self, d):
        self.track_download_artifacts(d)
        if self.is_cancelled: raise Exception("USER_CANCEL")
        self.pause_event.wait()
        
        if d['status'] == 'downloading':
            self.post_to_ui(self.set_download_phase, "downloading")
            # --- 修正點：直接用數值計算百分比，避開彩色字元 ---
            downloaded = d.get('downloaded_bytes', 0)
            total = d.get('total_bytes') or d.get('total_bytes_estimate', 0)
            
            if total > 0:
                p = (downloaded / total) * 100
            else:
                p = 0.0 # 避免除以零
            
            speed = format_bytes(d.get('speed')) + "/s" if d.get('speed') else "--"
            size = f"{format_bytes(downloaded)} / {format_bytes(total)}"
            self.post_to_ui(self.update_ui_data, round(p, 1), speed, size)
            
        elif d['status'] == 'finished':
            self.post_to_ui(self.set_download_phase, "merging")
            self.post_to_ui(self.update_ui_data, 100, "0 B/s", self.text['merging'])

    def toggle_pause(self):
        if self.download_phase not in ("downloading", "paused"):
            return
        self.is_paused = not self.is_paused
        self.pause_event.clear() if self.is_paused else self.pause_event.set()
        self.set_download_phase("paused" if self.is_paused else "downloading")

    def cancel_download(self):
        if self.download_phase not in ("downloading", "paused"):
            return
        self.is_cancelled = True
        self.pause_event.set()

    def set_download_phase(self, phase):
        self.download_phase = phase
        if phase == "downloading":
            self.btn_pause.config(state="normal", text=self.text['pause'])
            self.btn_cancel.config(state="normal")
        elif phase == "paused":
            self.btn_pause.config(state="normal", text=self.text['resume'])
            self.btn_cancel.config(state="normal")
        else:
            self.btn_pause.config(state="disabled", text=self.text['pause'])
            self.btn_cancel.config(state="disabled")

    def update_ui_data(self, p, speed, size):
        self.progress_bar['value'] = p
        self.lbl_percent.config(text=f"{p}%")
        self.lbl_speed.config(text=f"{self.text['speed']} {speed}")
        self.lbl_size.config(text=f"{self.text['size']} {size}")

    def reset_ui(self):
        self.set_download_phase("idle")
        self.refresh_download_button()
        self.progress_bar['value'] = 0
        self.lbl_percent.config(text="0%")

    def invalidate_analysis(self):
        self.analysis_request_id += 1
        self.analyzed_url = ""
        self.pending_analysis_url = ""
        self.current_video_title = ""
        self.video_format_list = []
        self.audio_format_list = []
        if hasattr(self, "combo_quality"):
            self.combo_quality["values"] = []
            self.combo_quality.set("")
        if hasattr(self, "combo_audio"):
            self.combo_audio["values"] = []
            self.combo_audio.set("")
        if hasattr(self, "btn_download"):
            self.btn_download.config(state="disabled")
        if hasattr(self, "btn_analyze"):
            self.btn_analyze.config(state="normal", text=self.text["analyze"])

    def handle_url_change(self, _event=None):
        current_url = self.clean_url(self.url_entry.get())
        if current_url == self.pending_analysis_url:
            return
        if current_url != self.analyzed_url:
            self.invalidate_analysis()

    def download_selection_is_valid(self, url, audio_only):
        if self.clean_url(url) != self.analyzed_url:
            return False
        if audio_only:
            return bool(self.audio_format_list)
        return bool(self.video_format_list and self.audio_format_list)

    def apply_analysis_result(self, request_id, url, title, video_data, audio_data):
        if request_id != self.analysis_request_id:
            return
        self.pending_analysis_url = ""
        self.analyzed_url = url
        self.current_video_title = title
        self.video_format_list = [item['id'] for item in video_data]
        self.audio_format_list = [item['id'] for item in audio_data]
        self.lbl_video_title.config(text=f"{self.text['video_title']} {title}")
        self.update_combos(
            [item['label'] for item in video_data],
            [item['label'] for item in audio_data],
        )

    def apply_analysis_error(self, request_id, error):
        if request_id != self.analysis_request_id:
            return
        self.pending_analysis_url = ""
        self.btn_analyze.config(state="normal", text=self.text['analyze'])
        messagebox.showerror(self.text['analyze_failed'], error)

    def start_analyze(self):
        url = self.clean_url(self.url_entry.get())
        if not url: return
        self.url_entry.delete(0, tk.END)
        self.url_entry.insert(0, url)
        self.invalidate_analysis()
        request_id = self.analysis_request_id
        self.pending_analysis_url = url
        self.btn_analyze.config(state="disabled", text=self.text['analyzing'])
        self.lbl_video_title.config(text="")
        threading.Thread(target=self.analyze_video, args=(request_id, url), daemon=True).start()

    def clean_url(self, url):
        try:
            p = urlparse(url)
            qs = parse_qs(p.query)
            if 'v' in qs: return urlunparse(p._replace(query=f"v={qs['v'][0]}", fragment=""))
            return url
        except: return url

    def update_combos(self, v_opts, a_opts):
        self.combo_quality['values'] = v_opts
        if v_opts: self.combo_quality.current(0)
        self.combo_audio['values'] = a_opts
        if a_opts: self.combo_audio.current(0)
        self.btn_analyze.config(state="normal", text=self.text['analyze'])

        self.refresh_download_button()

    def refresh_download_button(self):
        url = self.clean_url(self.url_entry.get())
        audio_only = bool(self.audio_only_var.get())
        state = "normal" if self.download_selection_is_valid(url, audio_only) else "disabled"
        self.btn_download.config(state=state)

    def start_download(self):
        url = self.clean_url(self.url_entry.get())
        audio_only = bool(self.audio_only_var.get())
        if not self.download_selection_is_valid(url, audio_only):
            messagebox.showerror(self.text['analyze_failed'], self.text['selection_invalid'])
            self.invalidate_analysis()
            return
        v_idx, a_idx = self.combo_quality.current(), self.combo_audio.current()
        v_fid = self.video_format_list[v_idx] if v_idx != -1 else None
        a_fid = self.audio_format_list[a_idx] if a_idx != -1 else None
        request = DownloadRequest(
            url=url,
            video_format_id=v_fid,
            audio_format_id=a_fid,
            audio_only=audio_only,
            output_directory=self.download_path,
            title=self.current_video_title,
        )
        self.is_cancelled = False
        self.is_paused = False
        self.pause_event.set()
        self.btn_download.config(state="disabled")
        self.set_download_phase("downloading")
        threading.Thread(target=self.download_video, args=(request,), daemon=True).start()

    def change_path(self):
        p = filedialog.askdirectory()
        if p:
            self.download_path = p
            self.settings["download_path"] = p
            self.save_settings()
            self.lbl_path.config(text=f"{self.text['save_to']} {self.download_path}")

    def get_system_language(self):
        return self.platform.language()

def run_app(platform_adapter):
    """Create and run the shared Tkinter interface for one platform."""
    root = tk.Tk()
    app = YTDownloaderApp(root, platform_adapter)
    root.mainloop()
    return app
