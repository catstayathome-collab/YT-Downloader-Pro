import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import certifi
import yt_dlp
import ssl
import sys
import threading
import queue
import os
import subprocess
import urllib.request
from urllib.parse import urlparse, parse_qs, urlunparse
import locale
import platform
import re
import webbrowser
import json
import base64
from dataclasses import dataclass
from pathlib import Path

VERSION = "1.8.7"
APP_NAME = "YT Downloader Pro"
DEFAULT_UPDATE_MANIFEST_URL = "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/contents/version.txt?ref=main"
DEFAULT_UPDATE_DOWNLOAD_URL = "https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest"
PUBLIC_UPDATE_MANIFEST_URL = os.environ.get("YTDP_UPDATE_MANIFEST_URL", DEFAULT_UPDATE_MANIFEST_URL).strip()
UPDATE_DOWNLOAD_URL = os.environ.get("YTDP_UPDATE_DOWNLOAD_URL", DEFAULT_UPDATE_DOWNLOAD_URL).strip()
COOKIES_BROWSER = os.environ.get("YTDP_COOKIES_BROWSER", "").strip()
DEFAULT_DOWNLOAD_PATH = os.path.join(os.path.expanduser("~"), "Downloads")


class ToolchainError(RuntimeError):
    pass


@dataclass(frozen=True)
class DownloadRequest:
    url: str
    video_format_id: str | None
    audio_format_id: str | None
    audio_only: bool
    output_directory: str
    title: str


class DownloadArtifactTracker:
    def __init__(self, directory, output_filename):
        self.directory = Path(directory).resolve()
        self.output_path = (self.directory / output_filename).absolute()
        self.preexisting = {path.absolute() for path in self.directory.iterdir()}
        self.preexisting_resolved = {path.resolve(strict=False) for path in self.preexisting}
        self.tracked = set()
        self.track(str(self.output_path))

    def track(self, path):
        if not path:
            return
        candidate = Path(path)
        if not candidate.is_absolute():
            candidate = self.directory / candidate
        candidate = candidate.absolute()
        resolved = candidate.resolve(strict=False)
        if resolved != self.directory and self.directory not in resolved.parents:
            return
        if candidate not in self.preexisting and resolved not in self.preexisting_resolved:
            self.tracked.add(candidate)

    def cleanup(self):
        removed = []
        for path in sorted(self.tracked, key=lambda item: len(str(item)), reverse=True):
            resolved = path.resolve(strict=False)
            if path in self.preexisting or resolved in self.preexisting_resolved:
                continue
            if resolved != self.directory and self.directory not in resolved.parents:
                continue
            if path.is_file() or path.is_symlink():
                path.unlink()
                removed.append(str(path))
        return sorted(removed)

