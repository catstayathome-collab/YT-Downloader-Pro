"""Localized UI strings and safe download error translation."""

from pathlib import Path
import re


LANG_DATA = {
    "zh": {
        "title": "YouTube 下載器 Pro", "video_title": "影片標題:", "analyze": "解析影片",
        "analyzing": "解析中...", "quality": "選擇畫質:", "audio_track": "選擇音軌:",
        "audio_only": "僅下載音訊 (轉為 MP3)", "change_path": "更改儲存路徑",
        "save_to": "儲存至:", "start_download": "開始下載", "pause": "暫停", "resume": "繼續",
        "cancel": "取消", "success": "下載完成！", "cancelled": "下載已取消，已強力清除殘留檔案",
        "about": "關於程式", "update_check": "檢查更新", "is_latest": "目前已是最新版本",
        "manual_update": "目前版本為 v{version}。請從正式發布頁面取得更新版本。",
        "update_available": "發現新版 v{latest}。是否前往下載頁面？", "update_failed": "無法檢查更新：{error}",
        "tool_missing": "找不到內附工具：{tool}", "tool_unavailable_title": "內建轉檔工具無法使用",
        "tool_unavailable": "內建轉檔工具無法在這台電腦上執行。\n\n工具：{tool}\n位置：{path}\n原因：{detail}\n\n請重新下載完整的應用程式，或聯絡開發者取得新版安裝檔。",
        "tool_validation_failed": "內建轉檔工具驗證失敗，影片解析與下載已停用。請重新下載完整的應用程式，或聯絡開發者。\n\n診斷記錄：{log_path}",
        "tool_ytdlp_error": "內建轉檔工具無法被下載核心使用，因此無法合併影音或轉換 MP3。\n\n請重新下載完整的應用程式，或聯絡開發者取得新版安裝檔。",
        "format_unavailable": "YouTube 回傳的格式已變動，或剛才選到的格式已不可用。\n\n請重新解析影片後再下載；若仍失敗，請改選另一個畫質或音訊選項。",
        "certificate_error": "安全憑證驗證失敗，無法建立受保護的連線。請確認電腦日期時間正確，並更新或重新安裝 App。",
        "network_error": "目前無法連上 YouTube。請檢查網路連線後再試一次。",
        "youtube_bot_check": "YouTube 暫時要求登入驗證，這不是影片網址或轉檔工具故障。請先在瀏覽器登入 YouTube，稍後重新解析；若持續出現，請重新啟動 App 或聯絡開發者。",
        "permission_error": "沒有權限寫入選擇的資料夾。請改選其他儲存位置，或在系統設定中允許 App 存取。",
        "content_unavailable": "影片目前無法播放或下載。可能已被移除、設為私人或受地區限制。",
        "disk_full": "儲存空間不足。請釋放磁碟空間後再試一次。",
        "invalid_path": "儲存路徑無效。請選擇其他資料夾後再試一次。",
        "path_too_long": "檔案名稱或儲存路徑過長。請選擇較短的資料夾或標題後再試一次。",
        "antivirus_blocked": "防毒軟體封鎖了內附工具或下載檔案。請確認防毒軟體允許此 App 後再試一次。",
        "download_failed": "下載失敗。請查看診斷記錄，或重新解析影片後再試一次。",
        "selection_invalid": "網址或可下載格式已變動，請重新解析影片後再下載。", "merging": "正在合併影音，請稍候…",
        "analyze_failed": "影片解析失敗", "speed": "速度:", "size": "檔案大小:",
    },
    "en": {
        "title": "YouTube Downloader Pro", "video_title": "Video Title:", "analyze": "Analyze",
        "analyzing": "Analyzing...", "quality": "Select Quality:", "audio_track": "Select Audio Track:",
        "audio_only": "Audio Only (MP3)", "change_path": "Change Save Path", "save_to": "Save to:",
        "start_download": "Download Now", "pause": "Pause", "resume": "Resume", "cancel": "Cancel",
        "success": "Download Finished!", "cancelled": "Cancelled and temp files cleared", "about": "About",
        "update_check": "Check Update", "is_latest": "Already up to date",
        "manual_update": "Current version is v{version}. Please use the official release page for updates.",
        "update_available": "Version v{latest} is available. Open the download page?", "update_failed": "Unable to check for updates: {error}",
        "tool_missing": "Bundled tool not found: {tool}", "tool_unavailable_title": "Bundled converter unavailable",
        "tool_unavailable": "The bundled converter cannot run on this computer.\n\nTool: {tool}\nPath: {path}\nReason: {detail}\n\nPlease download the complete application again or contact the developer for an updated build.",
        "tool_validation_failed": "Bundled helper validation failed, so analysis and downloads are disabled. Download the complete application again or contact the developer.\n\nDiagnostic log: {log_path}",
        "tool_ytdlp_error": "The bundled converter could not be used by the download engine, so video/audio merging or MP3 conversion cannot continue.\n\nPlease download the complete application again or contact the developer for an updated build.",
        "format_unavailable": "The YouTube format list changed, or the selected format is no longer available.\n\nAnalyze the video again before downloading. If it still fails, choose another video or audio format.",
        "certificate_error": "The secure certificate check failed. Verify the computer's date and time, then update or reinstall the app.",
        "network_error": "YouTube cannot be reached right now. Check the network connection and try again.",
        "youtube_bot_check": "YouTube temporarily requires a sign-in verification. The video URL and converter are not at fault. Sign in to YouTube in your browser and analyze again later. If this continues, restart the app or contact the developer.",
        "permission_error": "The selected folder cannot be written. Choose another location or allow access in System Settings.",
        "content_unavailable": "This video is unavailable for download. It may have been removed, made private, or restricted in your region.",
        "disk_full": "The selected drive is full. Free up disk space and try again.", "invalid_path": "The selected save path is invalid. Choose another folder and try again.",
        "path_too_long": "The file name or save path is too long. Choose a shorter folder or title and try again.",
        "antivirus_blocked": "Antivirus software blocked a bundled helper or download file. Allow this app, then try again.",
        "download_failed": "The download failed. Review the diagnostic log, then analyze the video and try again.",
        "selection_invalid": "The URL or available formats changed. Analyze the video again before downloading.", "merging": "Merging video and audio. Please wait…",
        "analyze_failed": "Video analysis failed", "speed": "Speed:", "size": "Size:",
    },
    "ja": {
        "title": "YouTube ダウンローダー Pro", "video_title": "動画のタイトル:", "analyze": "解析する",
        "analyzing": "解析中...", "quality": "画質を選択:", "audio_track": "音軌を選択:",
        "audio_only": "音聲を抽出 (MP3轉換)", "change_path": "保存先を変更", "save_to": "保存先:",
        "start_download": "ダウンロード開始", "pause": "一時停止", "resume": "再開", "cancel": "キャンセル",
        "success": "完了しました！", "cancelled": "キャンセルされ、ファイルが削除されました", "about": "このアプリについて",
        "update_check": "アップデートを確認", "is_latest": "最新バージョンです",
        "manual_update": "現在のバージョンは v{version} です。公式リリースページから更新してください。",
        "update_available": "新しいバージョン v{latest} があります。ダウンロードページを開きますか？", "update_failed": "アップデートを確認できません：{error}",
        "tool_missing": "同梱ツールが見つかりません: {tool}", "tool_unavailable_title": "内蔵変換ツールを使用できません",
        "tool_unavailable": "内蔵変換ツールをこのコンピューターで実行できません。\n\nツール: {tool}\n場所: {path}\n理由: {detail}\n\n完全なアプリケーションを再ダウンロードするか、開発者に新版を依頼してください。",
        "tool_validation_failed": "内蔵ツールの検証に失敗したため、解析とダウンロードを無効にしました。完全なアプリケーションを再ダウンロードするか、開発者に連絡してください。\n\n診断ログ：{log_path}",
        "tool_ytdlp_error": "内蔵変換ツールをダウンロードエンジンが使用できないため、動画と音声の結合または MP3 変換を続行できません。\n\n完全なアプリケーションを再ダウンロードするか、開発者に新版を依頼してください。",
        "format_unavailable": "YouTube の形式リストが変更されたか、選択した形式を利用できなくなりました。\n\n動画を再解析してから再度ダウンロードしてください。まだ失敗する場合は、別の画質または音声を選択してください。",
        "certificate_error": "安全な証明書を確認できませんでした。コンピューターの日付と時刻を確認し、App を更新または再インストールしてください。",
        "network_error": "現在 YouTube に接続できません。ネットワーク接続を確認して、もう一度お試しください。",
        "youtube_bot_check": "YouTube が一時的にログイン確認を求めています。動画 URL や変換ツールの故障ではありません。ブラウザで YouTube にログインし、しばらくしてから再解析してください。続く場合は App を再起動するか、開発者に連絡してください。",
        "permission_error": "選択したフォルダに書き込む権限がありません。別の保存先を選ぶか、システム設定でアクセスを許可してください。",
        "content_unavailable": "この動画はダウンロードできません。削除、非公開、または地域制限されている可能性があります。",
        "disk_full": "保存先の空き容量が不足しています。空き容量を確保してから、もう一度お試しください。",
        "invalid_path": "保存先のパスが無効です。別のフォルダーを選択して、もう一度お試しください。",
        "path_too_long": "ファイル名または保存先のパスが長すぎます。短いフォルダー名またはタイトルを選択してください。",
        "antivirus_blocked": "ウイルス対策ソフトが同梱ツールまたはダウンロードファイルをブロックしました。この App を許可してから、もう一度お試しください。",
        "download_failed": "ダウンロードに失敗しました。診断ログを確認し、動画を再解析してからもう一度お試しください。",
        "selection_invalid": "URL または利用可能な形式が変更されました。動画を再解析してからダウンロードしてください。", "merging": "動画と音声を結合しています。しばらくお待ちください…",
        "analyze_failed": "動画の解析に失敗しました", "speed": "速度:", "size": "サイズ:",
    },
}


