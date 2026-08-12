# YT Downloader Pro

YT Downloader Pro 是一款給 macOS 使用的單影片 YouTube 下載工具，由 Ta-Chou Weng 維護。目前正式版本 `1.8.7` 是 Python/Tkinter 安全修補版，主要支援 Apple Silicon Mac。

## 功能

- 解析單支 YouTube 影片並選擇可用畫質與音軌。
- 下載並合併為 MP4，預設選單會優先列出較高畫質與音質。
- 擷取音訊並轉換為 192 kbps MP3。
- 同名檔案不覆寫，依序使用 `名稱 (1)`、`名稱 (2)`。
- 記住上次選擇的下載資料夾。
- 下載期間顯示進度、速度與檔案大小。
- 下載階段可暫停、繼續或取消；取消只清理該次任務新建立的檔案。
- 內建 FFmpeg/FFprobe/QuickJS 啟動檢查與 GitHub 新版本提示。

## 系統需求

- Apple Silicon Mac（M1 或更新處理器）。
- macOS 11.0 或更新版本。
- 可連線至 YouTube 的網路環境。
- 不需要另外安裝 Homebrew、FFmpeg 或 Python。

Intel Mac、Windows 與 Linux 不屬於目前 `1.8.x` App 的支援範圍。Windows 版本會另外開發，不會共用這個 macOS 安裝檔。

## 安裝與開啟

1. 前往 [GitHub Releases](https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest) 下載最新的 macOS 壓縮檔。
2. 解壓縮後，將 `YT Downloader Pro.app` 移到「應用程式」資料夾。
3. 第一次開啟若 macOS 顯示安全提示，請在 Finder 對 App 按右鍵並選擇「打開」，再確認一次。
4. 貼上影片網址、按 Enter 或「解析影片」，選擇格式及儲存位置後開始下載。

請只從本專案的 Releases 頁取得安裝檔。目前最新公開版本為 `1.8.7`。

## 已知限制

- `1.8.7` 一次處理一支影片，不支援播放清單與多網址佇列。
- 暫停只在 yt-dlp 回報下載進度時生效；進入 FFmpeg 合併或 MP3 轉換後不能暫停或取消。
- DRM、付費、私人、會員限定、地區限制或需要登入驗證的影片不保證可下載。
- YouTube 隨時可能調整格式或驗證方式；遇到格式錯誤時請先重新解析並確認是否已有新版。
- 使用者必須確認自己有權下載內容，並遵守 YouTube 條款及所在地法律。

## 問題排除

- **解析失敗**：檢查網址與網路後重新解析，並確認系統日期時間正確。
- **內建轉檔工具無法使用**：重新下載完整 App，不要單獨移動 App 內的檔案。
- **無法儲存**：改選「下載項目」或其他有寫入權限的資料夾。
- **格式已變動**：重新解析影片，再選擇新的畫質與音軌。

## 問題回報

請在 GitHub Issues 提供下列資料，避免上傳帳號、Cookie 或其他私人資訊：

- App 完整版本，例如 `1.8.7`。
- Mac 型號與處理器，例如 MacBook Air M5。
- macOS 版本。
- 發生問題的 YouTube 網址。
- 完整錯誤文字或截圖。
- 問題發生在解析、MP4、MP3、暫停、取消或合併的哪個階段。

## 版本與原始碼

- `v1.8.0-original`：維護前的原始版本。
- `v1.8.3`：記住上次下載資料夾。
- `v1.8.4`：加入 Apple Silicon 工具與啟動檢查。
- `v1.8.5`：修正不可合併的 HLS 格式選擇。
- `v1.8.6`：加入 GitHub Contents API 更新檢查。
- `v1.8.7`：改善 Apple Silicon 相容性、下載安全性、錯誤訊息與完整尺寸 App 圖示。
- `YT_downloader_187.py`：`1.8.7` 對應的版本化原始碼。
- `develop/v2.0-swift`：原生 SwiftUI 下載中心開發線。

每個 Python 版本保留獨立檔名，方便比較與回復。公開發布時才會同步更新 `version.txt` 並建立相同版本的 Git tag。

## 開發與建置

```bash
python3 -m venv .venv-1.8.7
.venv-1.8.7/bin/python -m pip install -r requirements.txt
.venv-1.8.7/bin/python -m unittest discover -s tests -v
PATH="$PWD/.venv-1.8.7/bin:$PATH" ./scripts/build_1_8_7.sh
```

建置腳本會把唯一一組 `ffmpeg` 與 `ffprobe` 放入 `Contents/Helpers/`，設定 App 版本資訊並執行 arm64、工具版本、授權設定與簽章檢查。

## 第三方工具與授權

下載核心使用 [yt-dlp](https://github.com/yt-dlp/yt-dlp)，影音合併與 MP3 轉換使用 [FFmpeg](https://ffmpeg.org/)，YouTube JavaScript challenge 使用 [QuickJS](https://bellard.org/quickjs/)。完整來源與建置資訊記錄於 `THIRD_PARTY_NOTICES.md` 及對應工具說明。

本專案不授予下載第三方影音內容的權利。請只下載自己擁有、已獲授權，或法律允許保存的內容。
