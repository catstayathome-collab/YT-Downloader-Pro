import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import yt_dlp
import ssl
import sys
import threading
import os
import subprocess
import urllib.request
from urllib.parse import urlparse, parse_qs, urlunparse
import locale
import platform
import re
import webbrowser
import glob
import json

# 解決 Mac 憑證問題
ssl._create_default_https_context = ssl._create_unverified_context

VERSION = "1.8.4"
APP_NAME = "YT Downloader Pro"
PUBLIC_UPDATE_MANIFEST_URL = os.environ.get("YTDP_UPDATE_MANIFEST_URL", "").strip()
COOKIES_BROWSER = os.environ.get("YTDP_COOKIES_BROWSER", "").strip()
DEFAULT_DOWNLOAD_PATH = os.path.join(os.path.expanduser("~"), "Downloads")


class ToolchainError(RuntimeError):
    pass

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
        "tool_missing": "找不到內附工具：{tool}",
        "tool_unavailable_title": "內建轉檔工具無法使用",
        "tool_unavailable": "內建轉檔工具無法在這台 Mac 上執行。\n\n工具：{tool}\n位置：{path}\n原因：{detail}\n\n請重新下載完整的 Apple Silicon 版本，或聯絡開發者取得新版安裝檔。",
        "tool_ytdlp_error": "內建轉檔工具無法被下載核心使用，因此無法合併影音或轉換 MP3。\n\n請重新下載完整的 Apple Silicon 版本，或聯絡開發者取得新版安裝檔。",
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
        "tool_missing": "Bundled tool not found: {tool}",
        "tool_unavailable_title": "Bundled converter unavailable",
        "tool_unavailable": "The bundled converter cannot run on this Mac.\n\nTool: {tool}\nPath: {path}\nReason: {detail}\n\nPlease download the complete Apple Silicon build again or contact the developer for an updated app.",
        "tool_ytdlp_error": "The bundled converter could not be used by the download engine, so video/audio merging or MP3 conversion cannot continue.\n\nPlease download the complete Apple Silicon build again or contact the developer for an updated app.",
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
        "tool_missing": "同梱ツールが見つかりません: {tool}",
        "tool_unavailable_title": "内蔵変換ツールを使用できません",
        "tool_unavailable": "内蔵変換ツールをこの Mac で実行できません。\n\nツール: {tool}\n場所: {path}\n理由: {detail}\n\n完全な Apple Silicon 版を再ダウンロードするか、開発者に新版を依頼してください。",
        "tool_ytdlp_error": "内蔵変換ツールをダウンロードエンジンが使用できないため、動画と音声の結合または MP3 変換を続行できません。\n\n完全な Apple Silicon 版を再ダウンロードするか、開発者に新版を依頼してください。",
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
        self.safe_title_for_cleanup = ""
        self.browser_cookies = (COOKIES_BROWSER,) if COOKIES_BROWSER else None
        self.toolchain_error = None

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
        tk.Checkbutton(root, text=self.text['audio_only'], variable=self.audio_only_var).pack(pady=5)

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
        self.root.after(250, self.check_toolchain_on_startup)

    def show_context_menu(self, event):
        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label="Paste", command=self.force_paste)
        menu.post(event.x_root, event.y_root)

    def force_paste(self):
        try:
            content = self.root.clipboard_get()
            self.url_entry.delete(0, tk.END)
            self.url_entry.insert(0, content)
            return "break"
        except: pass

    def cleanup_incomplete_files(self):
        if not self.safe_title_for_cleanup: return
        try:
            search_pattern = os.path.join(self.download_path, f"{self.safe_title_for_cleanup}*")
            for file_path in glob.glob(search_pattern):
                if any(ext in file_path for ext in ['.part', '.ytdl', '.temp', '.mp4', '.m4a', '.webm', '.mp3']):
                    os.remove(file_path)
        except: pass

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
        self.safe_title_for_cleanup = safe_title
        base_name = f"{safe_title}.{ext}"
        if not os.path.exists(os.path.join(directory, base_name)): return base_name
        counter = 1
        while True:
            new_name = f"{safe_title} ({counter}).{ext}"
            if not os.path.exists(os.path.join(directory, new_name)): return new_name
            counter += 1

    def download_video(self, url, v_fid, a_fid):
        self.is_cancelled, self.is_paused = False, False
        self.pause_event.set()
        audio_only = self.audio_only_var.get()
        ext = 'mp3' if audio_only else 'mp4'
        safe_name = self.get_safe_filename(self.download_path, self.current_video_title, ext)
        try:
            ffmpeg_dir = self.get_ffmpeg_path()
        except ToolchainError as e:
            self.toolchain_error = str(e)
            self.root.after(0, lambda: messagebox.showerror(self.text['tool_unavailable_title'], str(e)))
            self.root.after(0, self.reset_ui)
            return
        ydl_opts = {
            'ffmpeg_location': ffmpeg_dir,
            'nocheckcertificate': True,
            'outtmpl': os.path.join(self.download_path, safe_name),
            'progress_hooks': [self.progress_hook],
            'format': f"{v_fid}+{a_fid}" if not audio_only else a_fid if a_fid else 'bestaudio/best',
            'merge_output_format': 'mp4' if not audio_only else None
        }
        if self.browser_cookies:
            ydl_opts['cookiesfrombrowser'] = self.browser_cookies
        if audio_only:
            ydl_opts['postprocessors'] = [{'key': 'FFmpegExtractAudio','preferredcodec': 'mp3','preferredquality': '192'}]
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl: ydl.download([url])
            messagebox.showinfo("OK", self.text['success'])
        except Exception as e:
            if str(e) == "USER_CANCEL":
                self.cleanup_incomplete_files()
                messagebox.showwarning("!", self.text['cancelled'])
            else: messagebox.showerror("Error", self.clean_download_error(e))
        finally: self.root.after(0, self.reset_ui)

    def analyze_video(self, url):
        ydl_opts = {'nocheckcertificate': True, 'quiet': True}
        if self.browser_cookies:
            ydl_opts['cookiesfrombrowser'] = self.browser_cookies
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                self.current_video_title = info.get('title', 'Unknown Title')
                self.root.after(0, lambda: self.lbl_video_title.config(text=f"{self.text['video_title']} {self.current_video_title}"))
                formats = info.get('formats', [])
                video_data, audio_data = [], []
                for f in formats:
                    h = f.get('height')
                    if h and f.get('vcodec') != 'none':
                        p = h * 10 + (5 if f.get('ext') == 'mp4' else 0)
                        label = f"{h}p - {f.get('ext')}" + (f" ({f.get('format_note')})" if f.get('format_note') else "")
                        video_data.append({'label': label, 'id': f.get('format_id'), 'priority': p})
                    if f.get('acodec') != 'none' and f.get('vcodec') == 'none':
                        note = f.get('format_note', '').lower()
                        abr = f.get('abr') or f.get('tbr') or 0
                        ext_bonus = 3 if f.get('ext') == 'm4a' else 0
                        if 'high' in note:
                            ap = 300
                        elif 'medium' in note:
                            ap = 200
                        elif 'low' in note:
                            ap = 100
                        else:
                            ap = 150
                        ap += abr + ext_bonus
                        if 'default' in note: ap += 1
                        label = f"Audio: {f.get('language') or 'original'} ({f.get('format_note')}) - {f.get('ext')}"
                        audio_data.append({'label': label, 'id': f.get('format_id'), 'priority': ap})
                video_data.sort(key=lambda x: x['priority'], reverse=True)
                audio_data.sort(key=lambda x: x['priority'], reverse=True)
                self.video_format_list = [i['id'] for i in video_data]
                self.audio_format_list = [i['id'] for i in audio_data]
                self.root.after(0, self.update_combos, [i['label'] for i in video_data], [i['label'] for i in audio_data])
        except Exception as e:
            self.root.after(0, lambda: self.btn_analyze.config(state="normal", text=self.text['analyze']))
            self.root.after(0, lambda: messagebox.showerror(self.text['analyze_failed'], str(e)))

    def show_about(self):
        messagebox.showinfo(self.text['about'], f"YT Downloader Pro v{VERSION}\nDeveloped by catstayathome")

    def check_update(self, silent=True):
        if not PUBLIC_UPDATE_MANIFEST_URL:
            if not silent:
                messagebox.showinfo("Update", self.text['manual_update'].format(version=VERSION))
            return

        def _check():
            try:
                with urllib.request.urlopen(urllib.request.Request(PUBLIC_UPDATE_MANIFEST_URL), timeout=5) as resp:
                    latest = resp.read().decode('utf-8').strip()
                if self.is_newer_version(latest, VERSION): self.root.after(0, lambda: self.show_update_dialog(latest))
                elif not silent: self.root.after(0, lambda: messagebox.showinfo("Update", self.text['is_latest']))
            except: pass
        threading.Thread(target=_check, daemon=True).start()

    def is_newer_version(self, latest, current):
        def parts(v):
            return [int(x) for x in re.findall(r'\d+', v)]
        return parts(latest) > parts(current)

    def show_update_dialog(self, latest):
        """Pro 版專屬更新邏輯：導向私密 Google Drive 下載連結"""
        pro_update_url = "https://pse.is/8pbb2x"
        if messagebox.askyesno("Update", f"v{latest} available! 是否前往下載 Pro 更新版本？"):
            webbrowser.open(pro_update_url)

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
            self.toolchain_error = None
        except ToolchainError as e:
            self.toolchain_error = str(e)
            messagebox.showerror(self.text['tool_unavailable_title'], str(e))

    def clean_download_error(self, error):
        message = str(error)
        lowered = message.lower()
        if "ffmpeg is not installed" in lowered or "requested merging of multiple formats" in lowered:
            return self.text['tool_ytdlp_error']
        return message

    def progress_hook(self, d):
        if self.is_cancelled: raise Exception("USER_CANCEL")
        self.pause_event.wait()
        
        if d['status'] == 'downloading':
            # --- 修正點：直接用數值計算百分比，避開彩色字元 ---
            downloaded = d.get('downloaded_bytes', 0)
            total = d.get('total_bytes') or d.get('total_bytes_estimate', 0)
            
            if total > 0:
                p = (downloaded / total) * 100
            else:
                p = 0.0 # 避免除以零
            
            speed = self.format_bytes(d.get('speed')) + "/s" if d.get('speed') else "--"
            size = f"{self.format_bytes(downloaded)} / {self.format_bytes(total)}"
            self.root.after(0, lambda: self.update_ui_data(round(p, 1), speed, size))
            
        elif d['status'] == 'finished':
            self.root.after(0, lambda: self.update_ui_data(100, "0 B/s", "Merging..."))

    def format_bytes(self, bytes):
        if not bytes: return "--"
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes < 1024.0: return f"{bytes:.2f} {unit}"
            bytes /= 1024.0
        return "--"

    def toggle_pause(self):
        self.is_paused = not self.is_paused
        self.pause_event.clear() if self.is_paused else self.pause_event.set()
        self.btn_pause.config(text=self.text['resume'] if self.is_paused else self.text['pause'])

    def cancel_download(self):
        self.is_cancelled = True
        self.pause_event.set()

    def update_ui_data(self, p, speed, size):
        self.progress_bar['value'] = p
        self.lbl_percent.config(text=f"{p}%")
        self.lbl_speed.config(text=f"{self.text['speed']} {speed}")
        self.lbl_size.config(text=f"{self.text['size']} {size}")

    def reset_ui(self):
        self.btn_download.config(state="normal")
        self.btn_pause.config(state="disabled", text=self.text['pause'])
        self.btn_cancel.config(state="disabled")
        self.progress_bar['value'] = 0
        self.lbl_percent.config(text="0%")

    def start_analyze(self):
        url = self.clean_url(self.url_entry.get())
        if not url: return
        self.url_entry.delete(0, tk.END)
        self.url_entry.insert(0, url)
        self.btn_analyze.config(state="disabled", text=self.text['analyzing'])
        self.lbl_video_title.config(text="")
        threading.Thread(target=self.analyze_video, args=(url,), daemon=True).start()

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
        self.btn_download.config(state="normal")
        self.btn_analyze.config(state="normal", text=self.text['analyze'])

    def start_download(self):
        url = self.url_entry.get()
        v_idx, a_idx = self.combo_quality.current(), self.combo_audio.current()
        v_fid = self.video_format_list[v_idx] if v_idx != -1 else None
        a_fid = self.audio_format_list[a_idx] if a_idx != -1 else None
        self.btn_download.config(state="disabled")
        self.btn_pause.config(state="normal")
        self.btn_cancel.config(state="normal")
        threading.Thread(target=self.download_video, args=(url, v_fid, a_fid), daemon=True).start()

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