_SENSITIVE_KEY = (
    r"cookies?|authorization|access[-_]?token|api[-_]?key|signature|sig|"
    r"credential|secret|session[-_]?token|token|password"
)
_SENSITIVE_HEADER_VALUE = re.compile(
    r"(?im)^(\s*(?:cookies?|authorization)\s*[:=]\s*)([^\r\n]*)"
)
_SENSITIVE_KEY_VALUE = re.compile(
    rf"(?i)(\b(?:{_SENSITIVE_KEY})\b\s*[:=]\s*)"
    r"(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
)
_BEARER_VALUE = re.compile(
    r"(?i)\bbearer\s+(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
)


def _redact_diagnostic_details(error):
    value = str(error)
    value = _SENSITIVE_HEADER_VALUE.sub(r"\1[REDACTED]", value)
    value = _SENSITIVE_KEY_VALUE.sub(r"\1[REDACTED]", value)
    return _BEARER_VALUE.sub("Bearer [REDACTED]", value)


def _write_diagnostic(error, log_path):
    if not log_path:
        return
    try:
        destination = Path(log_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("a", encoding="utf-8") as handle:
            handle.write(f"{_redact_diagnostic_details(error)}\n")
    except OSError:
        pass


def clean_download_error(error, language, log_path=None):
    """Return a localized safe error while retaining raw details only in logs."""
    _write_diagnostic(error, log_path)
    text = LANG_DATA.get(language, LANG_DATA["en"])
    message = str(error)
    lowered = message.lower()
    if isinstance(error, PermissionError) or "permission denied" in lowered or "access is denied" in lowered:
        return text["permission_error"]
    if isinstance(error, FileNotFoundError):
        return text["invalid_path"]
    if "sign in to confirm you" in lowered and "not a bot" in lowered:
        return text["youtube_bot_check"]
    if "certificate_verify_failed" in lowered or "certificate verify failed" in lowered:
        return text["certificate_error"]
    if any(value in lowered for value in ("no space left", "disk full", "winerror 112")):
        return text["disk_full"]
    if any(value in lowered for value in ("path too long", "filename or extension is too long", "winerror 206")):
        return text["path_too_long"]
    if any(value in lowered for value in ("file contains a virus", "antivirus", "winerror 225")):
        return text["antivirus_blocked"]
    if any(value in lowered for value in ("invalid argument", "invalid path", "filename, directory name, or volume label syntax")):
        return text["invalid_path"]
    if any(value in lowered for value in ("video unavailable", "video is unavailable", "private video", "not available in your country", "this live event will begin")):
        return text["content_unavailable"]
    if "requested format is not available" in lowered or "requested format not available" in lowered:
        return text["format_unavailable"]
    if any(value in lowered for value in ("ffmpeg", "ffprobe", "quickjs", "deno", "requested merging of multiple formats")):
        return text["tool_ytdlp_error"]
    if any(value in lowered for value in ("network is unreachable", "name or service not known", "temporary failure in name resolution", "timed out", "connection reset", "connection refused", "connection aborted")):
        return text["network_error"]
    return text["download_failed"]