# --- 國際化字典包 ---
LANG_DATA = {
    "zh": {
        "title": "YouTube 下載器 Pro",
        "video_title": "影片標題:",
        "analyze": "解析影片",
        "analyzing": "解析中...",
        "quality": "選擇畫質:",
        "audio_track": "選擇音軌:",
        "audio_only": "僅下載音訊 (轉為 MP3)",
        "change_path": "更改儲存路徑",
        "save_to": "儲存至:",
        "start_download": "開始下載",
        "pause": "暫停",
        "resume": "繼續",
        "cancel": "取消",
        "success": "下載完成！",
        "cancelled": "下載已取消，已強力清除殘留檔案",
        "about": "關於程式",
        "update_check": "檢查更新",
        "is_latest": "目前已是最新版本",
        "manual_update": "目前版本為 v{version}。請從正式發布頁面取得更新版本。",
        "update_available": "發現新版 v{latest}。是否前往下載頁面？",
        "update_failed": "無法檢查更新：{error}",
        "tool_missing": "找不到內附工具：{tool}",
        "tool_unavailable_title": "內建轉檔工具無法使用",
        "tool_unavailable": "內建轉檔工具無法在這台 Mac 上執行。\n\n工具：{tool}\n位置：{path}\n原因：{detail}\n\n請重新下載完整的 Apple Silicon 版本，或聯絡開發者取得新版安裝檔。",
        "tool_ytdlp_error": "內建轉檔工具無法被下載核心使用，因此無法合併影音或轉換 MP3。\n\n請重新下載完整的 Apple Silicon 版本，或聯絡開發者取得新版安裝檔。",
        "format_unavailable": "YouTube 回傳的格式已變動，或剛才選到的格式已不可用。\n\n請重新解析影片後再下載；若仍失敗，請改選另一個畫質或音訊選項。",
        "certificate_error": "安全憑證驗證失敗，無法建立受保護的連線。請確認 macOS 日期時間正確，並更新或重新安裝 App。",
        "network_error": "目前無法連上 YouTube。請檢查網路連線後再試一次。",
        "permission_error": "沒有權限寫入選擇的資料夾。請改選其他儲存位置，或在系統設定中允許 App 存取。",
        "selection_invalid": "網址或可下載格式已變動，請重新解析影片後再下載。",
        "merging": "正在合併影音，請稍候…",
        "analyze_failed": "影片解析失敗",
        "speed": "速度:",
        "size": "檔案大小:"
    },
    "en": {
        "title": "YouTube Downloader Pro",
        "video_title": "Video Title:",
        "analyze": "Analyze",
        "analyzing": "Analyzing...",
        "quality": "Select Quality:",
        "audio_track": "Audio Track:",
        "audio_only": "Audio Only (MP3)",
        "change_path": "Change Save Path",
        "save_to": "Save to:",
        "start_download": "Download Now",
        "pause": "Pause",
        "resume": "Resume",
        "cancel": "Cancel",
        "success": "Download Finished!",
        "cancelled": "Cancelled and temp files cleared",
        "about": "About",
        "update_check": "Check Update",
        "is_latest": "Already up to date",
        "manual_update": "Current version is v{version}. Please use the official release page for updates.",
        "update_available": "Version v{latest} is available. Open the download page?",
        "update_failed": "Unable to check for updates: {error}",
        "tool_missing": "Bundled tool not found: {tool}",
        "tool_unavailable_title": "Bundled converter unavailable",
        "tool_unavailable": "The bundled converter cannot run on this Mac.\n\nTool: {tool}\nPath: {path}\nReason: {detail}\n\nPlease download the complete Apple Silicon build again or contact the developer for an updated app.",
        "tool_ytdlp_error": "The bundled converter could not be used by the download engine, so video/audio merging or MP3 conversion cannot continue.\n\nPlease download the complete Apple Silicon build again or contact the developer for an updated app.",
        "format_unavailable": "The YouTube format list changed, or the selected format is no longer available.\n\nAnalyze the video again before downloading. If it still fails, choose another video or audio format.",
        "certificate_error": "The secure certificate check failed. Verify the Mac's date and time, then update or reinstall the app.",
        "network_error": "YouTube cannot be reached right now. Check the network connection and try again.",
        "permission_error": "The selected folder cannot be written. Choose another location or allow access in System Settings.",
        "selection_invalid": "The URL or available formats changed. Analyze the video again before downloading.",
        "merging": "Merging video and audio. Please wait…",
        "analyze_failed": "Video analysis failed",
        "speed": "Speed:",
        "size": "Size:"
    },
    "ja": {
        "title": "YouTube ダウンローダー Pro",
        "video_title": "動画のタイトル:",
        "analyze": "解析する",
        "analyzing": "解析中...",
        "quality": "画質を選択:",
        "audio_track": "音軌を選択:",
        "audio_only": "音聲を抽出 (MP3轉換)",
        "change_path": "保存先を変更",
        "save_to": "保存先:",
        "start_download": "ダウンロード開始",
        "pause": "一時停止",
        "resume": "再開",
        "cancel": "キャンセル",
        "success": "完了しました！",
        "cancelled": "キャンセルされ、ファイルが削除されました",
        "about": "このアプリについて",
        "update_check": "アップデートを確認",
        "is_latest": "最新バージョンです",
        "manual_update": "現在のバージョンは v{version} です。公式リリースページから更新してください。",
        "update_available": "新しいバージョン v{latest} があります。ダウンロードページを開きますか？",
        "update_failed": "アップデートを確認できません：{error}",
        "tool_missing": "同梱ツールが見つかりません: {tool}",
        "tool_unavailable_title": "内蔵変換ツールを使用できません",
        "tool_unavailable": "内蔵変換ツールをこの Mac で実行できません。\n\nツール: {tool}\n場所: {path}\n理由: {detail}\n\n完全な Apple Silicon 版を再ダウンロードするか、開発者に新版を依頼してください。",
        "tool_ytdlp_error": "内蔵変換ツールをダウンロードエンジンが使用できないため、動画と音声の結合または MP3 変換を続行できません。\n\n完全な Apple Silicon 版を再ダウンロードするか、開発者に新版を依頼してください。",
        "format_unavailable": "YouTube の形式リストが変更されたか、選択した形式を利用できなくなりました。\n\n動画を再解析してから再度ダウンロードしてください。まだ失敗する場合は、別の画質または音声を選択してください。",
        "certificate_error": "安全な証明書を確認できませんでした。Mac の日付と時刻を確認し、App を更新または再インストールしてください。",
        "network_error": "現在 YouTube に接続できません。ネットワーク接続を確認して、もう一度お試しください。",
        "permission_error": "選択したフォルダに書き込む権限がありません。別の保存先を選ぶか、システム設定でアクセスを許可してください。",
        "selection_invalid": "URL または利用可能な形式が変更されました。動画を再解析してからダウンロードしてください。",
        "merging": "動画と音声を結合しています。しばらくお待ちください…",
        "analyze_failed": "動画の解析に失敗しました",
        "speed": "速度:",
        "size": "サイズ:"
    }
}

class YTDownloaderApp:
    def __init__(self, root):
        self.root = root
        self.lang = self.get_system_language()
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
        support_dir = os.path.join(os.path.expanduser("~"), "Library", "Application Support", APP_NAME)
        return os.path.join(support_dir, "settings.json")

    def load_settings(self):
        try:
            with open(self.settings_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def save_settings(self):
        try:
            os.makedirs(os.path.dirname(self.settings_path), exist_ok=True)
            with open(self.settings_path, "w", encoding="utf-8") as f:
                json.dump(self.settings, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def get_saved_download_path(self):
        saved_path = self.settings.get("download_path")
        if saved_path and os.path.isdir(saved_path):
            return saved_path
        return DEFAULT_DOWNLOAD_PATH

    def get_safe_filename(self, directory, title, ext):
        safe_title = re.sub(r'[\\/*?:"<>|]', "", title)
        base_name = f"{safe_title}.{ext}"
        if not os.path.exists(os.path.join(directory, base_name)): return base_name
        counter = 1
        while True:
            new_name = f"{safe_title} ({counter}).{ext}"
            if not os.path.exists(os.path.join(directory, new_name)): return new_name
            counter += 1

    def make_analysis_options(self, js_runtime_path=None):
        options = {'quiet': True}
        if js_runtime_path:
            options['js_runtimes'] = {'quickjs': {'path': js_runtime_path}}
        if self.browser_cookies:
            options['cookiesfrombrowser'] = self.browser_cookies
        return options

    def make_download_options(self, request, ffmpeg_dir, js_runtime_path=None):
        ext = 'mp3' if request.audio_only else 'mp4'
        safe_name = self.get_safe_filename(request.output_directory, request.title, ext)
        self.current_artifacts = DownloadArtifactTracker(request.output_directory, safe_name)
        output_template = safe_name
        if request.audio_only:
            output_template = f"{Path(safe_name).stem}.%(ext)s"
        options = {
            'ffmpeg_location': ffmpeg_dir,
            'outtmpl': os.path.join(request.output_directory, output_template),
            'progress_hooks': [self.progress_hook],
            'postprocessor_hooks': [self.track_download_artifacts],
            'format': (
                f"{request.video_format_id}+{request.audio_format_id}"
                if not request.audio_only
                else request.audio_format_id or 'bestaudio/best'
            ),
            'merge_output_format': 'mp4' if not request.audio_only else None,
        }
        if js_runtime_path:
            options['js_runtimes'] = {'quickjs': {'path': js_runtime_path}}
        if self.browser_cookies:
            options['cookiesfrombrowser'] = self.browser_cookies
        if request.audio_only:
            options['postprocessors'] = [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': 'mp3',
                'preferredquality': '192',
            }]
        return options

    def download_video(self, request):
        self.is_cancelled, self.is_paused = False, False
        self.pause_event.set()
        try:
            ffmpeg_dir = self.get_ffmpeg_path()
            js_runtime_path = self.get_qjs_path()
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
            js_runtime_path = self.get_qjs_path()
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
        return ssl.create_default_context(cafile=certifi.where())

    def parse_update_manifest(self, content):
        content = (content or "").strip()
        if not content:
            return ""
        try:
            data = json.loads(content)
            if isinstance(data, dict):
                if data.get("content"):
                    decoded = base64.b64decode(str(data["content"]).encode()).decode("utf-8", errors="replace")
                    return self.parse_update_manifest(decoded)
                return str(data.get("latest_version") or data.get("version") or data.get("tag_name") or "").strip().lstrip("v")
        except json.JSONDecodeError:
            pass
        first_line = content.splitlines()[0].strip()
        return first_line.lstrip("v")

    def is_newer_version(self, latest, current):
        def parts(v):
            return [int(x) for x in re.findall(r'\d+', v)]
        return parts(latest) > parts(current)

    def show_update_dialog(self, latest):
        if messagebox.askyesno("Update", self.text['update_available'].format(latest=latest)):
            webbrowser.open(UPDATE_DOWNLOAD_URL)

    def get_app_contents_dir(self):
        if getattr(sys, 'frozen', False):
            exe_dir = os.path.dirname(sys.executable)
            if os.path.basename(exe_dir) == "MacOS" and os.path.basename(os.path.dirname(exe_dir)) == "Contents":
                return os.path.dirname(exe_dir)
            return exe_dir
        return os.path.dirname(os.path.abspath(__file__))

    def get_tool_dir(self):
        base = self.get_app_contents_dir()
        if getattr(sys, 'frozen', False):
            candidates = [os.path.join(base, "Helpers"), os.path.join(base, "_internal", "Helpers")]
        else:
            candidates = [os.path.join(base, "tools")]
        for candidate in candidates:
            if os.path.isdir(candidate):
                return candidate
        return candidates[0]

    def get_tool_path(self, tool):
        path = os.path.realpath(os.path.join(self.get_tool_dir(), tool))
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool=tool,
                path=path,
                detail=self.text['tool_missing'].format(tool=tool)
            ))
        return path

    def get_ffmpeg_path(self):
        self.validate_tool("ffmpeg")
        self.validate_tool("ffprobe")
        return self.get_tool_dir()

    def get_qjs_path(self):
        path = self.get_tool_path("qjs")
        if platform.machine() == "arm64":
            arches = self.get_tool_arches(path)
            if arches and "arm64" not in arches.split():
                raise ToolchainError(self.text['tool_unavailable'].format(
                    tool="qjs",
                    path=path,
                    detail=f"architecture is {arches}, not arm64",
                ))
        try:
            result = subprocess.run([path, "--help"], capture_output=True, text=True, timeout=8)
        except Exception as e:
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool="qjs",
                path=path,
                detail=str(e),
            )) from e
        output = f"{result.stdout}\n{result.stderr}"
        if result.returncode not in (0, 1) or "QuickJS version" not in output:
            detail = output.strip() or f"exit code {result.returncode}"
            raise ToolchainError(self.text['tool_unavailable'].format(
                tool="qjs",
                path=path,
                detail=detail,
            ))
        return path

    def validate_tool(self, tool):
        path = self.get_tool_path(tool)
        if platform.machine() == "arm64":
            arches = self.get_tool_arches(path)
            if arches and "arm64" not in arches.split():
                raise ToolchainError(self.text['tool_unavailable'].format(
                    tool=tool,
                    path=path,
                    detail=f"architecture is {arches}, not arm64"
                ))
        try:
            result = subprocess.run([path, "-version"], capture_output=True, text=True, timeout=8)
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

    def get_tool_arches(self, path):
        try:
            result = subprocess.run(["/usr/bin/lipo", "-archs", path], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass
        return ""

    def check_toolchain_on_startup(self):
        try:
            self.get_ffmpeg_path()
            self.get_qjs_path()
            self.toolchain_error = None
        except ToolchainError as e:
            self.toolchain_error = str(e)
            messagebox.showerror(self.text['tool_unavailable_title'], str(e))

    def clean_download_error(self, error):
        message = str(error)
        lowered = message.lower()
        if isinstance(error, PermissionError) or "permission denied" in lowered:
            return self.text['permission_error']
        if "certificate_verify_failed" in lowered or "certificate verify failed" in lowered:
            return self.text['certificate_error']
        if any(value in lowered for value in (
            "network is unreachable",
            "name or service not known",
            "temporary failure in name resolution",
            "timed out",
            "connection reset",
            "connection refused",
        )):
            return self.text['network_error']
        if "ffmpeg is not installed" in lowered or "requested merging of multiple formats" in lowered:
            return self.text['tool_ytdlp_error']
        if "requested format is not available" in lowered:
            return self.text['format_unavailable']
        return message

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
            
            speed = self.format_bytes(d.get('speed')) + "/s" if d.get('speed') else "--"
            size = f"{self.format_bytes(downloaded)} / {self.format_bytes(total)}"
            self.post_to_ui(self.update_ui_data, round(p, 1), speed, size)
            
        elif d['status'] == 'finished':
            self.post_to_ui(self.set_download_phase, "merging")
            self.post_to_ui(self.update_ui_data, 100, "0 B/s", self.text['merging'])

    def format_bytes(self, bytes):
        if not bytes: return "--"
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes < 1024.0: return f"{bytes:.2f} {unit}"
            bytes /= 1024.0
        return "--"

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

    def handle_url_change(self, _event=None):
        if _event is not None and getattr(_event, "keysym", "") in ("Return", "KP_Enter"):
            return
        current_url = self.clean_url(self.url_entry.get())
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
        self.btn_analyze.config(state="normal", text=self.text['analyze'])
        messagebox.showerror(self.text['analyze_failed'], error)

    def start_analyze(self):
        url = self.clean_url(self.url_entry.get())
        if not url: return
        self.url_entry.delete(0, tk.END)
        self.url_entry.insert(0, url)
        self.invalidate_analysis()
        request_id = self.analysis_request_id
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
        try:
            res = subprocess.run(['defaults', 'read', '-g', 'AppleLanguages'], capture_output=True, text=True, timeout=1)
            output = res.stdout.lower()
            m = re.search(r'"([^"]+)"', output)
            if m:
                primary = m.group(1)
                if primary.startswith("ja"): return "ja"
                if primary.startswith("zh"): return "zh"
        except: pass
        return "en"

if __name__ == "__main__":
    root = tk.Tk()
    app = YTDownloaderApp(root)
    root.mainloop()
